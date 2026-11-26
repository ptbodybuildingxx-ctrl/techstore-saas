begin;
create table tenant_private.shop_carrier_dispatch(
 store_id uuid not null,order_id uuid not null,request_id uuid not null,name text not null check(length(btrim(name)) between 1 and 100),tracking text not null check(length(btrim(tracking)) between 1 and 100),actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,order_id),unique(store_id,request_id),foreign key(store_id,order_id) references public.mt_online_orders(store_id,id)
);
alter table tenant_private.shop_carrier_dispatch enable row level security;
revoke all on tenant_private.shop_carrier_dispatch from public,anon,authenticated;
create function tenant_private.sy_phone(p text) returns text language sql immutable set search_path='' as $$
 select case when n ~ '^09[0-9]{8}$' then '963'||substring(n from 2) when n ~ '^9639[0-9]{8}$' then n when n ~ '^009639[0-9]{8}$' then substring(n from 3) else null end from (select regexp_replace(translate(coalesce(p,''),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'),'[ +()-]','','g') n)x
$$;
revoke all on function tenant_private.sy_phone(text) from public,anon,authenticated;
create function tenant_private.carrier_dispatch(s uuid,o uuid,req uuid,carrier text,tracking_ref text) returns uuid language plpgsql security definer set search_path='' as $$
declare e tenant_private.shop_carrier_dispatch%rowtype;
begin
 perform tenant_private.owner_write(s);
 if o is null or req is null or carrier is null or length(btrim(carrier)) not between 1 and 100 or tracking_ref is null or length(btrim(tracking_ref)) not between 1 and 100 then raise exception 'Invalid carrier dispatch';end if;
 select * into e from tenant_private.shop_carrier_dispatch where store_id=s and request_id=req;
 if found then if e.order_id<>o or e.name<>btrim(carrier) or e.tracking<>btrim(tracking_ref) or e.actor<>auth.uid() then raise exception 'Conflicting dispatch';end if;return req;end if;
 if exists(select 1 from tenant_private.shop_carrier_dispatch where store_id=s and order_id=o) then raise exception 'Carrier already documented';end if;
 perform tenant_private.dispatch_delivery(s,o,btrim(tracking_ref));
 insert into tenant_private.shop_carrier_dispatch(store_id,order_id,request_id,name,tracking,actor) values(s,o,req,btrim(carrier),btrim(tracking_ref),auth.uid());
 return req;
end $$;
create function public.mt_carrier_dispatch(s uuid,o uuid,req uuid,carrier text,tracking_ref text) returns uuid language sql set search_path='' as $$select tenant_private.carrier_dispatch(s,o,req,carrier,tracking_ref)$$;
revoke all on function tenant_private.carrier_dispatch(uuid,uuid,uuid,text,text),public.mt_carrier_dispatch(uuid,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function tenant_private.carrier_dispatch(uuid,uuid,uuid,text,text),public.mt_carrier_dispatch(uuid,uuid,uuid,text,text) to authenticated;
CREATE OR REPLACE FUNCTION tenant_private.shop_order_details(s uuid, o uuid, ch text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.mt_online_orders%rowtype;g tenant_private.guest_orders%rowtype;d tenant_private.order_discounts%rowtype;owner boolean;items jsonb;details jsonb;history jsonb;v jsonb;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live session required' using errcode='42501';end if;
 owner:=tenant_private.member_role(s) is not distinct from 'owner';
 if ch='online' then
  select * into a from public.mt_online_orders where store_id=s and id=o;
  if not found or not (owner or a.buyer=auth.uid()) then raise exception 'Order unavailable' using errcode='42501';end if;
  items:=a.lines;
  select * into d from tenant_private.order_discounts where store_id=s and order_id=o;
  v:=jsonb_build_object('id',a.id,'currency',a.currency,'state',a.state,'total_minor',a.total_minor,'delivery_method',a.delivery_method,'delivery_state',a.delivery_state,'tracking_reference',a.tracking_reference,'address',a.delivery_address,'phone',a.delivery_phone,'created_at',a.created_at,'finished_at',a.finished_at,'sale_id',a.sale_id,'discount_minor',coalesce(d.discount_minor,0),'gross_minor',coalesce(d.gross_minor,a.total_minor));
 elsif ch='guest' and owner then
  select * into g from tenant_private.guest_orders where store_id=s and id=o;
  if not found then raise exception 'Order unavailable' using errcode='42501';end if;
  items:=g.lines;
  v:=jsonb_build_object('id',g.id,'currency',g.currency,'state',g.state,'total_minor',g.total_minor,'delivery_method','pickup','delivery_state',null,'tracking_reference',null,'address',null,'phone',g.phone,'customer_name',g.customer_name,'created_at',g.created_at,'finished_at',g.finished_at,'sale_id',g.sale_id,'discount_minor',0,'gross_minor',g.total_minor);
 else raise exception 'Order unavailable' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('product_id',(x->>'product_id')::uuid,'name',coalesce(i.product_name,p.name,x->>'product_id'),'sku',coalesce(i.sku,p.sku,''),'snapshot',i.product_id is not null,'units',(x->>'units')::bigint,'unit_minor',(x->>'expected_price_minor')::bigint,'net_minor',case when d.order_id is null then (x->>'expected_price_minor')::bigint when d.line_prices is not null then (d.line_prices->>(x->>'product_id'))::bigint else (x->>'expected_price_minor')::bigint-(x->>'expected_price_minor')::bigint*d.basis_points/10000 end) order by x->>'product_id'),'[]'::jsonb) into details from jsonb_array_elements(items) x left join tenant_private.shop_order_items i on i.store_id=s and i.channel=ch and i.order_id=o and i.product_id=(x->>'product_id')::uuid left join public.mt_products p on p.store_id=s and p.id=(x->>'product_id')::uuid;
 select coalesce(jsonb_agg(jsonb_build_object('event',event,'created_at',created_at) order by created_at,case event when 'pending' then 1 when 'confirmed' then 2 when 'dispatched' then 3 else 4 end,id),'[]'::jsonb) into history from tenant_private.shop_order_history where store_id=s and channel=ch and order_id=o;
 if ch='online' and a.delivery_method='delivery' then v:=v||jsonb_build_object('carrier',(select jsonb_build_object('name',name,'recorded_at',created_at) from tenant_private.shop_carrier_dispatch where store_id=s and order_id=o),'phone_verified_now',exists(select 1 from auth.users u where u.id=a.buyer and u.phone_confirmed_at is not null and tenant_private.sy_phone(u.phone)=tenant_private.sy_phone(a.delivery_phone) and tenant_private.sy_phone(a.delivery_phone) is not null));end if;
 return v||jsonb_build_object('channel',ch,'confirmed',exists(select 1 from tenant_private.shop_order_confirmations where store_id=s and channel=ch and order_id=o),'items',details,'history',history);
end $function$
;
commit;