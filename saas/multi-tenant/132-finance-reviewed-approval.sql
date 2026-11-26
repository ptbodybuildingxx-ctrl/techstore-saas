-- 132: bind management approval to the exact reviewed journal and tax evidence.
-- No tax rate, automatic credit, financial posting or historical rewrite is introduced.
begin;
create or replace function tenant_private.sy_tax_period_review(s uuid,d1 date,d2 date)
returns jsonb language sql stable security definer set search_path='' as $$
 with docs as (
 select d.*,e.id entry_id,e.tax_minor,e.created_at posted,o.profile_id,o.document_ref output_ref,i.request_id input_id,i.treatment,i.tax_minor input_tax,
 parent.request_id parent_revision,parent.treatment parent_treatment,
 case when d.kind in ('purchase','supplier_return') then
   i.request_id is null or i.treatment in ('pending_review','potential_credit') or
   (d.kind='supplier_return' and (parent.request_id is null or parent.treatment in ('pending_review','potential_credit') or
     (i.tax_minor>0 and i.treatment is distinct from parent.treatment)))
 else o.profile_id is null end unresolved
 from tenant_private.sy_tax_documents(s) d
 left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id
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
 'evidence_digest',encode(sha256(convert_to(coalesce(jsonb_agg(jsonb_build_array(kind,source_id,invoice_id,branch_id,currency,gross_minor,occurred_at,entry_id,tax_minor,posted,profile_id,output_ref,input_id,input_tax,treatment,parent_revision,parent_treatment,unresolved) order by kind,source_id),'[]'::jsonb)::text,'UTF8')),'hex'),
 'totals',coalesce((select jsonb_agg(jsonb_build_object('branch_id',t.branch_id,'currency',t.currency,'output_net',t.output_net::text,'input_documented_net',t.input_documented_net::text,'unresolved_count',t.unresolved_count) order by t.branch_id nulls first,t.currency) from totals t),'[]'::jsonb)) from docs
$$;
revoke all on function tenant_private.sy_tax_period_review(uuid,date,date) from public,anon,authenticated;

create function tenant_private.finance_review_digest(snapshot jsonb) returns text
language sql immutable set search_path='' as $$
 select encode(sha256(convert_to(snapshot::text,'UTF8')),'hex')
$$;
revoke all on function tenant_private.finance_review_digest(jsonb) from public,anon,authenticated;

create or replace function tenant_private.branch_result_review(s uuid,d1 date,d2 date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;e tenant_private.branch_result_approvals%rowtype;
begin
 r:=tenant_private.branch_result_compute(s,d1,d2);
 select * into e from tenant_private.branch_result_approvals where store_id=s and from_day=d1 and to_day=d2 order by created_at desc,request_id desc limit 1;
 return r||jsonb_build_object('approval',e.request_id,'approval_reference',e.reference,'matches_approval',e.request_id is not null and e.snapshot=r,'review_digest',tenant_private.finance_review_digest(r));
end $$;

create function tenant_private.branch_result_approve_reviewed(s uuid,req uuid,d1 date,d2 date,previous uuid,proof text,confirmed boolean,expected_digest text)
returns uuid language plpgsql security definer set search_path='' as $$
declare r jsonb;e tenant_private.branch_result_approvals%rowtype;
begin
 perform tenant_private.owner_write(s);
 if expected_digest is null or expected_digest !~ '^[0-9a-f]{64}$' or d1 is null or d2 is null then raise exception 'Review fingerprint required' using errcode='22023';end if;
 select * into e from tenant_private.branch_result_approvals where store_id=s and request_id=req;
 if found then
  if e.actor<>auth.uid() or e.from_day is distinct from d1 or e.to_day is distinct from d2 or tenant_private.finance_review_digest(e.snapshot)<>expected_digest then raise exception 'Conflicting reviewed approval' using errcode='22023';end if;
 else
  r:=tenant_private.branch_result_compute(s,d1,d2);
  if tenant_private.finance_review_digest(r)<>expected_digest then raise exception 'Financial report changed; reload and review before approval' using errcode='22023';end if;
 end if;
 return tenant_private.branch_result_approve(s,req,d1,d2,previous,proof,confirmed);
end $$;
create function public.mt_branch_result_approve_reviewed(s uuid,req uuid,d1 date,d2 date,previous uuid,proof text,confirmed boolean,expected_digest text)
returns uuid language sql set search_path='' as $$select tenant_private.branch_result_approve_reviewed(s,req,d1,d2,previous,proof,confirmed,expected_digest)$$;
revoke all on function tenant_private.branch_result_approve_reviewed(uuid,uuid,date,date,uuid,text,boolean,text),public.mt_branch_result_approve_reviewed(uuid,uuid,date,date,uuid,text,boolean,text) from public,anon,authenticated;
grant execute on function tenant_private.branch_result_approve_reviewed(uuid,uuid,date,date,uuid,text,boolean,text),public.mt_branch_result_approve_reviewed(uuid,uuid,date,date,uuid,text,boolean,text) to authenticated;
-- Keep old signature for deployed callers but do not permit unreviewed new approvals.
revoke all on function tenant_private.branch_result_approve(uuid,uuid,date,date,uuid,text,boolean),public.mt_branch_result_approve(uuid,uuid,date,date,uuid,text,boolean) from public,anon,authenticated;
commit;
