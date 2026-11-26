-- Optional staff assignments. Branch-scoped stock can release allocated items to main; owner allocates/adjusts.
begin;
create table tenant_private.staff_branch_scope(store_id uuid not null,user_id uuid not null,branch_id uuid not null,role text not null check(role in ('stock','tech')),primary key(store_id,user_id),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
alter table tenant_private.staff_branch_scope enable row level security;revoke all on tenant_private.staff_branch_scope from public,anon,authenticated,service_role;
create function tenant_private.current_branch_scope(p_store uuid) returns uuid language sql stable security definer set search_path='' as $$
 select case tenant_private.member_role(p_store) when 'cashier' then (select branch_id from tenant_private.cashier_branch_scope where store_id=p_store and user_id=auth.uid()) when 'stock' then (select branch_id from tenant_private.staff_branch_scope where store_id=p_store and user_id=auth.uid() and role='stock') when 'tech' then (select branch_id from tenant_private.staff_branch_scope where store_id=p_store and user_id=auth.uid() and role='tech') end
$$;
create function tenant_private.staff_scope_set(p_store uuid,p_user uuid,p_branch uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r text;
begin
 perform tenant_private.owner_write(p_store);
 select role into r from tenant_private.members where store_id=p_store and user_id=p_user and active and role in ('cashier','stock','tech');
 if not found then raise exception 'Active staff required' using errcode='22023';end if;
 if r='cashier' then return tenant_private.cashier_scope_set(p_store,p_user,p_branch);end if;
 if p_branch is null then delete from tenant_private.staff_branch_scope where store_id=p_store and user_id=p_user;return true;end if;
 perform tenant_private.require_branch(p_store,p_branch);
 insert into tenant_private.staff_branch_scope values(p_store,p_user,p_branch,r) on conflict(store_id,user_id) do update set branch_id=excluded.branch_id,role=excluded.role;return true;
end $$;
create function tenant_private.staff_scope_read(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;role_now text:=tenant_private.member_role(p_store);
begin
 if role_now is null then raise exception 'Scope denied' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('user_id',a.user_id,'branch_id',a.branch_id,'name',b.name,'role',a.role) order by a.role,a.user_id),'[]') into r from (select store_id,user_id,branch_id,'cashier'::text as role from tenant_private.cashier_branch_scope union all select store_id,user_id,branch_id,role from tenant_private.staff_branch_scope)a join tenant_private.members m on m.store_id=a.store_id and m.user_id=a.user_id and m.role=a.role and m.active join tenant_private.branches b on b.store_id=a.store_id and b.id=a.branch_id where a.store_id=p_store and (role_now='owner' or a.user_id=auth.uid());return r;
end $$;
create function tenant_private.reset_staff_scope() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not new.active or old.role<>new.role then delete from tenant_private.staff_branch_scope where store_id=new.store_id and user_id=new.user_id;delete from tenant_private.cashier_branch_scope where store_id=new.store_id and user_id=new.user_id;end if;return new;
end $$;
create trigger mt_reset_staff_scope after update of role,active on tenant_private.members for each row execute function tenant_private.reset_staff_scope();
create or replace function tenant_private.can_write(p_store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) in ('owner','stock'),false) and tenant_private.shared_licensed(p_store) and tenant_private.current_branch_scope(p_store) is null
$$;
-- Direct base table access no longer reveals total stock to assigned cashiers/stock employees.
drop policy mt_products_member_read on public.mt_products;
create policy mt_products_member_read on public.mt_products for select to authenticated using (tenant_private.member_role(store_id) is not null and tenant_private.current_branch_scope(store_id) is null);
drop policy mt_stock_member_read on public.mt_stock_events;
create policy mt_stock_member_read on public.mt_stock_events for select to authenticated using (tenant_private.member_role(store_id) in ('owner','stock') and tenant_private.current_branch_scope(store_id) is null);
create function tenant_private.scoped_products(p_store uuid,p_currency text,p_query text,p_after uuid,p_limit integer,p_low boolean)
returns table(store_id uuid,id uuid,sku text,name text,quantity bigint,unit_price_minor bigint,specs jsonb) language plpgsql stable security definer set search_path='' as $$
declare b uuid:=tenant_private.current_branch_scope(p_store);
begin
 if not coalesce(tenant_private.member_role(p_store) in ('owner','stock','cashier'),false) then raise exception 'Tenant access required' using errcode='42501';end if;
 if p_query is null or length(p_query)>100 or p_low is null or p_limit is null or p_limit not between 1 and 100 or (p_currency is not null and p_currency not in ('SYP','USD','EUR')) then raise exception 'Invalid query' using errcode='22023';end if;
 return query select p.store_id,p.id,p.sku,p.name,case when b is null then p.quantity else bs.units end,pp.price_minor,p.specs from public.mt_products p left join tenant_private.branch_stock bs on bs.store_id=p.store_id and bs.product_id=p.id and bs.branch_id=b left join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and (b is null or bs.branch_id=b) and (p_after is null or p.id>p_after) and (not p_low or (case when b is null then p.quantity else bs.units end)<=5) and (btrim(p_query)='' or strpos(lower(p.name),lower(btrim(p_query)))>0 or strpos(lower(p.sku),lower(btrim(p_query)))>0) order by p.id limit p_limit;
end $$;
create or replace function public.mt_search_products(p_store uuid,p_currency text,p_query text,p_after uuid default null,p_limit integer default 50,p_low boolean default false)
returns table(store_id uuid,id uuid,sku text,name text,quantity bigint,unit_price_minor bigint,specs jsonb) language sql stable security invoker set search_path='' as $$select * from tenant_private.scoped_products(p_store,p_currency,p_query,p_after,p_limit,p_low)$$;
create function tenant_private.repair_scope_allowed(p_store uuid,p_repair uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) in ('owner','tech'),false) and (tenant_private.current_branch_scope(p_store) is null or exists(select 1 from tenant_private.branch_repairs where store_id=p_store and repair_id=p_repair and branch_id=tenant_private.current_branch_scope(p_store)))
$$;
drop policy mt_read on public.mt_repairs;create policy mt_read on public.mt_repairs for select to authenticated using(tenant_private.repair_scope_allowed(store_id,id));
drop policy mt_read on public.mt_repair_events;create policy mt_read on public.mt_repair_events for select to authenticated using(tenant_private.repair_scope_allowed(store_id,repair_id));
create or replace function tenant_private.repair_transition(p_store uuid,p_request uuid,p_repair uuid,p_next text,p_note text) returns text language plpgsql security definer set search_path='' as $$
declare r public.mt_repairs%rowtype; e public.mt_repair_events%rowtype; role_now text;
begin
 role_now:=tenant_private.member_role(p_store);
 if coalesce(role_now,'') not in ('owner','tech') then raise exception 'Repair role required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 role_now:=tenant_private.member_role(p_store);
 if coalesce(role_now,'') not in ('owner','tech') or not tenant_private.shared_licensed(p_store) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_repair is null or p_next is null or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid transition' using errcode='22023';end if;
 if not tenant_private.repair_scope_allowed(p_store,p_repair) then raise exception 'Repair branch denied' using errcode='42501';end if;
 if p_next in ('delivered','cancelled') and role_now<>'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into e from public.mt_repair_events where store_id=p_store and request_id=p_request;
 if found then
  if e.actor<>auth.uid() or e.repair_id<>p_repair or e.next_state<>p_next or e.note<>btrim(p_note) then raise exception 'Conflicting repair transition' using errcode='22023';end if;
  return e.next_state;
 end if;
 select * into r from public.mt_repairs where store_id=p_store and id=p_repair for update;
 if not found or not ((r.state='received' and p_next in ('diagnosing','cancelled')) or (r.state='diagnosing' and p_next in ('repairing','cancelled')) or (r.state='repairing' and p_next in ('ready','cancelled')) or (r.state='ready' and p_next in ('delivered','repairing','cancelled'))) then raise exception 'Invalid repair transition' using errcode='22023';end if;
 update public.mt_repairs set state=p_next where store_id=p_store and id=p_repair;
 insert into public.mt_repair_events(store_id,request_id,repair_id,prior_state,next_state,note,actor) values(p_store,p_request,p_repair,r.state,p_next,btrim(p_note),auth.uid());
 return p_next;
end $$;

create or replace function tenant_private.branch_transfer(p_store uuid,p_request uuid,p_source uuid,p_target uuid,p_product uuid,p_units bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare q bigint;old tenant_private.branch_transfers%rowtype;
begin
 if not coalesce(tenant_private.can_write(p_store),false) and not (coalesce(tenant_private.member_role(p_store)='stock',false) and tenant_private.shared_licensed(p_store) and tenant_private.current_branch_scope(p_store) is not null and p_source is not distinct from tenant_private.current_branch_scope(p_store) and p_target is null) then raise exception 'Stock write denied' using errcode='42501';end if;
 if p_request is null or p_source is not distinct from p_target or p_units is null or p_units not between 1 and 1000000000 then raise exception 'Invalid transfer' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if tenant_private.member_role(p_store)='stock' and tenant_private.current_branch_scope(p_store) is not null and (p_source is distinct from tenant_private.current_branch_scope(p_store) or p_target is not null) then raise exception 'Only release from assigned branch to main' using errcode='42501';end if;
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

create or replace function tenant_private.branch_overview(p_store uuid,p_product uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;role_now text:=tenant_private.member_role(p_store);b uuid:=tenant_private.current_branch_scope(p_store);
begin
 if not coalesce(role_now in ('owner','stock','cashier'),false) then raise exception 'Branch access denied' using errcode='42501';end if;
 select jsonb_build_object('branches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by name) from tenant_private.branches where store_id=p_store and (b is null or id=b)),'[]'::jsonb),'stock',case when p_product is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('branch_id',branch_id,'units',units)) from tenant_private.branch_stock where store_id=p_store and product_id=p_product and (b is null or branch_id=b)),'[]'::jsonb) end,'main',case when p_product is null or b is not null then null else (select quantity-tenant_private.branch_allocated(p_store,p_product) from public.mt_products where store_id=p_store and id=p_product) end,'transfers',case when p_product is null or role_now='cashier' then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id desc) from (select request_id,source,target,units,created_at from tenant_private.branch_transfers where store_id=p_store and product_id=p_product and (b is null or source=b or target=b) order by created_at desc,request_id desc limit 50)x),'[]'::jsonb) end) into r;return r;
end $$;

create function public.mt_staff_scope_set(p_store uuid,p_user uuid,p_branch uuid) returns boolean language sql security invoker set search_path='' as $$select tenant_private.staff_scope_set(p_store,p_user,p_branch)$$;
create function public.mt_staff_scope_read(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.staff_scope_read(p_store)$$;
revoke all on function tenant_private.current_branch_scope(uuid),tenant_private.staff_scope_set(uuid,uuid,uuid),tenant_private.staff_scope_read(uuid),tenant_private.reset_staff_scope(),tenant_private.scoped_products(uuid,text,text,uuid,integer,boolean),tenant_private.repair_scope_allowed(uuid,uuid),public.mt_staff_scope_set(uuid,uuid,uuid),public.mt_staff_scope_read(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.current_branch_scope(uuid),tenant_private.staff_scope_set(uuid,uuid,uuid),tenant_private.staff_scope_read(uuid),tenant_private.scoped_products(uuid,text,text,uuid,integer,boolean),tenant_private.repair_scope_allowed(uuid,uuid),public.mt_staff_scope_set(uuid,uuid,uuid),public.mt_staff_scope_read(uuid) to authenticated;
commit;
