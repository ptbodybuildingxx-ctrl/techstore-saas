begin;
do $$ begin if to_regclass('tenant_private.design_heads') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS only';end if;end $$;
-- Private original-image library. Object bytes must be uploaded/deleted through Storage API.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('saas-design-originals','saas-design-originals',false,2000000,array['image/jpeg']);
create table tenant_private.design_originals(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null unique,
 image_id text not null check(image_id ~ '^[a-z0-9-]{1,40}$'),alt text not null check(length(btrim(alt)) between 1 and 100),
 actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,image_id),
 object_path text generated always as (store_id::text||'/'||id::text||'.jpg') stored unique
);
alter table tenant_private.design_originals enable row level security;
revoke all on tenant_private.design_originals from public,anon,authenticated,service_role;
create function tenant_private.can_access_design_original(p_path text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(saas_private.is_operator(),false) and exists(select 1 from tenant_private.design_originals where object_path=p_path)
$$;
revoke all on function tenant_private.can_access_design_original(text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.can_access_design_original(text) to authenticated;
create policy mt_original_upload on storage.objects for insert to authenticated with check(bucket_id='saas-design-originals' and tenant_private.can_access_design_original(name));
create policy mt_original_download on storage.objects for select to authenticated using(bucket_id='saas-design-originals' and tenant_private.can_access_design_original(name));
-- No browser update/delete, no public read. Replacement needs a new thumbnail id.
create function tenant_private.reserve_design_original(p_store uuid,p_request uuid,p_image text,p_alt text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r tenant_private.design_originals%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_store is null or p_request is null or p_image is null or p_image !~ '^[a-z0-9-]{1,40}$' or p_alt is null or length(btrim(p_alt)) not between 1 and 100 then raise exception 'Invalid original image' using errcode='22023';end if;
 -- Bound aggregate reserved capacity to 200 MB in this development project.
 lock table tenant_private.design_originals in share row exclusive mode;
 select * into r from tenant_private.design_originals where request_id=p_request;
 if found then
 if r.store_id<>p_store or r.actor<>auth.uid() or r.image_id<>p_image or r.alt<>btrim(p_alt) then raise exception 'Conflicting image request' using errcode='22023';end if;
 else
 if not exists(select 1 from tenant_private.design_heads h join tenant_private.design_versions v on v.store_id=h.store_id and v.revision=h.draft_revision cross join lateral jsonb_array_elements(coalesce(v.theme->'site'->'images','[]'::jsonb)) i where h.store_id=p_store and i->>'id'=p_image) then raise exception 'Save thumbnail in current draft first' using errcode='22023';end if;
 if (select count(*) from tenant_private.design_originals)>=100 or (select count(*) from tenant_private.design_originals where store_id=p_store)>=12 then raise exception 'Development media quota reached' using errcode='22023';end if;
 insert into tenant_private.design_originals(store_id,request_id,image_id,alt,actor) values(p_store,p_request,p_image,btrim(p_alt),auth.uid()) returning * into r;
 end if;
 return jsonb_build_object('id',r.id,'image_id',r.image_id,'path',r.object_path,'uploaded',exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=r.object_path));
end $$;
create function tenant_private.list_design_originals(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'image_id',r.image_id,'alt',r.alt,'path',r.object_path,'uploaded',exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=r.object_path)) order by r.created_at,r.id) from tenant_private.design_originals r where r.store_id=p_store),'[]'::jsonb);
end $$;
create function public.mt_reserve_design_original(p_store uuid,p_request uuid,p_image text,p_alt text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.reserve_design_original(p_store,p_request,p_image,p_alt)$$;
create function public.mt_list_design_originals(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.list_design_originals(p_store)$$;
revoke all on function tenant_private.reserve_design_original(uuid,uuid,text,text),tenant_private.list_design_originals(uuid),public.mt_reserve_design_original(uuid,uuid,text,text),public.mt_list_design_originals(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.reserve_design_original(uuid,uuid,text,text),tenant_private.list_design_originals(uuid),public.mt_reserve_design_original(uuid,uuid,text,text),public.mt_list_design_originals(uuid) to authenticated;
commit;