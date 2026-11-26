-- Opt-in spend-based loyalty. Historic transaction-count points are preserved.
-- Currency conversion is an explicit store policy; each newly issued sale freezes it.
create table tenant_private.spend_loyalty_policy(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 enabled boolean not null,points_per_usd integer not null check(points_per_usd between 1 and 10000),
 max_redeem_bps integer not null check(max_redeem_bps between 100 and 5000),
 syp_per_usd_minor bigint check(syp_per_usd_minor between 1 and 1000000000000),
 eur_per_usd_minor bigint check(eur_per_usd_minor between 1 and 1000000000000),
 actor uuid not null,updated_at timestamptz not null default now()
);
create table tenant_private.spend_loyalty_sales(
 store_id uuid not null,sale_id uuid not null,buyer uuid not null,currency text not null check(currency in ('SYP','USD','EUR')),
 points_per_usd integer not null check(points_per_usd between 1 and 10000),
 currency_per_usd_minor bigint check(currency_per_usd_minor between 1 and 1000000000000),
 enabled boolean not null,source text not null check(source in ('online','pos')),
 created_at timestamptz not null default now(),primary key(store_id,sale_id),
 foreign key(store_id,sale_id) references public.mt_sales(store_id,id)
);
create index spend_loyalty_buyer_idx on tenant_private.spend_loyalty_sales(store_id,buyer);
alter table tenant_private.spend_loyalty_policy enable row level security;
alter table tenant_private.spend_loyalty_sales enable row level security;
revoke all on tenant_private.spend_loyalty_policy,tenant_private.spend_loyalty_sales from public,anon,authenticated,service_role;

create function tenant_private.spend_currency_rate(p tenant_private.spend_loyalty_policy,c text) returns bigint language sql immutable set search_path='' as $$
 select case c when 'USD' then 100 when 'SYP' then p.syp_per_usd_minor when 'EUR' then p.eur_per_usd_minor end
$$;
create function tenant_private.spend_loyalty_read(s uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p tenant_private.spend_loyalty_policy%rowtype;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into p from tenant_private.spend_loyalty_policy where store_id=s;
 return jsonb_build_object('configured',p.store_id is not null,'enabled',coalesce(p.enabled,false),'points_per_usd',coalesce(p.points_per_usd,100),'max_redeem_bps',coalesce(p.max_redeem_bps,2000),'syp_per_usd_minor',p.syp_per_usd_minor,'eur_per_usd_minor',p.eur_per_usd_minor);
end $$;
create function tenant_private.spend_loyalty_set(s uuid,e boolean,rate integer,cap integer,syp bigint,eur bigint) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(s);
 perform 1 from public.saas_stores where id=s for update;
 if e is null or rate is null or rate not between 1 and 10000 or cap is null or cap not between 100 and 5000 or (syp is not null and syp not between 1 and 1000000000000) or (eur is not null and eur not between 1 and 1000000000000) then raise exception 'Invalid spend loyalty policy';end if;
 if e and exists(select 1 from tenant_private.sale_currencies where store_id=s and ((currency='SYP' and syp is null) or (currency='EUR' and eur is null))) then raise exception 'Configure loyalty conversion for each enabled currency';end if;
 insert into tenant_private.spend_loyalty_policy values(s,e,rate,cap,syp,eur,auth.uid(),now()) on conflict(store_id) do update set enabled=excluded.enabled,points_per_usd=excluded.points_per_usd,max_redeem_bps=excluded.max_redeem_bps,syp_per_usd_minor=excluded.syp_per_usd_minor,eur_per_usd_minor=excluded.eur_per_usd_minor,actor=excluded.actor,updated_at=now();
 return tenant_private.spend_loyalty_read(s);
end $$;
create function tenant_private.capture_spend_loyalty(s uuid,a uuid,u uuid,src text) returns void language plpgsql security definer set search_path='' as $$
declare p tenant_private.spend_loyalty_policy%rowtype;v public.mt_sales%rowtype;
begin
 select * into p from tenant_private.spend_loyalty_policy where store_id=s;
 if not found then return;end if;
 select * into strict v from public.mt_sales where store_id=s and id=a;
 insert into tenant_private.spend_loyalty_sales(store_id,sale_id,buyer,currency,points_per_usd,currency_per_usd_minor,enabled,source) values(s,a,u,v.currency,p.points_per_usd,tenant_private.spend_currency_rate(p,v.currency),p.enabled,src)
 on conflict(store_id,sale_id) do nothing;
end $$;
create function tenant_private.capture_online_spend_loyalty() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.state='fulfilled' and new.sale_id is not null and (old.state is distinct from new.state or old.sale_id is distinct from new.sale_id) then perform tenant_private.capture_spend_loyalty(new.store_id,new.sale_id,new.buyer,'online');end if;
 return new;
end $$;
create function tenant_private.capture_pos_spend_loyalty() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.capture_spend_loyalty(new.store_id,new.sale_id,new.buyer,'pos');return new;
end $$;
create trigger capture_online_spend_loyalty after update of state,sale_id on public.mt_online_orders for each row execute function tenant_private.capture_online_spend_loyalty();
create trigger capture_pos_spend_loyalty after insert on tenant_private.pos_loyalty_sales for each row execute function tenant_private.capture_pos_spend_loyalty();

-- Only money actually collected earns points. Waived installments do not count.
-- Partial returns reverse proportional earnings; credit earns as payment is collected.
create function tenant_private.spend_sale_earned(s uuid,a uuid) returns bigint language sql stable security definer set search_path='' as $$
 select coalesce((select case when not p.enabled or p.currency_per_usd_minor is null then 0 else
 least(9007199254740991::numeric,floor(greatest(0,least(v.total_minor-coalesce(r.returned,0),
 case when v.payment_mode='credit' then coalesce(pay.paid,0)-coalesce(r.refunded,0) else v.total_minor-coalesce(r.returned,0) end))::numeric*p.points_per_usd/p.currency_per_usd_minor))::bigint end
 from tenant_private.spend_loyalty_sales p join public.mt_sales v on v.store_id=p.store_id and v.id=p.sale_id
 left join lateral(select sum(total_minor) returned,sum(refund_minor) refunded from public.mt_returns where store_id=s and sale_id=a)r on true
 left join lateral(select sum(dp.amount_minor) paid from public.mt_debts d join public.mt_debt_payments dp on dp.store_id=d.store_id and dp.debt_id=d.id where d.store_id=s and d.sale_id=a and dp.settlement_method='cash')pay on true
 where p.store_id=s and p.sale_id=a),0)
$$;
create function public.mt_spend_loyalty_read(p_store uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.spend_loyalty_read(p_store)$$;
create function public.mt_spend_loyalty_set(p_store uuid,p_enabled boolean,p_rate integer,p_cap integer,p_syp bigint,p_eur bigint) returns jsonb language sql set search_path='' as $$select tenant_private.spend_loyalty_set(p_store,p_enabled,p_rate,p_cap,p_syp,p_eur)$$;
revoke all on function tenant_private.spend_loyalty_read(uuid),tenant_private.spend_loyalty_set(uuid,boolean,integer,integer,bigint,bigint),public.mt_spend_loyalty_read(uuid),public.mt_spend_loyalty_set(uuid,boolean,integer,integer,bigint,bigint) from public,anon,authenticated,service_role;
grant execute on function tenant_private.spend_loyalty_read(uuid),tenant_private.spend_loyalty_set(uuid,boolean,integer,integer,bigint,bigint),public.mt_spend_loyalty_read(uuid),public.mt_spend_loyalty_set(uuid,boolean,integer,integer,bigint,bigint) to authenticated;
revoke all on function tenant_private.spend_currency_rate(tenant_private.spend_loyalty_policy,text),tenant_private.capture_spend_loyalty(uuid,uuid,uuid,text),tenant_private.capture_online_spend_loyalty(),tenant_private.capture_pos_spend_loyalty(),tenant_private.spend_sale_earned(uuid,uuid) from public,anon,authenticated,service_role;


-- A combined checkout uses the better of membership prices or coupon, then spend-value points.
-- Preserve old discount documents and use existing frozen line-price fulfillment.
create table tenant_private.spend_checkout(
 store_id uuid not null,order_id uuid not null,buyer uuid not null,request_id uuid not null,
 coupon_code text,requested_points bigint not null check(requested_points between 0 and 9007199254740991),
 points_used bigint not null check(points_used between 0 and requested_points),quote jsonb not null,
 created_at timestamptz not null default now(),primary key(store_id,order_id),unique(store_id,buyer,request_id),
 foreign key(store_id,order_id) references public.mt_online_orders(store_id,id)
);
create index spend_checkout_buyer_idx on tenant_private.spend_checkout(store_id,buyer);
alter table tenant_private.spend_checkout enable row level security;
revoke all on tenant_private.spend_checkout from public,anon,authenticated,service_role;
alter table tenant_private.order_discounts add column combined boolean not null default false;
alter table tenant_private.order_discounts drop constraint mt_discount_source;
alter table tenant_private.order_discounts add constraint mt_discount_source check(
 (not combined and (((coupon_id is not null) and reward_points is null and price_tier is null) or (coupon_id is null and reward_points between 2 and 100 and price_tier is null) or (coupon_id is null and reward_points is null and price_tier is not null)))
 or (combined and reward_points is null and price_tier is not null and line_prices is not null)
);
-- Returns restore only the proportional part of the spent points; cancellation releases all.
create function tenant_private.spend_checkout_consumed(s uuid,a uuid) returns bigint language sql stable security definer set search_path='' as $
 select coalesce((select case when o.state='cancelled' then 0 when o.state='fulfilled' then p.points_used-floor(p.points_used::numeric*least(o.total_minor,coalesce(r.returned,0))/o.total_minor)::bigint else p.points_used end
 from tenant_private.spend_checkout p join public.mt_online_orders o on o.store_id=p.store_id and o.id=p.order_id
 left join lateral(select sum(total_minor) returned from public.mt_returns where store_id=s and sale_id=o.sale_id) r on true
 where p.store_id=s and p.order_id=a),0)
$;
revoke all on function tenant_private.spend_checkout_consumed(uuid,uuid) from public,anon,authenticated,service_role;


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
$function$;

CREATE OR REPLACE FUNCTION tenant_private.buyer_points(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;s tenant_private.loyalty_settings%rowtype;p tenant_private.spend_loyalty_policy%rowtype;b bigint;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 select id into t from public.saas_stores where slug=p_slug;if t is null or not tenant_private.storefront_active(t) then raise exception 'Store unavailable' using errcode='22023';end if;
 select * into s from tenant_private.loyalty_settings where store_id=t;
 select * into p from tenant_private.spend_loyalty_policy where store_id=t;
 b:=tenant_private.points_balance(t,auth.uid());
 return jsonb_build_object('balance',greatest(0,b),'deficit',greatest(0,-b),'enabled',coalesce(s.enabled,false) and p.store_id is null,'points_required',coalesce(s.points_required,5),'basis_points',coalesce(s.basis_points,1000),'eligible',coalesce(s.enabled,false) and b>=coalesce(s.points_required,5) and p.store_id is null,'mode',case when p.store_id is null then 'legacy' else 'spend' end,'spend_enabled',coalesce(p.enabled,false),'points_per_usd',p.points_per_usd,'max_redeem_bps',p.max_redeem_bps,'unvalued_sales',(select count(*) from tenant_private.spend_loyalty_sales where store_id=t and buyer=auth.uid() and enabled and currency_per_usd_minor is null));
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
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_debt_payments','tenant_private.standalone_payment_allocations','tenant_private.receivable_grants','tenant_private.receivable_resolutions','tenant_private.membership_rates','tenant_private.membership_directory','tenant_private.buyer_product_prices','tenant_private.product_tier_prices','tenant_private.local_membership_terms','tenant_private.local_customer_prices','tenant_private.local_membership_sales','tenant_private.spend_loyalty_policy','tenant_private.spend_loyalty_sales','tenant_private.spend_checkout','tenant_private.order_discounts'] loop
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

create function tenant_private.combined_checkout_quote(slug_value text,c text,items jsonb,code text,requested bigint)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s uuid;p tenant_private.spend_loyalty_policy%rowtype;coupon public.mt_coupons%rowtype;m jsonb;x jsonb;pid uuid;qty bigint;retail bigint;net bigint;gross bigint:=0;subtotal bigint:=0;coupon_total bigint:=0;membership_total bigint;prices jsonb:='{}';coupon_prices jsonb:='{}';tier text;source text:='regular';chosen_coupon uuid;bps int:=0;balance bigint;rate bigint;budget bigint:=0;discount bigint:=0;part bigint;used bigint:=0;amount bigint;remaining bigint;delta bigint;
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
 -- Allocate a proportional integer reduction per unit, preserving existing same-price-per-line invoices.
 if budget>0 then
 for x in select value from jsonb_array_elements(items) order by (value->>'product_id')::uuid loop
 pid:=(x->>'product_id')::uuid;qty:=(x->>'units')::bigint;net:=(prices->>pid::text)::bigint;
 part:=least(net-1,floor(budget::numeric*net/subtotal)::bigint);
 prices:=jsonb_set(prices,array[pid::text],to_jsonb(net-part));discount:=discount+qty*part;
 end loop;
 -- Spend any remaining amount representable in whole unit increments, without exceeding budget.
 remaining:=budget-discount;
 for x in select value from jsonb_array_elements(items) order by (value->>'product_id')::uuid loop
 exit when remaining<=0;
 pid:=(x->>'product_id')::uuid;qty:=(x->>'units')::bigint;net:=(prices->>pid::text)::bigint;delta:=least(net-1,remaining/qty);
 prices:=jsonb_set(prices,array[pid::text],to_jsonb(net-delta));remaining:=remaining-delta*qty;discount:=discount+delta*qty;
 end loop;
 used:=ceil(discount::numeric*p.points_per_usd/rate)::bigint;
 if used>least(requested,balance) then raise exception 'Points allocation exceeds balance';end if;
 end if;
 end if;
 return jsonb_build_object('currency',c,'gross_minor',gross,'base_total_minor',subtotal,'total_minor',subtotal-discount,'points_discount_minor',discount,'points_used',used,'source',source,'tier',tier,'coupon_id',chosen_coupon,'basis_points',bps,'prices',prices,'currency_per_usd_minor',rate,'points_per_usd',p.points_per_usd,'max_redeem_bps',p.max_redeem_bps);
end $$;
create function tenant_private.combined_checkout_order(slug_value text,r uuid,c text,items jsonb,code text,requested bigint,expected jsonb,addr text,phone text) returns uuid language plpgsql security definer set search_path='' as $$
declare s uuid;oid uuid;o public.mt_online_orders%rowtype;old tenant_private.spend_checkout%rowtype;q jsonb;exists_before boolean;
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) or r is null or jsonb_typeof(expected) is distinct from 'object' or octet_length(expected::text)>30000 or (addr is null)<>(phone is null) then raise exception 'Invalid combined checkout';end if;
 select id into s from public.saas_stores where slug=slug_value for update;if s is null then raise exception 'Store unavailable';end if;
 exists_before:=exists(select 1 from public.mt_online_orders where store_id=s and buyer=auth.uid() and request_id=r);
 if addr is null then oid:=tenant_private.online_order(slug_value,r,c,items);else oid:=tenant_private.delivery_order(slug_value,r,c,items,addr,phone);end if;
 select * into strict o from public.mt_online_orders where store_id=s and id=oid;
 if o.delivery_method<>(case when addr is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method';end if;
 if exists_before then
 select * into old from tenant_private.spend_checkout where store_id=s and order_id=oid and buyer=auth.uid();
 if not found or old.coupon_code is distinct from upper(btrim(code)) or old.requested_points is distinct from requested or old.quote is distinct from expected then raise exception 'Conflicting combined checkout';end if;return oid;
 end if;
 q:=tenant_private.combined_checkout_quote(slug_value,c,o.lines,code,requested);
 if q is distinct from expected or (q->>'gross_minor')::bigint<>o.total_minor then raise exception 'Combined quote changed; review cart';end if;
 if (q->>'total_minor')::bigint<o.total_minor then
 insert into tenant_private.order_discounts(store_id,order_id,coupon_id,buyer,basis_points,gross_minor,discount_minor,price_tier,line_prices,combined)
 values(s,oid,(q->>'coupon_id')::uuid,auth.uid(),(q->>'basis_points')::int,o.total_minor,o.total_minor-(q->>'total_minor')::bigint,coalesce(q->>'tier','standard'),q->'prices',true);
 update public.mt_online_orders set total_minor=(q->>'total_minor')::bigint where store_id=s and id=oid;
 end if;
 insert into tenant_private.spend_checkout(store_id,order_id,buyer,request_id,coupon_code,requested_points,points_used,quote) values(s,oid,auth.uid(),r,upper(btrim(code)),requested,(q->>'points_used')::bigint,q);
 return oid;
end $$;
create function public.mt_combined_checkout_quote(p_slug text,p_currency text,p_lines jsonb,p_code text,p_points bigint) returns jsonb language sql stable set search_path='' as $$select tenant_private.combined_checkout_quote(p_slug,p_currency,p_lines,p_code,p_points)$$;
create function public.mt_combined_checkout_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_code text,p_points bigint,p_quote jsonb,p_address text,p_phone text) returns uuid language sql set search_path='' as $$select tenant_private.combined_checkout_order(p_slug,p_request,p_currency,p_lines,p_code,p_points,p_quote,p_address,p_phone)$$;
revoke all on function tenant_private.combined_checkout_quote(text,text,jsonb,text,bigint),tenant_private.combined_checkout_order(text,uuid,text,jsonb,text,bigint,jsonb,text,text),public.mt_combined_checkout_quote(text,text,jsonb,text,bigint),public.mt_combined_checkout_order(text,uuid,text,jsonb,text,bigint,jsonb,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.combined_checkout_quote(text,text,jsonb,text,bigint),tenant_private.combined_checkout_order(text,uuid,text,jsonb,text,bigint,jsonb,text,text),public.mt_combined_checkout_quote(text,text,jsonb,text,bigint),public.mt_combined_checkout_order(text,uuid,text,jsonb,text,bigint,jsonb,text,text) to authenticated;

CREATE OR REPLACE FUNCTION tenant_private.discount_order(p_slug text, p_request uuid, p_currency text, p_lines jsonb, p_code text, p_expected_total bigint, p_address text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;c public.mt_coupons%rowtype;discount bigint;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_code is null or upper(btrim(p_code)) !~ '^[A-Z0-9-]{3,24}$' or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid coupon order' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then if exists(select 1 from tenant_private.spend_checkout where store_id=t and order_id=oid) then raise exception 'Conflicting combined checkout';end if;
  select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
  if not found or o.total_minor<>p_expected_total or not exists(select 1 from public.mt_coupons where store_id=t and id=d.coupon_id and code=upper(btrim(p_code))) then raise exception 'Conflicting coupon request' using errcode='22023';end if;return oid;
 end if;
 c:=tenant_private.coupon_available(t,p_code,auth.uid());
 select sum((x->>'units')::bigint*((x->>'expected_price_minor')::bigint*c.basis_points/10000)) into discount from jsonb_array_elements(o.lines)x;
 if discount is null or discount<=0 or o.total_minor-discount<>p_expected_total then raise exception 'Discount quote changed' using errcode='22023';end if;
 insert into tenant_private.order_discounts(store_id,order_id,coupon_id,buyer,basis_points,gross_minor,discount_minor) values(t,oid,c.id,auth.uid(),c.basis_points,o.total_minor,discount);
 update public.mt_online_orders set total_minor=total_minor-discount where store_id=t and id=oid;return oid;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.member_order(p_slug text, p_request uuid, p_currency text, p_lines jsonb, p_tier text, p_bps integer, p_expected_total bigint, p_address text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;v tenant_private.buyer_price_terms%rowtype;discount bigint;units bigint;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_tier is null or p_tier not in ('standard','member','silver','gold','vip','wholesale') or p_bps is null or p_bps not between 100 and 5000 or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid price tier' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then if exists(select 1 from tenant_private.spend_checkout where store_id=t and order_id=oid) then raise exception 'Conflicting combined checkout';end if;
 select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
 if not found or d.price_tier is distinct from p_tier or d.basis_points<>p_bps or o.total_minor<>p_expected_total then raise exception 'Conflicting price tier' using errcode='22023';end if;return oid;
 end if;
 v:=tenant_private.effective_buyer_terms(t,auth.uid());
 if v.buyer is null or v.tier<>p_tier or v.basis_points<>p_bps then raise exception 'Price terms changed' using errcode='22023';end if;
 select sum((x->>'units')::bigint),sum((x->>'units')::bigint*((x->>'expected_price_minor')::bigint*p_bps/10000)) into units,discount from jsonb_array_elements(o.lines)x;
 if units<v.min_units or discount is null or discount<=0 or o.total_minor-discount<>p_expected_total then raise exception 'Minimum quantity or price quote changed' using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(o.lines) x where exists(select 1 from tenant_private.buyer_product_prices b where b.store_id=t and b.buyer=auth.uid() and b.product_id=(x->>'product_id')::uuid and b.currency=p_currency and b.min_units<=(x->>'units')::int and b.price_minor<=(x->>'expected_price_minor')::bigint) or exists(select 1 from tenant_private.product_tier_prices b where b.store_id=t and b.tier=v.tier and b.product_id=(x->>'product_id')::uuid and b.currency=p_currency and b.min_units<=(x->>'units')::int and b.price_minor<=(x->>'expected_price_minor')::bigint)) then raise exception 'Use current product tier quote';end if;
 insert into tenant_private.order_discounts(store_id,order_id,coupon_id,buyer,basis_points,gross_minor,discount_minor,reward_points,price_tier) values(t,oid,null,auth.uid(),p_bps,o.total_minor,discount,null,p_tier);
 update public.mt_online_orders set total_minor=total_minor-discount where store_id=t and id=oid;return oid;
end $function$;

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
 if a.currency<>c or a.gross_minor<>gross or (a.points>0) is distinct from use_reward or a.use_membership is distinct from use_member then raise exception 'Conflicting authorization';end if;
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

CREATE OR REPLACE FUNCTION tenant_private.product_tier_order(p_slug text, p_request uuid, p_currency text, p_lines jsonb, p_prices jsonb, p_expected_total bigint, p_address text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;q jsonb;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 if jsonb_typeof(p_prices) is distinct from 'object' or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid price quote' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then if exists(select 1 from tenant_private.spend_checkout where store_id=t and order_id=oid) then raise exception 'Conflicting combined checkout';end if; select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
 if not found or d.line_prices is distinct from p_prices or o.total_minor<>p_expected_total then raise exception 'Conflicting tier request' using errcode='22023';end if;return oid;end if;
 q:=tenant_private.product_tier_quote(p_slug,p_currency,o.lines);
 if q is null or q->'prices' is distinct from p_prices or (q->>'total_minor')::bigint<>p_expected_total or (q->>'gross_minor')::bigint<>o.total_minor then raise exception 'Tier quote changed' using errcode='22023';end if;
 insert into tenant_private.order_discounts(store_id,order_id,buyer,basis_points,gross_minor,discount_minor,price_tier,line_prices) values(t,oid,auth.uid(),(q->>'basis_points')::int,o.total_minor,o.total_minor-p_expected_total,q->>'tier',p_prices);
 update public.mt_online_orders set total_minor=p_expected_total where store_id=t and id=oid;return oid;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.reward_order(p_slug text, p_request uuid, p_currency text, p_lines jsonb, p_points integer, p_bps integer, p_expected_total bigint, p_address text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;s tenant_private.loyalty_settings%rowtype;discount bigint;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_points is null or p_points not between 2 and 100 or p_bps is null or p_bps not between 100 and 5000 or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid reward' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then if exists(select 1 from tenant_private.spend_checkout where store_id=t and order_id=oid) then raise exception 'Conflicting combined checkout';end if;
  select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
  if not found or d.reward_points is distinct from p_points or d.basis_points<>p_bps or o.total_minor<>p_expected_total then raise exception 'Conflicting reward request' using errcode='22023';end if;return oid;
 end if;
 if exists(select 1 from tenant_private.spend_loyalty_policy where store_id=t) then raise exception 'Use spend-value points checkout';end if;
 select * into s from tenant_private.loyalty_settings where store_id=t;
 if not found or not s.enabled or s.points_required<>p_points or s.basis_points<>p_bps or tenant_private.points_balance(t,auth.uid())<p_points then raise exception 'Reward unavailable' using errcode='22023';end if;
 select sum((x->>'units')::bigint*((x->>'expected_price_minor')::bigint*p_bps/10000)) into discount from jsonb_array_elements(o.lines)x;
 if discount is null or discount<=0 or o.total_minor-discount<>p_expected_total then raise exception 'Reward quote changed' using errcode='22023';end if;
 insert into tenant_private.order_discounts(store_id,order_id,coupon_id,buyer,basis_points,gross_minor,discount_minor,reward_points) values(t,oid,null,auth.uid(),p_bps,o.total_minor,discount,p_points);
 update public.mt_online_orders set total_minor=total_minor-discount where store_id=t and id=oid;return oid;
end $function$;
