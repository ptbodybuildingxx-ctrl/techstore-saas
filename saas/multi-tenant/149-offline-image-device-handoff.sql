-- 149: audited transfer of image jobs from permanently revoked installations.
begin;
set local lock_timeout='5s';
create table tenant_private.offline_image_handoffs(
 store_id uuid not null references public.saas_stores(id),
 id uuid not null default gen_random_uuid(),
 request_id uuid not null,
 kind text not null check(kind in ('upload','delete','retire')),
 old_actor uuid not null,old_device uuid not null,
 new_actor uuid not null,new_device uuid not null,
 reason text not null check(length(btrim(reason)) between 5 and 500),
 created_at timestamptz not null default clock_timestamp(),
 primary key(store_id,id),
 foreign key(store_id,old_device) references tenant_private.offline_devices(store_id,id),
 foreign key(store_id,new_device) references tenant_private.offline_devices(store_id,id)
);
alter table tenant_private.offline_image_handoffs enable row level security;
revoke all on tenant_private.offline_image_handoffs from public,anon,authenticated,service_role;
create index mt_offline_image_handoff_job_idx on tenant_private.offline_image_handoffs(store_id,request_id,created_at desc);
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.offline_image_handoffs for each row execute function tenant_private.offline_snapshot_touch();

-- The old device must be permanently revoked. Transfer the reservation rather
-- than clone the request, preserving its original ID, payload and audit trail.
create function tenant_private.offline_image_takeover(s uuid,d uuid,secret uuid,req uuid,job_kind text,expected_device uuid,reason text) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $$
declare u tenant_private.offline_original_uploads%rowtype;x tenant_private.offline_original_deletions%rowtype;old_device uuid;old_actor uuid;asset uuid;prior tenant_private.offline_reviewed_requests%rowtype;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if auth.jwt()->>'aal' is distinct from 'aal2' or not coalesce(tenant_private.central_read_permitted(s,'all_catalog_read'),false) or tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Owner AAL2 required' using errcode='42501';end if;
 if req is null or expected_device is null or expected_device=d or job_kind is null or job_kind not in ('upload','delete') or reason is null or length(btrim(reason)) not between 5 and 500 then raise exception 'Explicit handoff required' using errcode='22023';end if;
 if job_kind='upload' then
  select * into u from tenant_private.offline_original_uploads where store_id=s and request_id=req for update;
  if not found then raise exception 'Upload reservation missing' using errcode='22023';end if;
  old_device:=u.device_id;old_actor:=u.actor;asset:=u.request_id;
  if exists(select 1 from tenant_private.offline_reviewed_requests where store_id=s and request_id=req) or exists(select 1 from tenant_private.offline_original_deletions where store_id=s and asset_id=asset) then raise exception 'Upload already closed' using errcode='22023';end if;
 else
  select * into x from tenant_private.offline_original_deletions where store_id=s and request_id=req for update;
  if not found then raise exception 'Deletion reservation missing' using errcode='22023';end if;
  old_device:=x.device_id;old_actor:=x.actor;asset:=x.asset_id;
  if x.state='deleted' and not exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=s::text||'/'||asset::text||'.jpg') then raise exception 'Deletion already completed' using errcode='22023';end if;
 end if;
 if old_device<>expected_device then raise exception 'Reservation owner changed; refresh' using errcode='22023';end if;
 perform 1 from tenant_private.offline_devices v where v.store_id=s and v.id=old_device and v.actor=old_actor and v.state='revoked' for share;
 if not found then raise exception 'Revoke the original device first' using errcode='42501';end if;
 if job_kind='upload' then
  perform 1 from tenant_private.product_originals where store_id=s and id=asset and product_id=u.product_id and actor=old_actor and not published for update;
  if not found then raise exception 'Upload metadata missing or published' using errcode='22023';end if;
  update tenant_private.product_originals set actor=auth.uid() where store_id=s and id=asset;
  update tenant_private.offline_original_uploads set actor=auth.uid(),device_id=d where store_id=s and request_id=req;
 else
  -- For a completed deletion only the cleanup reservation moves; historic receipt
  -- actor/device and payload remain immutable.
  update tenant_private.offline_original_deletions set actor=auth.uid(),device_id=d where store_id=s and request_id=req;
 end if;
 insert into tenant_private.offline_image_handoffs(store_id,request_id,kind,old_actor,old_device,new_actor,new_device,reason) values(s,req,job_kind,old_actor,old_device,auth.uid(),d,btrim(reason));
 return tenant_private.offline_image_recovery(s,d,secret,req,job_kind);
end $$;

-- Missing or incorrect bytes can be explicitly retired rather than replaced
-- under the original ID. Reuse the normal reviewed deletion and Storage APIs.
create function tenant_private.offline_image_retire_upload(s uuid,d uuid,secret uuid,req uuid,reason text) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $$
declare u tenant_private.offline_original_uploads%rowtype;m tenant_private.product_originals%rowtype;x tenant_private.offline_original_deletions%rowtype;op jsonb;new_req uuid;present boolean;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if auth.jwt()->>'aal' is distinct from 'aal2' or not coalesce(tenant_private.central_read_permitted(s,'all_catalog_read'),false) or tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Owner AAL2 required' using errcode='42501';end if;
 if req is null or reason is null or length(btrim(reason)) not between 5 and 500 then raise exception 'Explicit retirement reason required' using errcode='22023';end if;
 select * into u from tenant_private.offline_original_uploads where store_id=s and request_id=req and actor=auth.uid() and device_id=d for update;
 if not found then raise exception 'Authorized installation required' using errcode='42501';end if;
 select * into x from tenant_private.offline_original_deletions where store_id=s and asset_id=req;
 if found then
  if x.actor<>auth.uid() or x.device_id<>d then raise exception 'Deletion assigned elsewhere' using errcode='42501';end if;
  return tenant_private.offline_image_recovery(s,d,secret,x.request_id,'delete');
 end if;
 if exists(select 1 from tenant_private.offline_reviewed_requests where store_id=s and request_id=req) then raise exception 'Upload already finalized; use normal image deletion' using errcode='22023';end if;
 select * into m from tenant_private.product_originals where store_id=s and id=req and product_id=u.product_id for update;
 if not found or m.published then raise exception 'Missing or published metadata' using errcode='22023';end if;
 present:=exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=m.object_path);
 new_req:=gen_random_uuid();
 op:=jsonb_build_object('kind','originalDelete','store',s,'requestId',new_req,'asset',req,'product',u.product_id,'alt',m.alt,'published',false,'uploaded',present,'confirm',true);
 -- Explicit confirmation of abandonment is logged before any file deletion.
 perform tenant_private.offline_original_delete_begin(s,d,secret,op);
 if not exists(select 1 from tenant_private.offline_original_deletions where store_id=s and request_id=new_req) then raise exception 'Retirement not reserved' using errcode='22023';end if;
 insert into tenant_private.offline_image_handoffs(store_id,request_id,kind,old_actor,old_device,new_actor,new_device,reason) values(s,req,'retire',auth.uid(),d,auth.uid(),d,btrim(reason));
 return tenant_private.offline_image_recovery(s,d,secret,new_req,'delete');
end $$;

create function tenant_private.offline_image_history(s uuid,d uuid,secret uuid,req uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.offline_device_require(s,d,secret);
 if tenant_private.member_role(s) is distinct from 'owner' or auth.jwt()->>'aal' is distinct from 'aal2' or not coalesce(tenant_private.central_read_permitted(s,'all_catalog_read'),false) then raise exception 'Owner AAL2 required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(h) order by h.created_at desc,h.id) from (select id,request_id,kind,old_actor,old_device,new_actor,new_device,reason,created_at from tenant_private.offline_image_handoffs where store_id=s and request_id=req order by created_at desc,id limit 100) h),'[]'::jsonb);
end $$;

CREATE OR REPLACE FUNCTION tenant_private.offline_image_jobs(s uuid, d uuid, secret uuid, after_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 if tenant_private.member_role(s) is distinct from 'owner' or auth.jwt()->>'aal' is distinct from 'aal2' or not coalesce(tenant_private.central_read_permitted(s,'all_catalog_read'),false) then raise exception 'Owner AAL2 required' using errcode='42501';end if;
 with jobs as (
 select u.request_id,u.product_id,u.request_id asset_id,u.device_id,u.created_at,'upload'::text kind,
 case when r.result->>'status'='confirmed' then 'confirmed' when r.result->>'status'='conflict' then 'conflict' when exists(select 1 from tenant_private.offline_original_deletions z where z.store_id=u.store_id and z.asset_id=u.request_id) then 'conflict' when m.id is null then 'metadata_missing' when exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=m.object_path) then 'verification_pending' else 'upload_pending' end state
 from tenant_private.offline_original_uploads u left join tenant_private.product_originals m on m.store_id=u.store_id and m.id=u.request_id left join tenant_private.offline_reviewed_requests r on r.store_id=u.store_id and r.request_id=u.request_id where u.store_id=s
 union all
 select x.request_id,x.product_id,x.asset_id,x.device_id,x.created_at,'delete',
 case when x.state='deleted' and exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=s::text||'/'||x.asset_id::text||'.jpg') then 'storage_mismatch'
 when x.state='deleted' then 'confirmed' when exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=s::text||'/'||x.asset_id::text||'.jpg') then 'delete_pending' else 'finalization_pending' end
 from tenant_private.offline_original_deletions x where x.store_id=s
 ) select coalesce(jsonb_agg(to_jsonb(j)||jsonb_build_object('device_state',coalesce(v.state,'missing'),'can_takeover',coalesce(v.state='revoked' and j.device_id<>d and j.state in ('upload_pending','verification_pending','delete_pending','finalization_pending','storage_mismatch'),false)) order by j.request_id),'[]'::jsonb) into result from (select * from jobs where after_id is null or request_id>after_id order by request_id limit 50) j left join tenant_private.offline_devices v on v.store_id=s and v.id=j.device_id;
 return result;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.product_original_reserve(p_store uuid, p_id uuid, p_product uuid, p_alt text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r tenant_private.product_originals%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_alt is null or length(btrim(p_alt)) not between 1 and 100 or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) then raise exception 'Invalid image' using errcode='22023';end if;
 if exists(select 1 from tenant_private.offline_original_deletions where store_id=p_store and asset_id=p_id) then raise exception 'Image retired' using errcode='22023';end if;
 select * into r from tenant_private.product_originals where store_id=p_store and id=p_id for update;
 if found then if r.actor<>auth.uid() or r.product_id<>p_product or r.alt<>btrim(p_alt) then raise exception 'Conflicting image reservation' using errcode='22023';end if;
 else
 -- Serialize only new quota reservations, not reads or existing upload resumes.
 perform pg_advisory_xact_lock(894313,149);
 if exists(select 1 from tenant_private.design_originals where store_id=p_store and id=p_id) then raise exception 'Image id already used' using errcode='22023';end if;
 if (select count(*) from tenant_private.product_originals)>=500 or (select count(*) from tenant_private.product_originals where store_id=p_store)>=100 or (select count(*) from tenant_private.product_originals where store_id=p_store and product_id=p_product)>=4 then raise exception 'Image quota' using errcode='22023';end if;
 insert into tenant_private.product_originals(store_id,id,product_id,alt,actor) values(p_store,p_id,p_product,btrim(p_alt),auth.uid()) returning * into r;
 end if;
 return jsonb_build_object('id',r.id,'path',r.object_path,'uploaded',exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=r.object_path));
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.offline_original_delete_finish(s uuid, d uuid, secret uuid, op jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare res jsonb;req uuid;
begin
 res:=tenant_private.offline_original_delete_begin(s,d,secret,op);
 if res->>'status'<>'reserved' then return res;end if;
 if (res->>'uploaded')::boolean is distinct from false then raise exception 'Storage deletion not confirmed' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;
 delete from tenant_private.product_originals where store_id=s and id=(op->>'asset')::uuid and product_id=(op->>'product')::uuid;
 update tenant_private.offline_original_deletions set state='deleted',finished_at=now() where store_id=s and request_id=req;
 res:=jsonb_build_object('status','confirmed','requestId',req,'resultId',op->>'asset');
 insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,res);
 -- A retired unconfirmed upload is terminal, never a successful dependency.
 insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result)
 select s,u.request_id,auth.uid(),d,jsonb_build_object('kind','originalUpload','store',s,'product',u.product_id,'requestId',u.request_id,'bytes',u.bytes,'digest',u.digest,'alt',u.alt),jsonb_build_object('status','conflict','requestId',u.request_id,'current','upload_retired') from tenant_private.offline_original_uploads u where u.store_id=s and u.request_id=(op->>'asset')::uuid and u.actor=auth.uid() and u.device_id=d on conflict(store_id,request_id) do nothing;
 return res;
end $function$;

-- Design media shares the bucket. Guard path collisions with retired product
-- IDs as well as current product originals; do not touch stored bytes.
create function tenant_private.offline_design_path_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from tenant_private.offline_original_deletions x where x.store_id=new.store_id and x.asset_id=new.id) or exists(select 1 from tenant_private.product_originals x where x.store_id=new.store_id and x.id=new.id) then raise exception 'Image path reserved or retired' using errcode='22023';end if;
 return new;
end $$;
create trigger mt_offline_design_path_guard before insert or update of store_id,id on tenant_private.design_originals for each row execute function tenant_private.offline_design_path_guard();
revoke all on function tenant_private.offline_design_path_guard() from public,anon,authenticated,service_role;

create function public.mt_offline_image_takeover(s uuid,d uuid,secret uuid,req uuid,job_kind text,expected_device uuid,reason text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_image_takeover(s,d,secret,req,job_kind,expected_device,reason)$$;
create function public.mt_offline_image_retire_upload(s uuid,d uuid,secret uuid,req uuid,reason text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_image_retire_upload(s,d,secret,req,reason)$$;
create function public.mt_offline_image_history(s uuid,d uuid,secret uuid,req uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_image_history(s,d,secret,req)$$;
revoke all on function tenant_private.offline_image_takeover(uuid,uuid,uuid,uuid,text,uuid,text),tenant_private.offline_image_retire_upload(uuid,uuid,uuid,uuid,text),tenant_private.offline_image_history(uuid,uuid,uuid,uuid),public.mt_offline_image_takeover(uuid,uuid,uuid,uuid,text,uuid,text),public.mt_offline_image_retire_upload(uuid,uuid,uuid,uuid,text),public.mt_offline_image_history(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_image_takeover(uuid,uuid,uuid,uuid,text,uuid,text),tenant_private.offline_image_retire_upload(uuid,uuid,uuid,uuid,text),tenant_private.offline_image_history(uuid,uuid,uuid,uuid),public.mt_offline_image_takeover(uuid,uuid,uuid,uuid,text,uuid,text),public.mt_offline_image_retire_upload(uuid,uuid,uuid,uuid,text),public.mt_offline_image_history(uuid,uuid,uuid,uuid) to authenticated;
commit;
