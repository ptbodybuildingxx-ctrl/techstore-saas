-- Shard-ready directory; only the current shared database can serve tenants.
begin;
do $$ begin
 if to_regclass('tenant_private.workspaces') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required'; end if;
end $$;
create table tenant_private.shards(
 code text primary key check(code ~ '^[a-z][a-z0-9-]{2,39}$'),
 state text not null check(state in ('local','planned')),
 region text not null check(length(region) between 1 and 80),
 created_at timestamptz not null default now()
);
create unique index mt_single_local_shard on tenant_private.shards(state) where state='local';
insert into tenant_private.shards(code,state,region) values('shared-001','local','eu-north-1');
create table tenant_private.placements(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 shard_code text not null references tenant_private.shards(code),
 generation bigint not null default 1 check(generation>0),
 assigned_at timestamptz not null default now()
);
create index mt_placement_shard_idx on tenant_private.placements(shard_code,store_id);
insert into tenant_private.placements(store_id,shard_code) select store_id,'shared-001' from tenant_private.workspaces;
create table tenant_private.move_plans(
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null references tenant_private.placements(store_id),
 source_shard text not null references tenant_private.shards(code),
 destination_shard text not null references tenant_private.shards(code),
 expected_generation bigint not null check(expected_generation>0),
 requested_by uuid not null,
 requested_at timestamptz not null default now(),
 state text not null default 'planned' check(state in ('planned','cancelled')),
 cancelled_at timestamptz,
 check(source_shard<>destination_shard),
 check((state='cancelled')=(cancelled_at is not null))
);
create unique index mt_one_move_per_store on tenant_private.move_plans(store_id) where state='planned';
create index mt_moves_recent_idx on tenant_private.move_plans(requested_at desc,id);
alter table tenant_private.shards enable row level security;
alter table tenant_private.placements enable row level security;
alter table tenant_private.move_plans enable row level security;
revoke all on tenant_private.shards,tenant_private.placements,tenant_private.move_plans from public,anon,authenticated,service_role;
create function tenant_private.assign_local_shard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into tenant_private.placements(store_id,shard_code) select new.store_id,code from tenant_private.shards where state='local';
 if not found then raise exception 'No local shard available';end if;
 return new;
end $$;
create trigger mt_assign_local_shard after insert on tenant_private.workspaces for each row execute function tenant_private.assign_local_shard();
-- Defense in depth: development placements are immutable. A real move requires a
-- later migration with audited, generation-fenced cutover and independent data validation.
create function tenant_private.reject_placement_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 raise exception 'Shard cutover is not implemented' using errcode='22023';
end $$;
create trigger mt_placement_immutable before update or delete on tenant_private.placements for each row execute function tenant_private.reject_placement_change();
create or replace function tenant_private.member_role(p_store uuid) returns text
language sql stable security definer set search_path='' as $$
 select m.role from tenant_private.members m join auth.users u on u.id=m.user_id
 join tenant_private.placements p on p.store_id=m.store_id join tenant_private.shards sh on sh.code=p.shard_code and sh.state='local'
 where m.store_id=p_store and m.user_id=auth.uid() and m.active and not u.is_anonymous and saas_private.live_session()
$$;
create function tenant_private.shard_register(p_code text,p_region text) returns text
language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501';end if;
 if p_code is null or p_code !~ '^[a-z][a-z0-9-]{2,39}$' or p_region is null or length(btrim(p_region)) not between 1 and 80 then raise exception 'Invalid planned group' using errcode='22023';end if;
 insert into tenant_private.shards(code,state,region) values(p_code,'planned',btrim(p_region));
 return p_code;
end $$;
create function tenant_private.plan_move(p_store uuid,p_destination text,p_action text) returns uuid
language plpgsql security definer set search_path='' as $$
declare pl tenant_private.placements%rowtype; mv tenant_private.move_plans%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501';end if;
 if p_store is null or p_destination is null or p_action is null or p_action not in ('plan','cancel') then raise exception 'Invalid move request' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store and state in ('provisioning','suspended') for update;
 if not found then raise exception 'Shared development store required' using errcode='22023';end if;
 select * into pl from tenant_private.placements where store_id=p_store;
 if not found then raise exception 'No placement' using errcode='22023';end if;
 select * into mv from tenant_private.move_plans where store_id=p_store and state='planned';
 if p_action='cancel' then
  if mv.id is null or mv.destination_shard<>p_destination then return null;end if;
  update tenant_private.move_plans set state='cancelled',cancelled_at=now() where id=mv.id;
  return mv.id;
 end if;
 if p_destination=pl.shard_code or not exists(select 1 from tenant_private.shards where code=p_destination and state='planned') then raise exception 'Planned destination required' using errcode='22023';end if;
 if mv.id is not null then
  if mv.destination_shard=p_destination and mv.expected_generation=pl.generation then return mv.id;end if;
  raise exception 'Cancel existing move first' using errcode='22023';
 end if;
 insert into tenant_private.move_plans(store_id,source_shard,destination_shard,expected_generation,requested_by) values(p_store,pl.shard_code,p_destination,pl.generation,auth.uid()) returning * into mv;
 return mv.id;
end $$;
create function tenant_private.cancel_closed_move() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='closed' then update tenant_private.move_plans set state='cancelled',cancelled_at=now() where store_id=new.id and state='planned';end if;
 return new;
end $$;
create trigger mt_cancel_closed_move after update of state on public.saas_stores for each row execute function tenant_private.cancel_closed_move();
create function tenant_private.shard_overview(p_after uuid,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page size' using errcode='22023';end if;
 select jsonb_build_object(
 'shards',coalesce((select jsonb_agg(to_jsonb(x) order by code) from (select s.code,s.state,s.region,(select count(*) from tenant_private.placements p where p.shard_code=s.code) as tenants from tenant_private.shards s order by code limit 100) x),'[]'::jsonb),
 'placements',coalesce((select jsonb_agg(to_jsonb(x) order by store_id) from (select p.store_id,s.name,s.slug,s.state as store_state,p.shard_code,p.generation,m.destination_shard as planned_destination from tenant_private.placements p join public.saas_stores s on s.id=p.store_id left join tenant_private.move_plans m on m.store_id=p.store_id and m.state='planned' where p_after is null or p.store_id>p_after order by p.store_id limit p_limit) x),'[]'::jsonb)
 ) into r;
 return r;
end $$;
-- Keyset paging avoids full-table scans and large OFFSET for tenant product lists.
create function public.mt_list_products(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_products
language plpgsql stable security invoker set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page size' using errcode='22023';end if;
 return query select * from public.mt_products where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $$;
create function public.mt_admin_shard_register(p_code text,p_region text) returns text
language sql security invoker set search_path='' as $$ select tenant_private.shard_register(p_code,p_region) $$;
create function public.mt_admin_move_plan(p_store uuid,p_destination text,p_action text) returns uuid
language sql security invoker set search_path='' as $$ select tenant_private.plan_move(p_store,p_destination,p_action) $$;
create function public.mt_admin_shard_overview(p_after uuid default null,p_limit integer default 50) returns jsonb
language sql stable security invoker set search_path='' as $$ select tenant_private.shard_overview(p_after,p_limit) $$;
revoke all on function tenant_private.assign_local_shard(),tenant_private.reject_placement_change(),tenant_private.cancel_closed_move(),tenant_private.shard_register(text,text),tenant_private.plan_move(uuid,text,text),tenant_private.shard_overview(uuid,integer),public.mt_list_products(uuid,uuid,integer),public.mt_admin_shard_register(text,text),public.mt_admin_move_plan(uuid,text,text),public.mt_admin_shard_overview(uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.shard_register(text,text),tenant_private.plan_move(uuid,text,text),tenant_private.shard_overview(uuid,integer),public.mt_list_products(uuid,uuid,integer),public.mt_admin_shard_register(text,text),public.mt_admin_move_plan(uuid,text,text),public.mt_admin_shard_overview(uuid,integer) to authenticated;
commit;