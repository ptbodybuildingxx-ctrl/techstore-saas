-- Shared tenant development foundation. Never apply to the original shop.
begin;
do $$ begin
 if to_regclass('saas_private.billing_sandbox_invoices') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Dedicated SaaS project required'; end if;
end $$;
create schema tenant_private;
revoke all on schema tenant_private from public,anon,authenticated,service_role;
grant usage on schema tenant_private to authenticated;
create table tenant_private.workspaces(
 store_id uuid primary key references public.saas_stores(id),
 created_at timestamptz not null default now()
);
create table tenant_private.members(
 store_id uuid not null references tenant_private.workspaces(store_id),
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null check(role in ('owner','stock','cashier','tech')),
 active boolean not null default true,
 primary key(store_id,user_id)
);
create index mt_member_user_idx on tenant_private.members(user_id,store_id);
create table public.mt_products(
 store_id uuid not null references tenant_private.workspaces(store_id),
 id uuid not null default gen_random_uuid(),
 sku text not null check(length(btrim(sku)) between 1 and 80),
 name text not null check(length(btrim(name)) between 1 and 160),
 quantity bigint not null default 0 check(quantity between 0 and 1000000000),
 created_at timestamptz not null default now(),
 primary key(store_id,id),
 unique(store_id,sku)
);
create table public.mt_stock_events(
 store_id uuid not null,
 request_id uuid not null,
 product_id uuid not null,
 delta bigint not null check(delta between -1000000000 and 1000000000 and delta<>0),
 balance bigint not null check(balance between 0 and 1000000000),
 actor uuid not null,
 created_at timestamptz not null default now(),
 primary key(store_id,request_id),
 foreign key(store_id,product_id) references public.mt_products(store_id,id)
);
create index mt_stock_product_idx on public.mt_stock_events(store_id,product_id,created_at desc);
alter table tenant_private.workspaces enable row level security;
alter table tenant_private.members enable row level security;
alter table public.mt_products enable row level security;
alter table public.mt_stock_events enable row level security;
revoke all on tenant_private.workspaces,tenant_private.members,public.mt_products,public.mt_stock_events from public,anon,authenticated,service_role;
grant select on public.mt_products,public.mt_stock_events to authenticated;
create function tenant_private.member_role(p_store uuid) returns text
language sql stable security definer set search_path='' as $$
 select m.role from tenant_private.members m join auth.users u on u.id=m.user_id
 where m.store_id=p_store and m.user_id=auth.uid() and m.active and not u.is_anonymous and saas_private.live_session()
$$;
-- Access for development only; paid entitlements will be a separate server-side gate.
create function tenant_private.can_write(p_store uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) in ('owner','stock'),false) and exists(
 select 1 from tenant_private.workspaces w join public.saas_stores s on s.id=w.store_id
 join public.saas_subscriptions sub on sub.store_id=s.id
 where w.store_id=p_store and s.state='provisioning' and s.project_ref is null and s.origin is null and sub.state='trial' and sub.valid_until>now())
$$;
create policy mt_products_member_read on public.mt_products for select to authenticated using (tenant_private.member_role(store_id) is not null);
create policy mt_stock_member_read on public.mt_stock_events for select to authenticated using (tenant_private.member_role(store_id) in ('owner','stock'));
-- Prevent legacy per-project provisioning for shared stores.
create function tenant_private.block_legacy_assignment() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from tenant_private.workspaces where store_id=new.id) and (new.project_ref is not null or new.origin is not null or new.state='ready') then raise exception 'Shared tenant must not use dedicated-project workflow' using errcode='22023'; end if;
 return new;
end $$;
create trigger mt_no_project_assignment before update of project_ref,origin,state on public.saas_stores for each row execute function tenant_private.block_legacy_assignment();
create function tenant_private.block_legacy_queue() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='queued' and exists(select 1 from tenant_private.workspaces where store_id=new.store_id) then raise exception 'Shared tenant requires no project request' using errcode='22023'; end if;
 return new;
end $$;
create trigger mt_no_project_queue before insert or update on saas_private.provisioning_requests for each row execute function tenant_private.block_legacy_queue();
create function tenant_private.create_store(p_name text,p_slug text,p_plan text,p_owner uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_store uuid;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501';end if;
 if p_owner is null or not exists(select 1 from auth.users where id=p_owner and email_confirmed_at is not null and not is_anonymous and (banned_until is null or banned_until<=now())) then raise exception 'Verified owner required' using errcode='22023';end if;
 if exists(select 1 from saas_private.operators where user_id=p_owner) then raise exception 'Use separate shop owner account' using errcode='22023';end if;
 v_store:=saas_private.register_store(p_name,p_slug,p_plan);
 insert into tenant_private.workspaces(store_id) values(v_store);
 insert into tenant_private.members(store_id,user_id,role) values(v_store,p_owner,'owner');
 insert into public.saas_memberships(store_id,user_id,role) values(v_store,p_owner,'owner');
 return v_store;
end $$;
create function tenant_private.add_product(p_store uuid,p_sku text,p_name text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_write(p_store),false) then raise exception 'Tenant write not permitted' using errcode='42501';end if;
 if p_sku is null or length(btrim(p_sku)) not between 1 and 80 or p_name is null or length(btrim(p_name)) not between 1 and 160 then raise exception 'Invalid product' using errcode='22023';end if;
 insert into public.mt_products(store_id,sku,name) values(p_store,btrim(p_sku),btrim(p_name)) returning id into v_id;
 return v_id;
end $$;
create function tenant_private.adjust_stock(p_store uuid,p_product uuid,p_delta bigint,p_request uuid) returns bigint
language plpgsql security definer set search_path='' as $$
declare q bigint; e public.mt_stock_events%rowtype;
begin
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_write(p_store),false) then raise exception 'Tenant write not permitted' using errcode='42501';end if;
 if p_product is null or p_request is null or p_delta is null or p_delta=0 or p_delta not between -1000000000 and 1000000000 then raise exception 'Invalid stock adjustment' using errcode='22023';end if;
 select * into e from public.mt_stock_events where store_id=p_store and request_id=p_request;
 if found then
  if e.product_id<>p_product or e.delta<>p_delta or e.actor<>auth.uid() then raise exception 'Conflicting request' using errcode='22023';end if;
  return e.balance;
 end if;
 select quantity into q from public.mt_products where store_id=p_store and id=p_product for update;
 if not found or q+p_delta not between 0 and 1000000000 then raise exception 'Invalid product or balance' using errcode='22023';end if;
 q:=q+p_delta;
 update public.mt_products set quantity=q where store_id=p_store and id=p_product;
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(p_store,p_request,p_product,p_delta,q,auth.uid());
 return q;
end $$;
create function tenant_private.my_stores() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'role',m.role,'can_write',tenant_private.can_write(s.id)) order by s.name,s.id),'[]'::jsonb)
 from tenant_private.members m join public.saas_stores s on s.id=m.store_id
 where m.user_id=auth.uid() and tenant_private.member_role(s.id) is not null
$$;
create function public.mt_admin_create_store(p_name text,p_slug text,p_plan text,p_owner uuid) returns uuid
language sql security invoker set search_path='' as $$ select tenant_private.create_store(p_name,p_slug,p_plan,p_owner) $$;
create function public.mt_add_product(p_store uuid,p_sku text,p_name text) returns uuid
language sql security invoker set search_path='' as $$ select tenant_private.add_product(p_store,p_sku,p_name) $$;
create function public.mt_adjust_stock(p_store uuid,p_product uuid,p_delta bigint,p_request uuid) returns bigint
language sql security invoker set search_path='' as $$ select tenant_private.adjust_stock(p_store,p_product,p_delta,p_request) $$;
create function public.mt_my_stores() returns jsonb
language sql stable security invoker set search_path='' as $$ select tenant_private.my_stores() $$;
revoke all on all functions in schema tenant_private from public,anon,authenticated,service_role;
grant execute on function tenant_private.member_role(uuid),tenant_private.can_write(uuid),tenant_private.create_store(text,text,text,uuid),tenant_private.add_product(uuid,text,text),tenant_private.adjust_stock(uuid,uuid,bigint,uuid),tenant_private.my_stores() to authenticated;
revoke all on function public.mt_admin_create_store(text,text,text,uuid),public.mt_add_product(uuid,text,text),public.mt_adjust_stock(uuid,uuid,bigint,uuid),public.mt_my_stores() from public,anon,authenticated,service_role;
grant execute on function public.mt_admin_create_store(text,text,text,uuid),public.mt_add_product(uuid,text,text),public.mt_adjust_stock(uuid,uuid,bigint,uuid),public.mt_my_stores() to authenticated;
commit;