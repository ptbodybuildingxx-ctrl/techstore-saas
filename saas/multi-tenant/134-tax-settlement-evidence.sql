-- 134: reconciliation and externally filed tax declaration evidence; no payment or automatic credit.
begin;
create table tenant_private.sy_tax_filing_evidence(
 store_id uuid not null references tenant_private.workspaces(store_id),
 request_id uuid not null,kind text not null check(kind in ('indirect','income')),currency text not null,
 from_day date not null,to_day date not null,previous uuid,
 filed_on date not null,authority text not null check(length(btrim(authority)) between 1 and 120),
 reference text not null check(length(btrim(reference)) between 1 and 160),
 legal_reference text not null check(length(btrim(legal_reference)) between 1 and 200),
 declared_minor bigint not null check(declared_minor between 0 and 100000000000000),
 explanation text not null check(length(explanation)<=500),
 snapshot jsonb not null,actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,request_id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 foreign key(store_id,previous) references tenant_private.sy_tax_filing_evidence(store_id,request_id),
 check(to_day>=from_day and to_day-from_day<=365 and filed_on>=to_day)
);
create index sy_tax_filing_scope on tenant_private.sy_tax_filing_evidence(store_id,kind,currency,from_day,to_day,created_at desc,request_id);
alter table tenant_private.sy_tax_filing_evidence enable row level security;
revoke all on tenant_private.sy_tax_filing_evidence from public,anon,authenticated,service_role;

create function tenant_private.sy_tax_settlement_compute(p_store uuid,p_kind text,p_currency text,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare lo timestamptz;hi timestamptz;account text;payment_kind text;opening numeric;assessed numeric;paid numeric;closing numeric;
 evidence text;payments jsonb;payment_count bigint;tax_review jsonb;summary jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_kind is null or p_kind not in ('indirect','income') or p_currency is null or p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 or p_to>=(now() at time zone 'Asia/Damascus')::date then raise exception 'Select a completed Damascus period' using errcode='22023';end if;
 if not exists(select 1 from tenant_private.sale_currencies c where c.store_id=p_store and c.currency=p_currency) then raise exception 'Currency not enabled' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'Asia/Damascus';hi:=(p_to+1)::timestamp at time zone 'Asia/Damascus';
 account:=case p_kind when 'indirect' then 'indirect_tax_payable' else 'income_tax_payable' end;
 payment_kind:=case p_kind when 'indirect' then 'expense_indirect_tax_payment' else 'expense_tax_payment' end;
 with legs as (
  select j.posted_at,j.source_type,j.source_id,j.debit_account,j.credit_account,j.amount,
   case when j.credit_account=account then j.amount else -j.amount end movement,
   coalesce(a.kind=payment_kind,false) is_payment
  from tenant_private.journal_pairs(p_store,hi) j left join public.mt_accounting_adjustments a
   on j.source_type='accounting_adjustment' and a.store_id=p_store and a.id=j.source_id
  where j.currency=p_currency and (j.debit_account=account or j.credit_account=account)
 )
 select coalesce(sum(movement) filter(where posted_at<lo),0),
  coalesce(sum(movement) filter(where posted_at>=lo and not is_payment),0),
  -coalesce(sum(movement) filter(where posted_at>=lo and is_payment),0),coalesce(sum(movement),0),
  tenant_private.finance_review_digest(coalesce(jsonb_agg(jsonb_build_array(posted_at,source_type,source_id,debit_account,credit_account,amount,is_payment) order by posted_at,source_type,source_id,debit_account,credit_account,amount),'[]'::jsonb))
 into opening,assessed,paid,closing,evidence from legs;
 if opening+assessed-paid<>closing then raise exception 'Tax journal does not reconcile';end if;
 select count(*) into payment_count from public.mt_accounting_adjustments a where a.store_id=p_store and a.currency=p_currency and a.kind=payment_kind and a.created_at>=lo and a.created_at<hi;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]'::jsonb) into payments from (
  select a.id,a.created_at,a.source_request,a.amount_minor::text amount_minor,a.reference,a.note from public.mt_accounting_adjustments a
  where a.store_id=p_store and a.currency=p_currency and a.kind=payment_kind and a.created_at>=lo and a.created_at<hi order by a.created_at desc,a.id limit 100
 ) x;
 tax_review:=case when p_kind='indirect' then tenant_private.sy_tax_period_review(p_store,p_from,p_to) else null end;
 summary:=jsonb_build_object('kind',p_kind,'currency',p_currency,'from',p_from,'to',p_to,
  'opening',opening::text,'net_assessed',assessed::text,'paid',paid::text,'closing',closing::text,
  'journal_digest',evidence,'payment_count',payment_count,'payments',payments,'tax_review',tax_review,
  'statutory_certified',false,'automatic_input_credit',false);
 return summary;
end $$;

create function tenant_private.sy_tax_settlement_review(p_store uuid,p_kind text,p_currency text,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;last_row tenant_private.sy_tax_filing_evidence%rowtype;history jsonb;
begin
 r:=tenant_private.sy_tax_settlement_compute(p_store,p_kind,p_currency,p_from,p_to);
 select * into last_row from tenant_private.sy_tax_filing_evidence x where x.store_id=p_store and x.kind=p_kind and x.currency=p_currency and x.from_day=p_from and x.to_day=p_to order by x.created_at desc,x.request_id desc limit 1;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id desc),'[]'::jsonb) into history from (
  select e.request_id,e.previous,e.filed_on,e.authority,e.reference,e.legal_reference,e.declared_minor::text declared_minor,e.explanation,e.created_at,
   e.snapshot->>'net_assessed' reviewed_assessment,e.snapshot->>'closing' reviewed_closing
  from tenant_private.sy_tax_filing_evidence e where e.store_id=p_store and e.kind=p_kind and e.currency=p_currency and e.from_day=p_from and e.to_day=p_to order by e.created_at desc,e.request_id desc limit 50
 ) x;
 return r||jsonb_build_object('review_digest',tenant_private.finance_review_digest(r),'latest',last_row.request_id,'matches_latest',last_row.request_id is not null and last_row.snapshot=r,'history',history);
end $$;

create function tenant_private.sy_tax_filing_record(p_store uuid,p_request uuid,p_kind text,p_currency text,p_from date,p_to date,p_previous uuid,p_digest text,p_filed_on date,p_authority text,p_reference text,p_legal text,p_declared bigint,p_explanation text,p_confirmed boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare r jsonb;old tenant_private.sy_tax_filing_evidence%rowtype;latest uuid;needs_reason boolean;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_kind is null or p_currency is null or p_from is null or p_to is null or p_digest is null or p_digest !~ '^[0-9a-f]{64}$' or p_filed_on is null or p_filed_on<p_to or p_filed_on>(now() at time zone 'Asia/Damascus')::date or p_authority is null or length(btrim(p_authority)) not between 1 and 120 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_legal is null or length(btrim(p_legal)) not between 1 and 200 or p_declared is null or p_declared not between 0 and 100000000000000 or p_explanation is null or length(btrim(p_explanation))>500 or p_confirmed is distinct from true then raise exception 'Confirm external filing evidence' using errcode='22023';end if;
 select * into old from tenant_private.sy_tax_filing_evidence where store_id=p_store and request_id=p_request;
 if found then
  if old.actor<>auth.uid() or old.kind<>p_kind or old.currency<>p_currency or old.from_day<>p_from or old.to_day<>p_to or old.previous is distinct from p_previous or old.filed_on<>p_filed_on or old.authority<>btrim(p_authority) or old.reference<>btrim(p_reference) or old.legal_reference<>btrim(p_legal) or old.declared_minor<>p_declared or old.explanation<>btrim(p_explanation) or tenant_private.finance_review_digest(old.snapshot)<>p_digest then raise exception 'Conflicting filing request' using errcode='22023';end if;return p_request;
 end if;
 if exists(select 1 from tenant_private.sy_tax_filing_evidence x where x.store_id=p_store and x.kind=p_kind and x.currency=p_currency and x.from_day<=p_to and x.to_day>=p_from and (x.from_day<>p_from or x.to_day<>p_to)) then raise exception 'Overlapping filing period; use the existing period' using errcode='22023';end if;
 select request_id into latest from tenant_private.sy_tax_filing_evidence x where x.store_id=p_store and x.kind=p_kind and x.currency=p_currency and x.from_day=p_from and x.to_day=p_to order by x.created_at desc,x.request_id desc limit 1;
 if latest is distinct from p_previous then raise exception 'Filing history changed; review again' using errcode='22023';end if;
 r:=tenant_private.sy_tax_settlement_compute(p_store,p_kind,p_currency,p_from,p_to);
 if tenant_private.finance_review_digest(r)<>p_digest then raise exception 'Tax settlement changed; review again' using errcode='22023';end if;
 needs_reason:=p_declared<>(r->>'net_assessed')::numeric or (p_kind='indirect' and ((r#>>'{tax_review,output_unclassified}')::numeric>0 or (r#>>'{tax_review,input_unclassified}')::numeric>0 or (r#>>'{tax_review,late_output_postings}')::numeric>0));
 if needs_reason and length(btrim(p_explanation))=0 then raise exception 'Explain the discrepancy or unresolved tax evidence' using errcode='22023';end if;
 if octet_length(r::text)>2000000 then raise exception 'Settlement too large';end if;
 insert into tenant_private.sy_tax_filing_evidence(store_id,request_id,kind,currency,from_day,to_day,previous,filed_on,authority,reference,legal_reference,declared_minor,explanation,snapshot,actor)
 values(p_store,p_request,p_kind,p_currency,p_from,p_to,p_previous,p_filed_on,btrim(p_authority),btrim(p_reference),btrim(p_legal),p_declared,btrim(p_explanation),r,auth.uid());
 return p_request;
end $$;
create function public.mt_sy_tax_settlement_review(p_store uuid,p_kind text,p_currency text,p_from date,p_to date) returns jsonb language sql stable set search_path='' as $$select tenant_private.sy_tax_settlement_review(p_store,p_kind,p_currency,p_from,p_to)$$;
create function public.mt_sy_tax_filing_record(p_store uuid,p_request uuid,p_kind text,p_currency text,p_from date,p_to date,p_previous uuid,p_digest text,p_filed_on date,p_authority text,p_reference text,p_legal text,p_declared bigint,p_explanation text,p_confirmed boolean) returns uuid language sql set search_path='' as $$select tenant_private.sy_tax_filing_record(p_store,p_request,p_kind,p_currency,p_from,p_to,p_previous,p_digest,p_filed_on,p_authority,p_reference,p_legal,p_declared,p_explanation,p_confirmed)$$;
revoke all on function tenant_private.sy_tax_settlement_compute(uuid,text,text,date,date) from public,anon,authenticated,service_role;
revoke all on function tenant_private.sy_tax_settlement_review(uuid,text,text,date,date),public.mt_sy_tax_settlement_review(uuid,text,text,date,date),tenant_private.sy_tax_filing_record(uuid,uuid,text,text,date,date,uuid,text,date,text,text,text,bigint,text,boolean),public.mt_sy_tax_filing_record(uuid,uuid,text,text,date,date,uuid,text,date,text,text,text,bigint,text,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.sy_tax_settlement_review(uuid,text,text,date,date),public.mt_sy_tax_settlement_review(uuid,text,text,date,date),tenant_private.sy_tax_filing_record(uuid,uuid,text,text,date,date,uuid,text,date,text,text,text,bigint,text,boolean),public.mt_sy_tax_filing_record(uuid,uuid,text,text,date,date,uuid,text,date,text,text,text,bigint,text,boolean) to authenticated;
commit;
