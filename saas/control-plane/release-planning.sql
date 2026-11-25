-- Central release planning only: no deployment, migration execution or restore.
begin;
do $$ begin
 if to_regclass('saas_private.protected_projects') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Dedicated control plane required'; end if;
end $$;
create table saas_private.release_catalog(
 id uuid primary key default gen_random_uuid(),
 version text unique not null check(version ~ '^(0|[1-9][0-9]{0,5})[.](0|[1-9][0-9]{0,5})[.](0|[1-9][0-9]{0,5})$'),
 commit_sha text not null check(commit_sha ~ '^[0-9a-f]{40}$'),
 bundle_sha256 text not null check(bundle_sha256 ~ '^[0-9a-f]{64}$'),
 migrations_sha256 text not null check(migrations_sha256 ~ '^[0-9a-f]{64}$'),
 notes text not null check(length(notes)<=2000),
 rollback_plan text not null check(length(btrim(rollback_plan)) between 1 and 2000),
 registered_by uuid not null,
 registered_at timestamptz not null default now()
);
create table saas_private.release_targets(
 id uuid primary key default gen_random_uuid(),
 release_id uuid not null references saas_private.release_catalog(id),
 store_id uuid not null references public.saas_stores(id),
 project_ref text not null check(project_ref ~ '^[a-z0-9]{20}$'),
 origin text not null,
 requested_by uuid not null,
 requested_at timestamptz not null default now(),
 state text not null default 'planned' check(state in ('planned','cancelled')),
 cancelled_at timestamptz,
 check((state='cancelled')=(cancelled_at is not null))
);
create unique index saas_one_planned_release_per_store on saas_private.release_targets(store_id) where state='planned';
create index saas_release_target_release_idx on saas_private.release_targets(release_id,requested_at desc);
alter table saas_private.release_catalog enable row level security;
alter table saas_private.release_targets enable row level security;
revoke all on saas_private.release_catalog,saas_private.release_targets from public,anon,authenticated,service_role;
create function saas_private.release_register(p_version text,p_commit text,p_bundle text,p_migrations text,p_notes text,p_rollback text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_version is null or p_version !~ '^(0|[1-9][0-9]{0,5})[.](0|[1-9][0-9]{0,5})[.](0|[1-9][0-9]{0,5})$' or p_commit is null or p_commit !~ '^[0-9a-f]{40}$' or p_bundle is null or p_bundle !~ '^[0-9a-f]{64}$' or p_migrations is null or p_migrations !~ '^[0-9a-f]{64}$' or p_notes is null or length(p_notes)>2000 or p_rollback is null or length(btrim(p_rollback)) not between 1 and 2000 then raise exception 'Invalid release manifest' using errcode='22023'; end if;
 insert into saas_private.release_catalog(version,commit_sha,bundle_sha256,migrations_sha256,notes,rollback_plan,registered_by)
 values(p_version,p_commit,p_bundle,p_migrations,p_notes,btrim(p_rollback),auth.uid()) returning id into v_id;
 return v_id;
end $$;
create function saas_private.release_plan(p_release uuid,p_store uuid,p_action text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_store public.saas_stores%rowtype; v_target saas_private.release_targets%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_release is null or p_store is null or p_action is null or p_action not in ('plan','cancel') then raise exception 'Invalid action' using errcode='22023'; end if;
 select * into v_store from public.saas_stores where id=p_store for update;
 if not found then raise exception 'Unknown store' using errcode='22023'; end if;
 select * into v_target from saas_private.release_targets where store_id=p_store and state='planned';
 if p_action='cancel' then
  if v_target.id is null or v_target.release_id<>p_release then return null; end if;
  update saas_private.release_targets set state='cancelled',cancelled_at=now() where id=v_target.id;
  return v_target.id;
 end if;
 if v_store.state<>'ready' or v_store.project_ref is null or v_store.origin is null or exists(select 1 from saas_private.protected_projects where project_ref=v_store.project_ref) then raise exception 'Eligible independent ready store required' using errcode='22023'; end if;
 if not exists(select 1 from saas_private.release_catalog where id=p_release) then raise exception 'Unknown release' using errcode='22023'; end if;
 if v_target.id is not null then
  if v_target.release_id=p_release and v_target.project_ref=v_store.project_ref and v_target.origin=v_store.origin then return v_target.id; end if;
  raise exception 'Cancel existing plan before changing release' using errcode='22023';
 end if;
 insert into saas_private.release_targets(release_id,store_id,project_ref,origin,requested_by) values(p_release,p_store,v_store.project_ref,v_store.origin,auth.uid()) returning * into v_target;
 return v_target.id;
end $$;
create function saas_private.cancel_stale_release_plan() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state<>'ready' or old.project_ref is distinct from new.project_ref or old.origin is distinct from new.origin then
  update saas_private.release_targets set state='cancelled',cancelled_at=now() where store_id=new.id and state='planned';
 end if;
 return new;
end $$;
create trigger saas_cancel_stale_release_plan after update of state,project_ref,origin on public.saas_stores for each row execute function saas_private.cancel_stale_release_plan();
create function saas_private.release_overview(p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid limit' using errcode='22023'; end if;
 select jsonb_build_object(
 'releases',coalesce((select jsonb_agg(to_jsonb(r) order by r.registered_at desc,r.id) from (select id,version,commit_sha,bundle_sha256,migrations_sha256,notes,rollback_plan,registered_at from saas_private.release_catalog order by registered_at desc,id limit p_limit) r),'[]'::jsonb),
 'targets',coalesce((select jsonb_agg(to_jsonb(t) order by t.requested_at desc,t.id) from (select t.id,t.release_id,r.version,t.store_id,s.name as store_name,t.state,t.requested_at from saas_private.release_targets t join saas_private.release_catalog r on r.id=t.release_id join public.saas_stores s on s.id=t.store_id order by t.requested_at desc,t.id limit p_limit) t),'[]'::jsonb),
 'eligible_stores',coalesce((select jsonb_agg(to_jsonb(s) order by s.name,s.id) from (select id,name,slug from public.saas_stores s where state='ready' and project_ref is not null and origin is not null and not exists(select 1 from saas_private.protected_projects p where p.project_ref=s.project_ref) order by name,id limit p_limit) s),'[]'::jsonb)
 ) into v_result;
 return v_result;
end $$;
create function public.saas_admin_release_register(p_version text,p_commit text,p_bundle text,p_migrations text,p_notes text,p_rollback text) returns uuid
language sql security invoker set search_path='' as $$ select saas_private.release_register(p_version,p_commit,p_bundle,p_migrations,p_notes,p_rollback) $$;
create function public.saas_admin_release_plan(p_release uuid,p_store uuid,p_action text) returns uuid
language sql security invoker set search_path='' as $$ select saas_private.release_plan(p_release,p_store,p_action) $$;
create function public.saas_admin_release_overview(p_limit integer default 50) returns jsonb
language sql stable security invoker set search_path='' as $$ select saas_private.release_overview(p_limit) $$;
revoke all on function saas_private.cancel_stale_release_plan(),saas_private.release_register(text,text,text,text,text,text),saas_private.release_plan(uuid,uuid,text),saas_private.release_overview(integer),public.saas_admin_release_register(text,text,text,text,text,text),public.saas_admin_release_plan(uuid,uuid,text),public.saas_admin_release_overview(integer) from public,anon,authenticated,service_role;
grant execute on function saas_private.release_register(text,text,text,text,text,text),saas_private.release_plan(uuid,uuid,text),saas_private.release_overview(integer),public.saas_admin_release_register(text,text,text,text,text,text),public.saas_admin_release_plan(uuid,uuid,text),public.saas_admin_release_overview(integer) to authenticated;
commit;
