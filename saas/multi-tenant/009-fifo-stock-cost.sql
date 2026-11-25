-- FIFO acquisition-cost foundation; report only comparable sale-currency gross margin.
begin;
do $$ begin
 if to_regclass('public.mt_returns') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
 if exists(select 1 from public.mt_stock_events) or exists(select 1 from public.mt_products where quantity<>0) then raise exception 'Historical stock requires explicit cost reconciliation before migration';end if;
end $$;
create table tenant_private.stock_layers(
 store_id uuid not null,
 product_id uuid not null,
 id bigint generated always as identity,
 intake_request uuid not null,
 original_units bigint not null check(original_units>0),
 remaining_units bigint not null check(remaining_units>=0 and remaining_units<=original_units),
 currency text,
 unit_cost_minor bigint,
 primary key(store_id,product_id,id),
 unique(store_id,intake_request),
 foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,intake_request) references public.mt_stock_events(store_id,request_id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 check((currency is null and unit_cost_minor is null) or (currency is not null and unit_cost_minor is not null and unit_cost_minor between 0 and 100000000))
);
create index mt_fifo_active_idx on tenant_private.stock_layers(store_id,product_id,id) where remaining_units>0;
create table tenant_private.stock_consumptions(
 store_id uuid not null,
 product_id uuid not null,
 event_id uuid not null,
 layer_id bigint not null,
 units bigint not null check(units>0),
 restored_units bigint not null default 0 check(restored_units>=0 and restored_units<=units),
 primary key(store_id,product_id,event_id,layer_id),
 foreign key(store_id,product_id,layer_id) references tenant_private.stock_layers(store_id,product_id,id),
 foreign key(store_id,event_id) references public.mt_stock_events(store_id,request_id)
);
create table tenant_private.cost_intakes(
 store_id uuid not null,
 request_id uuid not null,
 product_id uuid not null,
 units bigint not null check(units between 1 and 1000000000),
 currency text not null,
 unit_cost_minor bigint not null check(unit_cost_minor between 0 and 100000000),
 note text not null check(length(btrim(note)) between 1 and 300),
 actor uuid not null,
 primary key(store_id,request_id),
 foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
alter table tenant_private.stock_layers enable row level security;
alter table tenant_private.stock_consumptions enable row level security;
alter table tenant_private.cost_intakes enable row level security;
revoke all on tenant_private.stock_layers,tenant_private.stock_consumptions,tenant_private.cost_intakes from public,anon,authenticated,service_role;
create function tenant_private.post_stock_cost() returns trigger
language plpgsql security definer set search_path='' as $$
declare intake tenant_private.cost_intakes%rowtype; l tenant_private.stock_layers%rowtype; c tenant_private.stock_consumptions%rowtype; remaining bigint; used bigint; original_event uuid;
begin
 if new.return_id is not null then
  select e.request_id into strict original_event from public.mt_returns r join public.mt_stock_events e on e.store_id=r.store_id and e.sale_id=r.sale_id and e.product_id=r.product_id where r.store_id=new.store_id and r.id=new.return_id and r.product_id=new.product_id;
  remaining:=new.delta;
  for c in select * from tenant_private.stock_consumptions where store_id=new.store_id and product_id=new.product_id and event_id=original_event and restored_units<units order by layer_id for update loop
   exit when remaining=0;
   used:=least(remaining,c.units-c.restored_units);
   update tenant_private.stock_consumptions set restored_units=restored_units+used where store_id=c.store_id and product_id=c.product_id and event_id=c.event_id and layer_id=c.layer_id;
   update tenant_private.stock_layers set remaining_units=remaining_units+used where store_id=c.store_id and product_id=c.product_id and id=c.layer_id;
   remaining:=remaining-used;
  end loop;
  if remaining<>0 then raise exception 'Return cost allocation mismatch';end if;
 elsif new.delta>0 then
  select * into intake from tenant_private.cost_intakes where store_id=new.store_id and request_id=new.request_id;
  if found and (intake.product_id<>new.product_id or intake.units<>new.delta or intake.actor<>new.actor) then raise exception 'Cost intake mismatch';end if;
  insert into tenant_private.stock_layers(store_id,product_id,intake_request,original_units,remaining_units,currency,unit_cost_minor) values(new.store_id,new.product_id,new.request_id,new.delta,new.delta,intake.currency,intake.unit_cost_minor);
 else
  remaining:=-new.delta;
  for l in select * from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and remaining_units>0 order by id for update loop
   exit when remaining=0;
   used:=least(remaining,l.remaining_units);
   update tenant_private.stock_layers set remaining_units=remaining_units-used where store_id=l.store_id and product_id=l.product_id and id=l.id;
   insert into tenant_private.stock_consumptions(store_id,product_id,event_id,layer_id,units) values(l.store_id,l.product_id,new.request_id,l.id,used);
   remaining:=remaining-used;
  end loop;
  if remaining<>0 then raise exception 'Insufficient tracked stock layers';end if;
 end if;
 if (select coalesce(sum(remaining_units),0) from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and remaining_units>0)<>new.balance then raise exception 'Stock layer balance mismatch';end if;
 return new;
end $$;
create trigger mt_stock_cost_post after insert on public.mt_stock_events for each row execute function tenant_private.post_stock_cost();
create function tenant_private.receive_costed_stock(p_store uuid,p_product uuid,p_request uuid,p_units bigint,p_currency text,p_cost bigint,p_note text) returns bigint
language plpgsql security definer set search_path='' as $$
declare i tenant_private.cost_intakes%rowtype; e public.mt_stock_events%rowtype; q bigint;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_write(p_store),false) then raise exception 'Stock write denied' using errcode='42501';end if;
 if p_request is null or p_product is null or p_units is null or p_units not between 1 and 1000000000 or p_currency is null or p_cost is null or p_cost not between 0 and 100000000 or p_note is null or length(btrim(p_note)) not between 1 and 300 or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Invalid intake' using errcode='22023';end if;
 select * into i from tenant_private.cost_intakes where store_id=p_store and request_id=p_request;
 if found then
  if i.product_id<>p_product or i.units<>p_units or i.currency<>p_currency or i.unit_cost_minor<>p_cost or i.note<>btrim(p_note) or i.actor<>auth.uid() then raise exception 'Conflicting intake request' using errcode='22023';end if;
  select * into strict e from public.mt_stock_events where store_id=p_store and request_id=p_request;
  return e.balance;
 end if;
 if exists(select 1 from public.mt_stock_events where store_id=p_store and request_id=p_request) then raise exception 'Request already used' using errcode='22023';end if;
 select quantity into q from public.mt_products where store_id=p_store and id=p_product for update;
 if not found or q+p_units>1000000000 then raise exception 'Invalid stock balance' using errcode='22023';end if;
 insert into tenant_private.cost_intakes(store_id,request_id,product_id,units,currency,unit_cost_minor,note,actor) values(p_store,p_request,p_product,p_units,p_currency,p_cost,btrim(p_note),auth.uid());
 update public.mt_products set quantity=quantity+p_units where store_id=p_store and id=p_product returning quantity into q;
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(p_store,p_request,p_product,p_units,q,auth.uid());
 return q;
end $$;
create function tenant_private.sale_margin(p_store uuid,p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare s public.mt_sales%rowtype; result jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into s from public.mt_sales where store_id=p_store and id=p_sale;
 if not found then raise exception 'Unknown sale' using errcode='22023';end if;
 with amounts as (
 select l.product_id,l.product_name,l.units,l.unit_price_minor,coalesce((select sum(r.units)::bigint from public.mt_returns r where r.store_id=l.store_id and r.sale_id=l.sale_id and r.product_id=l.product_id),0) returned_units,
 coalesce((select sum(c.units-c.restored_units)::bigint from public.mt_stock_events e join tenant_private.stock_consumptions c on c.store_id=e.store_id and c.product_id=e.product_id and c.event_id=e.request_id where e.store_id=l.store_id and e.sale_id=l.sale_id and e.product_id=l.product_id),0) tracked_units,
 coalesce((select sum(c.units-c.restored_units)::bigint from public.mt_stock_events e join tenant_private.stock_consumptions c on c.store_id=e.store_id and c.product_id=e.product_id and c.event_id=e.request_id join tenant_private.stock_layers k on k.store_id=c.store_id and k.product_id=c.product_id and k.id=c.layer_id where e.store_id=l.store_id and e.sale_id=l.sale_id and e.product_id=l.product_id and k.currency=s.currency),0) comparable_units,
 coalesce((select sum((c.units-c.restored_units)*k.unit_cost_minor)::bigint from public.mt_stock_events e join tenant_private.stock_consumptions c on c.store_id=e.store_id and c.product_id=e.product_id and c.event_id=e.request_id join tenant_private.stock_layers k on k.store_id=c.store_id and k.product_id=c.product_id and k.id=c.layer_id where e.store_id=l.store_id and e.sale_id=l.sale_id and e.product_id=l.product_id and k.currency=s.currency),0) comparable_cost
 from public.mt_sale_lines l where l.store_id=p_store and l.sale_id=p_sale
 ), lines as (
 select product_id,product_name,units,returned_units,(units-returned_units)*unit_price_minor as net_revenue_minor,case when tracked_units=units-returned_units and comparable_units=tracked_units then comparable_cost else null end as cost_minor from amounts
 )
 select jsonb_build_object('sale_id',p_sale,'currency',s.currency,'lines',coalesce(jsonb_agg(to_jsonb(lines)||jsonb_build_object('gross_margin_minor',case when cost_minor is not null then net_revenue_minor-cost_minor else null end) order by product_id),'[]'::jsonb),
 'net_revenue_minor',coalesce(sum(net_revenue_minor),0),'cost_minor',case when count(*)=count(cost_minor) then coalesce(sum(cost_minor),0) else null end,'gross_margin_minor',case when count(*)=count(cost_minor) then coalesce(sum(net_revenue_minor-cost_minor),0) else null end) into result from lines;
 return result;
end $$;
create function public.mt_receive_costed_stock(p_store uuid,p_product uuid,p_request uuid,p_units bigint,p_currency text,p_cost bigint,p_note text) returns bigint language sql security invoker set search_path='' as $$ select tenant_private.receive_costed_stock(p_store,p_product,p_request,p_units,p_currency,p_cost,p_note) $$;
create function public.mt_sale_margin(p_store uuid,p_sale uuid) returns jsonb language sql stable security invoker set search_path='' as $$ select tenant_private.sale_margin(p_store,p_sale) $$;
revoke all on function tenant_private.post_stock_cost(),tenant_private.receive_costed_stock(uuid,uuid,uuid,bigint,text,bigint,text),tenant_private.sale_margin(uuid,uuid),public.mt_receive_costed_stock(uuid,uuid,uuid,bigint,text,bigint,text),public.mt_sale_margin(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.receive_costed_stock(uuid,uuid,uuid,bigint,text,bigint,text),tenant_private.sale_margin(uuid,uuid),public.mt_receive_costed_stock(uuid,uuid,uuid,bigint,text,bigint,text),public.mt_sale_margin(uuid,uuid) to authenticated;
commit;