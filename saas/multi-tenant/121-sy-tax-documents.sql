-- 121: Syrian tax document classification. No statutory rate or recoverable input credit is assumed.
begin;
create table tenant_private.sy_tax_profiles(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null,label text not null check(length(btrim(label)) between 1 and 120),
 regime text not null check(regime in ('consumption_expenditure','sales_tax','exempt','outside_scope')),
 rate_bps integer not null check(rate_bps between 0 and 10000),effective_from date not null,effective_to date,
 legal_reference text not null check(length(btrim(legal_reference)) between 1 and 200),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),check(effective_to is null or effective_to>=effective_from),
 check((regime in ('exempt','outside_scope') and rate_bps=0) or (regime in ('consumption_expenditure','sales_tax') and rate_bps>0))
);
create table tenant_private.sy_tax_output(
 store_id uuid not null,entry_id uuid not null,profile_id uuid not null,request_id uuid not null,
 document_ref text not null check(length(btrim(document_ref)) between 1 and 160),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,entry_id),unique(store_id,request_id),
 foreign key(store_id,entry_id) references public.mt_indirect_tax_entries(store_id,id),foreign key(store_id,profile_id) references tenant_private.sy_tax_profiles(store_id,id)
);
create table tenant_private.sy_tax_input_events(
 store_id uuid not null references tenant_private.workspaces(store_id),request_id uuid not null,
 kind text not null check(kind in ('purchase','supplier_return')),source_id uuid not null,invoice_id uuid not null,currency text not null,
 tax_minor bigint not null check(tax_minor between 0 and 100000000000000),
 treatment text not null check(treatment in ('not_applicable','nonrecoverable_in_cost','pending_review','potential_credit')),
 document_ref text not null check(length(btrim(document_ref)) between 1 and 160),legal_reference text not null check(length(btrim(legal_reference)) between 1 and 200),
 previous uuid,actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,request_id),
 foreign key(store_id,previous) references tenant_private.sy_tax_input_events(store_id,request_id),
 check((treatment='not_applicable' and tax_minor=0) or treatment='pending_review' or (treatment in ('nonrecoverable_in_cost','potential_credit') and tax_minor>0))
);
create index sy_tax_input_source on tenant_private.sy_tax_input_events(store_id,kind,source_id,created_at desc,request_id);
alter table tenant_private.sy_tax_profiles enable row level security;
alter table tenant_private.sy_tax_output enable row level security;
alter table tenant_private.sy_tax_input_events enable row level security;
revoke all on tenant_private.sy_tax_profiles,tenant_private.sy_tax_output,tenant_private.sy_tax_input_events from public,anon,authenticated;

create function tenant_private.sy_tax_documents(s uuid)
returns table(kind text,source_id uuid,invoice_id uuid,branch_id uuid,currency text,gross_minor bigint,occurred_at timestamptz)
language sql stable security definer set search_path='' as $$
 select 'sale',v.id,v.id,b.branch_id,v.currency,v.total_minor,v.created_at from public.mt_sales v left join tenant_private.branch_sales b on b.store_id=v.store_id and b.sale_id=v.id where v.store_id=s
 union all select 'repair',i.id,i.id,b.branch_id,i.currency,i.total_minor,i.created_at from public.mt_repair_invoices i left join tenant_private.branch_repairs b on b.store_id=i.store_id and b.repair_id=i.repair_id where i.store_id=s
 union all select 'sale_return',r.id,r.sale_id,b.branch_id,r.currency,r.total_minor,r.created_at from public.mt_returns r left join tenant_private.branch_sales b on b.store_id=r.store_id and b.sale_id=r.sale_id where r.store_id=s
 union all select 'repair_refund',r.id,r.invoice_id,b.branch_id,r.currency,r.amount_minor,r.created_at from public.mt_repair_refunds r join public.mt_repair_invoices i on i.store_id=r.store_id and i.id=r.invoice_id left join tenant_private.branch_repairs b on b.store_id=i.store_id and b.repair_id=i.repair_id where r.store_id=s
 union all select 'purchase',p.id,p.id,b.branch_id,p.currency,p.total_minor,p.created_at from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=s
 union all select 'supplier_return',r.id,r.purchase_id,b.branch_id,r.currency,(r.units*r.unit_cost_minor)::bigint,r.created_at from public.mt_supplier_returns r left join tenant_private.branch_purchases b on b.store_id=r.store_id and b.purchase_id=r.purchase_id where r.store_id=s
$$;
revoke all on function tenant_private.sy_tax_documents(uuid) from public,anon,authenticated;
create function tenant_private.sy_tax_input_current(s uuid)
returns setof tenant_private.sy_tax_input_events language sql stable security definer set search_path='' as $$
 select distinct on(kind,source_id) * from tenant_private.sy_tax_input_events where store_id=s order by kind,source_id,created_at desc,request_id desc
$$;
revoke all on function tenant_private.sy_tax_input_current(uuid) from public,anon,authenticated;

create function tenant_private.sy_tax_profile_add(s uuid,req uuid,label text,regime text,rate integer,valid_from date,valid_to date,legal text)
returns uuid language plpgsql security definer set search_path='' as $$
declare old tenant_private.sy_tax_profiles%rowtype;
begin
 perform tenant_private.owner_write(s);
 if req is null or label is null or length(btrim(label)) not between 1 and 120 or regime is null or regime not in ('consumption_expenditure','sales_tax','exempt','outside_scope') or rate is null or rate not between 0 and 10000 or (regime in ('exempt','outside_scope'))<>(rate=0) or valid_from is null or (valid_to is not null and valid_to<valid_from) or legal is null or length(btrim(legal)) not between 1 and 200 then raise exception 'Tax profile requires an effective date and verified legal reference' using errcode='22023';end if;
 select * into old from tenant_private.sy_tax_profiles where store_id=s and id=req;
 if found then
  if old.actor<>auth.uid() or old.label<>btrim(label) or old.regime<>regime or old.rate_bps<>rate or old.effective_from<>valid_from or old.effective_to is distinct from valid_to or old.legal_reference<>btrim(legal) then raise exception 'Conflicting tax profile' using errcode='22023';end if;return req;
 end if;
 if (select count(*) from tenant_private.sy_tax_profiles where store_id=s)>=200 then raise exception 'Tax profile capacity reached' using errcode='22023';end if;
 insert into tenant_private.sy_tax_profiles(store_id,id,label,regime,rate_bps,effective_from,effective_to,legal_reference,actor) values(s,req,btrim(label),regime,rate,valid_from,valid_to,btrim(legal),auth.uid());return req;
end $$;
create function tenant_private.sy_tax_profile_list(s uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by effective_from desc,id) from (select id,label,regime,rate_bps,effective_from,effective_to,legal_reference from tenant_private.sy_tax_profiles where store_id=s)x),'[]'::jsonb);
end $$;

create function tenant_private.sy_tax_output_preview(s uuid,k text,source uuid,profile uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d record;p tenant_private.sy_tax_profiles%rowtype;e public.mt_indirect_tax_entries%rowtype;original_profile uuid;q jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if k is null or k not in ('sale','repair','sale_return','repair_refund') or source is null then raise exception 'Invalid output source' using errcode='22023';end if;
 select * into d from tenant_private.sy_tax_documents(s) x where x.kind=k and x.source_id=source;
 if not found then raise exception 'Unknown source' using errcode='22023';end if;
 if k in ('sale_return','repair_refund') then
  select o.profile_id into original_profile from tenant_private.sy_tax_output o join public.mt_indirect_tax_entries e0 on e0.store_id=o.store_id and e0.id=o.entry_id where o.store_id=s and e0.kind=case when k='sale_return' then 'sale' else 'repair' end and e0.source_id=d.invoice_id;
  if original_profile is null or (profile is not null and profile<>original_profile) then raise exception 'Classify original invoice using a verified profile first' using errcode='22023';end if;
  profile:=original_profile;
 end if;
 select * into p from tenant_private.sy_tax_profiles where store_id=s and id=profile;
 if not found or (k in ('sale','repair') and ((d.occurred_at at time zone 'Asia/Damascus')::date<p.effective_from or (p.effective_to is not null and (d.occurred_at at time zone 'Asia/Damascus')::date>p.effective_to))) then raise exception 'Tax profile is not effective for this invoice' using errcode='22023';end if;
 select * into e from public.mt_indirect_tax_entries where store_id=s and kind=k and source_id=source;
 if found then
  if e.rate_bps<>p.rate_bps or e.currency<>d.currency or e.gross_minor<>d.gross_minor then raise exception 'Existing tax record differs from selected legal profile; accountant correction required' using errcode='22023';end if;
  if exists(select 1 from tenant_private.sy_tax_output where store_id=s and entry_id=e.id and profile_id<>profile) then raise exception 'Document already classified under another profile' using errcode='22023';end if;
  q:=jsonb_build_object('kind',k,'source_id',source,'invoice_id',d.invoice_id,'currency',d.currency,'gross_minor',d.gross_minor,'rate_bps',e.rate_bps,'tax_minor',e.tax_minor);
 else
  q:=tenant_private.indirect_tax_quote(s,k,source,case when k in ('sale','repair') then p.rate_bps else null end);
 end if;
 return q||jsonb_build_object('profile_id',p.id,'profile_label',p.label,'regime',p.regime,'legal_reference',p.legal_reference,'already_posted',e.id is not null,'entry_id',e.id);
end $$;

create function tenant_private.sy_tax_output_record(s uuid,req uuid,k text,source uuid,profile uuid,expected bigint,proof text)
returns uuid language plpgsql security definer set search_path='' as $$
declare old tenant_private.sy_tax_output%rowtype;e public.mt_indirect_tax_entries%rowtype;q jsonb;eid uuid;pid uuid;
begin
 perform tenant_private.owner_write(s);
 if req is null or expected is null or expected not between 0 and 100000000000000 or proof is null or length(btrim(proof)) not between 1 and 160 then raise exception 'Confirm tax calculation and document reference' using errcode='22023';end if;
 select * into old from tenant_private.sy_tax_output where store_id=s and request_id=req;
 if found then
  select * into strict e from public.mt_indirect_tax_entries where store_id=s and id=old.entry_id;
  if old.actor<>auth.uid() or old.document_ref<>btrim(proof) or e.kind is distinct from k or e.source_id is distinct from source or e.tax_minor<>expected or (profile is not null and old.profile_id<>profile) then raise exception 'Conflicting tax classification' using errcode='22023';end if;return old.entry_id;
 end if;
 q:=tenant_private.sy_tax_output_preview(s,k,source,profile);
 if (q->>'tax_minor')::bigint<>expected then raise exception 'Tax preview changed' using errcode='22023';end if;
 pid:=(q->>'profile_id')::uuid;
 eid:=(q->>'entry_id')::uuid;
 if eid is not null and exists(select 1 from tenant_private.sy_tax_output where store_id=s and entry_id=eid) then raise exception 'Document already classified' using errcode='22023';end if;
 if eid is null then eid:=tenant_private.record_indirect_tax(s,req,k,source,case when k in ('sale','repair') then (q->>'rate_bps')::integer else null end,expected,btrim(proof),left('Syrian tax profile: '||(q->>'profile_label'),300));end if;
 insert into tenant_private.sy_tax_output(store_id,entry_id,profile_id,request_id,document_ref,actor) values(s,eid,pid,req,btrim(proof),auth.uid());return eid;
end $$;

create function tenant_private.sy_tax_input_record(s uuid,req uuid,k text,source uuid,expected_previous uuid,amount bigint,treatment text,proof text,legal text)
returns uuid language plpgsql security definer set search_path='' as $$
declare d record;old tenant_private.sy_tax_input_events%rowtype;current_row tenant_private.sy_tax_input_events%rowtype;original tenant_private.sy_tax_input_events%rowtype;other_returns numeric;
begin
 perform tenant_private.owner_write(s);
 if req is null or source is null or k is null or k not in ('purchase','supplier_return') or amount is null or amount not between 0 and 100000000000000 or treatment is null or treatment not in ('not_applicable','nonrecoverable_in_cost','pending_review','potential_credit') or (treatment='not_applicable' and amount<>0) or (treatment in ('nonrecoverable_in_cost','potential_credit') and amount=0) or proof is null or length(btrim(proof)) not between 1 and 160 or legal is null or length(btrim(legal)) not between 1 and 200 then raise exception 'Invalid input tax documentation' using errcode='22023';end if;
 select * into old from tenant_private.sy_tax_input_events where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.kind<>k or old.source_id<>source or old.previous is distinct from expected_previous or old.tax_minor<>amount or old.treatment<>treatment or old.document_ref<>btrim(proof) or old.legal_reference<>btrim(legal) then raise exception 'Conflicting input tax request' using errcode='22023';end if;return req;
 end if;
 select * into d from tenant_private.sy_tax_documents(s) x where x.kind=k and x.source_id=source;
 if not found or amount>d.gross_minor then raise exception 'Input amount exceeds recorded document' using errcode='22023';end if;
 select * into current_row from tenant_private.sy_tax_input_current(s) x where x.kind=k and x.source_id=source;
 if current_row.request_id is distinct from expected_previous then raise exception 'Input review changed; reload' using errcode='22023';end if;
 select coalesce(sum(x.tax_minor),0) into other_returns from tenant_private.sy_tax_input_current(s) x where x.kind='supplier_return' and x.invoice_id=d.invoice_id and (k='purchase' or x.source_id<>source);
 if k='purchase' then
  if amount<other_returns then raise exception 'Input reversal exceeds revised purchase tax' using errcode='22023';end if;
 else
  select * into original from tenant_private.sy_tax_input_current(s) x where x.kind='purchase' and x.source_id=d.invoice_id;
  if not found or amount+other_returns>original.tax_minor then raise exception 'Document original purchase first; reversal cannot exceed purchase tax' using errcode='22023';end if;
  if original.treatment in ('pending_review','potential_credit') and treatment not in ('pending_review','potential_credit') then raise exception 'Resolve purchase tax treatment first' using errcode='22023';end if;
 end if;
 insert into tenant_private.sy_tax_input_events(store_id,request_id,kind,source_id,invoice_id,currency,tax_minor,treatment,document_ref,legal_reference,previous,actor) values(s,req,k,source,d.invoice_id,d.currency,amount,treatment,btrim(proof),btrim(legal),expected_previous,auth.uid());
 return req;
end $$;

create function tenant_private.sy_tax_queue(s uuid,d1 date,d2 date,filter_kind text,missing_only boolean,off integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare data jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if d1 is null or d2 is null or d2<d1 or d2-d1>365 or d2>(now() at time zone 'Asia/Damascus')::date or filter_kind is null or filter_kind not in ('all','sale','repair','sale_return','repair_refund','purchase','supplier_return') or missing_only is null or off is null or off not between 0 and 100000 then raise exception 'Invalid tax period' using errcode='22023';end if;
 with docs as (
 select d.*,coalesce(b.name,'') branch_name,e.id entry_id,o.profile_id,p.label profile_label,e.tax_minor output_tax,e.created_at tax_posted_at,
 inp.request_id input_revision,inp.tax_minor input_tax,inp.treatment,inp.document_ref input_document_ref,inp.legal_reference input_legal_reference,
 case when d.kind in ('purchase','supplier_return') then inp.request_id is null or inp.treatment in ('pending_review','potential_credit') else o.profile_id is null end unresolved
 from tenant_private.sy_tax_documents(s) d left join tenant_private.branches b on b.store_id=s and b.id=d.branch_id
 left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id left join tenant_private.sy_tax_profiles p on p.store_id=s and p.id=o.profile_id
 left join tenant_private.sy_tax_input_current(s) inp on inp.kind=d.kind and inp.source_id=d.source_id
 where d.occurred_at>=d1::timestamp at time zone 'Asia/Damascus' and d.occurred_at<(d2+1)::timestamp at time zone 'Asia/Damascus' and (filter_kind='all' or d.kind=filter_kind)
 ),page as (select * from docs where not missing_only or unresolved order by occurred_at desc,kind,source_id offset off limit 51)
 select coalesce(jsonb_agg(to_jsonb(page) order by occurred_at desc,kind,source_id),'[]'::jsonb) into data from page;
 return jsonb_build_object('rows',case when jsonb_array_length(data)>50 then data-50 else data end,'more',jsonb_array_length(data)>50);
end $$;

-- Internal period readiness. Input documents are evidence only, never automatic VAT offsets.
create function tenant_private.sy_tax_period_review(s uuid,d1 date,d2 date)
returns jsonb language sql stable security definer set search_path='' as $$
 with docs as (
 select d.*,e.id entry_id,e.tax_minor,e.created_at posted,o.profile_id,i.request_id input_id,i.treatment
 from tenant_private.sy_tax_documents(s) d left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id left join tenant_private.sy_tax_input_current(s) i on i.kind=d.kind and i.source_id=d.source_id
 where d.occurred_at>=d1::timestamp at time zone 'Asia/Damascus' and d.occurred_at<(d2+1)::timestamp at time zone 'Asia/Damascus'
 )
 select jsonb_build_object('output_unclassified',count(*) filter(where kind not in ('purchase','supplier_return') and profile_id is null),
 'input_unclassified',count(*) filter(where kind in ('purchase','supplier_return') and (input_id is null or treatment in ('pending_review','potential_credit'))),
 'late_output_postings',count(*) filter(where tax_minor>0 and (posted<d1::timestamp at time zone 'Asia/Damascus' or posted>=(d2+1)::timestamp at time zone 'Asia/Damascus'))+
 (select count(*) from public.mt_indirect_tax_entries e join tenant_private.sy_tax_documents(s) d on d.kind=e.kind and d.source_id=e.source_id where e.store_id=s and e.tax_minor>0 and e.created_at>=d1::timestamp at time zone 'Asia/Damascus' and e.created_at<(d2+1)::timestamp at time zone 'Asia/Damascus' and (d.occurred_at<d1::timestamp at time zone 'Asia/Damascus' or d.occurred_at>=(d2+1)::timestamp at time zone 'Asia/Damascus')),
 'input_credit_posting_enabled',false) from docs
$$;
revoke all on function tenant_private.sy_tax_period_review(uuid,date,date) from public,anon,authenticated;

create function public.mt_sy_tax_profile_add(s uuid,req uuid,label text,regime text,rate integer,valid_from date,valid_to date,legal text) returns uuid language sql set search_path='' as $$select tenant_private.sy_tax_profile_add(s,req,label,regime,rate,valid_from,valid_to,legal)$$;
create function public.mt_sy_tax_profile_list(s uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.sy_tax_profile_list(s)$$;
create function public.mt_sy_tax_output_preview(s uuid,k text,source uuid,profile uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.sy_tax_output_preview(s,k,source,profile)$$;
create function public.mt_sy_tax_output_record(s uuid,req uuid,k text,source uuid,profile uuid,expected bigint,proof text) returns uuid language sql set search_path='' as $$select tenant_private.sy_tax_output_record(s,req,k,source,profile,expected,proof)$$;
create function public.mt_sy_tax_input_record(s uuid,req uuid,k text,source uuid,expected_previous uuid,amount bigint,treatment text,proof text,legal text) returns uuid language sql set search_path='' as $$select tenant_private.sy_tax_input_record(s,req,k,source,expected_previous,amount,treatment,proof,legal)$$;
create function public.mt_sy_tax_queue(s uuid,d1 date,d2 date,filter_kind text,missing_only boolean,off integer) returns jsonb language sql stable set search_path='' as $$select tenant_private.sy_tax_queue(s,d1,d2,filter_kind,missing_only,off)$$;
revoke all on function tenant_private.sy_tax_profile_add(uuid,uuid,text,text,integer,date,date,text),public.mt_sy_tax_profile_add(uuid,uuid,text,text,integer,date,date,text) from public,anon,authenticated;
grant execute on function tenant_private.sy_tax_profile_add(uuid,uuid,text,text,integer,date,date,text),public.mt_sy_tax_profile_add(uuid,uuid,text,text,integer,date,date,text) to authenticated;
revoke all on function tenant_private.sy_tax_profile_list(uuid),public.mt_sy_tax_profile_list(uuid) from public,anon,authenticated;
grant execute on function tenant_private.sy_tax_profile_list(uuid),public.mt_sy_tax_profile_list(uuid) to authenticated;
revoke all on function tenant_private.sy_tax_output_preview(uuid,text,uuid,uuid),public.mt_sy_tax_output_preview(uuid,text,uuid,uuid) from public,anon,authenticated;
grant execute on function tenant_private.sy_tax_output_preview(uuid,text,uuid,uuid),public.mt_sy_tax_output_preview(uuid,text,uuid,uuid) to authenticated;
revoke all on function tenant_private.sy_tax_output_record(uuid,uuid,text,uuid,uuid,bigint,text),public.mt_sy_tax_output_record(uuid,uuid,text,uuid,uuid,bigint,text) from public,anon,authenticated;
grant execute on function tenant_private.sy_tax_output_record(uuid,uuid,text,uuid,uuid,bigint,text),public.mt_sy_tax_output_record(uuid,uuid,text,uuid,uuid,bigint,text) to authenticated;
revoke all on function tenant_private.sy_tax_input_record(uuid,uuid,text,uuid,uuid,bigint,text,text,text),public.mt_sy_tax_input_record(uuid,uuid,text,uuid,uuid,bigint,text,text,text) from public,anon,authenticated;
grant execute on function tenant_private.sy_tax_input_record(uuid,uuid,text,uuid,uuid,bigint,text,text,text),public.mt_sy_tax_input_record(uuid,uuid,text,uuid,uuid,bigint,text,text,text) to authenticated;
revoke all on function tenant_private.sy_tax_queue(uuid,date,date,text,boolean,integer),public.mt_sy_tax_queue(uuid,date,date,text,boolean,integer) from public,anon,authenticated;
grant execute on function tenant_private.sy_tax_queue(uuid,date,date,text,boolean,integer),public.mt_sy_tax_queue(uuid,date,date,text,boolean,integer) to authenticated;
commit;
