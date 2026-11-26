-- A completed trade-in offsets the purchase payable against the sale receivable.
-- Only the confirmed difference goes through cash. Existing returns remain separate transactions.
begin;
alter table public.mt_debt_payments add column settlement_method text not null default 'cash' check(settlement_method in ('cash','tradein_offset'));
alter table public.mt_supplier_payments add column settlement_method text not null default 'cash' check(settlement_method in ('cash','tradein_offset'));
create table tenant_private.tradein_suppliers(store_id uuid not null,customer_id uuid not null,supplier_id uuid not null,primary key(store_id,customer_id),unique(store_id,supplier_id),foreign key(store_id,customer_id) references public.mt_customers(store_id,id),foreign key(store_id,supplier_id) references public.mt_suppliers(store_id,id));
create table tenant_private.tradein_settlements(
 store_id uuid not null,id uuid not null,request_id uuid not null,actor uuid not null,used_product_id uuid not null,lines jsonb not null,
 purchase_id uuid not null,sale_id uuid not null,debt_payment_id uuid not null,supplier_payment_id uuid not null,currency text not null,
 estimate_minor bigint not null,sale_minor bigint not null,offset_minor bigint not null,cash_difference_minor bigint not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id),unique(store_id,purchase_id),unique(store_id,sale_id),
 foreign key(store_id,id) references tenant_private.tradein_estimates(store_id,id),foreign key(store_id,used_product_id) references public.mt_products(store_id,id),
 foreign key(store_id,purchase_id) references public.mt_purchases(store_id,id),foreign key(store_id,sale_id) references public.mt_sales(store_id,id),
 foreign key(store_id,debt_payment_id) references public.mt_debt_payments(store_id,id),foreign key(store_id,supplier_payment_id) references public.mt_supplier_payments(store_id,id),
 check(estimate_minor>0 and sale_minor>0 and offset_minor=least(estimate_minor,sale_minor) and cash_difference_minor=sale_minor-estimate_minor)
);
alter table tenant_private.tradein_suppliers enable row level security;alter table tenant_private.tradein_settlements enable row level security;
revoke all on tenant_private.tradein_suppliers,tenant_private.tradein_settlements from public,anon,authenticated,service_role;
create trigger mt_guard_closed_period before insert on tenant_private.tradein_settlements for each row execute function tenant_private.guard_closed_period();
create function tenant_private.tradein_execute(p_store uuid,p_request uuid,p_id uuid,p_used_product uuid,p_currency text,p_lines jsonb,p_difference bigint,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare e tenant_private.tradein_estimates%rowtype;prior tenant_private.tradein_settlements%rowtype;c public.mt_customers%rowtype;sup uuid;buy uuid;sale jsonb;sid uuid;debt uuid;dp uuid;sp uuid;total bigint;off bigint;today date:=(now() at time zone 'UTC')::date;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_id is null or p_used_product is null or p_currency is null or p_difference is null or p_confirm is distinct from true or jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>30000 then raise exception 'Invalid confirmed settlement' using errcode='22023';end if;
 select * into prior from tenant_private.tradein_settlements where store_id=p_store and id=p_id;
 if found then
 if prior.request_id<>p_request or prior.actor<>auth.uid() or prior.used_product_id<>p_used_product or prior.currency<>p_currency or prior.lines is distinct from p_lines or prior.cash_difference_minor<>p_difference then raise exception 'Conflicting settlement' using errcode='22023';end if;
 return p_id;
 end if;
 select * into e from tenant_private.tradein_estimates where store_id=p_store and id=p_id for update;
 if not found or e.state<>'accepted' or e.currency<>p_currency or e.amount_minor>100000000 then raise exception 'Accepted matching estimate required' using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_lines) x where x->>'product_id'=p_used_product::text) then raise exception 'Used device cannot be sold in the same exchange' using errcode='22023';end if;
 if not exists(select 1 from public.mt_products where store_id=p_store and id=p_used_product) then raise exception 'Unknown used product' using errcode='22023';end if;
 if exists(select 1 from public.mt_sales where store_id=p_store and request_id=p_request) then raise exception 'Sale request already used' using errcode='22023';end if;
 -- Credit sale engine validates actual prices and available stock before any intake.
 if e.branch_id is null then sale:=tenant_private.record_credit_sale(p_store,p_request,p_currency,p_lines,e.customer_id,0,1,today);
 else sale:=tenant_private.branch_credit_sale(p_store,e.branch_id,p_request,p_currency,p_lines,e.customer_id,0,1,today);end if;
 sid:=(sale->>'id')::uuid;total:=(sale->>'total_minor')::bigint;
 if total-e.amount_minor<>p_difference then raise exception 'Confirmed difference changed' using errcode='22023';end if;
 select id into strict debt from public.mt_debts where store_id=p_store and sale_id=sid;
 select supplier_id into sup from tenant_private.tradein_suppliers where store_id=p_store and customer_id=e.customer_id;
 if not found then
 select * into strict c from public.mt_customers where store_id=p_store and id=e.customer_id;
 sup:=tenant_private.add_supplier(p_store,gen_random_uuid(),left('استبدال: '||c.name,160),c.phone);
 insert into tenant_private.tradein_suppliers values(p_store,e.customer_id,sup);
 end if;
 if e.branch_id is null then buy:=tenant_private.purchase(p_store,gen_random_uuid(),sup,p_used_product,p_currency,1,e.amount_minor,0,'Trade-in '||p_id::text);
 else buy:=tenant_private.branch_purchase(p_store,e.branch_id,gen_random_uuid(),sup,p_used_product,p_currency,1,e.amount_minor,0,'Trade-in '||p_id::text);end if;
 off:=least(total,e.amount_minor);
 insert into public.mt_debt_payments(store_id,debt_id,request_id,amount_minor,actor,settlement_method) values(p_store,debt,gen_random_uuid(),off,auth.uid(),'tradein_offset') returning id into dp;
 update public.mt_installments set paid_minor=paid_minor+off where store_id=p_store and debt_id=debt and number=1;
 insert into public.mt_payment_allocations(store_id,payment_id,debt_id,installment_number,amount_minor) values(p_store,dp,debt,1,off);
 update public.mt_debts set remaining_minor=remaining_minor-off where store_id=p_store and id=debt;
 insert into public.mt_supplier_payments(store_id,request_id,purchase_id,amount_minor,actor,settlement_method) values(p_store,gen_random_uuid(),buy,off,auth.uid(),'tradein_offset') returning id into sp;
 update public.mt_purchases set paid_minor=paid_minor+off where store_id=p_store and id=buy;
 if p_difference>0 then perform tenant_private.pay_debt(p_store,debt,gen_random_uuid(),p_currency,p_difference);
 elsif p_difference<0 then perform tenant_private.pay_supplier(p_store,gen_random_uuid(),buy,p_currency,-p_difference);end if;
 insert into tenant_private.tradein_settlements(store_id,id,request_id,actor,used_product_id,lines,purchase_id,sale_id,debt_payment_id,supplier_payment_id,currency,estimate_minor,sale_minor,offset_minor,cash_difference_minor) values(p_store,p_id,p_request,auth.uid(),p_used_product,p_lines,buy,sid,dp,sp,p_currency,e.amount_minor,total,off,p_difference);
 update tenant_private.tradein_estimates set state='settled',purchase_id=buy,sale_id=sid where store_id=p_store and id=p_id;
 return p_id;
end $$;
create function public.mt_tradein_execute(p_store uuid,p_request uuid,p_id uuid,p_used_product uuid,p_currency text,p_lines jsonb,p_difference bigint,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.tradein_execute(p_store,p_request,p_id,p_used_product,p_currency,p_lines,p_difference,p_confirm)$$;
create function tenant_private.tradein_result(p_store uuid,p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select jsonb_build_object('id',id,'purchase_id',purchase_id,'sale_id',sale_id,'currency',currency,'estimate_minor',estimate_minor,'sale_minor',sale_minor,'offset_minor',offset_minor,'cash_difference_minor',cash_difference_minor,'created_at',created_at) into r from tenant_private.tradein_settlements where store_id=p_store and id=p_id;
 return r;
end $$;
create function public.mt_tradein_result(p_store uuid,p_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.tradein_result(p_store,p_id)$$;
create or replace function tenant_private.journal_pairs(p_store uuid,p_until timestamptz)
returns table(posted_at timestamptz,source_type text,source_id uuid,currency text,debit_account text,credit_account text,amount numeric)
language sql stable security definer set search_path='' as $$
with cash as (
 select * from public.mt_cash_movements where store_id=p_store and created_at<p_until
),costs as (
 select * from tenant_private.cost_postings where store_id=p_store and created_at<p_until
),return_costs as (
 select r.*,l.currency as source_currency,r.units::numeric*l.unit_cost_minor as source_cost
 from tenant_private.return_cost_postings r join tenant_private.stock_layers l on l.store_id=r.store_id and l.product_id=r.product_id and l.id=r.layer_id
 where r.store_id=p_store and r.created_at<p_until
),pairs(posted_at,source_type,source_id,currency,debit_account,credit_account,amount) as (
 select c.created_at,'cash',c.id,c.currency,
 case c.kind when 'expense' then 'expense_unclassified' when 'supplier_payment' then 'accounts_payable' when 'exchange' then 'fx_clearing' else 'cash' end,
 case c.kind when 'sale' then 'sales_revenue' when 'funding' then 'funding_unclassified' when 'debt_payment' then 'accounts_receivable' when 'repair_receipt' then 'repair_revenue' when 'mixed_receipt' then 'fx_clearing' when 'supplier_refund' then 'accounts_payable' else 'cash' end,c.amount_minor::numeric
 from cash c where c.kind in ('sale','funding','expense','exchange','debt_payment','supplier_payment','repair_receipt','mixed_receipt','supplier_refund')
 union all select created_at,'exchange_target',id,target_currency,'cash','fx_clearing',target_amount_minor from cash where kind='exchange'
 union all select created_at,'credit_sale',id,currency,'accounts_receivable','sales_revenue',total_minor from public.mt_sales where store_id=p_store and payment_mode='credit' and created_at<p_until
 union all select created_at,'mixed_sale',id,currency,'fx_clearing','sales_revenue',total_minor from public.mt_sales where store_id=p_store and payment_mode='mixed' and created_at<p_until
 union all select created_at,'sale_return_debt',id,currency,'sales_returns','accounts_receivable',debt_reduction_minor from public.mt_returns where store_id=p_store and created_at<p_until
 union all select created_at,'sale_return_cash',id,currency,'sales_returns','cash',refund_minor from public.mt_returns where store_id=p_store and created_at<p_until
 union all select created_at,'repair_refund',id,currency,'sales_returns','cash',amount_minor from public.mt_repair_refunds where store_id=p_store and created_at<p_until
 union all select created_at,'purchase',id,currency,'inventory','accounts_payable',total_minor from public.mt_purchases where store_id=p_store and created_at<p_until
 union all select created_at,'supplier_return',id,currency,'accounts_payable','inventory',units::numeric*unit_cost_minor from public.mt_supplier_returns where store_id=p_store and created_at<p_until
 union all select e.created_at,'standalone_intake',e.request_id,i.currency,'inventory','stock_intake_unclassified',i.units::numeric*i.unit_cost_minor
 from tenant_private.cost_intakes i join public.mt_stock_events e on e.store_id=i.store_id and e.request_id=i.request_id
 where i.store_id=p_store and e.created_at<p_until and not exists(select 1 from public.mt_purchases p where p.store_id=i.store_id and p.intake_request=i.request_id)
 union all select e.created_at,'stock_adjustment',e.request_id,l.currency,'stock_adjustment_expense','inventory',a.units::numeric*l.unit_cost_minor
 from public.mt_stock_events e join tenant_private.stock_consumptions a on a.store_id=e.store_id and a.product_id=e.product_id and a.event_id=e.request_id
 join tenant_private.stock_layers l on l.store_id=a.store_id and l.product_id=a.product_id and l.id=a.layer_id
 where e.store_id=p_store and e.created_at<p_until and e.delta<0 and e.sale_id is null and e.supplier_return_id is null and not exists(select 1 from tenant_private.cost_postings r where r.store_id=e.store_id and r.event_id=e.request_id)
 union all select created_at,'cost_source',event_id,source_currency,
 case when source_currency<>invoice_currency and invoice_cost_minor is not null then 'fx_clearing' else 'cost_of_goods_services' end,'inventory',source_cost_minor from costs
 union all select created_at,'cost_conversion',event_id,invoice_currency,'cost_of_goods_services','fx_clearing',invoice_cost_minor from costs where source_currency<>invoice_currency and invoice_cost_minor is not null
 union all select created_at,'return_cost_source',return_id,source_currency,'inventory',
 case when source_currency<>invoice_currency and invoice_cost_minor is not null then 'fx_clearing' else 'cost_of_goods_services' end,source_cost from return_costs
 union all select created_at,'return_cost_conversion',return_id,invoice_currency,'fx_clearing','cost_of_goods_services',invoice_cost_minor from return_costs where source_currency<>invoice_currency and invoice_cost_minor is not null
 union all select created_at,'tradein_offset',id,currency,'accounts_payable','accounts_receivable',offset_minor from tenant_private.tradein_settlements where store_id=p_store and created_at<p_until
 union all select created_at,'accounting_adjustment',id,currency,debit_account,credit_account,amount_minor from public.mt_accounting_adjustments where store_id=p_store and created_at<p_until
 union all select created_at,'indirect_tax',id,currency,case kind when 'sale' then 'sales_revenue' when 'repair' then 'repair_revenue' else 'indirect_tax_payable' end,case when kind in ('sale','repair') then 'indirect_tax_payable' else 'sales_returns' end,tax_minor from public.mt_indirect_tax_entries where store_id=p_store and created_at<p_until
)
select * from pairs where pairs.amount>0;
$$;

revoke all on function tenant_private.tradein_execute(uuid,uuid,uuid,uuid,text,jsonb,bigint,boolean),public.mt_tradein_execute(uuid,uuid,uuid,uuid,text,jsonb,bigint,boolean),tenant_private.tradein_result(uuid,uuid),public.mt_tradein_result(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tradein_execute(uuid,uuid,uuid,uuid,text,jsonb,bigint,boolean),public.mt_tradein_execute(uuid,uuid,uuid,uuid,text,jsonb,bigint,boolean),tenant_private.tradein_result(uuid,uuid),public.mt_tradein_result(uuid,uuid) to authenticated;
commit;
