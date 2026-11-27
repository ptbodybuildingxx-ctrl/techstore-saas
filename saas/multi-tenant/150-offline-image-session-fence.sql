-- 150: short-lived session-bound Storage permissions for offline image jobs.
begin;
set local lock_timeout='5s';
create table tenant_private.offline_image_session_grants(
 store_id uuid not null,
 request_id uuid not null,
 kind text not null check(kind in ('upload','delete')),
 actor uuid not null,
 device_id uuid not null,
 session_id uuid not null,
 object_path text not null,
 expires_at timestamptz not null,
 primary key(store_id,request_id,kind),
 foreign key(store_id,device_id) references tenant_private.offline_devices(store_id,id)
);
alter table tenant_private.offline_image_session_grants enable row level security;
revoke all on tenant_private.offline_image_session_grants from public,anon,authenticated,service_role;

create function tenant_private.offline_image_session_grant(s uuid,d uuid,req uuid,k text,p text) returns void
language plpgsql security definer set search_path='' as $$
declare sid uuid:=nullif(auth.jwt()->>'session_id','')::uuid;
begin
 -- Only internal callers that have already proved the installation secret and
 -- validated the exact job can issue a lease. No public grant endpoint.
 if auth.uid() is null or sid is null or not coalesce(saas_private.live_session(),false) or tenant_private.member_role(s) is distinct from 'owner'
 or k not in ('upload','delete') or not exists(select 1 from tenant_private.offline_devices v where v.store_id=s and v.id=d and v.actor=auth.uid() and v.state='approved') then raise exception 'Live approved session required' using errcode='42501';end if;
 insert into tenant_private.offline_image_session_grants(store_id,request_id,kind,actor,device_id,session_id,object_path,expires_at)
 values(s,req,k,auth.uid(),d,sid,p,clock_timestamp()+interval '10 minutes')
 on conflict(store_id,request_id,kind) do update set actor=excluded.actor,device_id=excluded.device_id,session_id=excluded.session_id,object_path=excluded.object_path,expires_at=excluded.expires_at;
end $$;
create function tenant_private.offline_image_session_allowed(s uuid,d uuid,req uuid,k text,p text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from tenant_private.offline_image_session_grants g join tenant_private.offline_devices v on v.store_id=g.store_id and v.id=g.device_id
 where g.store_id=s and g.request_id=req and g.kind=k and g.device_id=d and g.actor=auth.uid() and g.session_id::text=auth.jwt()->>'session_id' and g.object_path=p and g.expires_at>now() and v.actor=auth.uid() and v.state='approved')
 and coalesce(saas_private.live_session(),false)
$$;
revoke all on function tenant_private.offline_image_session_grant(uuid,uuid,uuid,text,text),tenant_private.offline_image_session_allowed(uuid,uuid,uuid,text,text) from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION tenant_private.product_original_access(p_path text, p_write boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '1500ms'
AS $function$
declare m tenant_private.product_originals%rowtype;u tenant_private.offline_original_uploads%rowtype;
begin
 if auth.uid() is null or p_path is null then return false;end if;
 if not p_write then
  return exists(select 1 from tenant_private.product_originals r where r.object_path=p_path and tenant_private.member_role(r.store_id)='owner' and tenant_private.central_read_permitted(r.store_id,'all_catalog_read'));
 end if;
 select * into m from tenant_private.product_originals where object_path=p_path for update;
 if not found or tenant_private.member_role(m.store_id) is distinct from 'owner'
 or not coalesce(tenant_private.shared_licensed(m.store_id),false)
 or not coalesce(tenant_private.central_read_permitted(m.store_id,'all_catalog_read'),false)
 or tenant_private.central_action_denied(m.store_id,'product_profile_edit')
 or exists(select 1 from tenant_private.offline_original_deletions x where x.store_id=m.store_id and x.asset_id=m.id) then return false;end if;
 select * into u from tenant_private.offline_original_uploads where store_id=m.store_id and request_id=m.id;
 if found then
  if u.actor is distinct from auth.uid() then return false;end if;
  perform 1 from tenant_private.offline_devices where store_id=m.store_id and id=u.device_id and actor=auth.uid() and state='approved' for share;
  if not found then return false;end if;
  if not tenant_private.offline_image_session_allowed(m.store_id,u.device_id,u.request_id,'upload',p_path) then return false;end if;
 end if;
 return true;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.offline_original_delete_allowed(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from tenant_private.offline_original_deletions x join tenant_private.product_originals m on m.store_id=x.store_id and m.id=x.asset_id join tenant_private.offline_devices d on d.store_id=x.store_id and d.id=x.device_id where m.object_path=p_path and x.state='reserved' and x.actor=auth.uid() and d.actor=auth.uid() and d.state='approved' and auth.jwt()->>'aal'='aal2' and tenant_private.member_role(x.store_id)='owner' and tenant_private.shared_licensed(x.store_id) and not tenant_private.central_action_denied(x.store_id,'product_profile_edit') and tenant_private.central_read_permitted(x.store_id,'all_catalog_read') and tenant_private.offline_image_session_allowed(x.store_id,x.device_id,x.request_id,'delete',p_path))
$function$;
CREATE OR REPLACE FUNCTION tenant_private.offline_retired_original_access(p_path text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '1500ms'
AS $function$
declare x tenant_private.offline_original_deletions%rowtype;
begin
 if auth.uid() is null or auth.jwt()->>'aal' is distinct from 'aal2' or p_path is null or p_path !~ '^[a-f0-9-]{36}/[a-f0-9-]{36}\.jpg$' then return false;end if;
 select * into x from tenant_private.offline_original_deletions where store_id=split_part(p_path,'/',1)::uuid and asset_id=split_part(split_part(p_path,'/',2),'.',1)::uuid and state='deleted' and actor=auth.uid() for share;
 if not found or tenant_private.member_role(x.store_id) is distinct from 'owner' or not coalesce(tenant_private.shared_licensed(x.store_id),false) or not coalesce(tenant_private.central_read_permitted(x.store_id,'all_catalog_read'),false) or tenant_private.central_action_denied(x.store_id,'product_profile_edit') or exists(select 1 from tenant_private.product_originals m where m.store_id=x.store_id and m.id=x.asset_id) or exists(select 1 from tenant_private.design_originals m where m.object_path=p_path) then return false;end if;
 perform 1 from tenant_private.offline_devices where store_id=x.store_id and id=x.device_id and actor=auth.uid() and state='approved' for share;
 return found and tenant_private.offline_image_session_allowed(x.store_id,x.device_id,x.request_id,'delete',p_path);
exception when invalid_text_representation then return false;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.offline_original_reserve(s uuid, d uuid, secret uuid, op jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare req uuid;pid uuid;old tenant_private.offline_original_uploads%rowtype;reserved jsonb;prior tenant_private.offline_reviewed_requests%rowtype;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if not tenant_private.central_read_permitted(s,'all_catalog_read') or tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Product access denied' using errcode='42501';end if;
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>4000 or op->>'kind' is distinct from 'originalUpload' or (op->>'store')::uuid is distinct from s then raise exception 'Invalid image request' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;pid:=(op->>'product')::uuid;
 if req is null or pid is null or op->>'digest' is null or op->>'digest' !~ '^[a-f0-9]{64}$' or (op->>'bytes')::integer is null or (op->>'bytes')::integer not between 12 and 2000000 or op->>'alt' is null or length(btrim(op->>'alt')) not between 1 and 100 then raise exception 'Invalid image metadata' using errcode='22023';end if;
 select * into prior from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if prior.actor<>auth.uid() or prior.device_id<>d or prior.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
  perform tenant_private.offline_receipt_scope_require(s,prior.access_digest);return prior.result;
 end if;
 select * into old from tenant_private.offline_original_uploads where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.product_id<>pid or old.alt<>btrim(op->>'alt') or old.digest<>op->>'digest' or old.bytes<>(op->>'bytes')::integer then raise exception 'Image request conflict' using errcode='22023';end if;
 else
  if exists(select 1 from tenant_private.product_originals where store_id=s and id=req) then raise exception 'Image reference in use' using errcode='22023';end if;
  insert into tenant_private.offline_original_uploads(store_id,request_id,actor,device_id,product_id,alt,digest,bytes) values(s,req,auth.uid(),d,pid,btrim(op->>'alt'),op->>'digest',(op->>'bytes')::integer);
 end if;
 reserved:=public.mt_product_original_reserve(s,req,pid,op->>'alt');
 perform tenant_private.offline_image_session_grant(s,d,req,'upload',reserved->>'path');
 return reserved||jsonb_build_object('status','reserved','requestId',req);
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.offline_original_delete_begin(s uuid, d uuid, secret uuid, op jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare req uuid;asset uuid;pid uuid;original tenant_private.product_originals%rowtype;prior tenant_private.offline_reviewed_requests%rowtype;pending tenant_private.offline_original_deletions%rowtype;uploaded boolean;res jsonb;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if auth.jwt()->>'aal' is distinct from 'aal2' or tenant_private.central_action_denied(s,'product_profile_edit') or not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Owner AAL2 catalog permission required' using errcode='42501';end if;
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>4000 or op->>'kind' is distinct from 'originalDelete' or (op->>'store')::uuid is distinct from s or (op->>'confirm')::boolean is distinct from true then raise exception 'Explicit image deletion required' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;asset:=(op->>'asset')::uuid;pid:=(op->>'product')::uuid;
 if req is null or asset is null or pid is null or op->>'alt' is null or (op->>'published')::boolean is null or (op->>'uploaded')::boolean is null then raise exception 'Invalid image review' using errcode='22023';end if;
 select * into prior from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then if prior.actor<>auth.uid() or prior.device_id<>d or prior.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;perform tenant_private.offline_receipt_scope_require(s,prior.access_digest);return prior.result;end if;
 select * into pending from tenant_private.offline_original_deletions where store_id=s and request_id=req;
 if found then
  if pending.actor<>auth.uid() or pending.device_id<>d or pending.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
 else
  select * into original from tenant_private.product_originals where store_id=s and id=asset and product_id=pid for update;
  if found then select exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=original.object_path) into uploaded;end if;
  if original.id is null or original.alt is distinct from op->>'alt' or original.published is distinct from (op->>'published')::boolean or uploaded is distinct from (op->>'uploaded')::boolean or exists(select 1 from tenant_private.offline_original_deletions where store_id=s and asset_id=asset) then
   res:=jsonb_build_object('status','conflict','requestId',req,'current','image_changed');
   insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,res);return res;
  end if;
  insert into tenant_private.offline_original_deletions(store_id,request_id,asset_id,product_id,actor,device_id,payload) values(s,req,asset,pid,auth.uid(),d,op);
  update tenant_private.product_originals set published=false where store_id=s and id=asset;
 end if;
 perform tenant_private.offline_image_session_grant(s,d,req,'delete',s::text||'/'||asset::text||'.jpg');
 return jsonb_build_object('status','reserved','requestId',req,'id',asset,'path',s::text||'/'||asset::text||'.jpg','uploaded',exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=s::text||'/'||asset::text||'.jpg'));
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.offline_image_recovery(s uuid, d uuid, secret uuid, req uuid, job_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '1500ms'
AS $function$
declare u tenant_private.offline_original_uploads%rowtype;x tenant_private.offline_original_deletions%rowtype;r tenant_private.offline_reviewed_requests%rowtype;m tenant_private.product_originals%rowtype;payload jsonb;path text;present boolean;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if auth.jwt()->>'aal' is distinct from 'aal2' or not coalesce(tenant_private.central_read_permitted(s,'all_catalog_read'),false) or tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Owner AAL2 required' using errcode='42501';end if;
 if req is null or job_kind not in ('upload','delete') or job_kind is null then raise exception 'Invalid recovery reference' using errcode='22023';end if;
 select * into r from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if job_kind='upload' then
  select * into u from tenant_private.offline_original_uploads where store_id=s and request_id=req and actor=auth.uid() and device_id=d;
  if not found then raise exception 'Original installation required' using errcode='42501';end if;
  if r.request_id is not null then return jsonb_build_object('status',case when r.result->>'status'='conflict' then 'conflict' else 'confirmed' end,'requestId',req);end if;
  select * into m from tenant_private.product_originals where store_id=s and id=req and product_id=u.product_id for update;
  if not found or exists(select 1 from tenant_private.offline_original_deletions where store_id=s and asset_id=req) then return jsonb_build_object('status','metadata_missing','requestId',req);end if;
  path:=m.object_path;
  perform tenant_private.offline_image_session_grant(s,d,req,'upload',path);
  present:=exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=path);
  -- Canonical payload of the existing offline client. A noncanonical historic
  -- client may require status-only reconciliation instead of detail replay.
  payload:=jsonb_build_object('kind','originalUpload','store',s,'product',u.product_id,'requestId',req,'bytes',u.bytes,'digest',u.digest,'alt',u.alt);
  return jsonb_build_object('status',case when present then 'verification_pending' else 'upload_pending' end,'requestId',req,'id',req,'path',path,'operation',payload);
 else
  select * into x from tenant_private.offline_original_deletions where store_id=s and request_id=req and actor=auth.uid() and device_id=d;
  if not found then raise exception 'Original installation required' using errcode='42501';end if;
  path:=s::text||'/'||x.asset_id::text||'.jpg';
  present:=exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=path);
  if x.state='deleted' and not present then return jsonb_build_object('status','confirmed','requestId',req);end if;
  perform tenant_private.offline_image_session_grant(s,d,req,'delete',path);
  return jsonb_build_object('status',case when x.state='deleted' then 'storage_mismatch' when present then 'delete_pending' else 'finalization_pending' end,'requestId',req,'id',x.asset_id,'path',path,'operation',x.payload);
 end if;
end $function$;

-- Prevent path reuse across the two metadata tables with the same per-path
-- advisory lock. Never mutate storage.objects directly.
create function tenant_private.offline_product_path_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(new.store_id::text||'/'||new.id::text,149));
 if exists(select 1 from tenant_private.design_originals x where x.store_id=new.store_id and x.id=new.id) or exists(select 1 from tenant_private.offline_original_deletions x where x.store_id=new.store_id and x.asset_id=new.id) then raise exception 'Image path reserved or retired' using errcode='22023';end if;
 return new;
end $$;
create trigger mt_offline_product_path_guard before insert or update of store_id,id on tenant_private.product_originals for each row execute function tenant_private.offline_product_path_guard();
create or replace function tenant_private.offline_design_path_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(new.store_id::text||'/'||new.id::text,149));
 if exists(select 1 from tenant_private.offline_original_deletions x where x.store_id=new.store_id and x.asset_id=new.id) or exists(select 1 from tenant_private.product_originals x where x.store_id=new.store_id and x.id=new.id) then raise exception 'Image path reserved or retired' using errcode='22023';end if;
 return new;
end $$;
revoke all on function tenant_private.offline_product_path_guard() from public,anon,authenticated,service_role;
commit;
