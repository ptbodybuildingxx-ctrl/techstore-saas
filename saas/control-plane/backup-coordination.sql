-- Backup/restore coordination only. Trusted independent verification is not automated.
begin;
do $$ begin
 if to_regclass('saas_private.release_targets') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Dedicated control plane required'; end if;
end $$;
create table saas_private.backup_catalog(
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null references public.saas_stores(id),
 project_ref text not null check(project_ref ~ '^[a-z0-9]{20}$'),
 origin text not null,
 captured_at timestamptz not null,
 database_sha256 text not null check(database_sha256 ~ '^[0-9a-f]{64}$'),
 storage_manifest_sha256 text not null check(storage_manifest_sha256 ~ '^[0-9a-f]{64}$'),
 configuration_sha256 text not null check(configuration_sha256 ~ '^[0-9a-f]{64}$'),
 evidence_sha256 text check(evidence_sha256 ~ '^[0-9a-f]{64}$'),
 restored_at timestamptz,
 verified_at timestamptz,
 revoked_at timestamptz,
 check ((verified_at is null and restored_at is null and evidence_sha256 is null) or
 (verified_at is not null and restored_at is not null and evidence_sha256 is not null and captured_at<=restored_at and restored_at<=verified_at))
);
create index saas_backup_lookup on saas_private.backup_catalog(store_id,captured_at desc);
create table saas_private.backup_requests(
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null references public.saas_stores(id),
 project_ref text not null,
 origin text not null,
 kind text not null check(kind in ('backup','restore_drill')),
 backup_id uuid references saas_private.backup_catalog(id),
 requested_by uuid not null,
 requested_at timestamptz not null default now(),
 state text not null default 'queued' check(state in ('queued','cancelled')),
 cancelled_at timestamptz,
 check((kind='restore_drill')=(backup_id is not null)),
 check((state='cancelled')=(cancelled_at is not null))
);
create unique index saas_one_backup_request on saas_private.backup_requests(store_id,kind) where state='queued';
create index saas_backup_request_history on saas_private.backup_requests(requested_at desc);
alter table saas_private.backup_catalog enable row level security;
alter table saas_private.backup_requests enable row level security;
revoke all on saas_private.backup_catalog,saas_private.backup_requests from public,anon,authenticated,service_role;
-- No browser or service role can manufacture evidence. A future isolated worker
-- must independently verify artifact hashes, restoration and ownership before recording evidence.
create function saas_private.recent_verified_backup(p_store uuid,p_project text,p_origin text) returns uuid
language sql stable security invoker set search_path='' as $$
 select b.id from saas_private.backup_catalog b where b.store_id=p_store and b.project_ref=p_project and b.origin=p_origin
 and b.captured_at between now()-interval '24 hours' and now() and b.verified_at<=now() and b.restored_at<=now()
 and b.evidence_sha256 is not null and b.revoked_at is null
 and not exists(select 1 from saas_private.protected_projects p where p.project_ref=p_project)
 order by b.captured_at desc,b.id limit 1
$$;
revoke all on function saas_private.recent_verified_backup(uuid,text,text) from public,anon,authenticated,service_role;
alter table saas_private.release_targets add column backup_id uuid references saas_private.backup_catalog(id);
-- Existing plans made before this gate must be cancelled, not grandfathered.
update saas_private.release_targets set state='cancelled',cancelled_at=now() where state='planned';
alter table saas_private.release_targets add constraint saas_planned_backup_required check(state<>'planned' or backup_id is not null);
create function saas_private.require_release_backup() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='planned' then
   new.backup_id:=saas_private.recent_verified_backup(new.store_id,new.project_ref,new.origin);
   if new.backup_id is null then raise exception 'Recent independently verified backup required' using errcode='22023'; end if;
 end if;
 return new;
end $$;
create trigger saas_require_release_backup before insert or update of state,backup_id,project_ref,origin on saas_private.release_targets for each row execute function saas_private.require_release_backup();
create function saas_private.cancel_revoked_backup_plans() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.revoked_at is not null or new.verified_at is distinct from old.verified_at or new.restored_at is distinct from old.restored_at or new.evidence_sha256 is distinct from old.evidence_sha256 or new.database_sha256 is distinct from old.database_sha256 or new.storage_manifest_sha256 is distinct from old.storage_manifest_sha256 or new.configuration_sha256 is distinct from old.configuration_sha256 or new.captured_at is distinct from old.captured_at or new.project_ref is distinct from old.project_ref or new.origin is distinct from old.origin or new.store_id is distinct from old.store_id then
  update saas_private.release_targets set state='cancelled',cancelled_at=now() where backup_id=new.id and state='planned';
 end if;
 return new;
end $$;
create trigger saas_cancel_revoked_backup_plans after update on saas_private.backup_catalog for each row execute function saas_private.cancel_revoked_backup_plans();
create function saas_private.backup_request(p_store uuid,p_kind text,p_action text,p_backup uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare s public.saas_stores%rowtype; r saas_private.backup_requests%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_store is null or p_kind is null or p_kind not in ('backup','restore_drill') or p_action is null or p_action not in ('request','cancel') then raise exception 'Invalid request' using errcode='22023'; end if;
 select * into s from public.saas_stores where id=p_store for update;
 if not found then raise exception 'Unknown store' using errcode='22023'; end if;
 select * into r from saas_private.backup_requests where store_id=s.id and kind=p_kind and state='queued';
 if p_action='cancel' then
   if r.id is not null then update saas_private.backup_requests set state='cancelled',cancelled_at=now() where id=r.id; end if;
   return r.id;
 end if;
 if s.state<>'ready' or s.project_ref is null or s.origin is null or exists(select 1 from saas_private.protected_projects where project_ref=s.project_ref) then raise exception 'Independent ready store required' using errcode='22023'; end if;
 if p_kind='backup' and p_backup is not null or p_kind='restore_drill' and (p_backup is null or not exists(select 1 from saas_private.backup_catalog where id=p_backup and store_id=s.id and project_ref=s.project_ref and origin=s.origin and revoked_at is null and captured_at<=now())) then raise exception 'Matching backup required' using errcode='22023'; end if;
 if r.id is not null then
   if r.backup_id is not distinct from p_backup then return r.id; end if;
   raise exception 'Cancel existing request first' using errcode='22023';
 end if;
 insert into saas_private.backup_requests(store_id,project_ref,origin,kind,backup_id,requested_by) values(s.id,s.project_ref,s.origin,p_kind,p_backup,auth.uid()) returning * into r;
 return r.id;
end $$;
create function saas_private.cancel_stale_backup_requests() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state<>'ready' or old.project_ref is distinct from new.project_ref or old.origin is distinct from new.origin then
  update saas_private.backup_requests set state='cancelled',cancelled_at=now() where store_id=new.id and state='queued';
 end if;
 return new;
end $$;
create trigger saas_cancel_stale_backup_requests after update of state,project_ref,origin on public.saas_stores for each row execute function saas_private.cancel_stale_backup_requests();
create function saas_private.backup_overview(p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid limit' using errcode='22023'; end if;
 select jsonb_build_object(
 'stores',coalesce((select jsonb_agg(to_jsonb(s) order by s.name,s.id) from (select id,name,slug,saas_private.recent_verified_backup(id,project_ref,origin) as recent_backup_id from public.saas_stores s where state='ready' and project_ref is not null and origin is not null and not exists(select 1 from saas_private.protected_projects p where p.project_ref=s.project_ref) order by name,id limit p_limit) s),'[]'::jsonb),
 'backups',coalesce((select jsonb_agg(to_jsonb(b) order by b.captured_at desc,b.id) from (select b.id,b.store_id,s.name as store_name,b.captured_at,case when b.revoked_at is not null then 'revoked' when b.verified_at is null then 'unverified' when b.captured_at<now()-interval '24 hours' or b.verified_at>now() or b.captured_at>now() then 'stale' else 'verified' end as status from saas_private.backup_catalog b join public.saas_stores s on s.id=b.store_id where b.project_ref=s.project_ref and b.origin=s.origin order by b.captured_at desc,b.id limit p_limit) b),'[]'::jsonb),
 'requests',coalesce((select jsonb_agg(to_jsonb(q) order by q.requested_at desc,q.id) from (select q.id,q.store_id,s.name as store_name,q.kind,q.backup_id,q.state,q.requested_at from saas_private.backup_requests q join public.saas_stores s on s.id=q.store_id order by q.requested_at desc,q.id limit p_limit) q),'[]'::jsonb)
 ) into r;
 return r;
end $$;
create function public.saas_admin_backup_request(p_store uuid,p_kind text,p_action text,p_backup uuid default null) returns uuid
language sql security invoker set search_path='' as $$ select saas_private.backup_request(p_store,p_kind,p_action,p_backup) $$;
create function public.saas_admin_backup_overview(p_limit integer default 50) returns jsonb
language sql stable security invoker set search_path='' as $$ select saas_private.backup_overview(p_limit) $$;
revoke all on function saas_private.require_release_backup(),saas_private.cancel_revoked_backup_plans(),saas_private.cancel_stale_backup_requests(),saas_private.backup_request(uuid,text,text,uuid),saas_private.backup_overview(integer),public.saas_admin_backup_request(uuid,text,text,uuid),public.saas_admin_backup_overview(integer) from public,anon,authenticated,service_role;
grant execute on function saas_private.backup_request(uuid,text,text,uuid),saas_private.backup_overview(integer),public.saas_admin_backup_request(uuid,text,text,uuid),public.saas_admin_backup_overview(integer) to authenticated;
commit;
