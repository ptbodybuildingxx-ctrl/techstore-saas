begin;
alter table tenant_private.design_originals add column public_fingerprint bytea check(public_fingerprint is null or octet_length(public_fingerprint)=32);
create function tenant_private.published_image_fingerprint(p_store uuid,p_image text) returns bytea language sql stable security definer set search_path='' as $$
 select sha256(convert_to(i->>'data','UTF8')) from tenant_private.design_heads h join tenant_private.design_versions v on v.store_id=h.store_id and v.revision=h.published_revision cross join lateral jsonb_array_elements(coalesce(v.theme->'site'->'images','[]'::jsonb)) i
 where h.store_id=p_store and i->>'id'=p_image and (exists(select 1 from jsonb_each_text(coalesce(v.theme->'site'->'product_images','{}'::jsonb)) x where x.value=p_image) or exists(select 1 from jsonb_array_elements(coalesce(v.theme->'site'->'pages','[]'::jsonb)) pg cross join lateral jsonb_array_elements(pg->'blocks') bl where bl->>'image'=p_image))
$$;
create function tenant_private.set_original_public(p_store uuid,p_asset uuid,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare r tenant_private.design_originals%rowtype;fp bytea;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_enabled is null then raise exception 'Explicit publication flag required' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 select * into r from tenant_private.design_originals where store_id=p_store and id=p_asset for update;
 if not found then raise exception 'Unknown asset' using errcode='22023';end if;
 if p_enabled then
 fp:=tenant_private.published_image_fingerprint(p_store,r.image_id);
 if fp is null or not exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=r.object_path) then raise exception 'Publish referenced thumbnail and upload original first' using errcode='22023';end if;
 end if;
 update tenant_private.design_originals set public_fingerprint=fp where store_id=p_store and id=p_asset;return p_enabled;
end $$;
create or replace function tenant_private.list_design_originals(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'image_id',r.image_id,'alt',r.alt,'path',r.object_path,'uploaded',exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=r.object_path),'public_enabled',r.public_fingerprint is not null,'public_visible',coalesce(r.public_fingerprint=tenant_private.published_image_fingerprint(r.store_id,r.image_id),false) and tenant_private.storefront_active(r.store_id)) order by r.created_at,r.id) from tenant_private.design_originals r where r.store_id=p_store),'[]'::jsonb);
end $$;
create function tenant_private.resolve_public_original(p_slug text,p_image text) returns text language sql stable security definer set search_path='' as $$
 select r.object_path from public.saas_stores s join tenant_private.design_originals r on r.store_id=s.id where s.slug=p_slug and r.image_id=p_image and tenant_private.storefront_active(s.id) and r.public_fingerprint is not null and r.public_fingerprint=tenant_private.published_image_fingerprint(s.id,r.image_id) and exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=r.object_path)
$$;
create function tenant_private.public_originals(p_slug text) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(r.image_id order by r.image_id),'[]'::jsonb) from public.saas_stores s join tenant_private.design_originals r on r.store_id=s.id where s.slug=p_slug and tenant_private.resolve_public_original(p_slug,r.image_id) is not null
$$;
create function public.mt_set_original_public(p_store uuid,p_asset uuid,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.set_original_public(p_store,p_asset,p_enabled)$$;
create function public.mt_public_originals(p_slug text) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.public_originals(p_slug)$$;
create function public.mt_service_public_original(p_slug text,p_image text) returns text language sql stable security invoker set search_path='' as $$select tenant_private.resolve_public_original(p_slug,p_image)$$;
revoke all on function tenant_private.published_image_fingerprint(uuid,text),tenant_private.set_original_public(uuid,uuid,boolean),tenant_private.public_originals(text),tenant_private.resolve_public_original(text,text),public.mt_set_original_public(uuid,uuid,boolean),public.mt_public_originals(text),public.mt_service_public_original(text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.set_original_public(uuid,uuid,boolean),public.mt_set_original_public(uuid,uuid,boolean) to authenticated;
grant execute on function tenant_private.public_originals(text),public.mt_public_originals(text) to anon,authenticated;
grant execute on function tenant_private.resolve_public_original(text,text),public.mt_service_public_original(text,text) to service_role;
commit;