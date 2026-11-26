-- Buyer-approved membership prices at physical checkout; old cash/reward codes remain compatible.
alter table tenant_private.pos_authorizations add column use_membership boolean not null default false;
alter table tenant_private.pos_authorizations add constraint pos_authorization_discount_exclusive check(not use_membership or (points=0 and basis_points=0));
alter table tenant_private.pos_loyalty_sales add column price_tier text check(price_tier in ('standard','member','silver','gold','vip','wholesale'));

-- Resolve the same per-item price for online and physical sales, independently of storefront listing.
create function tenant_private.membership_unit_price(s uuid,u uuid,t text,p uuid,c text,qty bigint,retail bigint,bps int)
returns bigint language plpgsql stable security definer set search_path='' as $$
declare net bigint;
begin
 select price_minor into net from tenant_private.buyer_product_prices where store_id=s and buyer=u and product_id=p and currency=c and min_units<=qty and price_minor<=retail;
 if not found then select price_minor into net from tenant_private.product_tier_prices where store_id=s and product_id=p and tier=t and currency=c and min_units<=qty and price_minor<=retail;end if;
 return coalesce(net,retail-retail*bps/10000);
end $$;
revoke all on function tenant_private.membership_unit_price(uuid,uuid,text,uuid,text,bigint,bigint,int) from public,anon,authenticated,service_role;

CREATE FUNCTION tenant_private.pos_authorize_mode(s uuid, r uuid, c text, gross bigint, use_reward boolean, use_member boolean)
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
 if a.currency<>c or a.gross_minor<>gross or (a.points>0) is distinct from use_reward or a.use_membership is distinct from use_member then raise exception 'Conflicting authorization';end if;
 else
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
declare a tenant_private.pos_authorizations%rowtype;l tenant_private.loyalty_settings%rowtype;x jsonb;pid uuid;u bigint;price bigint;quoted bigint;gross bigint:=0;discount bigint:=0;net bigint;loc bigint;v tenant_private.buyer_price_terms%rowtype;qty_total bigint:=0;prices jsonb:='{}';tier text;bps int;
begin
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.current_branch_scope(s) is not null and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 if t is null or c is null or c not in ('SYP','USD','EUR') or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or octet_length(items::text)>50000 then raise exception 'Invalid POS cart';end if;
 select * into a from tenant_private.pos_authorizations where store_id=s and token=t;
 if not found or a.revoked or a.expires_at<=now() or a.currency<>c or exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and token=t) then raise exception 'Authorization unavailable';end if;
 bps:=a.basis_points;
 if a.use_membership then
 if tenant_private.member_role(s)='cashier' and tenant_private.current_branch_scope(s) is distinct from b then raise exception 'Membership sale branch denied' using errcode='42501';end if;
 v:=tenant_private.effective_buyer_terms(s,a.buyer);if v.buyer is null then raise exception 'Membership changed';end if;tier:=v.tier;bps:=v.basis_points;
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
 if a.use_membership then net:=tenant_private.membership_unit_price(s,a.buyer,tier,pid,c,u,price,bps);else net:=price-price*a.basis_points/10000;end if;
 qty_total:=qty_total+u;prices:=prices||jsonb_build_object(pid::text,net);
 if net<1 then raise exception 'Invalid net price';end if;
 gross:=gross+u*price;discount:=discount+u*(price-net);
 end loop;
 if a.use_membership and qty_total<v.min_units then raise exception 'Membership minimum quantity not met';end if;
 if gross<>a.gross_minor or gross>100000000000000 or (a.points>0 and discount<=0) then raise exception 'Authorized amount changed';end if;
 return jsonb_build_object('currency',c,'gross_minor',gross,'discount_minor',discount,'total_minor',gross-discount,'points',a.points,'basis_points',bps,'price_tier',tier,'prices',prices);
end $function$;

CREATE FUNCTION tenant_private.pos_commit_priced(s uuid, b uuid, r uuid, t uuid, c text, items jsonb, meta jsonb, expected bigint, expected_prices jsonb)
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
 select * into old from tenant_private.pos_loyalty_sales where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting POS sale';end if;return old.result;end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale request';end if;
 quote:=tenant_private.pos_quote(s,b,t,c,items);
 if (quote->>'total_minor')::bigint<>expected then raise exception 'Net total changed';end if;
 select * into strict a from tenant_private.pos_authorizations where store_id=s and token=t;
 if a.use_membership and expected_prices is null then raise exception 'Confirm exact membership line prices';end if;
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
 perform tenant_private.snapshot_channel_invoice(s,v_sale.id,'pos',v_sale.id,meta,null,null);
 update tenant_private.sale_invoice_details set document=document||jsonb_build_object('loyalty',jsonb_build_object('gross_minor',a.gross_minor,'discount_minor',(quote->>'discount_minor')::bigint,'points',a.points,'price_tier',quote->>'price_tier')) where store_id=s and sale_id=v_sale.id;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.product_tier_quote(p_slug text, p_currency text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;v tenant_private.buyer_price_terms%rowtype;x jsonb;pid uuid;u bigint;retail bigint;net bigint;gross bigint:=0;total bigint:=0;units bigint:=0;prices jsonb:='{}';begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid cart' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 50 or octet_length(p_lines::text)>30000 then raise exception 'Invalid cart' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);
 v:=tenant_private.effective_buyer_terms(t,auth.uid());
 if v.buyer is null then return null;end if;
 for x in select value from jsonb_array_elements(p_lines) loop
 if jsonb_typeof(x) is distinct from 'object' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,3}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line' using errcode='22023';end if;
 pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
 if u not between 1 and 100 or prices ? pid::text then raise exception 'Invalid quantity or duplicate product' using errcode='22023';end if;
 select pp.price_minor into retail from public.mt_product_prices pp join tenant_private.storefront_products l on l.store_id=pp.store_id and l.product_id=pp.product_id and l.listed where pp.store_id=t and pp.product_id=pid and pp.currency=p_currency;
 if not found or retail<>(x->>'expected_price_minor')::bigint then raise exception 'List price changed' using errcode='22023';end if;
 net:=tenant_private.membership_unit_price(t,auth.uid(),v.tier,pid,p_currency,u,retail,v.basis_points);if net<1 then raise exception 'Invalid net price' using errcode='22023';end if;
 gross:=gross+retail*u;total:=total+net*u;units:=units+u;prices:=prices||jsonb_build_object(pid::text,net);
 end loop;
 if units<v.min_units or total>=gross then return null;end if;
 return jsonb_build_object('tier',v.tier,'basis_points',v.basis_points,'min_units',v.min_units,'prices',prices,'total_minor',total,'gross_minor',gross);
end $function$;


create or replace function tenant_private.pos_authorize(s uuid,r uuid,c text,gross bigint,use_reward boolean) returns jsonb language sql security definer set search_path='' as $$select tenant_private.pos_authorize_mode(s,r,c,gross,use_reward,false)$$;
create function public.mt_pos_authorize_membership(p_slug text,p_request uuid,p_currency text,p_gross bigint) returns jsonb language sql set search_path='' as $$select tenant_private.pos_authorize_mode(tenant_private.buyer_store(p_slug),p_request,p_currency,p_gross,false,true)$$;
create or replace function tenant_private.pos_commit(s uuid,b uuid,r uuid,t uuid,c text,items jsonb,meta jsonb,expected bigint) returns jsonb language sql security definer set search_path='' as $$select tenant_private.pos_commit_priced(s,b,r,t,c,items,meta,expected,null)$$;
create function public.mt_pos_commit_priced(p_store uuid,p_branch uuid,p_request uuid,p_token uuid,p_currency text,p_lines jsonb,p_metadata jsonb,p_expected bigint,p_prices jsonb) returns jsonb language sql set search_path='' as $$select tenant_private.pos_commit_priced(p_store,p_branch,p_request,p_token,p_currency,p_lines,p_metadata,p_expected,p_prices)$$;
revoke all on function tenant_private.pos_authorize_mode(uuid,uuid,text,bigint,boolean,boolean),tenant_private.pos_commit_priced(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint,jsonb),public.mt_pos_authorize_membership(text,uuid,text,bigint),public.mt_pos_commit_priced(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.pos_authorize_mode(uuid,uuid,text,bigint,boolean,boolean),tenant_private.pos_commit_priced(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint,jsonb),public.mt_pos_authorize_membership(text,uuid,text,bigint),public.mt_pos_commit_priced(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint,jsonb) to authenticated;
