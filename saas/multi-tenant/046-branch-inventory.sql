-- Branch allocations preserve the existing store-wide FIFO and accounting ledger.
begin;
create table tenant_private.branches(store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),name text not null check(length(btrim(name)) between 1 and 120),primary key(store_id,id),unique(store_id,name));
create table tenant_private.branch_stock(store_id uuid not null,branch_id uuid not null,product_id uuid not null,units bigint not null check(units between 0 and 1000000000),primary key(store_id,branch_id,product_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),foreign key(store_id,product_id) references public.mt_products(store_id,id));
create index mt_branch_product on tenant_private.branch_stock(store_id,product_id);
create table tenant_private.branch_transfers(store_id uuid not null,request_id uuid not null,source uuid,target uuid,product_id uuid not null,units bigint not null check(units between 1 and 1000000000),actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,request_id),foreign key(store_id,source) references tenant_private.branches(store_id,id),foreign key(store_id,target) references tenant_private.branches(store_id,id),foreign key(store_id,product_id) references public.mt_products(store_id,id),check(source is distinct from target));
create table tenant_private.branch_sales(store_id uuid not null,sale_id uuid not null,branch_id uuid not null,primary key(store_id,sale_id),foreign key(store_id,sale_id) references public.mt_sales(store_id,id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
alter table tenant_private.branches enable row level security;
alter table tenant_private.branch_stock enable row level security;
alter table tenant_private.branch_transfers enable row level security;
alter table tenant_private.branch_sales enable row level security;
revoke all on tenant_private.branches,tenant_private.branch_stock,tenant_private.branch_transfers,tenant_private.branch_sales from public,anon,authenticated,service_role;
create function tenant_private.branch_allocated(p_store uuid,p_product uuid) returns bigint language sql stable security definer set search_path='' as $$select coalesce(sum(units),0)::bigint from tenant_private.branch_stock where store_id=p_store and product_id=p_product$$;
create function tenant_private.guard_branch_quantity() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.quantity<old.quantity and new.quantity<tenant_private.branch_allocated(new.store_id,new.id)+(select coalesce(sum(units),0) from tenant_private.order_reservations where store_id=new.store_id and product_id=new.id) then raise exception 'Stock allocated to branches or reserved orders' using errcode='22023';end if;return new;
end $$;
create trigger mt_guard_branch_quantity before update of quantity on public.mt_products for each row execute function tenant_private.guard_branch_quantity();
create function tenant_private.guard_branch_reservation() returns trigger language plpgsql security definer set search_path='' as $$
declare q bigint;
begin
 select quantity into strict q from public.mt_products where store_id=new.store_id and id=new.product_id for update;
 if q<tenant_private.branch_allocated(new.store_id,new.product_id)+new.units+(select coalesce(sum(units),0) from tenant_private.order_reservations where store_id=new.store_id and product_id=new.product_id) then raise exception 'Insufficient main stock for delivery' using errcode='22023';end if;return new;
end $$;
create trigger mt_branch_reservation before insert on tenant_private.order_reservations for each row execute function tenant_private.guard_branch_reservation();
create function tenant_private.branch_create(p_store uuid,p_name text) returns uuid language plpgsql security definer set search_path='' as $$
declare v uuid;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not coalesce(tenant_private.can_write(p_store),false) then raise exception 'Owner required' using errcode='42501';end if;
 if p_name is null or length(btrim(p_name)) not between 1 and 120 then raise exception 'Invalid branch' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if (select count(*) from tenant_private.branches where store_id=p_store)>=50 then raise exception 'Branch limit' using errcode='22023';end if;
 insert into tenant_private.branches(store_id,name) values(p_store,btrim(p_name)) returning id into v;return v;
end $$;
create function tenant_private.branch_transfer(p_store uuid,p_request uuid,p_source uuid,p_target uuid,p_product uuid,p_units bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare q bigint;old tenant_private.branch_transfers%rowtype;
begin
 if not coalesce(tenant_private.can_write(p_store),false) then raise exception 'Stock write denied' using errcode='42501';end if;
 if p_request is null or p_source is not distinct from p_target or p_units is null or p_units not between 1 and 1000000000 then raise exception 'Invalid transfer' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 select * into old from tenant_private.branch_transfers where store_id=p_store and request_id=p_request;
 if found then if old.actor<>auth.uid() or old.source is distinct from p_source or old.target is distinct from p_target or old.product_id is distinct from p_product or old.units<>p_units then raise exception 'Conflicting transfer' using errcode='22023';end if;return p_request;end if;
 if (p_source is not null and not exists(select 1 from tenant_private.branches where store_id=p_store and id=p_source)) or (p_target is not null and not exists(select 1 from tenant_private.branches where store_id=p_store and id=p_target)) then raise exception 'Unknown branch' using errcode='22023';end if;
 select quantity into q from public.mt_products where store_id=p_store and id=p_product for update;
 if not found then raise exception 'Unknown product' using errcode='22023';end if;
 if p_source is null then
  if q-tenant_private.branch_allocated(p_store,p_product)-(select coalesce(sum(units),0) from tenant_private.order_reservations where store_id=p_store and product_id=p_product)<p_units then raise exception 'Insufficient main stock' using errcode='22023';end if;
 else
  update tenant_private.branch_stock set units=units-p_units where store_id=p_store and branch_id=p_source and product_id=p_product and units>=p_units;
  if not found then raise exception 'Insufficient branch stock' using errcode='22023';end if;
 end if;
 if p_target is not null then insert into tenant_private.branch_stock(store_id,branch_id,product_id,units) values(p_store,p_target,p_product,p_units) on conflict(store_id,branch_id,product_id) do update set units=branch_stock.units+excluded.units;end if;
 insert into tenant_private.branch_transfers(store_id,request_id,source,target,product_id,units,actor) values(p_store,p_request,p_source,p_target,p_product,p_units,auth.uid());return p_request;
end $$;
create function tenant_private.branch_overview(p_store uuid,p_product uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;role_now text:=tenant_private.member_role(p_store);
begin
 if not coalesce(role_now in ('owner','stock','cashier'),false) then raise exception 'Branch access denied' using errcode='42501';end if;
 select jsonb_build_object('branches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by name) from tenant_private.branches where store_id=p_store),'[]'::jsonb),'stock',case when p_product is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('branch_id',branch_id,'units',units)) from tenant_private.branch_stock where store_id=p_store and product_id=p_product),'[]'::jsonb) end,'main',case when p_product is null then null else (select quantity-tenant_private.branch_allocated(p_store,p_product) from public.mt_products where store_id=p_store and id=p_product) end,'transfers',case when p_product is null or role_now='cashier' then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(x)) from (select request_id,source,target,units,created_at from tenant_private.branch_transfers where store_id=p_store and product_id=p_product order by created_at desc,request_id desc limit 50)x),'[]'::jsonb) end) into r;return r;
end $$;
create function tenant_private.branch_cash_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare x jsonb;r jsonb;s uuid;pid uuid;u bigint;
begin
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Sale denied' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not exists(select 1 from tenant_private.branches where store_id=p_store and id=p_branch) then raise exception 'Unknown branch' using errcode='22023';end if;
 select id into s from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then if not exists(select 1 from tenant_private.branch_sales where store_id=p_store and sale_id=s and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;return tenant_private.record_currency_sale(p_store,p_request,p_currency,p_lines);end if;
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 then raise exception 'Invalid sale' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if coalesce(x->>'units','') !~ '^[0-9]{1,5}$' then raise exception 'Invalid units' using errcode='22023';end if;
  u:=(x->>'units')::bigint;pid:=(x->>'product_id')::uuid;
  if u not between 1 and 10000 then raise exception 'Invalid units' using errcode='22023';end if;
  update tenant_private.branch_stock set units=units-u where store_id=p_store and branch_id=p_branch and product_id=pid and units>=u;
  if not found then raise exception 'Insufficient branch stock' using errcode='22023';end if;
 end loop;
 r:=tenant_private.record_currency_sale(p_store,p_request,p_currency,p_lines);
 insert into tenant_private.branch_sales(store_id,sale_id,branch_id) values(p_store,(r->>'id')::uuid,p_branch);return r;
end $$;
create function tenant_private.restore_branch_return() returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;
begin
 if new.return_id is not null then
  select bs.branch_id into b from public.mt_returns r join tenant_private.branch_sales bs on bs.store_id=r.store_id and bs.sale_id=r.sale_id where r.store_id=new.store_id and r.id=new.return_id;
  if found then insert into tenant_private.branch_stock(store_id,branch_id,product_id,units) values(new.store_id,b,new.product_id,new.delta) on conflict(store_id,branch_id,product_id) do update set units=branch_stock.units+excluded.units;end if;
 end if;return new;
end $$;
create trigger mt_branch_return after insert on public.mt_stock_events for each row execute function tenant_private.restore_branch_return();
create function public.mt_branch_create(p_store uuid,p_name text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_create(p_store,p_name)$$;
create function public.mt_branch_transfer(p_store uuid,p_request uuid,p_source uuid,p_target uuid,p_product uuid,p_units bigint) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_transfer(p_store,p_request,p_source,p_target,p_product,p_units)$$;
create function public.mt_branch_overview(p_store uuid,p_product uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_overview(p_store,p_product)$$;
create function public.mt_branch_cash_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.branch_cash_sale(p_store,p_branch,p_request,p_currency,p_lines)$$;
revoke all on function tenant_private.branch_allocated(uuid,uuid),tenant_private.guard_branch_quantity(),tenant_private.guard_branch_reservation(),tenant_private.restore_branch_return(),tenant_private.branch_create(uuid,text),tenant_private.branch_transfer(uuid,uuid,uuid,uuid,uuid,bigint),tenant_private.branch_overview(uuid,uuid),tenant_private.branch_cash_sale(uuid,uuid,uuid,text,jsonb),public.mt_branch_create(uuid,text),public.mt_branch_transfer(uuid,uuid,uuid,uuid,uuid,bigint),public.mt_branch_overview(uuid,uuid),public.mt_branch_cash_sale(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_create(uuid,text),tenant_private.branch_transfer(uuid,uuid,uuid,uuid,uuid,bigint),tenant_private.branch_overview(uuid,uuid),tenant_private.branch_cash_sale(uuid,uuid,uuid,text,jsonb),public.mt_branch_create(uuid,text),public.mt_branch_transfer(uuid,uuid,uuid,uuid,uuid,bigint),public.mt_branch_overview(uuid,uuid),public.mt_branch_cash_sale(uuid,uuid,uuid,text,jsonb) to authenticated;
commit;
