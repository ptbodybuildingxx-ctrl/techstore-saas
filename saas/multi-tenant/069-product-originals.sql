-- Full product image files are private, with an explicit per-product publication flag.
begin;
create table tenant_private.product_originals(
 store_id uuid not null,id uuid not null,product_id uuid not null,alt text not null check(length(btrim(alt)) between 1 and 100),published boolean not null default false,actor uuid not null,created_at timestamptz not null default now(),
 image_id text generated always as ('p-'||replace(id::text,'-','')) stored,object_path text generated always as (store_id::text||'/'||id::text||'.jpg') stored unique,
 primary key(store_id,id),foreign key(store_id,product_id) references public.mt_products(store_id,id),unique(store_id,image_id)
);
alter table tenant_private.product_originals enable row level security;revoke all on tenant_private.product_originals from public,anon,authenticated,service_role;
create function tenant_private.product_original_access(p_path text,p_write boolean) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from tenant_private.product_originals m where m.object_path=p_path and tenant_private.member_role(m.store_id)='owner' and (not p_write or tenant_private.shared_licensed(m.store_id)))
$$;
revoke all on function tenant_private.product_original_access(text,boolean) from public,anon,authenticated,service_role;grant execute on function tenant_private.product_original_access(text,boolean) to authenticated;
create policy mt_product_original_upload on storage.objects for insert to authenticated with check(bucket_id='saas-design-originals' and tenant_private.product_original_access(name,true));
create policy mt_product_original_read on storage.objects for select to authenticated using(bucket_id='saas-design-originals' and tenant_private.product_original_access(name,false));
create function tenant_private.product_original_reserve(p_store uuid,p_id uuid,p_product uuid,p_alt text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r tenant_private.product_originals%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_alt is null or length(btrim(p_alt)) not between 1 and 100 or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) then raise exception 'Invalid image' using errcode='22023';end if;
 lock table tenant_private.product_originals in share row exclusive mode;
 select * into r from tenant_private.product_originals where store_id=p_store and id=p_id;
 if found then if r.actor<>auth.uid() or r.product_id<>p_product or r.alt<>btrim(p_alt) then raise exception 'Conflicting image reservation' using errcode='22023';end if;
 else
 if exists(select 1 from tenant_private.design_originals where store_id=p_store and id=p_id) then raise exception 'Image id already used' using errcode='22023';end if;
 if (select count(*) from tenant_private.product_originals)>=500 or (select count(*) from tenant_private.product_originals where store_id=p_store)>=100 or (select count(*) from tenant_private.product_originals where store_id=p_store and product_id=p_product)>=4 then raise exception 'Image quota' using errcode='22023';end if;
 insert into tenant_private.product_originals(store_id,id,product_id,alt,actor) values(p_store,p_id,p_product,btrim(p_alt),auth.uid()) returning * into r;
 end if;
 return jsonb_build_object('id',r.id,'path',r.object_path,'uploaded',exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=r.object_path));
end $$;
create function tenant_private.product_original_list(p_store uuid,p_product uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'alt',r.alt,'path',r.object_path,'published',r.published,'uploaded',exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=r.object_path)) order by r.created_at,r.id) from tenant_private.product_originals r where r.store_id=p_store and r.product_id=p_product),'[]'::jsonb);
end $$;
create function tenant_private.product_original_publish(p_store uuid,p_id uuid,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare r tenant_private.product_originals%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 select * into r from tenant_private.product_originals where store_id=p_store and id=p_id;
 if not found or p_enabled is null then raise exception 'Invalid asset' using errcode='22023';end if;
 if p_enabled and not exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=r.object_path) then raise exception 'Upload first' using errcode='22023';end if;
 update tenant_private.product_originals set published=p_enabled where store_id=p_store and id=p_id;return p_enabled;
end $$;
create or replace function tenant_private.resolve_public_original(p_slug text,p_image text) returns text language sql stable security definer set search_path='' as $$
 select coalesce((select m.object_path from public.saas_stores s0 join tenant_private.product_originals m on m.store_id=s0.id join tenant_private.storefront_products l on l.store_id=m.store_id and l.product_id=m.product_id and l.listed where s0.slug=p_slug and m.image_id=p_image and m.published and tenant_private.storefront_active(s0.id) and exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=m.object_path)),(select r.object_path from public.saas_stores s join tenant_private.design_originals r on r.store_id=s.id where s.slug=p_slug and r.image_id=p_image and tenant_private.storefront_active(s.id) and r.public_fingerprint is not null and r.public_fingerprint=tenant_private.published_image_fingerprint(s.id,r.image_id) and exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=r.object_path)))
$$;

create function tenant_private.public_product_originals(p_slug text,p_product uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('image',r.image_id,'alt',r.alt) order by r.created_at,r.id),'[]') from public.saas_stores s join tenant_private.product_originals r on r.store_id=s.id where s.slug=p_slug and r.product_id=p_product and r.published and tenant_private.resolve_public_original(p_slug,r.image_id) is not null
$$;
create function public.mt_product_original_reserve(p_store uuid,p_id uuid,p_product uuid,p_alt text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.product_original_reserve(p_store,p_id,p_product,p_alt)$$;
create function public.mt_product_original_list(p_store uuid,p_product uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.product_original_list(p_store,p_product)$$;
create function public.mt_product_original_publish(p_store uuid,p_id uuid,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.product_original_publish(p_store,p_id,p_enabled)$$;
create function public.mt_public_product_originals(p_slug text,p_product uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.public_product_originals(p_slug,p_product)$$;
revoke all on function tenant_private.product_original_reserve(uuid,uuid,uuid,text),tenant_private.product_original_list(uuid,uuid),tenant_private.product_original_publish(uuid,uuid,boolean),tenant_private.public_product_originals(text,uuid),public.mt_product_original_reserve(uuid,uuid,uuid,text),public.mt_product_original_list(uuid,uuid),public.mt_product_original_publish(uuid,uuid,boolean),public.mt_public_product_originals(text,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.product_original_reserve(uuid,uuid,uuid,text),tenant_private.product_original_list(uuid,uuid),tenant_private.product_original_publish(uuid,uuid,boolean),public.mt_product_original_reserve(uuid,uuid,uuid,text),public.mt_product_original_list(uuid,uuid),public.mt_product_original_publish(uuid,uuid,boolean) to authenticated;
grant execute on function tenant_private.public_product_originals(text,uuid),public.mt_public_product_originals(text,uuid) to anon,authenticated;
commit;
