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
 left join lateral(select sum(dp.amount_minor) paid from public.mt_debts d join public.mt_debt_payments dp on dp.store_id=d.store_id and dp.debt_id=d.id where d.store_id=s and d.sale_id=a and dp.settlement_method in ('cash','bank'))pay on true
 where p.store_id=s and p.sale_id=a),0)
$$;
create function public.mt_spend_loyalty_read(p_store uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.spend_loyalty_read(p_store)$$;
create function public.mt_spend_loyalty_set(p_store uuid,p_enabled boolean,p_rate integer,p_cap integer,p_syp bigint,p_eur bigint) returns jsonb language sql set search_path='' as $$select tenant_private.spend_loyalty_set(p_store,p_enabled,p_rate,p_cap,p_syp,p_eur)$$;
revoke all on function tenant_private.spend_loyalty_read(uuid),tenant_private.spend_loyalty_set(uuid,boolean,integer,integer,bigint,bigint),public.mt_spend_loyalty_read(uuid),public.mt_spend_loyalty_set(uuid,boolean,integer,integer,bigint,bigint) from public,anon,authenticated,service_role;
grant execute on function tenant_private.spend_loyalty_read(uuid),tenant_private.spend_loyalty_set(uuid,boolean,integer,integer,bigint,bigint),public.mt_spend_loyalty_read(uuid),public.mt_spend_loyalty_set(uuid,boolean,integer,integer,bigint,bigint) to authenticated;
revoke all on function tenant_private.spend_currency_rate(tenant_private.spend_loyalty_policy,text),tenant_private.capture_spend_loyalty(uuid,uuid,uuid,text),tenant_private.capture_online_spend_loyalty(),tenant_private.capture_pos_spend_loyalty(),tenant_private.spend_sale_earned(uuid,uuid) from public,anon,authenticated,service_role;

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
 return jsonb_build_object('balance',greatest(0,b),'deficit',greatest(0,-b),'enabled',coalesce(s.enabled,false),'points_required',coalesce(s.points_required,5),'basis_points',coalesce(s.basis_points,1000),'eligible',coalesce(s.enabled,false) and b>=coalesce(s.points_required,5),'mode',case when p.store_id is null then 'legacy' else 'spend' end,'spend_enabled',coalesce(p.enabled,false),'points_per_usd',p.points_per_usd,'max_redeem_bps',p.max_redeem_bps,'unvalued_sales',(select count(*) from tenant_private.spend_loyalty_sales where store_id=t and buyer=auth.uid() and enabled and currency_per_usd_minor is null));
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
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_debt_payments','tenant_private.standalone_payment_allocations','tenant_private.receivable_grants','tenant_private.receivable_resolutions','tenant_private.membership_rates','tenant_private.membership_directory','tenant_private.buyer_product_prices','tenant_private.product_tier_prices','tenant_private.local_membership_terms','tenant_private.local_customer_prices','tenant_private.local_membership_sales','tenant_private.spend_loyalty_policy','tenant_private.spend_loyalty_sales'] loop
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
