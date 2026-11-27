-- 155: private authenticated pull scheduler; no pg_net request queue.
begin;
set local lock_timeout='5s';
-- Idempotently remove the superseded dispatch path and its cron entry.
select cron.unschedule(jobid) from cron.job where jobname='techstore-tenant-media-backup';
drop function if exists tenant_private.tenant_backup_media_dispatch();
create table tenant_private.tenant_backup_scheduler_auth(
 singleton boolean primary key default true check(singleton),
 key_sha256 text not null check(key_sha256~'^[0-9a-f]{64}$'),
 enabled boolean not null default false,
 changed_at timestamptz not null default now(),
 last_poll timestamptz,
 last_claim timestamptz
);
alter table tenant_private.tenant_backup_scheduler_auth enable row level security;
revoke all on tenant_private.tenant_backup_scheduler_auth from public,anon,authenticated,service_role;

create function tenant_private.tenant_backup_media_next(p_key text) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare c tenant_private.tenant_backup_scheduler_auth%rowtype;f tenant_private.tenant_backup_media_files%rowtype;token text;r record;job jsonb;stamp timestamptz:=clock_timestamp();
begin
 if p_key is null or p_key!~'^[0-9a-f]{64}$' then return jsonb_build_object('status','denied');end if;
 if not pg_try_advisory_xact_lock(894313,154) then return jsonb_build_object('status','busy');end if;
 select * into c from tenant_private.tenant_backup_scheduler_auth where singleton for update;
 if not found or not c.enabled or c.key_sha256 is distinct from encode(sha256(convert_to(p_key,'UTF8')),'hex') then return jsonb_build_object('status','denied');end if;
 if c.last_poll is not null and c.last_poll>stamp-interval '4 minutes' then return jsonb_build_object('status','rate_limited');end if;
 update tenant_private.tenant_backup_scheduler_auth set last_poll=stamp where singleton;
 -- Reclaim expired attempts. Never retry more than three times.
 update tenant_private.tenant_backup_media_files set state=case when attempts>=3 then 'error' else 'queued' end,lease_hash=null,lease_until=null,next_due=stamp+interval '5 minutes'
 where state in ('leased','running') and lease_until<=stamp;
 update tenant_private.tenant_backup_media_files j set state='permission',lease_hash=null,lease_until=null where j.state='queued' and not exists(
 select 1 from tenant_private.tenant_backup_media_runs m join tenant_private.tenant_backup_settings cfg on cfg.store_id=m.store_id
 where m.store_id=j.store_id and m.archive_id=j.archive_id and cfg.enabled and cfg.configured_by=m.configured_by and cfg.fingerprint=m.key_fingerprint and tenant_private.tenant_backup_eligible(m.store_id,m.configured_by));
 for r in select m.store_id,m.archive_id from tenant_private.tenant_backup_media_runs m where m.state='queued' loop perform tenant_private.tenant_backup_media_finalize(r.store_id,r.archive_id);end loop;
 select * into f from tenant_private.tenant_backup_media_files where state='queued' and attempts<3 and next_due<=stamp order by next_due,store_id,archive_id,asset_id limit 1 for update skip locked;
 if not found then return jsonb_build_object('status','idle');end if;
 token:=encode(extensions.gen_random_bytes(32),'hex');
 update tenant_private.tenant_backup_media_files set state='leased',attempts=attempts+1,lease_hash=encode(sha256(convert_to(token,'UTF8')),'hex'),lease_until=stamp+interval '10 minutes' where store_id=f.store_id and archive_id=f.archive_id and asset_id=f.asset_id;
 job:=tenant_private.tenant_backup_media_claim(token);
 if job is null then return jsonb_build_object('status','idle');end if;
 update tenant_private.tenant_backup_scheduler_auth set last_claim=stamp where singleton;
 return jsonb_build_object('status','claimed','token',token,'job',job);
end $$;
create function public.mt_backup_media_next(p_key text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_media_next(p_key)$$;
revoke all on function tenant_private.tenant_backup_media_next(text),public.mt_backup_media_next(text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_media_next(text),public.mt_backup_media_next(text) to service_role;
-- Old standalone claim endpoint is no longer needed. Internal claim remains callable by its owner.
revoke all on function public.mt_backup_media_claim(text),tenant_private.tenant_backup_media_claim(text) from public,anon,authenticated,service_role;

create or replace function tenant_private.tenant_backup_media_overview(s uuid,d uuid,secret uuid,bid uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r tenant_private.tenant_backup_media_runs%rowtype;heartbeat jsonb;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 select jsonb_build_object('enabled',enabled,'last_poll',last_poll,'healthy',enabled and coalesce(last_poll>now()-interval '15 minutes',false)) into heartbeat from tenant_private.tenant_backup_scheduler_auth where singleton;
 heartbeat:=coalesce(heartbeat,jsonb_build_object('enabled',false,'last_poll',null,'healthy',false));
 select * into r from tenant_private.tenant_backup_media_runs where store_id=s and archive_id=bid;
 if not found then return jsonb_build_object('store',s,'archive',bid,'status','not_captured','files','[]'::jsonb,'scheduler',heartbeat);end if;
 return jsonb_build_object('store',s,'archive',bid,'status',r.state,'planned_count',r.planned_count,'planned_bytes',r.planned_bytes,'scheduler',heartbeat,'files',coalesce((select jsonb_agg(to_jsonb(x) order by x.asset_id) from (select asset_id,product_id,state,plain_bytes,cipher_bytes,plaintext_sha256,ciphertext_sha256 from tenant_private.tenant_backup_media_files where store_id=s and archive_id=bid order by asset_id limit 100) x),'[]'));
end $$;
commit;
