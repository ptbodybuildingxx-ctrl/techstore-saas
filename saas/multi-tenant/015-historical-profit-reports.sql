-- Historical cost postings and period operating result, per invoice currency.
begin;
do $$ begin
 if to_regclass('public.mt_mixed_sales') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
 if exists(select 1 from public.mt_sales) or exists(select 1 from public.mt_repair_invoices) or exists(select 1 from public.mt_returns) then raise exception 'Reconcile historical cost and returns before enabling period reports';end if;
end $$;
create table tenant_private.cost_postings(
 store_id uuid not null,product_id uuid not null,event_id uuid not null,layer_id bigint not null,
 sale_id uuid,repair_invoice_id uuid,
 units bigint not null check(units>0),invoice_currency text not null,source_currency text,source_cost_minor numeric,
 invoice_cost_minor numeric,fx_rate_id uuid,created_at timestamptz not null,
 primary key(store_id,product_id,event_id,layer_id),
 foreign key(store_id,product_id,event_id,layer_id) references tenant_private.stock_consumptions(store_id,product_id,event_id,layer_id),
 foreign key(store_id,sale_id) references public.mt_sales(store_id,id),foreign key(store_id,repair_invoice_id) references public.mt_repair_invoices(store_id,id),
 foreign key(store_id,fx_rate_id) references public.mt_fx_rates(store_id,id),
 check((sale_id is null)<>(repair_invoice_id is null)),
 check(source_cost_minor is null or source_cost_minor>=0),check(invoice_cost_minor is null or invoice_cost_minor>=0)
);
create index mt_cost_postings_period on tenant_private.cost_postings(store_id,created_at,invoice_currency);
create table tenant_private.return_cost_postings(
 store_id uuid not null,return_id uuid not null,product_id uuid not null,event_id uuid not null,layer_id bigint not null,
 units bigint not null check(units>0),invoice_currency text not null,invoice_cost_minor numeric check(invoice_cost_minor>=0),created_at timestamptz not null,
 primary key(store_id,return_id,layer_id),foreign key(store_id,return_id) references public.mt_returns(store_id,id),
 foreign key(store_id,product_id,event_id,layer_id) references tenant_private.cost_postings(store_id,product_id,event_id,layer_id)
);
create index mt_return_cost_period on tenant_private.return_cost_postings(store_id,created_at,invoice_currency);
alter table tenant_private.cost_postings enable row level security;alter table tenant_private.return_cost_postings enable row level security;
revoke all on tenant_private.cost_postings,tenant_private.return_cost_postings from public,anon,authenticated,service_role;
create function tenant_private.snapshot_cost(p_store uuid,p_product uuid,p_event uuid,p_sale uuid,p_repair uuid,p_currency text,p_time timestamptz) returns void
language plpgsql security definer set search_path='' as $$
declare c record;q public.mt_fx_rates%rowtype;cost numeric;converted numeric;rate uuid;total_units bigint:=0;expected bigint;
begin
 select -delta into strict expected from public.mt_stock_events where store_id=p_store and product_id=p_product and request_id=p_event;
 for c in select a.*,l.currency,l.unit_cost_minor from tenant_private.stock_consumptions a join tenant_private.stock_layers l on l.store_id=a.store_id and l.product_id=a.product_id and l.id=a.layer_id where a.store_id=p_store and a.product_id=p_product and a.event_id=p_event order by a.layer_id loop
  cost:=c.units::numeric*c.unit_cost_minor;converted:=null;rate:=null;
  if c.currency=p_currency then converted:=cost;
  elsif c.currency is not null and cost is not null then
   select * into q from public.mt_fx_rates where store_id=p_store and from_currency=c.currency and to_currency=p_currency and created_at<=p_time and created_at>=p_time-interval '24 hours' order by created_at desc,id desc limit 1;
   if found then rate:=q.id;converted:=round(cost*q.numerator/q.denominator);end if;
  end if;
  insert into tenant_private.cost_postings(store_id,product_id,event_id,layer_id,sale_id,repair_invoice_id,units,invoice_currency,source_currency,source_cost_minor,invoice_cost_minor,fx_rate_id,created_at) values(p_store,p_product,p_event,c.layer_id,p_sale,p_repair,c.units,p_currency,c.currency,cost,converted,rate,p_time);
  total_units:=total_units+c.units;
 end loop;
 if total_units<>expected or expected<=0 then raise exception 'Cost snapshot allocation mismatch';end if;
end $$;
create function tenant_private.snapshot_sale_cost() returns trigger
language plpgsql security definer set search_path='' as $$
declare s public.mt_sales%rowtype;
begin
 if new.sale_id is not null then
  select * into strict s from public.mt_sales where store_id=new.store_id and id=new.sale_id;
  perform tenant_private.snapshot_cost(new.store_id,new.product_id,new.request_id,s.id,null,s.currency,s.created_at);
 end if;return new;
end $$;
-- PostgreSQL runs same-kind triggers alphabetically; after mt_stock_cost_post allocates FIFO.
create trigger mt_zz_snapshot_sale_cost after insert on public.mt_stock_events for each row execute function tenant_private.snapshot_sale_cost();
create function tenant_private.snapshot_repair_cost() returns trigger
language plpgsql security definer set search_path='' as $$
declare r public.mt_repair_invoices%rowtype;
begin
 select * into strict r from public.mt_repair_invoices where store_id=new.store_id and id=new.invoice_id;
 perform tenant_private.snapshot_cost(new.store_id,new.product_id,new.stock_request,null,r.id,r.currency,r.created_at);return new;
end $$;
create trigger mt_snapshot_repair_cost after insert on public.mt_repair_invoice_lines for each row execute function tenant_private.snapshot_repair_cost();
create function tenant_private.snapshot_return_cost() returns trigger
language plpgsql security definer set search_path='' as $$
declare c record;r public.mt_returns%rowtype;original_event uuid;remaining bigint;used bigint;value numeric;
begin
 if new.return_id is null then return new;end if;
 select * into strict r from public.mt_returns where store_id=new.store_id and id=new.return_id;
 select request_id into strict original_event from public.mt_stock_events where store_id=new.store_id and sale_id=r.sale_id and product_id=r.product_id;
 remaining:=new.delta;
 for c in select a.units,a.restored_units,a.layer_id,k.invoice_cost_minor from tenant_private.stock_consumptions a join tenant_private.cost_postings k on k.store_id=a.store_id and k.product_id=a.product_id and k.event_id=a.event_id and k.layer_id=a.layer_id where a.store_id=new.store_id and a.product_id=new.product_id and a.event_id=original_event and a.restored_units<a.units order by a.layer_id loop
  exit when remaining=0;
  used:=least(remaining,c.units-c.restored_units);
  value:=round(c.invoice_cost_minor*(c.restored_units+used)/c.units)-round(c.invoice_cost_minor*c.restored_units/c.units);
  insert into tenant_private.return_cost_postings(store_id,return_id,product_id,event_id,layer_id,units,invoice_currency,invoice_cost_minor,created_at) values(new.store_id,r.id,new.product_id,original_event,c.layer_id,used,r.currency,value,r.created_at);
  remaining:=remaining-used;
 end loop;
 if remaining<>0 then raise exception 'Return cost snapshot allocation mismatch';end if;
 return new;
end $$;
-- BEFORE insert sees original restored_units; existing AFTER trigger performs restoration.
create trigger mt_snapshot_return_cost before insert on public.mt_stock_events for each row execute function tenant_private.snapshot_return_cost();
create function tenant_private.operating_report(p_store uuid,p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;lo timestamptz;hi timestamptz;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'UTC';hi:=(p_to+1)::timestamp at time zone 'UTC';
 with revenue_events as (
 select currency,total_minor::numeric as goods,0::numeric as repairs,0::numeric as returns from public.mt_sales where store_id=p_store and created_at>=lo and created_at<hi
 union all select currency,0,total_minor,0 from public.mt_repair_invoices where store_id=p_store and created_at>=lo and created_at<hi
 union all select currency,0,0,total_minor from public.mt_returns where store_id=p_store and created_at>=lo and created_at<hi
 ),revenues as (select currency,sum(goods) goods,sum(repairs) repairs,sum(returns) returns from revenue_events group by currency),
 cost_events as (select invoice_currency currency,invoice_cost_minor cost from tenant_private.cost_postings where store_id=p_store and created_at>=lo and created_at<hi union all select invoice_currency,-invoice_cost_minor from tenant_private.return_cost_postings where store_id=p_store and created_at>=lo and created_at<hi),
 costs as (select currency,sum(cost) cost,count(*) filter(where cost is null) unknown from cost_events group by currency),
 expenses as (select currency,sum(amount_minor)::numeric unclassified from public.mt_cash_movements where store_id=p_store and created_at>=lo and created_at<hi and kind='expense' group by currency),
 vals as (select c.currency,coalesce(v.goods,0) goods,coalesce(v.repairs,0) repairs,coalesce(v.returns,0) returns,coalesce(k.cost,0) known_cost,coalesce(k.unknown,0) unknown,coalesce(e.unclassified,0) unclassified from tenant_private.sale_currencies c left join revenues v on v.currency=c.currency left join costs k on k.currency=c.currency left join expenses e on e.currency=c.currency where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'goods_revenue',goods::text,'repair_revenue',repairs::text,'returns',returns::text,'net_revenue',(goods+repairs-returns)::text,'cost',case when unknown=0 then known_cost::text else null end,'gross_margin',case when unknown=0 then (goods+repairs-returns-known_cost)::text else null end,'unknown_cost_allocations',unknown,'unclassified_cash_expenses',unclassified::text,'indicative_after_cash_expenses',case when unknown=0 then (goods+repairs-returns-known_cost-unclassified)::text else null end) order by currency),'[]'::jsonb) into r from vals;
 return r;
end $$;
create function public.mt_operating_report(p_store uuid,p_from date,p_to date) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.operating_report(p_store,p_from,p_to)$$;
revoke all on function tenant_private.snapshot_cost(uuid,uuid,uuid,uuid,uuid,text,timestamptz),tenant_private.snapshot_sale_cost(),tenant_private.snapshot_repair_cost(),tenant_private.snapshot_return_cost(),tenant_private.operating_report(uuid,date,date),public.mt_operating_report(uuid,date,date) from public,anon,authenticated,service_role;
grant execute on function tenant_private.operating_report(uuid,date,date),public.mt_operating_report(uuid,date,date) to authenticated;
commit;