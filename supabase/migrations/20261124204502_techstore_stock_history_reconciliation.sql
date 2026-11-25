create table techstore_private.central_stock_history(
 id bigint generated always as identity primary key, product_id text not null, revision bigint not null,
 qty_before bigint not null check(qty_before>=0), qty_after bigint not null check(qty_after>=0), recorded_at timestamptz not null default now()
);
alter table techstore_private.central_stock_history enable row level security;
revoke all on techstore_private.central_stock_history from public,anon,authenticated;
create index central_stock_history_product on techstore_private.central_stock_history(product_id,id);
insert into techstore_private.central_stock_history(product_id,revision,qty_before,qty_after)
select p->>'id',w.revision,0,(p->>'qty')::bigint from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'products','[]')) p where w.id=1;
CREATE OR REPLACE FUNCTION techstore_private.track_central_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.id<>1 or new.payload->'data'->'products' is not distinct from old.payload->'data'->'products' then return new;end if;
 insert into techstore_private.central_stock_history(product_id,revision,qty_before,qty_after)
 select coalesce(o.product_id,n.product_id),new.revision,coalesce(o.qty,0),coalesce(n.qty,0)
 from (select p->>'id' product_id,(p->>'qty')::bigint qty from jsonb_array_elements(coalesce(old.payload->'data'->'products','[]')) p) o
 full join (select p->>'id' product_id,(p->>'qty')::bigint qty from jsonb_array_elements(coalesce(new.payload->'data'->'products','[]')) p) n using(product_id)
 where coalesce(o.qty,0)<>coalesce(n.qty,0);
 return new;
end $function$
;
revoke all on function techstore_private.track_central_stock() from public,anon,authenticated;
create trigger ts_track_central_stock after update of payload on public.ts_workspace for each row execute function techstore_private.track_central_stock();
CREATE OR REPLACE FUNCTION techstore_private.reconcile_business()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
,
 jsonb_build_object('key','legacy_openings','mismatches',(with source as (select k,x from public.ts_workspace w cross join lateral unnest(array['debts','installments']) k cross join lateral jsonb_array_elements(coalesce(w.payload->'records'->k,'[]')) x where w.id=1) select count(*) from source s full join (select * from public.ts_business_entries where kind='legacy_opening') e on e.source_key='legacy-opening:'||s.k||':'||(s.x->>'id') where s.x is null or e.id is null or e.amount is distinct from (s.x->>'amount')::numeric or e.debit is distinct from case when s.k='installments' or s.x->>'direction'='receivable' then 'receivables' else 'legacy_opening_balance' end or e.credit is distinct from case when s.k='installments' or s.x->>'direction'='receivable' then 'legacy_opening_balance' else 'legacy_payable' end)),
 jsonb_build_object('key','legacy_payments','mismatches',(with payments as (select x from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'records'->'payments','[]')) x where w.id=1 and x->>'kind' in ('debts','installments')) select count(*) from payments p full join (select * from public.ts_business_entries where kind='legacy_payment') e on e.source_key='legacy-payment:'||(p.x->>'id') where p.x is null or e.id is null or e.amount is distinct from (p.x->>'amount')::numeric or not exists(select 1 from public.ts_business_entries o where o.source_key='legacy-opening:'||(p.x->>'kind')||':'||(p.x->>'reference') and ((o.debit='receivables' and e.debit='cash' and e.credit='receivables') or (o.credit='legacy_payable' and e.debit='legacy_payable' and e.credit='cash'))))),
 jsonb_build_object('key','legacy_balances','mismatches',(select count(*) from public.ts_workspace w cross join lateral unnest(array['debts','installments']) k cross join lateral jsonb_array_elements(coalesce(w.payload->'records'->k,'[]')) x where w.id=1 and (coalesce((x->>'paid')::numeric,0) is distinct from coalesce((select sum((p->>'amount')::numeric) from jsonb_array_elements(coalesce(w.payload->'records'->'payments','[]')) p where p->>'kind'=k and p->>'reference'=x->>'id'),0) or coalesce((x->>'paid')::numeric,0)<0 or coalesce((x->>'paid')::numeric,0)>(x->>'amount')::numeric)))
,
 jsonb_build_object('key','central_stock_history','mismatches',(with current_stock as (select p->>'id' product_id,(p->>'qty')::bigint qty from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'products','[]')) p where w.id=1), history as (select product_id,sum(qty_after-qty_before) qty from techstore_private.central_stock_history group by product_id) select count(*) from current_stock c full join history h using(product_id) where coalesce(c.qty,0)<>coalesce(h.qty,0))),
 jsonb_build_object('key','central_stock_chain','mismatches',(select count(*) from (select qty_before,coalesce(lag(qty_after) over(partition by product_id order by id),0) previous_qty from techstore_private.central_stock_history) h where h.qty_before<>h.previous_qty)),
 jsonb_build_object('key','cash_count_difference','mismatches',(select count(*) from public.ts_business_closings where expected is distinct from counted))
 ) into checks;
 return jsonb_build_object('checks',checks,'checked_at',now(),'counts',jsonb_build_object('invoices',(select count(*) from public.ts_invoices),'branch_events',(select count(*) from public.ts_branch_events),'entries',(select count(*) from public.ts_business_entries)));
end $function$
;
