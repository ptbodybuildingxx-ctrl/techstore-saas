-- 125: central plan admission and storefront feature policy; all existing access defaults unchanged.
begin;
create table tenant_private.admin_plan_policy(
 plan_code text primary key references public.saas_plans(code),revision bigint not null default 1,
 enrollment boolean not null default true,storefront boolean not null default true,orders boolean not null default true,guest boolean not null default true,delivery boolean not null default true,
 updated_at timestamptz not null default now()
);
insert into tenant_private.admin_plan_policy(plan_code) select code from public.saas_plans;
create table tenant_private.admin_plan_policy_events(
 request_id uuid primary key,plan_code text not null references public.saas_plans(code),actor uuid not null,
 reference text not null check(length(btrim(reference)) between 1 and 200),
 before_state jsonb not null,after_state jsonb not null,created_at timestamptz not null default now()
);
alter table tenant_private.admin_plan_policy enable row level security;
alter table tenant_private.admin_plan_policy_events enable row level security;
revoke all on tenant_private.admin_plan_policy,tenant_private.admin_plan_policy_events from public,anon,authenticated;

create function tenant_private.plan_shop_feature(s uuid,feature text)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select case feature when 'storefront' then p.storefront when 'orders' then p.orders when 'guest' then p.guest when 'delivery' then p.delivery else false end from public.saas_subscriptions sub join tenant_private.admin_plan_policy p on p.plan_code=sub.plan_code where sub.store_id=s),false)
$$;
revoke all on function tenant_private.plan_shop_feature(uuid,text) from public,anon,authenticated;

create function tenant_private.guard_plan_enrollment() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and new.plan_code is not distinct from old.plan_code then return new;end if;
 -- An existing subscription may renew in its existing plan even when new enrollment is closed.
 if not exists(select 1 from tenant_private.admin_plan_policy p where p.plan_code=new.plan_code and p.enrollment) then raise exception 'Plan closed to new enrollment' using errcode='22023';end if;
 return new;
end $$;
revoke all on function tenant_private.guard_plan_enrollment() from public,anon,authenticated;
create trigger mt_guard_plan_enrollment before insert or update of plan_code on public.saas_subscriptions for each row execute function tenant_private.guard_plan_enrollment();

CREATE OR REPLACE FUNCTION tenant_private.storefront_active(p_store uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select tenant_private.shared_licensed(p_store) and tenant_private.plan_shop_feature(p_store,'storefront') and not exists(select 1 from tenant_private.admin_store_controls where store_id=p_store and storefront_paused) and exists(select 1 from tenant_private.storefronts where store_id=p_store and enabled)
$function$;
CREATE OR REPLACE FUNCTION tenant_private.delivery_available(p_slug text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from public.saas_stores s join tenant_private.storefronts f on f.store_id=s.id where s.slug=p_slug and f.delivery_enabled and tenant_private.storefront_active(s.id) and tenant_private.plan_shop_feature(s.id,'orders') and tenant_private.plan_shop_feature(s.id,'delivery'))
$function$
;
CREATE OR REPLACE FUNCTION tenant_private.guest_enabled(p_slug text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin return exists(select 1 from public.saas_stores s join tenant_private.guest_settings g on g.store_id=s.id and g.enabled where s.slug=p_slug and tenant_private.storefront_active(s.id) and tenant_private.plan_shop_feature(s.id,'orders') and tenant_private.plan_shop_feature(s.id,'guest'));end
$function$
;
CREATE OR REPLACE FUNCTION tenant_private.online_order(p_slug text, p_request uuid, p_currency text, p_lines jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;x jsonb;norm jsonb;o public.mt_online_orders%rowtype;pr public.mt_products%rowtype;price bigint;total bigint:=0;u bigint;product uuid;
begin
 if not coalesce(saas_private.live_session(),false) or not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null and not is_anonymous) then raise exception 'Confirmed live account required' using errcode='42501';end if;
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_request is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid order' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 50 or octet_length(p_lines::text)>25000 then raise exception 'Invalid cart size' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid cart line' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,3}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid cart values' using errcode='22023';end if;
  if (x->>'units')::bigint not between 1 and 100 or (x->>'expected_price_minor')::bigint not between 1 and 100000000 then raise exception 'Invalid cart amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into norm from jsonb_array_elements(p_lines);
 select id into t from public.saas_stores where slug=p_slug for update;
 if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 select * into o from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request;
 if found then
  if o.currency<>p_currency or o.lines is distinct from norm then raise exception 'Conflicting order request' using errcode='22023';end if;return o.id;
 end if;
 if not tenant_private.storefront_active(t) or not tenant_private.plan_shop_feature(t,'orders') then raise exception 'Store unavailable' using errcode='22023';end if;
 if (select count(*) from public.mt_online_orders where store_id=t and buyer=auth.uid() and created_at>now()-interval '24 hours')>=10 or (select count(*) from public.mt_online_orders where store_id=t and buyer=auth.uid() and state='pending')>=3 then raise exception 'Order limit reached' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(norm) loop
  product:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
  select p.* into pr from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed where p.store_id=t and p.id=product;
  if not found or coalesce(tenant_private.main_available(t,product),0)<u then raise exception 'Product unavailable' using errcode='22023';end if;
  select price_minor into price from public.mt_product_prices where store_id=t and product_id=product and currency=p_currency;
  if not found or price<>(x->>'expected_price_minor')::bigint then raise exception 'Price changed' using errcode='22023';end if;
  total:=total+u*price;
 end loop;
 insert into public.mt_online_orders(store_id,request_id,buyer,currency,lines,total_minor) values(t,p_request,auth.uid(),p_currency,norm,total) returning * into o;
 return o.id;
end $function$
;
create function tenant_private.admin_plan_policy_review()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return jsonb_build_object('plans',coalesce((select jsonb_agg(to_jsonb(x) order by plan_code) from (select p.*,s.name,s.monthly_usd_cents,(select count(*) from public.saas_subscriptions sub where sub.plan_code=p.plan_code) as subscribers,(select count(*) from public.saas_subscriptions sub where sub.plan_code=p.plan_code and tenant_private.shared_licensed(sub.store_id)) as licensed from tenant_private.admin_plan_policy p join public.saas_plans s on s.code=p.plan_code)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id) from (select request_id,plan_code,actor,reference,before_state,after_state,created_at from tenant_private.admin_plan_policy_events order by created_at desc,request_id limit 50)x),'[]'::jsonb));
end $$;
create function tenant_private.admin_plan_policy_change(req uuid,plan text,expected bigint,flags jsonb,proof text)
returns uuid language plpgsql security definer set search_path='' as $$
declare p tenant_private.admin_plan_policy%rowtype;e tenant_private.admin_plan_policy_events%rowtype;nextp tenant_private.admin_plan_policy%rowtype;v jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if req is null or plan is null or plan not in ('basic','business','pro') or expected is null or expected<1 or jsonb_typeof(flags) is distinct from 'object' or octet_length(flags::text)>1000 or (select count(*) from jsonb_object_keys(flags))<>5 or not(flags ?& array['enrollment','storefront','orders','guest','delivery']) or exists(select 1 from jsonb_each(flags) where jsonb_typeof(value)<>'boolean') or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid policy change' using errcode='22023';end if;
 select * into strict p from tenant_private.admin_plan_policy where plan_code=plan for update;
 select * into e from tenant_private.admin_plan_policy_events where request_id=req;
 if found then
  if e.plan_code<>plan or e.actor<>auth.uid() or e.reference<>btrim(proof) or (e.before_state->>'revision')::bigint<>expected or (e.after_state - array['plan_code','revision','updated_at'])<>flags then raise exception 'Conflicting policy request';end if;
  return req;
 end if;
 if p.revision<>expected or (to_jsonb(p)-array['plan_code','revision','updated_at'])=flags then raise exception 'Policy changed or unchanged';end if;
 update tenant_private.admin_plan_policy set enrollment=(flags->>'enrollment')::boolean,storefront=(flags->>'storefront')::boolean,orders=(flags->>'orders')::boolean,guest=(flags->>'guest')::boolean,delivery=(flags->>'delivery')::boolean,revision=revision+1,updated_at=now() where plan_code=plan returning * into nextp;
 insert into tenant_private.admin_plan_policy_events(request_id,plan_code,actor,reference,before_state,after_state) values(req,plan,auth.uid(),btrim(proof),to_jsonb(p),to_jsonb(nextp));
 return req;
end $$;

create function public.mt_admin_plan_policy_review() returns jsonb language sql stable set search_path='' as $$select tenant_private.admin_plan_policy_review()$$;
create function public.mt_admin_plan_policy_change(req uuid,plan text,expected bigint,flags jsonb,proof text) returns uuid language sql set search_path='' as $$select tenant_private.admin_plan_policy_change(req,plan,expected,flags,proof)$$;
revoke all on function tenant_private.admin_plan_policy_review(),public.mt_admin_plan_policy_review(),tenant_private.admin_plan_policy_change(uuid,text,bigint,jsonb,text),public.mt_admin_plan_policy_change(uuid,text,bigint,jsonb,text) from public,anon,authenticated;
grant execute on function tenant_private.admin_plan_policy_review(),public.mt_admin_plan_policy_review(),tenant_private.admin_plan_policy_change(uuid,text,bigint,jsonb,text),public.mt_admin_plan_policy_change(uuid,text,bigint,jsonb,text) to authenticated;

-- Public status is only a shop's ability to accept new orders, not its subscription details.
create function tenant_private.shop_order_intake(p_slug text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.saas_stores s where s.slug=p_slug and tenant_private.storefront_active(s.id) and tenant_private.plan_shop_feature(s.id,'orders'))
$$;
revoke all on function tenant_private.shop_order_intake(text) from public,anon,authenticated;
grant execute on function tenant_private.shop_order_intake(text) to anon,authenticated;
create function public.mt_shop_order_intake(p_slug text) returns boolean language sql stable set search_path='' as $$
 select coalesce(tenant_private.shop_order_intake(p_slug),false)
$$;
revoke all on function public.mt_shop_order_intake(text) from public,anon,authenticated;
grant execute on function public.mt_shop_order_intake(text) to anon,authenticated;
commit;
