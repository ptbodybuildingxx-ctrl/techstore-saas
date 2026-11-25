-- Shared-shard recovery coordination, not a backup or deployment worker.
begin;
do $$ begin if to_regclass('tenant_private.billing_configuration') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;end $$;
create table tenant_private.shared_backup_evidence(
 id uuid primary key default gen_random_uuid(),shard_code text not null references tenant_private.shards(code),captured_at timestamptz not null,
 database_sha256 text not null check(database_sha256 ~ '^[0-9a-f]{64}$'),storage_sha256 text not null check(storage_sha256 ~ '^[0-9a-f]{64}$'),config_sha256 text not null check(config_sha256 ~ '^[0-9a-f]{64}$'),
 restore_target_ref text not null check(restore_target_ref ~ '^[a-z0-9]{20}$'),restored_at timestamptz not null,verified_at timestamptz not null,
 evidence_sha256 text not null check(evidence_sha256 ~ '^[0-9a-f]{64}$'),revoked_at timestamptz,
 check(captured_at<=restored_at and restored_at<=verified_at)
);
create index mt_shared_backup_recent on tenant_private.shared_backup_evidence(shard_code,captured_at desc);
create table tenant_private.shared_recovery_requests(
 id uuid primary key default gen_random_uuid(),request_id uuid not null unique,shard_code text not null references tenant_private.shards(code),
 store_id uuid references tenant_private.workspaces(store_id),kind text not null check(kind in ('project_backup','tenant_export','restore_drill')),
 backup_id uuid references tenant_private.shared_backup_evidence(id),state text not null default 'queued' check(state in ('queued','cancelled')),
 actor uuid not null,created_at timestamptz not null default now(),cancelled_at timestamptz,
 check((kind='tenant_export')=(store_id is not null)),check((kind='restore_drill')=(backup_id is not null)),check((state='cancelled')=(cancelled_at is not null))
);
create index mt_recovery_requests_recent on tenant_private.shared_recovery_requests(created_at desc,id);
create unique index mt_one_project_backup on tenant_private.shared_recovery_requests(shard_code) where state='queued' and kind='project_backup';
create unique index mt_one_tenant_export on tenant_private.shared_recovery_requests(store_id) where state='queued' and kind='tenant_export';
create unique index mt_one_restore_drill on tenant_private.shared_recovery_requests(backup_id) where state='queued' and kind='restore_drill';
create table tenant_private.shared_release_plans(
 id uuid primary key default gen_random_uuid(),request_id uuid not null unique,shard_code text not null references tenant_private.shards(code),
 release_id uuid not null references saas_private.release_catalog(id),backup_id uuid not null references tenant_private.shared_backup_evidence(id),
 state text not null default 'planned' check(state in ('planned','cancelled')),actor uuid not null,created_at timestamptz not null default now(),cancelled_at timestamptz,
 check((state='cancelled')=(cancelled_at is not null))
);
create unique index mt_one_shard_release on tenant_private.shared_release_plans(shard_code) where state='planned';
do $$ declare t text;begin foreach t in array array['shared_backup_evidence','shared_recovery_requests','shared_release_plans'] loop
 execute format('alter table tenant_private.%I enable row level security',t);
 execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);
end loop;end $$;
create function tenant_private.shared_verified_backup(p_shard text,p_backup uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from tenant_private.shared_backup_evidence b where b.shard_code=p_shard and b.id=p_backup and b.revoked_at is null and b.captured_at between now()-interval '24 hours' and now() and b.verified_at<=now() and not exists(select 1 from saas_private.protected_projects p where p.project_ref=b.restore_target_ref) and not exists(select 1 from public.saas_stores s where s.project_ref=b.restore_target_ref))
$$;
create function tenant_private.shared_recovery_request(p_request uuid,p_shard text,p_kind text,p_store uuid,p_backup uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare r tenant_private.shared_recovery_requests%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_request is null or p_kind is null or p_kind not in ('project_backup','tenant_export','restore_drill') or (p_kind='tenant_export')<>(p_store is not null) or (p_kind='restore_drill')<>(p_backup is not null) then raise exception 'Invalid recovery request' using errcode='22023';end if;
 perform 1 from tenant_private.shards where code=p_shard and state='local' for update;
 if not found then raise exception 'Local shard required' using errcode='22023';end if;
 if p_store is not null and not exists(select 1 from tenant_private.placements where store_id=p_store and shard_code=p_shard) then raise exception 'Tenant placement mismatch' using errcode='22023';end if;
 if p_backup is not null and not exists(select 1 from tenant_private.shared_backup_evidence where id=p_backup and shard_code=p_shard and revoked_at is null) then raise exception 'Backup mismatch' using errcode='22023';end if;
 select * into r from tenant_private.shared_recovery_requests where request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.shard_code<>p_shard or r.kind<>p_kind or r.store_id is distinct from p_store or r.backup_id is distinct from p_backup then raise exception 'Conflicting recovery request' using errcode='22023';end if;return r.id;
 end if;
 insert into tenant_private.shared_recovery_requests(request_id,shard_code,kind,store_id,backup_id,actor) values(p_request,p_shard,p_kind,p_store,p_backup,auth.uid()) returning * into r;return r.id;
end $$;
create function tenant_private.shared_release_plan(p_request uuid,p_shard text,p_release uuid,p_backup uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare r tenant_private.shared_release_plans%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_request is null or p_release is null or p_backup is null then raise exception 'Invalid plan' using errcode='22023';end if;
 perform 1 from tenant_private.shards where code=p_shard and state='local' for update;
 if not found or not exists(select 1 from saas_private.release_catalog where id=p_release) or not tenant_private.shared_verified_backup(p_shard,p_backup) then raise exception 'Recent independently restored backup required' using errcode='22023';end if;
 select * into r from tenant_private.shared_release_plans where request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.shard_code<>p_shard or r.release_id<>p_release or r.backup_id<>p_backup then raise exception 'Conflicting release plan' using errcode='22023';end if;return r.id;
 end if;
 insert into tenant_private.shared_release_plans(request_id,shard_code,release_id,backup_id,actor) values(p_request,p_shard,p_release,p_backup,auth.uid()) returning * into r;return r.id;
end $$;
create function tenant_private.shared_recovery_cancel(p_id uuid,p_type text) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_type='recovery' then update tenant_private.shared_recovery_requests set state='cancelled',cancelled_at=now() where id=p_id and state='queued';
 elsif p_type='release' then update tenant_private.shared_release_plans set state='cancelled',cancelled_at=now() where id=p_id and state='planned';
 else raise exception 'Invalid type' using errcode='22023';end if;return found;
end $$;
create function tenant_private.cancel_shared_release_on_evidence_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update tenant_private.shared_release_plans set state='cancelled',cancelled_at=now() where backup_id=old.id and state='planned';return new;
end $$;
create trigger mt_shared_evidence_change after update on tenant_private.shared_backup_evidence for each row execute function tenant_private.cancel_shared_release_on_evidence_change();
create function tenant_private.shared_recovery_overview(p_limit integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 select jsonb_build_object('requests',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id) from (select id,shard_code,store_id,kind,backup_id,state,created_at from tenant_private.shared_recovery_requests order by created_at desc,id limit p_limit) x),'[]'::jsonb),
 'backups',coalesce((select jsonb_agg(to_jsonb(x) order by captured_at desc,id) from (select id,shard_code,captured_at,tenant_private.shared_verified_backup(shard_code,id) as eligible from tenant_private.shared_backup_evidence order by captured_at desc,id limit p_limit) x),'[]'::jsonb),
 'plans',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id) from (select id,shard_code,release_id,backup_id,state,created_at,tenant_private.shared_verified_backup(shard_code,backup_id) and state='planned' as eligible from tenant_private.shared_release_plans order by created_at desc,id limit p_limit) x),'[]'::jsonb)) into r;return r;
end $$;
create function public.mt_admin_shared_recovery_request(p_request uuid,p_shard text,p_kind text,p_store uuid default null,p_backup uuid default null) returns uuid language sql security invoker set search_path='' as $$select tenant_private.shared_recovery_request(p_request,p_shard,p_kind,p_store,p_backup)$$;
create function public.mt_admin_shared_release_plan(p_request uuid,p_shard text,p_release uuid,p_backup uuid) returns uuid language sql security invoker set search_path='' as $$select tenant_private.shared_release_plan(p_request,p_shard,p_release,p_backup)$$;
create function public.mt_admin_shared_recovery_cancel(p_id uuid,p_type text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.shared_recovery_cancel(p_id,p_type)$$;
create function public.mt_admin_shared_recovery_overview(p_limit integer default 50) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.shared_recovery_overview(p_limit)$$;
revoke all on function tenant_private.shared_verified_backup(text,uuid),tenant_private.shared_recovery_request(uuid,text,text,uuid,uuid),tenant_private.shared_release_plan(uuid,text,uuid,uuid),tenant_private.shared_recovery_cancel(uuid,text),tenant_private.cancel_shared_release_on_evidence_change(),tenant_private.shared_recovery_overview(integer),public.mt_admin_shared_recovery_request(uuid,text,text,uuid,uuid),public.mt_admin_shared_release_plan(uuid,text,uuid,uuid),public.mt_admin_shared_recovery_cancel(uuid,text),public.mt_admin_shared_recovery_overview(integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.shared_recovery_request(uuid,text,text,uuid,uuid),tenant_private.shared_release_plan(uuid,text,uuid,uuid),tenant_private.shared_recovery_cancel(uuid,text),tenant_private.shared_recovery_overview(integer),public.mt_admin_shared_recovery_request(uuid,text,text,uuid,uuid),public.mt_admin_shared_release_plan(uuid,text,uuid,uuid),public.mt_admin_shared_recovery_cancel(uuid,text),public.mt_admin_shared_recovery_overview(integer) to authenticated;
commit;