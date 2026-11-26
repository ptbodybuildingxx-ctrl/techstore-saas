-- Customer library and moderated, verified-purchase reviews.
begin;
create table tenant_private.buyer_favorites(store_id uuid not null,buyer uuid not null references auth.users(id) on delete cascade,product_id uuid not null,created_at timestamptz not null default now(),primary key(store_id,buyer,product_id),foreign key(store_id,product_id) references public.mt_products(store_id,id));
create table tenant_private.buyer_builds(store_id uuid not null references tenant_private.workspaces(store_id),buyer uuid not null references auth.users(id) on delete cascade,id uuid not null,name text not null check(length(btrim(name)) between 1 and 120),currency text not null check(currency in ('SYP','USD','EUR')),parts jsonb not null,created_at timestamptz not null default now(),primary key(store_id,buyer,id));
create table tenant_private.product_reviews(store_id uuid not null,buyer uuid not null references auth.users(id) on delete cascade,product_id uuid not null,id uuid not null default gen_random_uuid(),rating integer not null check(rating between 1 and 5),body text not null check(length(btrim(body)) between 1 and 600),state text not null default 'pending' check(state in ('pending','published','rejected')),created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,buyer,product_id),foreign key(store_id,product_id) references public.mt_products(store_id,id));
create index mt_review_product on tenant_private.product_reviews(store_id,product_id,state,created_at desc);
do $$declare t text;begin foreach t in array array['buyer_favorites','buyer_builds','product_reviews'] loop execute format('alter table tenant_private.%I enable row level security',t);execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create function tenant_private.favorite_set(p_slug text,p_product uuid,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);
begin
 if p_enabled is null then raise exception 'Invalid flag' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=t for update;
 if not p_enabled then delete from tenant_private.buyer_favorites where store_id=t and buyer=auth.uid() and product_id=p_product;return false;end if;
 if not exists(select 1 from tenant_private.storefront_products where store_id=t and product_id=p_product and listed) then raise exception 'Unavailable product' using errcode='22023';end if;
 if exists(select 1 from tenant_private.buyer_favorites where store_id=t and buyer=auth.uid() and product_id=p_product) then return true;end if;
 if (select count(*) from tenant_private.buyer_favorites where store_id=t and buyer=auth.uid())>=100 then raise exception 'Favorite limit' using errcode='22023';end if;
 insert into tenant_private.buyer_favorites(store_id,buyer,product_id) values(t,auth.uid(),p_product);return true;
end
$$;
create function public.mt_favorite_set(p_slug text,p_product uuid,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.favorite_set(p_slug,p_product,p_enabled)$$;
create function tenant_private.build_save(p_slug text,p_id uuid,p_name text,p_currency text,p_products uuid[]) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);parts_now jsonb;old tenant_private.buyer_builds%rowtype;
begin
 if p_id is null or p_name is null or length(btrim(p_name)) not between 1 and 120 or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_products is null or cardinality(p_products) not between 1 and 8 or (select count(distinct x) from unnest(p_products)x)<>cardinality(p_products) then raise exception 'Invalid build' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=t for update;
 select * into old from tenant_private.buyer_builds where store_id=t and buyer=auth.uid() and id=p_id;
 if found then if old.name<>btrim(p_name) or old.currency<>p_currency or (select array_agg((x->>'id')::uuid order by x->>'id') from jsonb_array_elements(old.parts)x) is distinct from (select array_agg(x order by x::text) from unnest(p_products)x) then raise exception 'Conflicting build' using errcode='22023';end if;return p_id;end if;
 if (select count(*) from tenant_private.buyer_builds where store_id=t and buyer=auth.uid())>=20 then raise exception 'Build limit' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'specs',p.specs,'price_minor',pp.price_minor) order by p.id) into parts_now from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=t and p.id=any(p_products);
 if coalesce(jsonb_array_length(parts_now),0)<>cardinality(p_products) then raise exception 'Unavailable part' using errcode='22023';end if;
 insert into tenant_private.buyer_builds(store_id,buyer,id,name,currency,parts) values(t,auth.uid(),p_id,btrim(p_name),p_currency,parts_now);return p_id;
end
$$;
create function public.mt_build_save(p_slug text,p_id uuid,p_name text,p_currency text,p_products uuid[]) returns uuid language sql security invoker set search_path='' as $$select tenant_private.build_save(p_slug,p_id,p_name,p_currency,p_products)$$;
create function tenant_private.build_delete(p_slug text,p_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);begin delete from tenant_private.buyer_builds where store_id=t and buyer=auth.uid() and id=p_id;return true;end
$$;
create function public.mt_build_delete(p_slug text,p_id uuid) returns boolean language sql security invoker set search_path='' as $$select tenant_private.build_delete(p_slug,p_id)$$;
create function tenant_private.buyer_library(p_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);begin
 return jsonb_build_object('favorites',coalesce((select jsonb_agg(jsonb_build_object('id',f.product_id,'name',case when l.listed then p.name else 'منتج غير متاح' end) order by f.created_at desc) from tenant_private.buyer_favorites f join public.mt_products p on p.store_id=f.store_id and p.id=f.product_id left join tenant_private.storefront_products l on l.store_id=f.store_id and l.product_id=f.product_id where f.store_id=t and f.buyer=auth.uid()),'[]'::jsonb),'builds',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'currency',currency,'parts',parts,'created_at',created_at) order by created_at desc) from tenant_private.buyer_builds where store_id=t and buyer=auth.uid()),'[]'::jsonb),'reviews',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc) from (select id,product_id,rating,body,state,created_at from tenant_private.product_reviews where store_id=t and buyer=auth.uid() order by created_at desc limit 100)x),'[]'::jsonb));
end
$$;
create function public.mt_buyer_library(p_slug text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.buyer_library(p_slug)$$;
create function tenant_private.review_submit(p_slug text,p_product uuid,p_rating integer,p_body text) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);v uuid;
begin
 if p_rating is null or p_rating not between 1 and 5 or p_body is null or length(btrim(p_body)) not between 1 and 600 then raise exception 'Invalid review' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=t for update;
 if not exists(select 1 from tenant_private.storefront_products where store_id=t and product_id=p_product and listed) or not exists(select 1 from public.mt_online_orders o cross join lateral jsonb_array_elements(o.lines)x where o.store_id=t and o.buyer=auth.uid() and o.state='fulfilled' and x->>'product_id'=p_product::text) then raise exception 'Verified purchase required' using errcode='22023';end if;
 insert into tenant_private.product_reviews(store_id,buyer,product_id,rating,body) values(t,auth.uid(),p_product,p_rating,btrim(p_body)) on conflict(store_id,buyer,product_id) do update set rating=excluded.rating,body=excluded.body,state='pending',created_at=now() returning id into v;return v;
end
$$;
create function public.mt_review_submit(p_slug text,p_product uuid,p_rating integer,p_body text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.review_submit(p_slug,p_product,p_rating,p_body)$$;
create function tenant_private.public_reviews(p_slug text,p_product uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid;begin
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);
 if not found or not exists(select 1 from tenant_private.storefront_products where store_id=t and product_id=p_product and listed) then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc) from (select rating,body,created_at from tenant_private.product_reviews where store_id=t and product_id=p_product and state='published' order by created_at desc,id desc limit 50)x),'[]'::jsonb);
end
$$;
create function public.mt_public_reviews(p_slug text,p_product uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.public_reviews(p_slug,p_product)$$;
create function tenant_private.review_queue(p_store uuid,p_after uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by id) from (select r.id,p.name,r.rating,r.body,r.state,r.created_at from tenant_private.product_reviews r join public.mt_products p on p.store_id=r.store_id and p.id=r.product_id where r.store_id=p_store and (p_after is null or r.id>p_after) order by r.id limit 50)x),'[]'::jsonb);
end
$$;
create function public.mt_review_queue(p_store uuid,p_after uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.review_queue(p_store,p_after)$$;
create function tenant_private.review_moderate(p_store uuid,p_id uuid,p_state text) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_state is null or p_state not in ('published','rejected') then raise exception 'Invalid moderation' using errcode='22023';end if;
 update tenant_private.product_reviews set state=p_state where store_id=p_store and id=p_id;return found;
end
$$;
create function public.mt_review_moderate(p_store uuid,p_id uuid,p_state text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.review_moderate(p_store,p_id,p_state)$$;
revoke all on function tenant_private.favorite_set(text,uuid,boolean),public.mt_favorite_set(text,uuid,boolean),tenant_private.build_save(text,uuid,text,text,uuid[]),public.mt_build_save(text,uuid,text,text,uuid[]),tenant_private.build_delete(text,uuid),public.mt_build_delete(text,uuid),tenant_private.buyer_library(text),public.mt_buyer_library(text),tenant_private.review_submit(text,uuid,integer,text),public.mt_review_submit(text,uuid,integer,text),tenant_private.public_reviews(text,uuid),public.mt_public_reviews(text,uuid),tenant_private.review_queue(uuid,uuid),public.mt_review_queue(uuid,uuid),tenant_private.review_moderate(uuid,uuid,text),public.mt_review_moderate(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.favorite_set(text,uuid,boolean),public.mt_favorite_set(text,uuid,boolean),tenant_private.build_save(text,uuid,text,text,uuid[]),public.mt_build_save(text,uuid,text,text,uuid[]),tenant_private.build_delete(text,uuid),public.mt_build_delete(text,uuid),tenant_private.buyer_library(text),public.mt_buyer_library(text),tenant_private.review_submit(text,uuid,integer,text),public.mt_review_submit(text,uuid,integer,text),tenant_private.public_reviews(text,uuid),public.mt_public_reviews(text,uuid),tenant_private.review_queue(uuid,uuid),public.mt_review_queue(uuid,uuid),tenant_private.review_moderate(uuid,uuid,text),public.mt_review_moderate(uuid,uuid,text) to authenticated;
grant execute on function tenant_private.public_reviews(text,uuid),public.mt_public_reviews(text,uuid) to anon;
commit;
