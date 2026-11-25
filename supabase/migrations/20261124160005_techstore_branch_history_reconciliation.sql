begin;
create index if not exists ts_branch_sales_history_idx on public.ts_branch_events(created_at desc,id desc) where kind='sale';
create or replace function techstore_private.branch_sales_history(p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; query_value text; branch_value uuid; cursor_time timestamptz; cursor_id uuid;
begin
 if techstore_private.live_session() is distinct from true or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>4000 then raise exception 'Invalid search';end if;
 query_value:=lower(btrim(coalesce(p_args->>'query','')));if length(query_value)>200 then raise exception 'Invalid search';end if;
 branch_value:=nullif(p_args->>'branch','')::uuid;cursor_time:=nullif(p_args->>'before_time','')::timestamptz;cursor_id:=nullif(p_args->>'before_id','')::uuid;
 if (cursor_time is null)<>(cursor_id is null) then raise exception 'Invalid cursor';end if;
 with candidates as (
 select e.id,e.branch_from,e.product_id,e.qty,e.amount,e.created_at,coalesce(b.title,e.branch_from::text) as branch_name,coalesce(p.product_name,e.product_id) as product_name,
 e.qty-coalesce((select sum(r.qty) from public.ts_branch_events r where r.kind='return' and r.original_sale_id=e.id),0) as remaining
 from public.ts_branch_events e left join public.ts_pro_entries b on b.id=e.branch_from
 left join lateral (select x->>'name' as product_name from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'products','[]')) x where w.id=1 and x->>'id'=e.product_id limit 1) p on true
 where e.kind='sale' and (branch_value is null or e.branch_from=branch_value) and (cursor_time is null or (e.created_at,e.id)<(cursor_time,cursor_id))
 and (query_value='' or strpos(lower(e.id::text),query_value)>0 or strpos(lower(e.product_id),query_value)>0 or strpos(lower(coalesce(p.product_name,'')),query_value)>0)
 order by e.created_at desc,e.id desc limit 51
 ), page as (select * from candidates order by created_at desc,id desc limit 50)
 select jsonb_build_object('sales',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from page x),'[]'),'has_more',(select count(*)>50 from candidates)) into result;
 return result;
end $$;
revoke all on function techstore_private.branch_sales_history(jsonb) from public,anon,authenticated;
grant execute on function techstore_private.branch_sales_history(jsonb) to authenticated;
create or replace function techstore_private.branch_totals() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if techstore_private.live_session() is distinct from true or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 return (select jsonb_build_object('revenue',coalesce(sum(case when kind='sale' then amount when kind='return' then -amount else 0 end),0),'cost',coalesce(sum(case when kind='sale' then cost when kind='return' then -cost else 0 end),0),'events',count(*)) from public.ts_branch_events);
end $$;
revoke all on function techstore_private.branch_totals() from public,anon,authenticated;
grant execute on function techstore_private.branch_totals() to authenticated;
create or replace function public.ts_branch_operation(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select case when p_action='return' then techstore_private.branch_return(p_args) when p_action='history' then techstore_private.branch_sales_history(p_args) when p_action='totals' then techstore_private.branch_totals() else techstore_private.branch_operation(p_action,p_args) end $$;
create function techstore_private.reconcile_business() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare checks jsonb;
begin
 if techstore_private.live_session() is distinct from true or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 select jsonb_build_array(
 jsonb_build_object('key','invoice_revenue','mismatches',(select count(*) from public.ts_invoices i where (i.document->>'total')::numeric is distinct from coalesce((select sum(e.amount) from public.ts_business_entries e where e.invoice_id=i.id and e.kind='invoice'),0))),
 jsonb_build_object('key','invoice_initial_payment','mismatches',(select count(*) from public.ts_invoices i where (i.document->>'paid')::numeric is distinct from coalesce((select sum(e.amount) from public.ts_business_entries e where e.invoice_id=i.id and e.kind='initial_payment'),0))),
 jsonb_build_object('key','supplier_bills','mismatches',(select count(*) from public.ts_supplier_bills b where not exists(select 1 from public.ts_business_entries e where e.source_key='purchase:'||b.purchase_id and e.amount=b.amount and e.debit='inventory' and e.credit='supplier_payable'))),
 jsonb_build_object('key','supplier_payments','mismatches',(select count(*) from public.ts_supplier_payments p where not exists(select 1 from public.ts_business_entries e where e.source_key='supplier-payment:'||p.id and e.amount=p.amount and e.debit='supplier_payable' and e.credit='cash'))),
 jsonb_build_object('key','payroll','mismatches',(select count(*) from public.ts_staff_payroll p where p.total>0 and (not exists(select 1 from public.ts_business_entries e where e.source_key='payroll:'||p.id and e.amount=p.total and e.debit='payroll_expense' and e.credit='payroll_payable') or (p.paid_at is not null and not exists(select 1 from public.ts_business_entries e where e.source_key='payroll-payment:'||p.id and e.amount=p.total and e.debit='payroll_payable' and e.credit='cash'))))),
 jsonb_build_object('key','branch_journal','mismatches',(select count(*) from public.ts_journal_pairs j where not exists(select 1 from public.ts_business_entries e where e.source_key='branch-pair:'||j.id and e.amount=j.amount and e.debit=case when j.debit_account='sales' then 'sales_revenue' else j.debit_account end and e.credit=case when j.credit_account='sales' then 'sales_revenue' else j.credit_account end))),
 jsonb_build_object('key','branch_stock','mismatches',(with moves as (select branch_to as branch_id,product_id,qty from public.ts_branch_events where kind='transfer' and branch_to is not null union all select branch_from,product_id,case when kind='return' then qty else -qty end from public.ts_branch_events where branch_from is not null), totals as (select branch_id,product_id,sum(qty) qty from moves group by branch_id,product_id) select count(*) from totals t full join public.ts_branch_stock s using(branch_id,product_id) where coalesce(t.qty,0)<>coalesce(s.qty,0))),
 jsonb_build_object('key','sale_stock_reference','mismatches',(select count(*) from public.ts_invoices i where i.kind='sale' and not exists(select 1 from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'sales','[]')) s where w.id=1 and s->>'id'=i.id::text))),
 jsonb_build_object('key','negative_central_stock','mismatches',(select count(*) from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'products','[]')) p where w.id=1 and coalesce((p->>'qty')::numeric,-1)<0))
 ) into checks;
 return jsonb_build_object('checks',checks,'checked_at',now(),'counts',jsonb_build_object('invoices',(select count(*) from public.ts_invoices),'branch_events',(select count(*) from public.ts_branch_events),'entries',(select count(*) from public.ts_business_entries)));
end $$;
revoke all on function techstore_private.reconcile_business() from public,anon,authenticated;
grant execute on function techstore_private.reconcile_business() to authenticated;
create function public.ts_reconcile_business() returns jsonb language sql stable security invoker set search_path='' as $$ select techstore_private.reconcile_business() $$;
revoke all on function public.ts_reconcile_business() from public,anon,authenticated;
grant execute on function public.ts_reconcile_business() to authenticated;
commit;