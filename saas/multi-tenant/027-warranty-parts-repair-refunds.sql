begin;
do $$ begin if to_regclass('public.mt_supplier_returns') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS required';end if;end $$;
create table public.mt_warranty_parts(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,claim_id uuid not null,product_id uuid not null,
 units bigint not null check(units between 1 and 10000),stock_request uuid not null,reason text not null check(length(btrim(reason)) between 1 and 300),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),unique(store_id,stock_request),
 foreign key(store_id,claim_id) references public.mt_warranty_claims(store_id,id),foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,stock_request) references public.mt_stock_events(store_id,request_id)
);
create table public.mt_repair_refunds(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,invoice_id uuid not null,currency text not null,
 amount_minor bigint not null check(amount_minor between 1 and 100000000000000),reason text not null check(length(btrim(reason)) between 1 and 300),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,invoice_id) references public.mt_repair_invoices(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
create index mt_repair_refund_invoice on public.mt_repair_refunds(store_id,invoice_id);
create index mt_warranty_parts_claim on public.mt_warranty_parts(store_id,claim_id);
alter table public.mt_cash_movements drop constraint mt_cash_movements_kind_check,
 add constraint mt_cash_movements_kind_check check(kind in ('sale','funding','expense','exchange','debt_payment','return_refund','supplier_payment','repair_receipt','mixed_receipt','supplier_refund','repair_refund')),
 add column repair_refund_id uuid,add foreign key(store_id,repair_refund_id) references public.mt_repair_refunds(store_id,id),add unique(store_id,repair_refund_id),add check((kind='repair_refund')=(repair_refund_id is not null));
do $$ declare t text;begin foreach t in array array['mt_warranty_parts','mt_repair_refunds'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('create policy owner_read on public.%I for select to authenticated using (tenant_private.member_role(store_id)=''owner'')',t);
end loop;end $$;
create function tenant_private.warranty_part(p_store uuid,p_request uuid,p_claim uuid,p_product uuid,p_units bigint,p_reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare c public.mt_warranty_claims%rowtype;v public.mt_repair_invoices%rowtype;r public.mt_warranty_parts%rowtype;q bigint;event_id uuid:=gen_random_uuid();
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_claim is null or p_product is null or p_units is null or p_units not between 1 and 10000 or p_reason is null or length(btrim(p_reason)) not between 1 and 300 then raise exception 'Invalid warranty part' using errcode='22023';end if;
 select * into r from public.mt_warranty_parts where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.claim_id<>p_claim or r.product_id<>p_product or r.units<>p_units or r.reason<>btrim(p_reason) then raise exception 'Conflicting request' using errcode='22023';end if;return r.id;
 end if;
 select * into c from public.mt_warranty_claims where store_id=p_store and id=p_claim for update;
 if not found or c.state<>'accepted' then raise exception 'Accepted claim required' using errcode='22023';end if;
 select * into strict v from public.mt_repair_invoices where store_id=p_store and id=c.invoice_id;
 update public.mt_products set quantity=quantity-p_units where store_id=p_store and id=p_product and quantity>=p_units returning quantity into q;
 if not found then raise exception 'Insufficient warranty stock' using errcode='22023';end if;
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(p_store,event_id,p_product,-p_units,q,auth.uid());
 insert into public.mt_warranty_parts(store_id,request_id,claim_id,product_id,units,stock_request,reason,actor) values(p_store,p_request,p_claim,p_product,p_units,event_id,btrim(p_reason),auth.uid()) returning * into r;
 perform tenant_private.snapshot_cost(p_store,p_product,event_id,null,v.id,v.currency,r.created_at);
 return r.id;
end $$;
create function tenant_private.repair_refund(p_store uuid,p_request uuid,p_invoice uuid,p_amount bigint,p_reason text,p_confirm boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare v public.mt_repair_invoices%rowtype;r public.mt_repair_refunds%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_invoice is null or p_amount is null or p_amount not between 1 and 100000000000000 or p_reason is null or length(btrim(p_reason)) not between 1 and 300 or p_confirm is distinct from true then raise exception 'Confirm actual cash refund' using errcode='22023';end if;
 select * into r from public.mt_repair_refunds where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.invoice_id<>p_invoice or r.amount_minor<>p_amount or r.reason<>btrim(p_reason) then raise exception 'Conflicting request' using errcode='22023';end if;return r.id;
 end if;
 select * into v from public.mt_repair_invoices where store_id=p_store and id=p_invoice for update;
 if not found or p_amount>v.total_minor-(select coalesce(sum(amount_minor),0) from public.mt_repair_refunds where store_id=p_store and invoice_id=p_invoice) then raise exception 'Refund exceeds original invoice' using errcode='22023';end if;
 insert into public.mt_repair_refunds(store_id,request_id,invoice_id,currency,amount_minor,reason,actor) values(p_store,p_request,p_invoice,v.currency,p_amount,btrim(p_reason),auth.uid()) returning * into r;
 insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,repair_refund_id) values(p_store,gen_random_uuid(),'repair_refund',v.currency,p_amount,'Repair refund paid',auth.uid(),r.id);
 return r.id;
end $$;
create or replace function tenant_private.cash_report(p_store uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 with movements as (select * from public.mt_cash_movements where store_id=p_store and created_at>=p_from::timestamp at time zone 'UTC' and created_at<(p_to+1)::timestamp at time zone 'UTC'),
 flows as (select currency,kind,case when kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then amount_minor else -amount_minor end as value from movements union all select target_currency,'exchange_in',target_amount_minor from movements where kind='exchange'),
 totals as (select currency,sum(value) filter(where value>0) as incoming,sum(-value) filter(where value<0) as outgoing,sum(value) as net,sum(value) filter(where kind in ('sale','debt_payment','repair_receipt','mixed_receipt')) as collections,sum(-value) filter(where kind in ('return_refund','repair_refund')) as refunds,sum(-value) filter(where kind='supplier_payment') as supplier_payments,sum(value) filter(where kind='supplier_refund') as supplier_refunds,sum(-value) filter(where kind='expense') as expenses from flows group by currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency,'incoming',coalesce(t.incoming,0)::text,'outgoing',coalesce(t.outgoing,0)::text,'net',coalesce(t.net,0)::text,'collections',coalesce(t.collections,0)::text,'refunds',coalesce(t.refunds,0)::text,'supplier_payments',coalesce(t.supplier_payments,0)::text,'supplier_refunds',coalesce(t.supplier_refunds,0)::text,'expenses',coalesce(t.expenses,0)::text) order by c.currency),'[]'::jsonb) into r
 from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store;
 return r;
end $$;
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
)
select * from pairs where pairs.amount>0;
$$;
create or replace function tenant_private.operating_report(p_store uuid,p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;lo timestamptz;hi timestamptz;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'UTC';hi:=(p_to+1)::timestamp at time zone 'UTC';
 with revenue_events as (
 select currency,total_minor::numeric as goods,0::numeric as repairs,0::numeric as returns from public.mt_sales where store_id=p_store and created_at>=lo and created_at<hi
 union all select currency,0,total_minor,0 from public.mt_repair_invoices where store_id=p_store and created_at>=lo and created_at<hi
 union all select currency,0,0,total_minor from public.mt_returns where store_id=p_store and created_at>=lo and created_at<hi
 union all select currency,0,0,amount_minor from public.mt_repair_refunds where store_id=p_store and created_at>=lo and created_at<hi
 ),revenues as (select currency,sum(goods) goods,sum(repairs) repairs,sum(returns) returns from revenue_events group by currency),
 cost_events as (select invoice_currency currency,invoice_cost_minor cost from tenant_private.cost_postings where store_id=p_store and created_at>=lo and created_at<hi union all select invoice_currency,-invoice_cost_minor from tenant_private.return_cost_postings where store_id=p_store and created_at>=lo and created_at<hi),
 costs as (select currency,sum(cost) cost,count(*) filter(where cost is null) unknown from cost_events group by currency),
 expenses as (select currency,sum(amount_minor)::numeric unclassified from public.mt_cash_movements where store_id=p_store and created_at>=lo and created_at<hi and kind='expense' group by currency),
 vals as (select c.currency,coalesce(v.goods,0) goods,coalesce(v.repairs,0) repairs,coalesce(v.returns,0) returns,coalesce(k.cost,0) known_cost,coalesce(k.unknown,0) unknown,coalesce(e.unclassified,0) unclassified from tenant_private.sale_currencies c left join revenues v on v.currency=c.currency left join costs k on k.currency=c.currency left join expenses e on e.currency=c.currency where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'goods_revenue',goods::text,'repair_revenue',repairs::text,'returns',returns::text,'net_revenue',(goods+repairs-returns)::text,'cost',case when unknown=0 then known_cost::text else null end,'gross_margin',case when unknown=0 then (goods+repairs-returns-known_cost)::text else null end,'unknown_cost_allocations',unknown,'unclassified_cash_expenses',unclassified::text,'indicative_after_cash_expenses',case when unknown=0 then (goods+repairs-returns-known_cost-unclassified)::text else null end) order by currency),'[]'::jsonb) into r from vals;
 return r;
end $$;
create function public.mt_warranty_part(p_store uuid,p_request uuid,p_claim uuid,p_product uuid,p_units bigint,p_reason text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.warranty_part(p_store,p_request,p_claim,p_product,p_units,p_reason)$$;
create function public.mt_repair_refund(p_store uuid,p_request uuid,p_invoice uuid,p_amount bigint,p_reason text,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.repair_refund(p_store,p_request,p_invoice,p_amount,p_reason,p_confirm)$$;
do $$ declare t text;f text;begin foreach t in array array['warranty_parts','repair_refunds'] loop
 f:='mt_list_'||t;
 execute format('create function public.%I(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.%I language plpgsql stable security invoker set search_path='''' as $body$ begin if p_limit is null or p_limit not between 1 and 100 then raise exception ''Invalid page'' using errcode=''22023'';end if;return query select * from public.%I where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $body$',f,'mt_'||t,'mt_'||t);
end loop;end $$;
revoke all on function tenant_private.warranty_part(uuid,uuid,uuid,uuid,bigint,text),tenant_private.repair_refund(uuid,uuid,uuid,bigint,text,boolean),public.mt_warranty_part(uuid,uuid,uuid,uuid,bigint,text),public.mt_repair_refund(uuid,uuid,uuid,bigint,text,boolean),public.mt_list_warranty_parts(uuid,uuid,integer),public.mt_list_repair_refunds(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.warranty_part(uuid,uuid,uuid,uuid,bigint,text),tenant_private.repair_refund(uuid,uuid,uuid,bigint,text,boolean),public.mt_warranty_part(uuid,uuid,uuid,uuid,bigint,text),public.mt_repair_refund(uuid,uuid,uuid,bigint,text,boolean),public.mt_list_warranty_parts(uuid,uuid,integer),public.mt_list_repair_refunds(uuid,uuid,integer) to authenticated;
commit;