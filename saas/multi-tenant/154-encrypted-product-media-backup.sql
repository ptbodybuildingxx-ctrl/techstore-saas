-- 154: asynchronous encrypted product-original capture on an owner-enrolled schedule.
-- No design-admin raw media is disclosed to tenant owners; no Storage writes.
begin;
set local lock_timeout='5s';
create extension if not exists pg_net;
create table tenant_private.tenant_backup_media_runs(
 store_id uuid not null,archive_id uuid not null,configured_by uuid not null,key_fingerprint text not null,
 manifest_digest text not null,planned_count integer not null check(planned_count>=0),
 planned_bytes bigint not null check(planned_bytes>=0),state text not null check(state in ('queued','complete','partial','capacity')),
 captured_at timestamptz not null default now(),finished_at timestamptz,
 primary key(store_id,archive_id),
 foreign key(store_id,archive_id) references tenant_private.tenant_backup_archives(store_id,id) on delete cascade
);
create table tenant_private.tenant_backup_media_files(
 store_id uuid not null,archive_id uuid not null,asset_id uuid not null,product_id uuid not null,
 object_path text not null,object_stamp text,plain_bytes integer not null check(plain_bytes between 0 and 2000000),
 state text not null check(state in ('queued','leased','running','saved','missing','changed','error','capacity','permission')),
 attempts integer not null default 0 check(attempts between 0 and 3),
 next_due timestamptz not null default now(),lease_until timestamptz,lease_hash text,
 plaintext_sha256 text,ciphertext_sha256 text,cipher_bytes integer,ciphertext bytea,
 primary key(store_id,archive_id,asset_id),
 foreign key(store_id,archive_id) references tenant_private.tenant_backup_media_runs(store_id,archive_id) on delete cascade,
 check(object_path=store_id::text||'/'||asset_id::text||'.jpg'),
 check((state='saved')=(ciphertext is not null)),
 check(ciphertext is null or (cipher_bytes=octet_length(ciphertext) and cipher_bytes between 1 and 2010000 and plaintext_sha256~'^[0-9a-f]{64}$' and ciphertext_sha256~'^[0-9a-f]{64}$'))
);
create index mt_backup_media_dispatch_idx on tenant_private.tenant_backup_media_files(next_due,store_id,archive_id,asset_id) where state='queued';
create index mt_backup_media_lease_idx on tenant_private.tenant_backup_media_files(lease_until) where state in ('leased','running');
create unique index mt_backup_media_lease_hash_idx on tenant_private.tenant_backup_media_files(lease_hash) where lease_hash is not null;
alter table tenant_private.tenant_backup_media_runs enable row level security;
alter table tenant_private.tenant_backup_media_files enable row level security;
revoke all on tenant_private.tenant_backup_media_runs,tenant_private.tenant_backup_media_files from public,anon,authenticated,service_role;

create function tenant_private.tenant_backup_media_identity(s uuid,a uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('asset_id',m.id,'product_id',m.product_id,'path',m.object_path,
 'stamp',case when o.id is not null then tenant_private.finance_review_digest(jsonb_build_object('id',o.id,'version',o.version,'updated_at',o.updated_at,'metadata',o.metadata)) end,
 'bytes',case when o.metadata->>'size'~'^[0-9]{1,9}$' and (o.metadata->>'size')::bigint between 12 and 2000000 then (o.metadata->>'size')::integer else 0 end,
 'state',case when exists(select 1 from tenant_private.offline_original_deletions z where z.store_id=s and z.asset_id=m.id) then 'missing'
 when exists(select 1 from tenant_private.offline_original_uploads u where u.store_id=s and u.request_id=m.id and not exists(select 1 from tenant_private.offline_reviewed_requests r where r.store_id=s and r.request_id=u.request_id and r.result->>'status'='confirmed')) then 'missing'
 when o.id is null then 'missing' when o.metadata->>'size'~'^[0-9]{1,9}$' and (o.metadata->>'size')::bigint between 12 and 2000000 then 'queued' else 'capacity' end)
 from tenant_private.product_originals m left join storage.objects o on o.bucket_id='saas-design-originals' and o.name=m.object_path
 where m.store_id=s and m.id=a and m.object_path=s::text||'/'||m.id::text||'.jpg'
$$;
create function tenant_private.tenant_backup_media_manifest(s uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare n bigint;items jsonb;total bigint;
begin
 select count(*) into n from tenant_private.product_originals where store_id=s;
 if n>100 then return jsonb_build_object('count',n,'bytes',0,'state','capacity','items','[]'::jsonb);end if;
 select coalesce(jsonb_agg(v order by v->>'asset_id'),'[]'),coalesce(sum((v->>'bytes')::bigint),0) into items,total
 from (select tenant_private.tenant_backup_media_identity(s,m.id) v from tenant_private.product_originals m where m.store_id=s) x;
 if total>12000000 or exists(select 1 from jsonb_array_elements(items) i where i='null'::jsonb) then return jsonb_build_object('count',n,'bytes',total,'state','capacity','items','[]'::jsonb);end if;
 return jsonb_build_object('count',n,'bytes',total,'state','queued','items',items);
end $$;
create function tenant_private.tenant_backup_media_enqueue(s uuid,bid uuid,u uuid,fp text,manifest jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare state_value text;item jsonb;
begin
 state_value:=case when manifest->>'state'='capacity' then 'capacity' when (manifest->>'count')::int=0 then 'complete' else 'queued' end;
 insert into tenant_private.tenant_backup_media_runs(store_id,archive_id,configured_by,key_fingerprint,manifest_digest,planned_count,planned_bytes,state,finished_at)
 values(s,bid,u,fp,tenant_private.finance_review_digest(manifest),(manifest->>'count')::int,(manifest->>'bytes')::bigint,state_value,case when state_value<>'queued' then now() end);
 if state_value='queued' then
  for item in select value from jsonb_array_elements(manifest->'items') loop
   insert into tenant_private.tenant_backup_media_files(store_id,archive_id,asset_id,product_id,object_path,object_stamp,plain_bytes,state)
   values(s,bid,(item->>'asset_id')::uuid,(item->>'product_id')::uuid,item->>'path',item->>'stamp',(item->>'bytes')::integer,item->>'state');
  end loop;
 end if;
end $$;

create function tenant_private.tenant_backup_media_finalize(s uuid,bid uuid) returns void
language sql security definer set search_path='' as $$
 update tenant_private.tenant_backup_media_runs r set state=case when exists(select 1 from tenant_private.tenant_backup_media_files f where f.store_id=s and f.archive_id=bid and f.state<>'saved') then 'partial' else 'complete' end,finished_at=clock_timestamp()
 where r.store_id=s and r.archive_id=bid and r.state='queued' and not exists(select 1 from tenant_private.tenant_backup_media_files f where f.store_id=s and f.archive_id=bid and f.state in ('queued','leased','running'))
$$;

-- Dispatch only one bounded file per five-minute tick; no HTTP request when
-- no work is due. Tokens are random, single-job, single-claim, short-lived.
-- No API key or service_role secret is embedded in SQL or the repository.
create function tenant_private.tenant_backup_media_dispatch() returns void
language plpgsql security definer set search_path='' set lock_timeout='2s' as $$
declare f tenant_private.tenant_backup_media_files%rowtype;token text;r record;
begin
 if not pg_try_advisory_xact_lock(894313,154) then return;end if;
 update tenant_private.tenant_backup_media_files set state=case when attempts>=3 then 'error' else 'queued' end,lease_hash=null,lease_until=null,next_due=clock_timestamp()+interval '5 minutes'
 where state in ('leased','running') and lease_until<=now();
 -- Paused/rekeyed/unauthorized schedules stop pending media capture, not saved files.
 update tenant_private.tenant_backup_media_files j set state='permission',lease_hash=null,lease_until=null where j.state='queued' and not exists(
 select 1 from tenant_private.tenant_backup_media_runs m join tenant_private.tenant_backup_settings c on c.store_id=m.store_id
 where m.store_id=j.store_id and m.archive_id=j.archive_id and c.enabled and c.configured_by=m.configured_by and c.fingerprint=m.key_fingerprint and tenant_private.tenant_backup_eligible(m.store_id,m.configured_by));
 for r in select m.store_id,m.archive_id from tenant_private.tenant_backup_media_runs m where m.state='queued' loop perform tenant_private.tenant_backup_media_finalize(r.store_id,r.archive_id);end loop;
 select * into f from tenant_private.tenant_backup_media_files where state='queued' and next_due<=now() order by next_due,store_id,archive_id,asset_id limit 1 for update skip locked;
 if not found then return;end if;
 token:=encode(extensions.gen_random_bytes(32),'hex');
 update tenant_private.tenant_backup_media_files set state='leased',attempts=attempts+1,lease_hash=encode(sha256(convert_to(token,'UTF8')),'hex'),lease_until=clock_timestamp()+interval '10 minutes' where store_id=f.store_id and archive_id=f.archive_id and asset_id=f.asset_id;
 perform net.http_post(url:='https://mezsyzdieqmqulddcrtg.supabase.co/functions/v1/techstore-media-backup',body:=jsonb_build_object('token',token),headers:='{"Content-Type":"application/json"}'::jsonb,timeout_milliseconds:=90000);
end $$;

-- Only the isolated Edge Function's service role can claim or finish a token.
-- The token selects exactly one reserved path, never a caller-provided path.
create function tenant_private.tenant_backup_media_claim(token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare f tenant_private.tenant_backup_media_files%rowtype;identity jsonb;
begin
 if token is null or token!~'^[0-9a-f]{64}$' then return null;end if;
 select * into f from tenant_private.tenant_backup_media_files where lease_hash=encode(sha256(convert_to(token,'UTF8')),'hex') and state='leased' and lease_until>now() for update;
 if not found then return null;end if;
 if not exists(select 1 from tenant_private.tenant_backup_media_runs m join tenant_private.tenant_backup_settings c on c.store_id=m.store_id where m.store_id=f.store_id and m.archive_id=f.archive_id and c.enabled and c.configured_by=m.configured_by and c.fingerprint=m.key_fingerprint and tenant_private.tenant_backup_eligible(m.store_id,m.configured_by)) then
  update tenant_private.tenant_backup_media_files set state='permission',lease_hash=null,lease_until=null where store_id=f.store_id and archive_id=f.archive_id and asset_id=f.asset_id;perform tenant_private.tenant_backup_media_finalize(f.store_id,f.archive_id);return null;
 end if;
 identity:=tenant_private.tenant_backup_media_identity(f.store_id,f.asset_id);
 if identity->>'stamp' is distinct from f.object_stamp or identity->>'state' is distinct from 'queued' or (identity->>'bytes')::int is distinct from f.plain_bytes then
  update tenant_private.tenant_backup_media_files set state='changed',lease_hash=null,lease_until=null where store_id=f.store_id and archive_id=f.archive_id and asset_id=f.asset_id;perform tenant_private.tenant_backup_media_finalize(f.store_id,f.archive_id);return null;
 end if;
 update tenant_private.tenant_backup_media_files set state='running' where store_id=f.store_id and archive_id=f.archive_id and asset_id=f.asset_id;
 return jsonb_build_object('store',f.store_id,'asset',f.asset_id,'path',f.object_path,'bytes',f.plain_bytes);
end $$;
create function tenant_private.tenant_backup_media_finish(token text,body_base64 text) returns boolean
language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare f tenant_private.tenant_backup_media_files%rowtype;c tenant_private.tenant_backup_settings%rowtype;identity jsonb;raw bytea;enc bytea;state_value text:='saved';used bigint;
begin
 if token is null or token!~'^[0-9a-f]{64}$' then return false;end if;
 -- Shared budget serialized before obtaining file locks.
 perform pg_advisory_xact_lock(894313,154);
 select * into f from tenant_private.tenant_backup_media_files where lease_hash=encode(sha256(convert_to(token,'UTF8')),'hex') and state='running' and lease_until>now() for update;
 if not found then return false;end if;
 select cfg.* into c from tenant_private.tenant_backup_media_runs m join tenant_private.tenant_backup_settings cfg on cfg.store_id=m.store_id where m.store_id=f.store_id and m.archive_id=f.archive_id and cfg.enabled and cfg.configured_by=m.configured_by and cfg.fingerprint=m.key_fingerprint and tenant_private.tenant_backup_eligible(m.store_id,m.configured_by);
 identity:=tenant_private.tenant_backup_media_identity(f.store_id,f.asset_id);
 if c.store_id is null then state_value:='permission';
 elsif identity->>'stamp' is distinct from f.object_stamp or identity->>'state' is distinct from 'queued' or (identity->>'bytes')::int is distinct from f.plain_bytes then state_value:='changed';
 elsif body_base64 is null then state_value:=case when f.attempts<3 then 'queued' else 'error' end;
 elsif octet_length(body_base64)>2670000 then state_value:='error';
 else
  begin
   raw:=decode(body_base64,'base64');
   if octet_length(raw)<>f.plain_bytes or substring(raw from 1 for 2)<>decode('ffd8','hex') or substring(raw from octet_length(raw)-1 for 2)<>decode('ffd9','hex') then state_value:='changed';
   else
    enc:=extensions.pgp_pub_encrypt_bytea(raw,c.public_key,'cipher-algo=aes256,compress-algo=0');
    select coalesce(sum(cipher_bytes),0) into used from tenant_private.tenant_backup_media_files where state='saved';
    if used+octet_length(enc)>32000000 or octet_length(enc)>2010000 then state_value:='capacity';end if;
   end if;
  exception when others then state_value:=case when f.attempts<3 then 'queued' else 'error' end;
  end;
 end if;
 if state_value='saved' then
  update tenant_private.tenant_backup_media_files set state='saved',ciphertext=enc,cipher_bytes=octet_length(enc),ciphertext_sha256=encode(sha256(enc),'hex'),plaintext_sha256=encode(sha256(raw),'hex'),lease_hash=null,lease_until=null where store_id=f.store_id and archive_id=f.archive_id and asset_id=f.asset_id;
 else
  update tenant_private.tenant_backup_media_files set state=state_value,lease_hash=null,lease_until=null,next_due=clock_timestamp()+interval '5 minutes' where store_id=f.store_id and archive_id=f.archive_id and asset_id=f.asset_id;
 end if;
 perform tenant_private.tenant_backup_media_finalize(f.store_id,f.archive_id);
 return state_value='saved';
end $$;

create function tenant_private.tenant_backup_media_overview(s uuid,d uuid,secret uuid,bid uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r tenant_private.tenant_backup_media_runs%rowtype;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 select * into r from tenant_private.tenant_backup_media_runs where store_id=s and archive_id=bid;
 if not found then return jsonb_build_object('store',s,'archive',bid,'status','not_captured','files','[]'::jsonb);end if;
 return jsonb_build_object('store',s,'archive',bid,'status',r.state,'planned_count',r.planned_count,'planned_bytes',r.planned_bytes,'files',coalesce((select jsonb_agg(to_jsonb(x) order by x.asset_id) from (select asset_id,product_id,state,plain_bytes,cipher_bytes,plaintext_sha256,ciphertext_sha256 from tenant_private.tenant_backup_media_files where store_id=s and archive_id=bid order by asset_id limit 100) x),'[]'));
end $$;
create function tenant_private.tenant_backup_media_chunk(s uuid,d uuid,secret uuid,bid uuid,asset uuid,start_at integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare f tenant_private.tenant_backup_media_files%rowtype;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 if start_at is null or start_at<0 or start_at%49152<>0 then raise exception 'Invalid offset' using errcode='22023';end if;
 select * into f from tenant_private.tenant_backup_media_files where store_id=s and archive_id=bid and asset_id=asset and state='saved';
 if not found or start_at>=f.cipher_bytes then raise exception 'Image backup missing' using errcode='22023';end if;
 return jsonb_build_object('store',s,'archive',bid,'asset',asset,'offset',start_at,'bytes',f.cipher_bytes,'sha256',f.ciphertext_sha256,'data',encode(substring(f.ciphertext from start_at+1 for 49152),'base64'));
end $$;

revoke all on function tenant_private.tenant_backup_media_identity(uuid,uuid),tenant_private.tenant_backup_media_manifest(uuid),tenant_private.tenant_backup_media_enqueue(uuid,uuid,uuid,text,jsonb),tenant_private.tenant_backup_media_finalize(uuid,uuid),tenant_private.tenant_backup_media_dispatch(),tenant_private.tenant_backup_media_claim(text),tenant_private.tenant_backup_media_finish(text,text) from public,anon,authenticated,service_role;
create function public.mt_backup_media_claim(token text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_media_claim(token)$$;
create function public.mt_backup_media_finish(token text,body_base64 text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_media_finish(token,body_base64)$$;
revoke all on function public.mt_backup_media_claim(text),public.mt_backup_media_finish(text,text) from public,anon,authenticated,service_role;
grant execute on function public.mt_backup_media_claim(text),public.mt_backup_media_finish(text,text),tenant_private.tenant_backup_media_claim(text),tenant_private.tenant_backup_media_finish(text,text) to service_role;
create function public.mt_backup_media_overview(s uuid,d uuid,secret uuid,bid uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_media_overview(s,d,secret,bid)$$;
revoke all on function tenant_private.tenant_backup_media_overview(uuid,uuid,uuid,uuid),public.mt_backup_media_overview(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_media_overview(uuid,uuid,uuid,uuid),public.mt_backup_media_overview(uuid,uuid,uuid,uuid) to authenticated;
create function public.mt_backup_media_chunk(s uuid,d uuid,secret uuid,bid uuid,asset uuid,start_at integer) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_media_chunk(s,d,secret,bid,asset,start_at)$$;
revoke all on function tenant_private.tenant_backup_media_chunk(uuid,uuid,uuid,uuid,uuid,integer),public.mt_backup_media_chunk(uuid,uuid,uuid,uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_media_chunk(uuid,uuid,uuid,uuid,uuid,integer),public.mt_backup_media_chunk(uuid,uuid,uuid,uuid,uuid,integer) to authenticated;
CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_snapshot(s uuid, u uuid, bid uuid, fp text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rel text;data jsonb:='{}';part jsonb;n bigint;size_bytes bigint;total_bytes bigint:=0;total_rows bigint:=0;counts jsonb:='{}';digests jsonb:='{}';receipt jsonb;projection text;
begin
 if not tenant_private.tenant_backup_eligible(s,u) then raise exception 'Backup permission changed' using errcode='42501';end if;
 foreach rel in array tenant_private.tenant_backup_relations(2) loop
  projection:=case when rel='tenant_private.design_originals' then '(to_jsonb(r)-''public_fingerprint'')' else 'to_jsonb(r)' end;
  execute format('select count(*),coalesce(sum(octet_length((%s)::text)::bigint+2),0) from %I.%I r where r.store_id=$1',projection,split_part(rel,'.',1),split_part(rel,'.',2)) into n,size_bytes using s;
  if total_bytes+size_bytes>8000000 or total_rows+n>100000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  execute format('select coalesce(jsonb_agg(%s order by (%s)::text),''[]''::jsonb) from %I.%I r where r.store_id=$1',projection,projection,split_part(rel,'.',1),split_part(rel,'.',2)) into part using s;
  counts:=counts||jsonb_build_object(rel,n);digests:=digests||jsonb_build_object(rel,tenant_private.finance_review_digest(part));
  data:=data||jsonb_build_object(rel,part);total_bytes:=total_bytes+size_bytes;total_rows:=total_rows+n;
 end loop;
 receipt:=tenant_private.effective_receipt_settings(s);
 return jsonb_build_object('version',2,'scope','tenant_operational_archive','id',bid,'store',s,'captured_at',statement_timestamp(),'key_fingerprint',fp,'rows',total_rows,'relation_count',140,'table_counts',counts,'table_digests',digests,'product_media_manifest',tenant_private.tenant_backup_media_manifest(s),'restore_documents',tenant_private.tenant_backup_documents(data),'effective_receipt_settings',receipt,'configuration_evidence_only',to_jsonb(array['tenant_private.design_heads','tenant_private.design_versions','tenant_private.design_originals','tenant_private.storefronts','tenant_private.guest_settings','tenant_private.loyalty_settings','tenant_private.sales_settings','tenant_private.members','tenant_private.staff_profiles','tenant_private.staff_denials','tenant_private.staff_branch_scope','tenant_private.cashier_branch_scope','tenant_private.procurement_grants','tenant_private.receivable_grants','tenant_private.branch_fifo_enabled','tenant_private.branch_treasury_enabled']),'excluded_relations',to_jsonb(array['tenant_private.pos_loyalty_sales','tenant_private.spend_pos_redemptions']),'tables',data);
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '2s'
AS $function$
declare cfg tenant_private.tenant_backup_settings%rowtype;bid uuid:=gen_random_uuid();snapshot jsonb;plain text;encrypted bytea;retained bigint;status text:='error';
begin
 if not pg_try_advisory_xact_lock(894313,151) then return;end if;
 select * into cfg from tenant_private.tenant_backup_settings where enabled and next_due<=now() order by next_due,store_id limit 1 for update skip locked;
 if not found then return;end if;
 begin
  if not tenant_private.tenant_backup_eligible(cfg.store_id,cfg.configured_by) then raise exception 'Backup permission changed' using errcode='42501';end if;
  snapshot:=tenant_private.tenant_backup_snapshot(cfg.store_id,cfg.configured_by,bid,cfg.fingerprint);
  plain:=snapshot::text;
  if octet_length(plain)>8000000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  encrypted:=extensions.pgp_pub_encrypt(plain,cfg.public_key,'cipher-algo=aes256,compress-algo=0');
  if octet_length(encrypted)>9000000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  if not tenant_private.tenant_backup_eligible(cfg.store_id,cfg.configured_by) then raise exception 'Backup permission changed' using errcode='42501';end if;
  -- Keep the previous two snapshots plus the new one. Check global budget
  -- before committing; failed capture never prunes a previously saved archive.
  select coalesce(sum(a.bytes),0) into retained from tenant_private.tenant_backup_archives a
  where a.store_id<>cfg.store_id or a.id in (select b.id from tenant_private.tenant_backup_archives b where b.store_id=cfg.store_id order by b.captured_at desc,b.id limit 2);
  if retained+octet_length(encrypted)>64000000 then raise exception 'Archive quota exceeded' using errcode='54000';end if;
  insert into tenant_private.tenant_backup_archives(store_id,id,captured_at,key_fingerprint,relation_count,row_count,bytes,ciphertext,sha256,archive_version,plaintext_sha256,table_counts,receipt_digest,table_digests,document_digests)
  values(cfg.store_id,bid,(snapshot->>'captured_at')::timestamptz,cfg.fingerprint,(snapshot->>'relation_count')::int,(snapshot->>'rows')::bigint,octet_length(encrypted),encrypted,encode(sha256(encrypted),'hex'),2,encode(sha256(convert_to(plain,'UTF8')),'hex'),snapshot->'table_counts',tenant_private.finance_review_digest(snapshot->'effective_receipt_settings'),snapshot->'table_digests',tenant_private.tenant_backup_document_digests(snapshot->'restore_documents'));
  perform tenant_private.tenant_backup_media_enqueue(cfg.store_id,bid,cfg.configured_by,cfg.fingerprint,snapshot->'product_media_manifest');
  delete from tenant_private.tenant_backup_archives a where a.store_id=cfg.store_id and a.id not in (select b.id from tenant_private.tenant_backup_archives b where b.store_id=cfg.store_id order by b.captured_at desc,b.id limit 3);
  update tenant_private.tenant_backup_settings set last_attempt=clock_timestamp(),last_success=clock_timestamp(),last_status='saved',next_due=clock_timestamp()+interval '24 hours' where store_id=cfg.store_id;
 exception when others then
  status:=case sqlstate when '42501' then 'permission' when '54000' then 'capacity' else 'error' end;
  update tenant_private.tenant_backup_settings set last_attempt=clock_timestamp(),last_status=status,next_due=clock_timestamp()+case when status='error' then interval '1 hour' else interval '24 hours' end where store_id=cfg.store_id;
 end;
end $function$;
-- Job stays dormant until a scheduled tenant archive has product images.
select cron.schedule('techstore-tenant-media-backup','*/5 * * * *','select tenant_private.tenant_backup_media_dispatch()');
commit;
