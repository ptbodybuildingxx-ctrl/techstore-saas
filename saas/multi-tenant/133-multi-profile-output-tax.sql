-- 133: documented tax-inclusive multi-profile allocations using the existing output tax journal.
begin;
-- NULL means no single invoice-wide rate; every mixed entry has private immutable allocations.
alter table public.mt_indirect_tax_entries alter column rate_bps drop not null;
create table tenant_private.sy_tax_mixed_parts(
 store_id uuid not null,entry_id uuid not null,profile_id uuid not null,
 gross_minor bigint not null check(gross_minor between 1 and 100000000000000),
 tax_minor bigint not null check(tax_minor between 0 and gross_minor),
 primary key(store_id,entry_id,profile_id),
 foreign key(store_id,entry_id) references public.mt_indirect_tax_entries(store_id,id),
 foreign key(store_id,profile_id) references tenant_private.sy_tax_profiles(store_id,id)
);
alter table tenant_private.sy_tax_mixed_parts enable row level security;
revoke all on tenant_private.sy_tax_mixed_parts from public,anon,authenticated,service_role;

create function tenant_private.sy_tax_mixed_quote(p_store uuid,p_kind text,p_source uuid,p_parts jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d record; p tenant_private.sy_tax_profiles%rowtype; original public.mt_indirect_tax_entries%rowtype;
 a tenant_private.sy_tax_mixed_parts%rowtype; item jsonb; pid uuid; g bigint; tax bigint;
 prev_gross numeric;prev_tax numeric; total_gross numeric:=0;total_tax numeric:=0;
 parts jsonb:='[]'::jsonb; result jsonb; seen uuid[]:='{}'; is_return boolean;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_source is null or p_kind is null or p_kind not in ('sale','repair','sale_return','repair_refund') or jsonb_typeof(p_parts) is distinct from 'array' then raise exception 'Invalid mixed tax document' using errcode='22023';end if;
 is_return:=p_kind in ('sale_return','repair_refund');
 if jsonb_array_length(p_parts) not between (case when is_return then 1 else 2 end) and 30 then raise exception 'Invalid allocation count' using errcode='22023';end if;
 select * into d from tenant_private.sy_tax_documents(p_store) x where x.kind=p_kind and x.source_id=p_source;
 if not found or d.gross_minor<=0 or exists(select 1 from public.mt_indirect_tax_entries e where e.store_id=p_store and e.kind=p_kind and e.source_id=p_source) then raise exception 'Unknown or already classified document' using errcode='22023';end if;
 if is_return then
  select * into original from public.mt_indirect_tax_entries e where e.store_id=p_store and e.kind=case p_kind when 'sale_return' then 'sale' else 'repair' end and e.source_id=d.invoice_id;
  if not found or original.rate_bps is not null or original.currency<>d.currency then raise exception 'Original multi-profile invoice required' using errcode='22023';end if;
 end if;
 for item in select value from jsonb_array_elements(p_parts) order by value->>'profile_id' loop
  if jsonb_typeof(item) is distinct from 'object' or coalesce(item->>'profile_id','') !~ '^[0-9a-fA-F-]{36}$' or coalesce(item->>'gross_minor','') !~ '^[0-9]{1,15}$' then raise exception 'Invalid allocation' using errcode='22023';end if;
  pid:=(item->>'profile_id')::uuid;g:=(item->>'gross_minor')::bigint;
  if pid=any(seen) or g not between 1 and 100000000000000 then raise exception 'Duplicate profile or invalid amount' using errcode='22023';end if;
  seen:=array_append(seen,pid);
  select * into p from tenant_private.sy_tax_profiles z where z.store_id=p_store and z.id=pid;
  if not found then raise exception 'Unknown legal profile' using errcode='22023';end if;
  if is_return then
   select * into a from tenant_private.sy_tax_mixed_parts z where z.store_id=p_store and z.entry_id=original.id and z.profile_id=pid;
   if not found then raise exception 'Profile not on original invoice' using errcode='22023';end if;
   select coalesce(sum(z.gross_minor),0),coalesce(sum(z.tax_minor),0) into prev_gross,prev_tax from tenant_private.sy_tax_mixed_parts z join public.mt_indirect_tax_entries e on e.store_id=z.store_id and e.id=z.entry_id where z.store_id=p_store and z.profile_id=pid and e.kind=p_kind and e.invoice_id=d.invoice_id;
   if prev_gross+g>a.gross_minor then raise exception 'Refund allocation exceeds original profile amount' using errcode='22023';end if;
   tax:=tenant_private.tax_inclusive_minor((prev_gross+g)::bigint,p.rate_bps)-prev_tax;
   if tax<0 or tax>g or prev_tax+tax>a.tax_minor then raise exception 'Refund tax exceeds original profile tax' using errcode='22023';end if;
  else
   if (d.occurred_at at time zone 'Asia/Damascus')::date<p.effective_from or (p.effective_to is not null and (d.occurred_at at time zone 'Asia/Damascus')::date>p.effective_to) then raise exception 'Profile not effective for invoice date' using errcode='22023';end if;
   tax:=tenant_private.tax_inclusive_minor(g,p.rate_bps);
  end if;
  total_gross:=total_gross+g;total_tax:=total_tax+tax;
  parts:=parts||jsonb_build_array(jsonb_build_object('profile_id',pid,'gross_minor',g,'tax_minor',tax,'label',p.label,'rate_bps',p.rate_bps,'legal_reference',p.legal_reference));
 end loop;
 if total_gross<>d.gross_minor then raise exception 'Allocation must equal full document gross' using errcode='22023';end if;
 result:=jsonb_build_object('kind',p_kind,'source_id',p_source,'invoice_id',d.invoice_id,'currency',d.currency,'gross_minor',d.gross_minor,'tax_minor',total_tax,'parts',parts);
 return result||jsonb_build_object('digest',tenant_private.finance_review_digest(result));
end $$;
create function tenant_private.sy_tax_mixed_record(p_store uuid,p_request uuid,p_kind text,p_source uuid,p_parts jsonb,p_digest text,p_proof text)
returns uuid language plpgsql security definer set search_path='' as $$
declare q jsonb; old public.mt_indirect_tax_entries%rowtype; eid uuid; stored jsonb; normalized jsonb;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_digest is null or p_digest !~ '^[0-9a-f]{64}$' or p_proof is null or length(btrim(p_proof)) not between 1 and 160 then raise exception 'Confirm reviewed allocation and document reference' using errcode='22023';end if;
 select * into old from public.mt_indirect_tax_entries e where e.store_id=p_store and e.request_id=p_request;
 if found then
  select jsonb_agg(jsonb_build_object('profile_id',z.profile_id,'gross_minor',z.gross_minor,'tax_minor',z.tax_minor,'label',p.label,'rate_bps',p.rate_bps,'legal_reference',p.legal_reference) order by z.profile_id::text) into stored from tenant_private.sy_tax_mixed_parts z join tenant_private.sy_tax_profiles p on p.store_id=z.store_id and p.id=z.profile_id where z.store_id=p_store and z.entry_id=old.id;
  if jsonb_typeof(p_parts) is distinct from 'array' or jsonb_array_length(p_parts)>30 then raise exception 'Invalid replay';end if;
  select jsonb_agg(jsonb_build_object('profile_id',value->>'profile_id','gross_minor',(value->>'gross_minor')::bigint) order by value->>'profile_id') into normalized from jsonb_array_elements(p_parts);
  if old.actor<>auth.uid() or old.kind is distinct from p_kind or old.source_id is distinct from p_source or old.reference<>btrim(p_proof) or old.rate_bps is not null or stored is null or normalized is distinct from (select jsonb_agg(jsonb_build_object('profile_id',value->>'profile_id','gross_minor',(value->>'gross_minor')::bigint) order by value->>'profile_id') from jsonb_array_elements(stored)) or p_digest<>tenant_private.finance_review_digest(jsonb_build_object('kind',old.kind,'source_id',old.source_id,'invoice_id',old.invoice_id,'currency',old.currency,'gross_minor',old.gross_minor,'tax_minor',old.tax_minor,'parts',stored)) then raise exception 'Conflicting mixed tax request' using errcode='22023';end if;
  return old.id;
 end if;
 q:=tenant_private.sy_tax_mixed_quote(p_store,p_kind,p_source,p_parts);
 if q->>'digest' is distinct from p_digest then raise exception 'Tax allocation changed; review again' using errcode='22023';end if;
 insert into public.mt_indirect_tax_entries(store_id,request_id,kind,source_id,invoice_id,currency,gross_minor,rate_bps,tax_minor,reference,note,actor)
 values(p_store,p_request,p_kind,p_source,(q->>'invoice_id')::uuid,q->>'currency',(q->>'gross_minor')::bigint,null,(q->>'tax_minor')::bigint,btrim(p_proof),'Documented multi-profile tax allocation',auth.uid()) returning id into eid;
 insert into tenant_private.sy_tax_mixed_parts(store_id,entry_id,profile_id,gross_minor,tax_minor)
 select p_store,eid,(value->>'profile_id')::uuid,(value->>'gross_minor')::bigint,(value->>'tax_minor')::bigint from jsonb_array_elements(q->'parts');
 return eid;
end $$;
create function public.mt_sy_tax_mixed_quote(p_store uuid,p_kind text,p_source uuid,p_parts jsonb) returns jsonb language sql stable set search_path='' as $$select tenant_private.sy_tax_mixed_quote(p_store,p_kind,p_source,p_parts)$$;
create function public.mt_sy_tax_mixed_record(p_store uuid,p_request uuid,p_kind text,p_source uuid,p_parts jsonb,p_digest text,p_proof text) returns uuid language sql set search_path='' as $$select tenant_private.sy_tax_mixed_record(p_store,p_request,p_kind,p_source,p_parts,p_digest,p_proof)$$;
revoke all on function tenant_private.sy_tax_mixed_quote(uuid,text,uuid,jsonb),public.mt_sy_tax_mixed_quote(uuid,text,uuid,jsonb),tenant_private.sy_tax_mixed_record(uuid,uuid,text,uuid,jsonb,text,text),public.mt_sy_tax_mixed_record(uuid,uuid,text,uuid,jsonb,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.sy_tax_mixed_quote(uuid,text,uuid,jsonb),public.mt_sy_tax_mixed_quote(uuid,text,uuid,jsonb),tenant_private.sy_tax_mixed_record(uuid,uuid,text,uuid,jsonb,text,text),public.mt_sy_tax_mixed_record(uuid,uuid,text,uuid,jsonb,text,text) to authenticated;

create or replace function tenant_private.sy_tax_output_preview(s uuid,k text,source uuid,profile uuid)
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
  if e.rate_bps is distinct from p.rate_bps or e.currency<>d.currency or e.gross_minor<>d.gross_minor then raise exception 'Existing tax record differs from selected legal profile; accountant correction required' using errcode='22023';end if;
  if exists(select 1 from tenant_private.sy_tax_output where store_id=s and entry_id=e.id and profile_id<>profile) then raise exception 'Document already classified under another profile' using errcode='22023';end if;
  q:=jsonb_build_object('kind',k,'source_id',source,'invoice_id',d.invoice_id,'currency',d.currency,'gross_minor',d.gross_minor,'rate_bps',e.rate_bps,'tax_minor',e.tax_minor);
 else
  q:=tenant_private.indirect_tax_quote(s,k,source,case when k in ('sale','repair') then p.rate_bps else null end);
 end if;
 return q||jsonb_build_object('profile_id',p.id,'profile_label',p.label,'regime',p.regime,'legal_reference',p.legal_reference,'already_posted',e.id is not null,'entry_id',e.id);
end $$;
create or replace function tenant_private.sy_tax_queue(s uuid,d1 date,d2 date,filter_kind text,missing_only boolean,off integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare data jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if d1 is null or d2 is null or d2<d1 or d2-d1>365 or d2>(now() at time zone 'Asia/Damascus')::date or filter_kind is null or filter_kind not in ('all','sale','repair','sale_return','repair_refund','purchase','supplier_return') or missing_only is null or off is null or off not between 0 and 100000 then raise exception 'Invalid tax period' using errcode='22023';end if;
 with docs as (
 select d.*,coalesce(b.name,'') branch_name,e.id entry_id,o.profile_id,p.label profile_label,e.tax_minor output_tax,e.created_at tax_posted_at,
 m.parts mixed_parts, (orig.id is not null and orig.rate_bps is null) original_mixed,
 inp.request_id input_revision,inp.tax_minor input_tax,inp.treatment,inp.document_ref input_document_ref,inp.legal_reference input_legal_reference,
 case when d.kind in ('purchase','supplier_return') then inp.request_id is null or inp.treatment in ('pending_review','potential_credit') else o.profile_id is null and m.parts is null end unresolved
 from tenant_private.sy_tax_documents(s) d left join tenant_private.branches b on b.store_id=s and b.id=d.branch_id
 left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id left join tenant_private.sy_tax_profiles p on p.store_id=s and p.id=o.profile_id
 left join lateral (select jsonb_agg(jsonb_build_object('profile_id',z.profile_id,'gross_minor',z.gross_minor,'tax_minor',z.tax_minor,'label',p0.label,'rate_bps',p0.rate_bps) order by z.profile_id) parts from tenant_private.sy_tax_mixed_parts z join tenant_private.sy_tax_profiles p0 on p0.store_id=z.store_id and p0.id=z.profile_id where z.store_id=s and z.entry_id=e.id) m on true
 left join public.mt_indirect_tax_entries orig on orig.store_id=s and orig.source_id=d.invoice_id and orig.kind=case d.kind when 'sale_return' then 'sale' when 'repair_refund' then 'repair' end
 left join tenant_private.sy_tax_input_current(s) inp on inp.kind=d.kind and inp.source_id=d.source_id
 where d.occurred_at>=d1::timestamp at time zone 'Asia/Damascus' and d.occurred_at<(d2+1)::timestamp at time zone 'Asia/Damascus' and (filter_kind='all' or d.kind=filter_kind)
 ),page as (select * from docs where not missing_only or unresolved order by occurred_at desc,kind,source_id offset off limit 51)
 select coalesce(jsonb_agg(to_jsonb(page) order by occurred_at desc,kind,source_id),'[]'::jsonb) into data from page;
 return jsonb_build_object('rows',case when jsonb_array_length(data)>50 then data-50 else data end,'more',jsonb_array_length(data)>50);
end $$;
create or replace function tenant_private.sy_tax_period_review(s uuid,d1 date,d2 date)
returns jsonb language sql stable security definer set search_path='' as $$
 with docs as (
 select d.*,e.id entry_id,e.tax_minor,e.created_at posted,o.profile_id,o.document_ref output_ref,i.request_id input_id,i.treatment,i.tax_minor input_tax,
 parent.request_id parent_revision,parent.treatment parent_treatment,m.parts mixed_parts,
 case when d.kind in ('purchase','supplier_return') then
   i.request_id is null or i.treatment in ('pending_review','potential_credit') or
   (d.kind='supplier_return' and (parent.request_id is null or parent.treatment in ('pending_review','potential_credit') or
     (i.tax_minor>0 and i.treatment is distinct from parent.treatment)))
 else o.profile_id is null and m.parts is null end unresolved
 from tenant_private.sy_tax_documents(s) d
 left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id
 left join lateral (select jsonb_agg(jsonb_build_array(z.profile_id,z.gross_minor,z.tax_minor) order by z.profile_id) parts from tenant_private.sy_tax_mixed_parts z where z.store_id=s and z.entry_id=e.id) m on true
 left join tenant_private.sy_tax_input_current(s) i on i.kind=d.kind and i.source_id=d.source_id
 left join tenant_private.sy_tax_input_current(s) parent on d.kind='supplier_return' and parent.kind='purchase' and parent.source_id=d.invoice_id
 where d.occurred_at>=d1::timestamp at time zone 'Asia/Damascus' and d.occurred_at<(d2+1)::timestamp at time zone 'Asia/Damascus'
 ), totals as (
 select branch_id,currency,
 coalesce(sum(tax_minor::numeric) filter(where kind in ('sale','repair')),0)-coalesce(sum(tax_minor::numeric) filter(where kind in ('sale_return','repair_refund')),0) output_net,
 coalesce(sum(input_tax::numeric) filter(where kind='purchase'),0)-coalesce(sum(input_tax::numeric) filter(where kind='supplier_return'),0) input_documented_net,
 count(*) filter(where unresolved) unresolved_count
 from docs group by branch_id,currency
 )
 select jsonb_build_object('output_unclassified',count(*) filter(where kind not in ('purchase','supplier_return') and unresolved),
 'input_unclassified',count(*) filter(where kind in ('purchase','supplier_return') and unresolved),
 'late_output_postings',count(*) filter(where tax_minor>0 and (posted<d1::timestamp at time zone 'Asia/Damascus' or posted>=(d2+1)::timestamp at time zone 'Asia/Damascus'))+
 (select count(*) from public.mt_indirect_tax_entries e join tenant_private.sy_tax_documents(s) d on d.kind=e.kind and d.source_id=e.source_id where e.store_id=s and e.tax_minor>0 and e.created_at>=d1::timestamp at time zone 'Asia/Damascus' and e.created_at<(d2+1)::timestamp at time zone 'Asia/Damascus' and (d.occurred_at<d1::timestamp at time zone 'Asia/Damascus' or d.occurred_at>=(d2+1)::timestamp at time zone 'Asia/Damascus')),
 'input_credit_posting_enabled',false,
 'evidence_digest',encode(sha256(convert_to(coalesce(jsonb_agg(jsonb_build_array(kind,source_id,invoice_id,branch_id,currency,gross_minor,occurred_at,entry_id,tax_minor,posted,profile_id,output_ref,input_id,input_tax,treatment,parent_revision,parent_treatment,mixed_parts,unresolved) order by kind,source_id),'[]'::jsonb)::text,'UTF8')),'hex'),
 'totals',coalesce((select jsonb_agg(jsonb_build_object('branch_id',t.branch_id,'currency',t.currency,'output_net',t.output_net::text,'input_documented_net',t.input_documented_net::text,'unresolved_count',t.unresolved_count) order by t.branch_id nulls first,t.currency) from totals t),'[]'::jsonb)) from docs
$$;

commit;
