-- Control plane only. Queue is a record of intent; no paid project creation.
begin;
do $$ begin
 if to_regclass('saas_private.operators') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Dedicated control plane required'; end if;
end $$;
create table saas_private.provisioning_requests (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null references public.saas_stores(id),
 requested_by uuid not null,
 requested_at timestamptz not null default now(),
 state text not null default 'queued' check(state in ('queued','cancelled')),
 cancelled_at timestamptz,
 check ((state='cancelled')=(cancelled_at is not null))
);
create unique index provisioning_one_queued on saas_private.provisioning_requests(store_id) where state='queued';
create index provisioning_store_history on saas_private.provisioning_requests(store_id,requested_at desc);
create table saas_private.protected_projects (
 project_ref text primary key check(project_ref ~ '^[a-z0-9]{20}$')
);
-- The source ref is already forbidden in the base schema. Additional protected refs
-- are configured privately on the control plane.
create table saas_private.trial_grants (
 store_id uuid primary key references public.saas_stores(id),
 project_ref text not null check(project_ref ~ '^[a-z0-9]{20}$'),
 valid_until timestamptz not null,
 approved_at timestamptz not null default now(),
 revoked_at timestamptz,
 check(valid_until>approved_at)
);
alter table saas_private.provisioning_requests enable row level security;
alter table saas_private.protected_projects enable row level security;
alter table saas_private.trial_grants enable row level security;
revoke all on saas_private.provisioning_requests,saas_private.protected_projects,saas_private.trial_grants from public,anon,authenticated,service_role;
grant usage on schema saas_private to service_role;
grant select on saas_private.trial_grants,saas_private.protected_projects to service_role;
-- No browser, service-role or public grant-issuance endpoint. Approval requires a
-- separately verified provisioning workflow, not supplied by this migration.
create function saas_private.protect_project_assignment() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.project_ref is not null and exists(select 1 from saas_private.protected_projects p where p.project_ref=new.project_ref) then
  raise exception 'Protected project cannot be assigned' using errcode='22023';
 end if;
 return new;
end $$;
revoke all on function saas_private.protect_project_assignment() from public,anon,authenticated,service_role;
create trigger saas_protect_project before insert or update of project_ref on public.saas_stores for each row execute function saas_private.protect_project_assignment();
create function saas_private.reconcile_provisioning() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state<>'provisioning' or new.project_ref is not null then
  update saas_private.provisioning_requests set state='cancelled',cancelled_at=now() where store_id=new.id and state='queued';
 end if;
 -- A grant must never survive reassignment, suspension or closure.
 if new.state<>'ready' or old.project_ref is distinct from new.project_ref then
  update saas_private.trial_grants set revoked_at=now() where store_id=new.id and revoked_at is null;
 end if;
 return new;
end $$;
revoke all on function saas_private.reconcile_provisioning() from public,anon,authenticated,service_role;
create trigger saas_reconcile_provisioning after update of state,project_ref on public.saas_stores for each row execute function saas_private.reconcile_provisioning();
create function saas_private.queue_provisioning(p_store uuid,p_action text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_request uuid;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_store is null or p_action is null or p_action not in ('request','cancel') then raise exception 'Invalid action' using errcode='22023'; end if;
 perform 1 from public.saas_stores where id=p_store and state='provisioning' and project_ref is null and origin is null for update;
 if not found then raise exception 'Unprovisioned store required' using errcode='22023'; end if;
 select id into v_request from saas_private.provisioning_requests where store_id=p_store and state='queued';
 if p_action='cancel' then
  if v_request is not null then update saas_private.provisioning_requests set state='cancelled',cancelled_at=now() where id=v_request; end if;
  return v_request;
 end if;
 if not exists(select 1 from public.saas_subscriptions where store_id=p_store and state in ('pending','trial')) then raise exception 'Eligible registration required' using errcode='22023'; end if;
 if v_request is not null then return v_request; end if;
 insert into saas_private.provisioning_requests(store_id,requested_by) values(p_store,auth.uid()) returning id into v_request;
 return v_request;
end $$;
create function saas_private.admin_provisioning_status(p_stores uuid[]) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_stores is null or cardinality(p_stores)>100 or array_position(p_stores,null) is not null then raise exception 'Invalid stores' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'queue',case when q.id is not null then 'queued' else 'none' end,
 'license',case when s.project_ref is null or s.state<>'ready' then 'unprovisioned_or_blocked'
 when sub.state='trial' and sub.valid_until<=now() then 'expired'
 else 'verification_required' end)),'[]'::jsonb) into v_result
 from public.saas_stores s left join saas_private.provisioning_requests q on q.store_id=s.id and q.state='queued' left join public.saas_subscriptions sub on sub.store_id=s.id where s.id=any(p_stores);
 return v_result;
end $$;
create function public.saas_admin_provisioning(p_store uuid,p_action text) returns uuid
language sql security invoker set search_path='' as $$ select saas_private.queue_provisioning(p_store,p_action) $$;
create function public.saas_admin_provisioning_status(p_stores uuid[]) returns jsonb
language sql stable security invoker set search_path='' as $$ select saas_private.admin_provisioning_status(p_stores) $$;
revoke all on function saas_private.queue_provisioning(uuid,text),saas_private.admin_provisioning_status(uuid[]),public.saas_admin_provisioning(uuid,text),public.saas_admin_provisioning_status(uuid[]) from public,anon,authenticated,service_role;
grant execute on function saas_private.queue_provisioning(uuid,text),saas_private.admin_provisioning_status(uuid[]),public.saas_admin_provisioning(uuid,text),public.saas_admin_provisioning_status(uuid[]) to authenticated;
-- Service-only decision; no customer key, no paid entitlement, no shop-side enforcement yet.
create function public.saas_service_trial_entitlement(p_store uuid,p_project text) returns boolean
language sql stable security invoker set search_path='' as $$
 select coalesce(exists(
  select 1 from public.saas_stores s join public.saas_subscriptions sub on sub.store_id=s.id
  join saas_private.trial_grants g on g.store_id=s.id and g.project_ref=s.project_ref
  where s.id=p_store and s.project_ref=p_project and s.state='ready' and s.origin is not null
    and sub.state='trial' and sub.valid_until>now() and g.valid_until>now() and g.revoked_at is null
    and not exists(select 1 from saas_private.protected_projects p where p.project_ref=s.project_ref)
 ),false)
$$;
revoke all on function public.saas_service_trial_entitlement(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.saas_service_trial_entitlement(uuid,text) to service_role;
commit;
