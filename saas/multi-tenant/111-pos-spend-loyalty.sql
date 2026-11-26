-- Spend-value redemption at point of sale, with exact buyer-approved maximum and frozen net line prices.
alter table tenant_private.pos_authorizations add column spend_requested bigint check(spend_requested between 1 and 9007199254740991);
alter table tenant_private.pos_authorizations add constraint spend_pos_authorization_exclusive check(spend_requested is null or (points=0 and basis_points=0 and not use_membership));
create table tenant_private.spend_pos_redemptions(
 store_id uuid not null,sale_id uuid not null,buyer uuid not null,token uuid not null,
 requested_points bigint not null check(requested_points between 1 and 9007199254740991),
 points_used bigint not null check(points_used between 0 and requested_points),quote jsonb not null,created_at timestamptz not null default now(),
 primary key(store_id,sale_id),unique(store_id,token),
 foreign key(store_id,sale_id) references public.mt_sales(store_id,id)
);
create index spend_pos_redemptions_buyer_idx on tenant_private.spend_pos_redemptions(store_id,buyer);
alter table tenant_private.spend_pos_redemptions enable row level security;
revoke all on tenant_private.spend_pos_redemptions from public,anon,authenticated,service_role;

create function tenant_private.spend_pos_consumed(s uuid,a uuid) returns bigint language sql stable security definer set search_path='' as $$
 select coalesce((select p.points_used-floor(p.points_used::numeric*least(v.total_minor,coalesce(r.returned,0))/v.total_minor)::bigint
 from tenant_private.spend_pos_redemptions p join public.mt_sales v on v.store_id=p.store_id and v.id=p.sale_id
 left join lateral(select sum(total_minor) returned from public.mt_returns where store_id=s and sale_id=a)r on true
 where p.store_id=s and p.sale_id=a),0)
$$;
revoke all on function tenant_private.spend_pos_consumed(uuid,uuid) from public,anon,authenticated,service_role;

-- Internal allocation shared by storefront and POS; each line retains one integer unit price.
create function tenant_private.allocate_spend_points(items jsonb,base_prices jsonb,subtotal bigint,budget bigint,available bigint,rate bigint,points_per_usd integer)
returns jsonb language plpgsql immutable set search_path='' as $$
declare prices jsonb:=base_prices;x jsonb;pid uuid;qty bigint;net bigint;part bigint;discount bigint:=0;remaining bigint;delta bigint;used bigint:=0;
begin
 if budget>0 then
 for x in select value from jsonb_array_elements(items) order by (value->>'product_id')::uuid loop
 pid:=(x->>'product_id')::uuid;qty:=(x->>'units')::bigint;net:=(prices->>pid::text)::bigint;
 part:=least(net-1,floor(budget::numeric*net/subtotal)::bigint);
 prices:=jsonb_set(prices,array[pid::text],to_jsonb(net-part));discount:=discount+qty*part;
 end loop;
 remaining:=budget-discount;
 for x in select value from jsonb_array_elements(items) order by (value->>'product_id')::uuid loop
 exit when remaining<=0;
 pid:=(x->>'product_id')::uuid;qty:=(x->>'units')::bigint;net:=(prices->>pid::text)::bigint;delta:=least(net-1,remaining/qty);
 prices:=jsonb_set(prices,array[pid::text],to_jsonb(net-delta));remaining:=remaining-delta*qty;discount:=discount+delta*qty;
 end loop;
 used:=ceil(discount::numeric*points_per_usd/rate)::bigint;
 if used>available then raise exception 'Points allocation exceeds balance';end if;
 end if;
 return jsonb_build_object('prices',prices,'discount_minor',discount,'points_used',used);
end $$;
revoke all on function tenant_private.allocate_spend_points(jsonb,jsonb,bigint,bigint,bigint,bigint,integer) from public,anon,authenticated,service_role;

create function tenant_private.pos_authorize_spend(s uuid,r uuid,c text,gross bigint,requested bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a tenant_private.pos_authorizations%rowtype;p tenant_private.spend_loyalty_policy%rowtype;
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) or not tenant_private.storefront_active(s) or not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null and not is_anonymous) then raise exception 'Live buyer required' using errcode='42501';end if;
 if r is null or c is null or c not in ('SYP','USD','EUR') or gross is null or gross not between 1 and 100000000000000 or requested is null or requested not between 1 and 9007199254740991 then raise exception 'Invalid POS authorization';end if;
 perform 1 from public.saas_stores where id=s for update;
 if not exists(select 1 from tenant_private.sale_currencies where store_id=s and currency=c) then raise exception 'Currency unavailable';end if;
 select * into a from tenant_private.pos_authorizations where store_id=s and buyer=auth.uid() and request_id=r;
 if found then
 if a.currency<>c or a.gross_minor<>gross or a.spend_requested is distinct from requested then raise exception 'Conflicting authorization';end if;
 else
 select * into p from tenant_private.spend_loyalty_policy where store_id=s;
 if not found or not p.enabled or tenant_private.spend_currency_rate(p,c) is null or tenant_private.points_balance(s,auth.uid())<=0 then raise exception 'Spend-value redemption unavailable';end if;
 if (select count(*) from tenant_private.pos_authorizations where store_id=s and buyer=auth.uid() and created_at>now()-interval '10 minutes')>=10 then raise exception 'Too many authorizations';end if;
 update tenant_private.pos_authorizations set revoked=true where store_id=s and buyer=auth.uid() and expires_at>now() and not revoked;
 insert into tenant_private.pos_authorizations(store_id,buyer,request_id,currency,gross_minor,points,basis_points,expires_at,spend_requested) values(s,auth.uid(),r,c,gross,0,0,now()+interval '10 minutes',requested) returning * into a;
 end if;
 return jsonb_build_object('token',a.token,'currency',a.currency,'gross_minor',a.gross_minor,'points',0,'basis_points',0,'use_membership',false,'spend_requested',a.spend_requested,'expires_at',a.expires_at,'revoked',a.revoked,'used',exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and token=a.token));
end $$;
create function public.mt_pos_authorize_spend(p_slug text,p_request uuid,p_currency text,p_gross bigint,p_points bigint) returns jsonb language sql set search_path='' as $$select tenant_private.pos_authorize_spend(tenant_private.buyer_store(p_slug),p_request,p_currency,p_gross,p_points)$$;
revoke all on function tenant_private.pos_authorize_spend(uuid,uuid,text,bigint,bigint),public.mt_pos_authorize_spend(text,uuid,text,bigint,bigint) from public,anon,authenticated,service_role;
grant execute on function tenant_private.pos_authorize_spend(uuid,uuid,text,bigint,bigint),public.mt_pos_authorize_spend(text,uuid,text,bigint,bigint) to authenticated;

CREATE OR REPLACE FUNCTION tenant_private.points_balance(p_store uuid, p_buyer uuid)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select (select count(*) from public.mt_online_orders o where o.store_id=p_store and o.buyer=p_buyer and o.state='fulfilled' and not exists(select 1 from tenant_private.spend_loyalty_sales v where v.store_id=o.store_id and v.sale_id=o.sale_id)
 and o.total_minor>(select coalesce(sum(r.total_minor),0) from public.mt_returns r where r.store_id=o.store_id and r.sale_id=o.sale_id)
 and not exists(select 1 from tenant_private.order_discounts d where d.store_id=o.store_id and d.order_id=o.id and d.reward_points is not null))
 + (select count(*) from tenant_private.pos_loyalty_sales p join public.mt_sales a on a.store_id=p.store_id and a.id=p.sale_id where p.store_id=p_store and p.buyer=p_buyer and p.points=0 and not exists(select 1 from tenant_private.spend_loyalty_sales v where v.store_id=p.store_id and v.sale_id=p.sale_id) and (a.payment_mode<>'credit' or exists(select 1 from public.mt_debts d where d.store_id=a.store_id and d.sale_id=a.id and d.remaining_minor=0)) and a.total_minor>(select coalesce(sum(r.total_minor),0) from public.mt_returns r where r.store_id=p.store_id and r.sale_id=p.sale_id))
 + (select coalesce(sum(tenant_private.spend_sale_earned(v.store_id,v.sale_id)),0) from tenant_private.spend_loyalty_sales v where v.store_id=p_store and v.buyer=p_buyer)
 - (select coalesce(sum(p.points),0) from tenant_private.pos_loyalty_sales p where p.store_id=p_store and p.buyer=p_buyer)
 - (select coalesce(sum(d.reward_points),0) from tenant_private.order_discounts d join public.mt_online_orders o on o.store_id=d.store_id and o.id=d.order_id where d.store_id=p_store and d.buyer=p_buyer and d.reward_points is not null and o.state<>'cancelled')
 - (select coalesce(sum(tenant_private.spend_checkout_consumed(v.store_id,v.order_id)),0) from tenant_private.spend_checkout v where v.store_id=p_store and v.buyer=p_buyer)
 - (select coalesce(sum(tenant_private.spend_pos_consumed(v.store_id,v.sale_id)),0) from tenant_private.spend_pos_redemptions v where v.store_id=p_store and v.buyer=p_buyer)
$function$;

CREATE OR REPLACE FUNCTION tenant_private.pos_authorize_mode(s uuid, r uuid, c text, gross bigint, use_reward boolean, use_member boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a tenant_private.pos_authorizations%rowtype;l tenant_private.loyalty_settings%rowtype;v tenant_private.buyer_price_terms%rowtype;
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) or not tenant_private.storefront_active(s) then raise exception 'Live buyer required' using errcode='42501';end if;
 if r is null or c is null or c not in ('SYP','USD','EUR') or gross is null or gross not between 1 and 100000000000000 or use_reward is null or use_member is null or (use_reward and use_member) then raise exception 'Invalid POS authorization';end if;
 perform 1 from public.saas_stores where id=s for update;
 if not exists(select 1 from tenant_private.sale_currencies where store_id=s and currency=c) then raise exception 'Currency unavailable';end if;
 select * into a from tenant_private.pos_authorizations where store_id=s and buyer=auth.uid() and request_id=r;
 if found then
 if a.spend_requested is not null or a.currency<>c or a.gross_minor<>gross or (a.points>0) is distinct from use_reward or a.use_membership is distinct from use_member then raise exception 'Conflicting authorization';end if;
 else
 if use_reward and exists(select 1 from tenant_private.spend_loyalty_policy where store_id=s) then raise exception 'Spend-value points redemption requires combined checkout';end if;
 if (select count(*) from tenant_private.pos_authorizations where store_id=s and buyer=auth.uid() and created_at>now()-interval '10 minutes')>=10 then raise exception 'Too many authorizations';end if;
 if use_member then v:=tenant_private.effective_buyer_terms(s,auth.uid());if v.buyer is null then raise exception 'Membership unavailable';end if;end if;
 select * into l from tenant_private.loyalty_settings where store_id=s;
 if use_reward and (not found or not l.enabled or tenant_private.points_balance(s,auth.uid())<l.points_required) then raise exception 'Reward unavailable';end if;
 update tenant_private.pos_authorizations set revoked=true where store_id=s and buyer=auth.uid() and expires_at>now() and not revoked;
 insert into tenant_private.pos_authorizations(store_id,buyer,request_id,currency,gross_minor,points,basis_points,expires_at,use_membership) values(s,auth.uid(),r,c,gross,case when use_reward then l.points_required else 0 end,case when use_reward then l.basis_points else 0 end,now()+interval '10 minutes',use_member) returning * into a;
 end if;
 return jsonb_build_object('token',a.token,'currency',a.currency,'gross_minor',a.gross_minor,'points',a.points,'basis_points',a.basis_points,'use_membership',a.use_membership,'expires_at',a.expires_at,'revoked',a.revoked,'used',exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and token=a.token));
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.pos_quote(s uuid, b uuid, t uuid, c text, items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a tenant_private.pos_authorizations%rowtype;l tenant_private.loyalty_settings%rowtype;x jsonb;pid uuid;u bigint;price bigint;quoted bigint;gross bigint:=0;discount bigint:=0;net bigint;loc bigint;v tenant_private.buyer_price_terms%rowtype;qty_total bigint:=0;prices jsonb:='{}';tier text;bps int;p tenant_private.spend_loyalty_policy%rowtype;rate bigint;balance bigint;subtotal bigint;budget bigint;allocation jsonb;used bigint:=0;points_discount bigint:=0;retail_prices jsonb:='{}';
begin
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.current_branch_scope(s) is not null and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 if t is null or c is null or c not in ('SYP','USD','EUR') or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or octet_length(items::text)>50000 then raise exception 'Invalid POS cart';end if;
 select * into a from tenant_private.pos_authorizations where store_id=s and token=t;
 if not found or a.revoked or a.expires_at<=now() or a.currency<>c or exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and token=t) then raise exception 'Authorization unavailable';end if;
 bps:=a.basis_points;
 if a.use_membership or a.spend_requested is not null then
 if tenant_private.member_role(s)='cashier' and tenant_private.current_branch_scope(s) is distinct from b then raise exception 'Membership sale branch denied' using errcode='42501';end if;
 v:=tenant_private.effective_buyer_terms(s,a.buyer);if v.buyer is null and a.use_membership then raise exception 'Membership changed';end if;tier:=v.tier;bps:=coalesce(v.basis_points,0);
 end if;
 if a.points>0 then
 select * into l from tenant_private.loyalty_settings where store_id=s;
 if not found or not l.enabled or l.points_required<>a.points or l.basis_points<>a.basis_points or tenant_private.points_balance(s,a.buyer)<a.points then raise exception 'Reward changed';end if;
 end if;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(items))<>jsonb_array_length(items) then raise exception 'Duplicate product';end if;
 for x in select value from jsonb_array_elements(items) loop
 if jsonb_typeof(x) is distinct from 'object' or (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid sale line';end if;
 pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;quoted:=(x->>'expected_price_minor')::bigint;
 if u not between 1 and 10000 or quoted not between 1 and 100000000 then raise exception 'Invalid line amount';end if;
 select price_minor into price from public.mt_product_prices where store_id=s and product_id=pid and currency=c;
 if not found or price<>quoted then raise exception 'Price changed';end if;
 if b is null then loc:=tenant_private.main_available(s,pid);else select units into loc from tenant_private.branch_stock where store_id=s and branch_id=b and product_id=pid;end if;
 if coalesce(loc,0)<u then raise exception 'Insufficient stock';end if;
 if tier is not null then net:=tenant_private.membership_unit_price(s,a.buyer,tier,pid,c,u,price,bps);else net:=price-price*a.basis_points/10000;end if;
 retail_prices:=retail_prices||jsonb_build_object(pid::text,price);
 qty_total:=qty_total+u;prices:=prices||jsonb_build_object(pid::text,net);
 if net<1 then raise exception 'Invalid net price';end if;
 gross:=gross+u*price;discount:=discount+u*(price-net);
 end loop;
 if tier is not null and qty_total<v.min_units then
 if a.use_membership then raise exception 'Membership minimum quantity not met';end if;
 tier:=null;bps:=0;prices:=retail_prices;discount:=0;
 end if;
 if gross<>a.gross_minor or gross>100000000000000 or (a.points>0 and discount<=0) then raise exception 'Authorized amount changed';end if;
 subtotal:=gross-discount;
 if a.spend_requested is not null then
 select * into p from tenant_private.spend_loyalty_policy where store_id=s;
 if not found or not p.enabled then raise exception 'Spend-value redemption unavailable';end if;
 rate:=tenant_private.spend_currency_rate(p,c);if rate is null then raise exception 'Loyalty conversion unavailable';end if;
 balance:=greatest(0,tenant_private.points_balance(s,a.buyer));
 budget:=least(floor(subtotal::numeric*p.max_redeem_bps/10000),floor(least(a.spend_requested,balance)::numeric*rate/p.points_per_usd),subtotal-1)::bigint;
 allocation:=tenant_private.allocate_spend_points(items,prices,subtotal,budget,least(a.spend_requested,balance),rate,p.points_per_usd);
 prices:=allocation->'prices';points_discount:=(allocation->>'discount_minor')::bigint;used:=(allocation->>'points_used')::bigint;
 if used<1 then raise exception 'No redeemable points for this cart';end if;
 discount:=discount+points_discount;
 end if;
 return jsonb_build_object('currency',c,'gross_minor',gross,'discount_minor',discount,'total_minor',gross-discount,'points',a.points,'basis_points',bps,'price_tier',tier,'prices',prices,'spend_requested',a.spend_requested,'spend_points_used',used,'points_discount_minor',points_discount,'base_total_minor',subtotal,'currency_per_usd_minor',rate,'points_per_usd',p.points_per_usd,'max_redeem_bps',p.max_redeem_bps);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.pos_membership_financed(s uuid, b uuid, r uuid, t uuid, c text, items jsonb, meta jsonb, terms jsonb, expected bigint, prices jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a tenant_private.pos_authorizations%rowtype;old tenant_private.pos_loyalty_sales%rowtype;q jsonb;net_items jsonb;payload jsonb;result jsonb;sid uuid;credit boolean;
begin
 if r is null or t is null or expected is null or expected<1 or jsonb_typeof(prices) is distinct from 'object' or jsonb_typeof(terms) is distinct from 'object' then raise exception 'Invalid priced sale';end if;
 credit:=terms ? 'customer';
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.member_role(s)='cashier' and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if credit then
 if not tenant_private.receivable_allowed(s,'credit_sale') or not tenant_private.receivable_branch_allowed(s,b) or not(terms ?& array['customer','deposit','count','due']) or (select count(*) from jsonb_object_keys(terms))<>4 then raise exception 'Credit denied';end if;
 else
 if tenant_private.member_role(s) is distinct from 'owner' or not(terms ?& array['tenders','refund_policy']) or (select count(*) from jsonb_object_keys(terms))<>2 then raise exception 'Mixed sale denied';end if;
 end if;
 perform 1 from public.saas_stores where id=s for update;
 if credit then perform tenant_private.assert_receivable_live(s,r,'credit');end if;
 payload:=jsonb_build_object('branch',b,'token',t,'currency',c,'lines',items,'meta',meta,'terms',terms,'expected',expected,'prices',prices);
 select * into old from tenant_private.pos_loyalty_sales where store_id=s and request_id=r;
 if found then
 if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting membership sale';end if;
 return old.result;
 end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale request';end if;
 select * into strict a from tenant_private.pos_authorizations where store_id=s and token=t;
 if not a.use_membership or a.points<>0 or a.spend_requested is not null then raise exception 'Membership-only code required';end if;
 q:=tenant_private.pos_quote(s,b,t,c,items);
 if q->>'price_tier' is null or (q->>'total_minor')::bigint<>expected or q->'prices' is distinct from prices then raise exception 'Membership quote changed';end if;
 select jsonb_agg(jsonb_build_object('product_id',(x->>'product_id')::uuid,'units',(x->>'units')::bigint,'expected_price_minor',(prices->>(x->>'product_id'))::bigint) order by (x->>'product_id')::uuid) into net_items from jsonb_array_elements(items) x;
 insert into tenant_private.membership_sale_context values(s,r,auth.uid(),c,prices);
 result:=tenant_private.issue_sale_invoice(s,b,r,c,net_items,meta,terms);
 delete from tenant_private.membership_sale_context where store_id=s and request_id=r;
 sid:=(result->>'id')::uuid;
 if (result->>'total_minor')::bigint<>expected then raise exception 'Priced invoice mismatch';end if;
 result:=result||q;
 insert into tenant_private.pos_loyalty_sales(store_id,sale_id,token,buyer,points,basis_points,gross_minor,discount_minor,actor,request_id,branch_id,payload,result,price_tier)
 values(s,sid,t,a.buyer,0,(q->>'basis_points')::int,a.gross_minor,(q->>'discount_minor')::bigint,auth.uid(),r,b,payload,result,q->>'price_tier');
 update tenant_private.sale_invoice_details set document=document||jsonb_build_object('loyalty',jsonb_build_object('gross_minor',a.gross_minor,'discount_minor',(q->>'discount_minor')::bigint,'points',0,'price_tier',q->>'price_tier')) where store_id=s and sale_id=sid;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.combined_checkout_quote(slug_value text, c text, items jsonb, code text, requested bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s uuid;p tenant_private.spend_loyalty_policy%rowtype;coupon public.mt_coupons%rowtype;m jsonb;x jsonb;pid uuid;qty bigint;retail bigint;net bigint;gross bigint:=0;subtotal bigint:=0;coupon_total bigint:=0;membership_total bigint;prices jsonb:='{}';coupon_prices jsonb:='{}';tier text;source text:='regular';chosen_coupon uuid;bps int:=0;balance bigint;rate bigint;budget bigint:=0;discount bigint:=0;part bigint;used bigint:=0;amount bigint;remaining bigint;delta bigint;allocation jsonb;
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) or not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null and not is_anonymous) then raise exception 'Confirmed live buyer required' using errcode='42501';end if;
 if c is null or c not in ('SYP','USD','EUR') or requested is null or requested not between 0 and 9007199254740991 or code is not null and upper(btrim(code)) !~ '^[A-Z0-9-]{3,24}$' or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 50 or octet_length(items::text)>25000 then raise exception 'Invalid combined checkout';end if;
 select id into s from public.saas_stores where slug=slug_value and tenant_private.storefront_active(id);
 if s is null then raise exception 'Store unavailable';end if;
 if code is not null then coupon:=tenant_private.coupon_available(s,code,auth.uid());end if;
 for x in select value from jsonb_array_elements(items) loop
 if jsonb_typeof(x) is distinct from 'object' or (select count(*) from jsonb_object_keys(x))<>3 or not(x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'units','') !~ '^[0-9]{1,3}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line';end if;
 pid:=(x->>'product_id')::uuid;qty:=(x->>'units')::bigint;
 if pid is null or qty not between 1 and 100 or prices ? pid::text then raise exception 'Invalid product quantity';end if;
 select pp.price_minor into retail from public.mt_product_prices pp join tenant_private.storefront_products l on l.store_id=pp.store_id and l.product_id=pp.product_id and l.listed where pp.store_id=s and pp.product_id=pid and pp.currency=c;
 if not found or retail is distinct from (x->>'expected_price_minor')::bigint then raise exception 'Price changed';end if;
 net:=retail-retail*coalesce(coupon.basis_points,0)/10000;
 gross:=gross+retail*qty;coupon_total:=coupon_total+net*qty;
 prices:=prices||jsonb_build_object(pid::text,retail);coupon_prices:=coupon_prices||jsonb_build_object(pid::text,net);
 end loop;
 m:=tenant_private.product_tier_quote(slug_value,c,items);membership_total:=coalesce((m->>'total_minor')::bigint,gross);
 subtotal:=gross;
 if membership_total<gross and membership_total<=coupon_total then prices:=m->'prices';subtotal:=membership_total;tier:=m->>'tier';source:='membership';bps:=(m->>'basis_points')::int;
 elsif coupon_total<gross then prices:=coupon_prices;subtotal:=coupon_total;chosen_coupon:=coupon.id;source:='coupon';bps:=coupon.basis_points;end if;
 balance:=greatest(0,tenant_private.points_balance(s,auth.uid()));
 select * into p from tenant_private.spend_loyalty_policy where store_id=s;
 if requested>0 then
 if not found or not p.enabled then raise exception 'Spend-value redemption unavailable';end if;
 rate:=tenant_private.spend_currency_rate(p,c);if rate is null then raise exception 'Configure loyalty currency conversion';end if;
 budget:=least(floor(subtotal::numeric*p.max_redeem_bps/10000),floor(least(requested,balance)::numeric*rate/p.points_per_usd),subtotal-1)::bigint;
 allocation:=tenant_private.allocate_spend_points(items,prices,subtotal,budget,least(requested,balance),rate,p.points_per_usd);
 prices:=allocation->'prices';discount:=(allocation->>'discount_minor')::bigint;used:=(allocation->>'points_used')::bigint;
 end if;
 return jsonb_build_object('currency',c,'gross_minor',gross,'base_total_minor',subtotal,'total_minor',subtotal-discount,'points_discount_minor',discount,'points_used',used,'source',source,'tier',tier,'coupon_id',chosen_coupon,'basis_points',bps,'prices',prices,'currency_per_usd_minor',rate,'points_per_usd',p.points_per_usd,'max_redeem_bps',p.max_redeem_bps);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t text;v jsonb;out_data jsonb:='{}';n bigint;total_rows bigint:=0;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not tenant_private.shared_licensed(p_store) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner and AAL2 required' using errcode='42501';end if;
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_debt_payments','tenant_private.standalone_payment_allocations','tenant_private.receivable_grants','tenant_private.receivable_resolutions','tenant_private.membership_rates','tenant_private.membership_directory','tenant_private.buyer_product_prices','tenant_private.product_tier_prices','tenant_private.local_membership_terms','tenant_private.local_customer_prices','tenant_private.local_membership_sales','tenant_private.spend_loyalty_policy','tenant_private.spend_loyalty_sales','tenant_private.spend_checkout','tenant_private.order_discounts','tenant_private.spend_pos_redemptions'] loop
 -- Fixed relation allowlist; no user-supplied table or SQL text.
 execute format('select count(*) from (select 1 from %I.%I where store_id=$1 limit 5001)x',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>5000 or total_rows+n>20000 then raise exception 'Export exceeds browser snapshot limit; use controlled server backup' using errcode='22023';end if;
 -- Limit before building the aggregate, including large image-containing product rows.
 execute format('select coalesce(sum(octet_length(to_jsonb(r)::text)),0) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>4000000 or octet_length(out_data::text)+n>8000000 then raise exception 'Export exceeds browser byte limit' using errcode='22023';end if;
 execute format('select coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into v using p_store;
 total_rows:=total_rows+jsonb_array_length(v);out_data:=out_data||jsonb_build_object(t,v);
 end loop;
 return jsonb_build_object('version',1,'scope','business_export_only','store',p_store,'captured_at',now(),'rows',total_rows,'tables',out_data);
end $function$;

CREATE FUNCTION tenant_private.pos_commit_mode(s uuid, b uuid, r uuid, t uuid, c text, items jsonb, meta jsonb, expected bigint, expected_prices jsonb, expected_spend jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a tenant_private.pos_authorizations%rowtype;old tenant_private.pos_loyalty_sales%rowtype;v_settings tenant_private.sales_settings%rowtype;v_sale public.mt_sales%rowtype;pr public.mt_products%rowtype;x jsonb;pid uuid;u bigint;net bigint;quote jsonb;payload jsonb;result jsonb;
begin
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.current_branch_scope(s) is not null and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if r is null or t is null or expected is null or expected<1 or meta is null then raise exception 'Invalid confirmed POS sale';end if;
 perform 1 from public.saas_stores where id=s for update;
 payload:=jsonb_build_object('branch',b,'token',t,'currency',c,'lines',items,'meta',meta,'expected',expected);
 if expected_prices is not null then payload:=payload||jsonb_build_object('prices',expected_prices);end if;
 if expected_spend is not null then payload:=payload||jsonb_build_object('spend',expected_spend);end if;
 select * into old from tenant_private.pos_loyalty_sales where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting POS sale';end if;return old.result;end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale request';end if;
 quote:=tenant_private.pos_quote(s,b,t,c,items);
 if (quote->>'total_minor')::bigint<>expected then raise exception 'Net total changed';end if;
 select * into strict a from tenant_private.pos_authorizations where store_id=s and token=t;
 if (a.use_membership or a.spend_requested is not null) and expected_prices is null then raise exception 'Confirm exact line prices';end if;
 if a.spend_requested is not null then
 if expected_spend is distinct from jsonb_build_object('requested',quote->'spend_requested','used',quote->'spend_points_used','points_discount_minor',quote->'points_discount_minor','currency_per_usd_minor',quote->'currency_per_usd_minor','points_per_usd',quote->'points_per_usd','max_redeem_bps',quote->'max_redeem_bps','base_total_minor',quote->'base_total_minor') then raise exception 'Spend-value quote changed';end if;
 elsif expected_spend is not null then raise exception 'Unexpected spend-value confirmation';end if;
 if expected_prices is not null and expected_prices is distinct from quote->'prices' then raise exception 'Net line prices changed';end if;
 select * into strict v_settings from tenant_private.sales_settings where store_id=s for update;
 if b is not null then perform tenant_private.branch_take(s,b,items);insert into tenant_private.branch_sale_context(store_id,request_id,branch_id,actor) values(s,r,b,auth.uid());end if;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(s,v_settings.next_number,r,auth.uid(),c,expected,'cash') returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=s;
 for x in select value from jsonb_array_elements(items) loop
 pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;net:=(quote->'prices'->>pid::text)::bigint;
 update public.mt_products set quantity=quantity-u where store_id=s and id=pid returning * into pr;
 insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(s,v_sale.id,pid,pr.sku,pr.name,u,net);
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(s,gen_random_uuid(),pid,-u,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 if b is not null then delete from tenant_private.branch_sale_context where store_id=s and request_id=r;insert into tenant_private.branch_sales(store_id,sale_id,branch_id) values(s,v_sale.id,b);end if;
 insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(s,v_sale.id,c,expected);
 result:=quote||jsonb_build_object('id',v_sale.id,'number',v_sale.number,'request_id',r);
 insert into tenant_private.pos_loyalty_sales(store_id,sale_id,token,buyer,points,basis_points,gross_minor,discount_minor,actor,request_id,branch_id,payload,result,price_tier) values(s,v_sale.id,t,a.buyer,a.points,(quote->>'basis_points')::int,a.gross_minor,(quote->>'discount_minor')::bigint,auth.uid(),r,b,payload,result,quote->>'price_tier');
 if a.spend_requested is not null then
 insert into tenant_private.spend_pos_redemptions(store_id,sale_id,buyer,token,requested_points,points_used,quote) values(s,v_sale.id,a.buyer,t,a.spend_requested,(quote->>'spend_points_used')::bigint,quote);
 end if;
 perform tenant_private.snapshot_channel_invoice(s,v_sale.id,'pos',v_sale.id,meta,null,null);
 update tenant_private.sale_invoice_details set document=document||jsonb_build_object('loyalty',jsonb_build_object('gross_minor',a.gross_minor,'discount_minor',(quote->>'discount_minor')::bigint,'points',a.points,'price_tier',quote->>'price_tier','spend_points_used',quote->'spend_points_used','points_discount_minor',quote->'points_discount_minor')) where store_id=s and sale_id=v_sale.id;
 return result;
end $function$;
create or replace function tenant_private.pos_commit_priced(s uuid,b uuid,r uuid,t uuid,c text,items jsonb,meta jsonb,expected bigint,expected_prices jsonb) returns jsonb language sql security definer set search_path='' as $$select tenant_private.pos_commit_mode(s,b,r,t,c,items,meta,expected,expected_prices,null)$$;
create function public.mt_pos_commit_spend(p_store uuid,p_branch uuid,p_request uuid,p_token uuid,p_currency text,p_lines jsonb,p_metadata jsonb,p_expected bigint,p_prices jsonb,p_spend jsonb) returns jsonb language sql set search_path='' as $$select tenant_private.pos_commit_mode(p_store,p_branch,p_request,p_token,p_currency,p_lines,p_metadata,p_expected,p_prices,p_spend)$$;
revoke all on function tenant_private.pos_commit_mode(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint,jsonb,jsonb),public.mt_pos_commit_spend(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint,jsonb,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.pos_commit_mode(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint,jsonb,jsonb),public.mt_pos_commit_spend(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint,jsonb,jsonb) to authenticated;

CREATE OR REPLACE FUNCTION tenant_private.buyer_pos_sales(s uuid, off integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) or off is null or off not between 0 and 100000 then raise exception 'Buyer access denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.number desc) from (select a.id,a.id sale_id,a.number,a.currency,a.total_minor,a.created_at,p.points,p.discount_minor,coalesce(v.points_used,0) spend_points_used from tenant_private.pos_loyalty_sales p join public.mt_sales a on a.store_id=p.store_id and a.id=p.sale_id left join tenant_private.spend_pos_redemptions v on v.store_id=p.store_id and v.sale_id=p.sale_id where p.store_id=s and p.buyer=auth.uid() order by a.number desc offset off limit 50)x),'[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.capture_online_spend_loyalty()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.state='fulfilled' and new.sale_id is not null and (old.state is distinct from new.state or old.sale_id is distinct from new.sale_id) then perform tenant_private.capture_spend_loyalty(new.store_id,new.sale_id,new.buyer,'online');
 update tenant_private.sale_invoice_details d set document=d.document||jsonb_build_object('combined_loyalty',jsonb_build_object('gross_minor',p.quote->'gross_minor','base_total_minor',p.quote->'base_total_minor','points_used',p.quote->'points_used','points_discount_minor',p.quote->'points_discount_minor','source',p.quote->'source','tier',p.quote->'tier')) from tenant_private.spend_checkout p where d.store_id=new.store_id and d.sale_id=new.sale_id and p.store_id=new.store_id and p.order_id=new.id;
 end if;
 return new;
end $function$;
