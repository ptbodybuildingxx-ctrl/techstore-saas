-- Durable in-app buyer notifications; no external transport or service credentials.
begin;
create table tenant_private.product_watches(
 store_id uuid not null, buyer uuid not null references auth.users(id) on delete cascade, product_id uuid not null,currency text not null check(currency in ('SYP','USD','EUR')),kind text not null check(kind in ('price_drop','restock')),created_at timestamptz not null default now(),primary key(store_id,buyer,product_id,currency,kind),
 foreign key(store_id,product_id) references public.mt_products(store_id,id)
);
create index mt_watch_product on tenant_private.product_watches(store_id,product_id,kind,currency);
create table tenant_private.buyer_notifications(
 store_id uuid not null references tenant_private.workspaces(store_id),buyer uuid not null references auth.users(id) on delete cascade,id uuid not null default gen_random_uuid(),
 kind text not null check(kind in ('order','price_drop','restock')),subject text not null,reference uuid not null,detail text not null,created_at timestamptz not null default now(),read_at timestamptz,primary key(store_id,buyer,id)
);
create index mt_buyer_notifications_recent on tenant_private.buyer_notifications(store_id,buyer,created_at desc,id desc);
alter table tenant_private.product_watches enable row level security;
alter table tenant_private.buyer_notifications enable row level security;
revoke all on tenant_private.product_watches,tenant_private.buyer_notifications from public,anon,authenticated,service_role;
create function tenant_private.buyer_store(p_slug text) returns uuid language plpgsql stable security definer set search_path='' as $$
declare t uuid;
begin
 if not coalesce(saas_private.live_session(),false) or auth.uid() is null then raise exception 'Live buyer required' using errcode='42501';end if;
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);
 if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 return t;
end $$;
create function tenant_private.watch_product(p_slug text,p_product uuid,p_currency text,p_kind text,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);
begin
 if p_enabled is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_kind is null or p_kind not in ('price_drop','restock') then raise exception 'Invalid alert' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=t for update;
 if not p_enabled then delete from tenant_private.product_watches where store_id=t and buyer=auth.uid() and product_id=p_product and currency=p_currency and kind=p_kind;return false;end if;
 if not exists(select 1 from tenant_private.storefront_products l join public.mt_product_prices pp on pp.store_id=l.store_id and pp.product_id=l.product_id and pp.currency=p_currency where l.store_id=t and l.product_id=p_product and l.listed) then raise exception 'Unavailable product' using errcode='22023';end if;
 if exists(select 1 from tenant_private.product_watches where store_id=t and buyer=auth.uid() and product_id=p_product and currency=p_currency and kind=p_kind) then return true;end if;
 if (select count(*) from tenant_private.product_watches where store_id=t and buyer=auth.uid())>=30 or (select count(*) from tenant_private.product_watches where store_id=t)>=1000 then raise exception 'Watch limit' using errcode='22023';end if;
 insert into tenant_private.product_watches(store_id,buyer,product_id,currency,kind) values(t,auth.uid(),p_product,p_currency,p_kind);return true;
end $$;
create function tenant_private.notify_buyer_order() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' then if old.state=new.state and old.delivery_state is not distinct from new.delivery_state then return new;end if;end if;
 insert into tenant_private.buyer_notifications(store_id,buyer,kind,subject,reference,detail) values(new.store_id,new.buyer,'order','طلب',new.id,coalesce(new.delivery_state,new.state));return new;
end $$;
create trigger mt_notify_buyer_order after insert or update of state,delivery_state on public.mt_online_orders for each row execute function tenant_private.notify_buyer_order();
create function tenant_private.notify_product_watch() returns trigger language plpgsql security definer set search_path='' as $$
declare p uuid;k text;c text;detail_text text;n text;
begin
 if tg_table_name='mt_products' then
  if old.quantity<>0 or new.quantity<=0 then return new;end if;
  p:=new.id;k:='restock';c:=null;detail_text:='available';
 else
  if new.price_minor>=old.price_minor then return new;end if;
  p:=new.product_id;k:='price_drop';c:=new.currency;detail_text:=new.price_minor::text;
 end if;
 if not tenant_private.storefront_active(new.store_id) or not exists(select 1 from tenant_private.storefront_products where store_id=new.store_id and product_id=p and listed) then return new;end if;
 select name into n from public.mt_products where store_id=new.store_id and id=p;
 with matched as (
  delete from tenant_private.product_watches w where w.store_id=new.store_id and w.product_id=p and w.kind=k and (c is null or w.currency=c) and exists(select 1 from public.mt_product_prices pp where pp.store_id=w.store_id and pp.product_id=w.product_id and pp.currency=w.currency) returning w.*
 )
 insert into tenant_private.buyer_notifications(store_id,buyer,kind,subject,reference,detail) select store_id,buyer,k,n,p,case when k='price_drop' then detail_text||' '||currency else detail_text end from matched;
 return new;
end $$;
create trigger mt_notify_restock after update of quantity on public.mt_products for each row execute function tenant_private.notify_product_watch();
create trigger mt_notify_price after update of price_minor on public.mt_product_prices for each row execute function tenant_private.notify_product_watch();
create function tenant_private.buyer_inbox(p_slug text,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);r jsonb;
begin
 if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page' using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc,id desc),'[]'::jsonb) into r from (select id,kind,subject,reference,detail,created_at,read_at from tenant_private.buyer_notifications where store_id=t and buyer=auth.uid() and (p_before is null or (created_at,id)<(p_before,p_before_id)) order by created_at desc,id desc limit 50)x;return r;
end $$;
create function tenant_private.buyer_read(p_slug text,p_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);
begin
 update tenant_private.buyer_notifications set read_at=coalesce(read_at,now()) where store_id=t and buyer=auth.uid() and id=p_id;return found;
end $$;
create function public.mt_watch_product(p_slug text,p_product uuid,p_currency text,p_kind text,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.watch_product(p_slug,p_product,p_currency,p_kind,p_enabled)$$;
create function public.mt_buyer_inbox(p_slug text,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.buyer_inbox(p_slug,p_before,p_before_id)$$;
create function public.mt_buyer_read(p_slug text,p_id uuid) returns boolean language sql security invoker set search_path='' as $$select tenant_private.buyer_read(p_slug,p_id)$$;
revoke all on function tenant_private.buyer_store(text),tenant_private.watch_product(text,uuid,text,text,boolean),tenant_private.notify_buyer_order(),tenant_private.notify_product_watch(),tenant_private.buyer_inbox(text,timestamptz,uuid),tenant_private.buyer_read(text,uuid),public.mt_watch_product(text,uuid,text,text,boolean),public.mt_buyer_inbox(text,timestamptz,uuid),public.mt_buyer_read(text,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.watch_product(text,uuid,text,text,boolean),tenant_private.buyer_inbox(text,timestamptz,uuid),tenant_private.buyer_read(text,uuid),public.mt_watch_product(text,uuid,text,text,boolean),public.mt_buyer_inbox(text,timestamptz,uuid),public.mt_buyer_read(text,uuid) to authenticated;
commit;
