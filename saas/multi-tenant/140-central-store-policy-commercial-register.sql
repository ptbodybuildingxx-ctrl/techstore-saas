-- 140: central plan + store restrictions, actual server enforcement, and consolidated external billing.
begin;
create table tenant_private.admin_store_action_policy(
 store_id uuid primary key references tenant_private.workspaces(store_id),revision bigint not null check(revision>=1),denied text[] not null,updated_at timestamptz not null default now()
);
create table tenant_private.admin_store_action_events(
 request_id uuid primary key,store_id uuid not null references tenant_private.workspaces(store_id),actor uuid not null,reference text not null check(length(btrim(reference)) between 1 and 200),
 previous_revision bigint not null,before_denied text[] not null,after_denied text[] not null,created_at timestamptz not null default now()
);
create index admin_store_action_event_history on tenant_private.admin_store_action_events(store_id,created_at desc,request_id);
alter table tenant_private.admin_store_action_policy enable row level security;
alter table tenant_private.admin_store_action_events enable row level security;
revoke all on tenant_private.admin_store_action_policy,tenant_private.admin_store_action_events from public,anon,authenticated,service_role;
create function tenant_private.central_action_keys() returns text[] language sql immutable set search_path='' as $$select array['staff_sell','staff_stock_adjust','staff_stock_transfer','staff_product_create','staff_repair_transition','staff_repair_evidence','staff_attendance','staff_catalog_read','staff_stock_history_read','staff_sales_read','staff_repair_read','staff_product_edit','staff_repair_task_finish','staff_customer_create','staff_debt_payment','staff_quote_create','staff_quote_read','staff_receipt_read','staff_warranty_read','staff_receivable_read','staff_customer_edit','staff_credit_sale','staff_standalone_open','staff_standalone_payment','staff_payable_manage','staff_procurement_read','staff_supplier_write','staff_purchase_write','staff_notifications_read','staff_customer_read','staff_debt_read','staff_installment_read','staff_supplier_read','staff_purchase_read','product_profile_edit','product_price_change','customer_profile_edit','supplier_profile_edit','supplier_archive','coupon_edit','coupon_disable','repair_cancel','all_catalog_read','all_sales_read','all_purchase_read','all_supplier_read','all_customer_read','all_debt_read','all_repair_read','all_returns_read','all_order_read','all_warranty_read','all_coupon_read','all_finance_read','all_catalog_create','all_sales_create','all_purchase_create','all_supplier_create','all_customer_create','all_debt_create','all_repair_create','all_returns_create','all_supplier_return_create','all_repair_refund_create','all_warranty_create','all_coupon_create','all_finance_create','all_order_edit','all_warranty_edit','all_repair_edit','all_catalog_delete','all_customer_delete','all_supplier_delete','all_coupon_delete','all_stock_transfer_create','all_stock_count_create','all_quote_create','all_payroll_create','all_standalone_create','all_branch_create']::text[]$$;
create function tenant_private.central_effective_denials(s uuid) returns text[] language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(k order by k),'{}'::text[]) from (select distinct k from (select unnest(p.denied) k from public.saas_subscriptions sub join tenant_private.admin_action_policy p on p.plan_code=sub.plan_code where sub.store_id=s union all select unnest(p.denied) from tenant_private.admin_store_action_policy p where p.store_id=s) z) q
$$;
revoke all on function tenant_private.central_action_keys(),tenant_private.central_effective_denials(uuid) from public,anon,authenticated,service_role;
create or replace function tenant_private.central_action_denied(s uuid,k text) returns boolean language sql stable security definer set search_path='' as $$select k=any(tenant_private.central_effective_denials(s))$$;
create or replace function tenant_private.staff_central_denials(s uuid) returns text[] language sql stable security definer set search_path='' as $$select coalesce(array_agg(substr(k,7) order by k),'{}'::text[]) from unnest(tenant_private.central_effective_denials(s)) k where left(k,6)='staff_'$$;
create or replace function tenant_private.member_central_actions(s uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;return to_jsonb(tenant_private.central_effective_denials(s));end $$;
CREATE OR REPLACE FUNCTION tenant_private.admin_actions_change(req uuid, plan text, expected bigint, desired text[], proof text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare previous text[];rev bigint;e tenant_private.admin_action_events%rowtype;normalized text[];
begin
 if not coalesce(saas_private.is_operator(),false) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Operator MFA required' using errcode='42501';end if;
 if req is null or plan is null or expected is null or expected<1 or desired is null or cardinality(desired)>cardinality(tenant_private.central_action_keys()) or array_position(desired,null) is not null or not desired <@ tenant_private.central_action_keys() or cardinality(desired)<>(select count(distinct k) from unnest(desired) k) or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid action policy';end if;
 select coalesce(array_agg(k order by k),'{}'::text[]) into normalized from unnest(desired) k;
 perform 1 from public.saas_plans where code=plan for update;if not found then raise exception 'Unknown plan';end if;
 select * into e from tenant_private.admin_action_events where request_id=req;
 if found then
  if e.plan_code<>plan or e.actor<>auth.uid() or e.reference<>btrim(proof) or e.previous_revision<>expected or e.after_denied<>normalized then raise exception 'Conflicting policy request';end if;return req;
 end if;
 select revision,denied into rev,previous from tenant_private.admin_action_policy where plan_code=plan;
 rev:=coalesce(rev,1);previous:=coalesce(previous,'{}'::text[]);
 if rev<>expected or previous=normalized then raise exception 'Policy changed or unchanged';end if;
 insert into tenant_private.admin_action_policy(plan_code,revision,denied) values(plan,rev+1,normalized) on conflict(plan_code) do update set revision=excluded.revision,denied=excluded.denied,updated_at=now();
 insert into tenant_private.admin_action_events(request_id,plan_code,actor,reference,previous_revision,before_denied,after_denied) values(req,plan,auth.uid(),btrim(proof),rev,previous,normalized);
 return req;
end $function$;

create function tenant_private.admin_store_actions_review(s uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 select jsonb_build_object('store',st.id,'name',st.name,'plan',sub.plan_code,'revision',coalesce(a.revision,1),'denied',coalesce(a.denied,'{}'::text[]),'plan_denied',coalesce(p.denied,'{}'::text[]),'effective',tenant_private.central_effective_denials(s)) into v from tenant_private.workspaces w join public.saas_stores st on st.id=w.store_id join public.saas_subscriptions sub on sub.store_id=w.store_id left join tenant_private.admin_action_policy p on p.plan_code=sub.plan_code left join tenant_private.admin_store_action_policy a on a.store_id=w.store_id where w.store_id=s;
 if v is null then raise exception 'Shared store required';end if;
 return v||jsonb_build_object('history',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id) from (select request_id,actor,reference,before_denied,after_denied,created_at from tenant_private.admin_store_action_events where store_id=s order by created_at desc,request_id limit 50)x),'[]'::jsonb));
end $$;
create function tenant_private.admin_store_actions_change(s uuid,req uuid,expected bigint,desired text[],proof text) returns uuid language plpgsql security definer set search_path='' as $$
declare e tenant_private.admin_store_action_events%rowtype;rev bigint;old_keys text[];normalized text[];
begin
 if not coalesce(saas_private.is_operator(),false) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Operator MFA required' using errcode='42501';end if;
 if s is null or req is null or expected is null or expected<1 or desired is null or cardinality(desired)>cardinality(tenant_private.central_action_keys()) or array_position(desired,null) is not null or not desired <@ tenant_private.central_action_keys() or cardinality(desired)<>(select count(distinct k) from unnest(desired) k) or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid store action policy';end if;
 perform 1 from public.saas_stores where id=s for update;
 if not exists(select 1 from tenant_private.workspaces where store_id=s) then raise exception 'Shared store required';end if;
 select coalesce(array_agg(k order by k),'{}'::text[]) into normalized from unnest(desired) k;
 select * into e from tenant_private.admin_store_action_events where request_id=req;
 if found then
  if e.store_id<>s or e.actor<>auth.uid() or e.reference<>btrim(proof) or e.previous_revision<>expected or e.after_denied<>normalized then raise exception 'Conflicting store action request';end if;return req;
 end if;
 select revision,denied into rev,old_keys from tenant_private.admin_store_action_policy where store_id=s;
 rev:=coalesce(rev,1);old_keys:=coalesce(old_keys,'{}'::text[]);
 if rev<>expected or old_keys=normalized then raise exception 'Policy changed or unchanged';end if;
 insert into tenant_private.admin_store_action_policy(store_id,revision,denied) values(s,rev+1,normalized) on conflict(store_id) do update set revision=excluded.revision,denied=excluded.denied,updated_at=now();
 insert into tenant_private.admin_store_action_events values(req,s,auth.uid(),btrim(proof),rev,old_keys,normalized,now());return req;
end $$;
create function public.mt_admin_store_actions_review(s uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.admin_store_actions_review(s)$$;
create function public.mt_admin_store_actions_change(s uuid,req uuid,expected bigint,desired text[],proof text) returns uuid language sql set search_path='' as $$select tenant_private.admin_store_actions_change(s,req,expected,desired,proof)$$;
revoke all on function tenant_private.admin_store_actions_review(uuid),tenant_private.admin_store_actions_change(uuid,uuid,bigint,text[],text),public.mt_admin_store_actions_review(uuid),public.mt_admin_store_actions_change(uuid,uuid,bigint,text[],text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.admin_store_actions_review(uuid),tenant_private.admin_store_actions_change(uuid,uuid,bigint,text[],text),public.mt_admin_store_actions_review(uuid),public.mt_admin_store_actions_change(uuid,uuid,bigint,text[],text) to authenticated;

-- Existing access remains necessary. This restricts tenant-member reads, not public catalog/customer rights.
create function tenant_private.central_read_permitted(s uuid,k text) returns boolean language sql stable security definer set search_path='' as $$
 select case when tenant_private.member_role(s) is null then true else not tenant_private.central_action_denied(s,k) end
$$;
revoke all on function tenant_private.central_read_permitted(uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.central_read_permitted(uuid,text) to authenticated;
create function tenant_private.guard_central_operation() returns trigger language plpgsql security definer set search_path='' as $$
declare s uuid:=case when tg_op='DELETE' then old.store_id else new.store_id end;
begin
 if auth.uid() is not null and tenant_private.member_role(s) is not null and tenant_private.central_action_denied(s,tg_argv[0]) then raise exception 'Central operation restriction: %',tg_argv[0] using errcode='42501';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function tenant_private.guard_central_operation() from public,anon,authenticated,service_role;
create trigger mt_central_action_1 before insert on public.mt_products for each row execute function tenant_private.guard_central_operation('all_catalog_create');
create trigger mt_central_action_2 before insert on public.mt_sales for each row execute function tenant_private.guard_central_operation('all_sales_create');
create trigger mt_central_action_3 before insert on public.mt_purchases for each row execute function tenant_private.guard_central_operation('all_purchase_create');
create trigger mt_central_action_4 before insert on public.mt_suppliers for each row execute function tenant_private.guard_central_operation('all_supplier_create');
create trigger mt_central_action_5 before insert on public.mt_customers for each row execute function tenant_private.guard_central_operation('all_customer_create');
create trigger mt_central_action_6 before insert on public.mt_debts for each row execute function tenant_private.guard_central_operation('all_debt_create');
create trigger mt_central_action_7 before insert on public.mt_repairs for each row execute function tenant_private.guard_central_operation('all_repair_create');
create trigger mt_central_action_8 before insert on public.mt_returns for each row execute function tenant_private.guard_central_operation('all_returns_create');
create trigger mt_central_action_9 before insert on public.mt_supplier_returns for each row execute function tenant_private.guard_central_operation('all_supplier_return_create');
create trigger mt_central_action_10 before insert on public.mt_repair_refunds for each row execute function tenant_private.guard_central_operation('all_repair_refund_create');
create trigger mt_central_action_11 before insert on public.mt_warranty_claims for each row execute function tenant_private.guard_central_operation('all_warranty_create');
create trigger mt_central_action_12 before insert on public.mt_coupons for each row execute function tenant_private.guard_central_operation('all_coupon_create');
create trigger mt_central_action_13 before insert on public.mt_accounting_adjustments for each row execute function tenant_private.guard_central_operation('all_finance_create');
create trigger mt_central_action_14 before update on public.mt_online_orders for each row execute function tenant_private.guard_central_operation('all_order_edit');
create trigger mt_central_action_15 before update on public.mt_warranty_claims for each row execute function tenant_private.guard_central_operation('all_warranty_edit');
create trigger mt_central_action_16 before update on public.mt_repairs for each row execute function tenant_private.guard_central_operation('all_repair_edit');
create trigger mt_central_action_17 before delete on public.mt_products for each row execute function tenant_private.guard_central_operation('all_catalog_delete');
create trigger mt_central_action_18 before delete on public.mt_customers for each row execute function tenant_private.guard_central_operation('all_customer_delete');
create trigger mt_central_action_19 before delete on public.mt_suppliers for each row execute function tenant_private.guard_central_operation('all_supplier_delete');
create trigger mt_central_action_20 before delete on public.mt_coupons for each row execute function tenant_private.guard_central_operation('all_coupon_delete');
create trigger mt_central_action_21 before insert on tenant_private.branch_transfers for each row execute function tenant_private.guard_central_operation('all_stock_transfer_create');
create trigger mt_central_action_22 before insert on tenant_private.stock_counts for each row execute function tenant_private.guard_central_operation('all_stock_count_create');
create trigger mt_central_action_23 before insert on tenant_private.price_quotes for each row execute function tenant_private.guard_central_operation('all_quote_create');
create trigger mt_central_action_24 before insert on tenant_private.staff_payroll for each row execute function tenant_private.guard_central_operation('all_payroll_create');
create trigger mt_central_action_25 before insert on tenant_private.standalone_debts for each row execute function tenant_private.guard_central_operation('all_standalone_create');
create trigger mt_central_action_26 before insert on tenant_private.branches for each row execute function tenant_private.guard_central_operation('all_branch_create');
create policy mt_central_read_catalog on public.mt_products as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_catalog_read'));
create policy mt_central_read_catalog on public.mt_product_prices as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_catalog_read'));
create policy mt_central_read_sales on public.mt_sales as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_sales_read'));
create policy mt_central_read_sales on public.mt_sale_lines as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_sales_read'));
create policy mt_central_read_sales on public.mt_mixed_sales as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_sales_read'));
create policy mt_central_read_sales on public.mt_mixed_tenders as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_sales_read'));
create policy mt_central_read_purchase on public.mt_purchases as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_purchase_read'));
create policy mt_central_read_purchase on public.mt_purchase_batches as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_purchase_read'));
create policy mt_central_read_purchase on public.mt_supplier_returns as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_purchase_read'));
create policy mt_central_read_purchase on public.mt_supplier_payments as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_purchase_read'));
create policy mt_central_read_supplier on public.mt_suppliers as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_supplier_read'));
create policy mt_central_read_customer on public.mt_customers as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_customer_read'));
create policy mt_central_read_debt on public.mt_debts as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_debt_read'));
create policy mt_central_read_debt on public.mt_installments as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_debt_read'));
create policy mt_central_read_debt on public.mt_debt_payments as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_debt_read'));
create policy mt_central_read_debt on public.mt_payment_allocations as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_debt_read'));
create policy mt_central_read_repair on public.mt_repairs as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_repair_read'));
create policy mt_central_read_repair on public.mt_repair_events as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_repair_read'));
create policy mt_central_read_repair on public.mt_repair_invoices as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_repair_read'));
create policy mt_central_read_repair on public.mt_repair_invoice_lines as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_repair_read'));
create policy mt_central_read_repair on public.mt_repair_refunds as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_repair_read'));
create policy mt_central_read_returns on public.mt_returns as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_returns_read'));
create policy mt_central_read_returns on public.mt_return_allocations as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_returns_read'));
create policy mt_central_read_order on public.mt_online_orders as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_order_read'));
create policy mt_central_read_warranty on public.mt_warranty_claims as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_warranty_read'));
create policy mt_central_read_warranty on public.mt_warranty_events as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_warranty_read'));
create policy mt_central_read_warranty on public.mt_warranty_parts as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_warranty_read'));
create policy mt_central_read_coupon on public.mt_coupons as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_coupon_read'));
create policy mt_central_read_finance on public.mt_accounting_adjustments as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_finance_read'));
create policy mt_central_read_finance on public.mt_indirect_tax_entries as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_finance_read'));
create policy mt_central_read_finance on public.mt_period_closes as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_finance_read'));
create policy mt_central_read_finance on public.mt_fx_rates as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_finance_read'));
create policy mt_central_read_finance on public.mt_cash_movements as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_finance_read'));
create policy mt_central_read_finance on public.mt_cash_receipts as restrictive for select to authenticated using (tenant_private.central_read_permitted(store_id,'all_finance_read'));
CREATE OR REPLACE FUNCTION public.mt_list_products(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_products
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_catalog_read') then return;end if;
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page size' using errcode='22023';end if;
 return query select * from public.mt_products where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_currency_products(p_store uuid, p_currency text, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS TABLE(store_id uuid, id uuid, sku text, name text, quantity bigint, unit_price_minor bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_catalog_read') then return;end if;
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 if (p_currency is not null and p_currency not in ('SYP','USD','EUR')) or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid query' using errcode='22023';end if;
 return query select p.store_id,p.id,p.sku,p.name,p.quantity,pp.price_minor from public.mt_products p left join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and (p_after is null or p.id>p_after) order by p.id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_customers(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_customers
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select q.* from (select * from tenant_private.receivable_customers(p_store,'',p_after,p_limit)) q where tenant_private.central_read_permitted(p_store,'all_customer_read') $function$;

CREATE OR REPLACE FUNCTION public.mt_list_sales(p_store uuid, p_before bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_sales
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_sales_read') then return;end if;
 if coalesce(tenant_private.member_role(p_store),'') not in ('owner','cashier') then raise exception 'Sales access required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 or (p_before is not null and p_before<=0) then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_sales where store_id=p_store and (p_before is null or number<p_before) order by number desc limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_repairs(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_repairs
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$ begin if not tenant_private.central_read_permitted(p_store,'all_repair_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_repairs where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_purchases(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_purchases
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$ begin if not tenant_private.central_read_permitted(p_store,'all_purchase_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_purchases where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_purchase_batches(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS TABLE(store_id uuid, id uuid, supplier_id uuid, currency text, reference text, total_minor bigint, paid_minor bigint, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_purchase_read') then return;end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select b.store_id,b.id,b.supplier_id,b.currency,b.reference,(b.total_minor-(select coalesce(sum(p.returned_units*p.unit_cost_minor),0)::bigint from public.mt_purchases p where p.store_id=b.store_id and p.batch_id=b.id)),(select coalesce(sum(p.paid_minor-p.refunded_minor),0)::bigint from public.mt_purchases p where p.store_id=b.store_id and p.batch_id=b.id),b.created_at from public.mt_purchase_batches b where b.store_id=p_store and (p_after is null or b.id>p_after) order by b.id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_suppliers(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_suppliers
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$ begin if not tenant_private.central_read_permitted(p_store,'all_supplier_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_suppliers where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_orders(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_online_orders
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_order_read') then return;end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_online_orders where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_coupons(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_coupons
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_coupon_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_coupons where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_returns(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_returns
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_returns_read') then return;end if;
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_returns where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_supplier_returns(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_supplier_returns
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_purchase_read') then return;end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_supplier_returns where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_debts(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_debts
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select q.* from (select * from tenant_private.receivable_debts(p_store,p_after,p_limit)) q where tenant_private.central_read_permitted(p_store,'all_debt_read') $function$;

CREATE OR REPLACE FUNCTION public.mt_list_accounting_adjustments(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_accounting_adjustments
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_finance_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_accounting_adjustments where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_indirect_tax_entries(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_indirect_tax_entries
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_finance_read') then return;end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_indirect_tax_entries where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end; $function$;

CREATE OR REPLACE FUNCTION public.mt_list_period_closes(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS TABLE(store_id uuid, id uuid, period_from date, period_to date, note text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_finance_read') then return;end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select c.store_id,c.id,c.period_from,c.period_to,c.note,c.created_at from public.mt_period_closes c where c.store_id=p_store and (p_after is null or c.id>p_after) order by c.id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_warranty_claims(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_warranty_claims
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$ begin if not tenant_private.central_read_permitted(p_store,'all_warranty_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_warranty_claims where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_warranty_parts(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_warranty_parts
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$ begin if not tenant_private.central_read_permitted(p_store,'all_warranty_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_warranty_parts where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_repair_invoices(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_repair_invoices
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$ begin if not tenant_private.central_read_permitted(p_store,'all_repair_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_repair_invoices where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_repair_refunds(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_repair_refunds
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$ begin if not tenant_private.central_read_permitted(p_store,'all_repair_read') then return;end if; if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_repair_refunds where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $function$;


-- A refunded subscription can be reactivated only after full documented repayment and fresh approval.
CREATE OR REPLACE FUNCTION tenant_private.offline_billing_record(s uuid, req uuid, i uuid, k text, orig uuid, amount integer, method text, proof text, day_value date, expected bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v tenant_private.offline_billing_invoices%rowtype;e tenant_private.offline_billing_payments%rowtype;o tenant_private.offline_billing_payments%rowtype;net bigint;returned bigint;
begin
 perform tenant_private.offline_billing_lock(s);
 if req is null or i is null or k is null or k not in ('payment','refund') or (k='refund')<>(orig is not null) or amount is null or amount not between 1 and 10000000 or method is null or method not in ('cash','bank_transfer','other_external') or proof is null or length(btrim(proof)) not between 1 and 160 or day_value is null or day_value>(now() at time zone 'Asia/Damascus')::date or expected is null then raise exception 'Invalid external receipt';end if;
 select * into e from tenant_private.offline_billing_payments where id=req;
 if found then
  if e.store_id<>s or e.invoice_id<>i or e.kind<>k or e.original_id is distinct from orig or e.amount_cents<>amount or e.channel<>method or e.document_ref<>btrim(proof) or e.occurred_on<>day_value or e.actor<>auth.uid() then raise exception 'Conflicting receipt request';end if;return req;
 end if;
 select * into strict v from tenant_private.offline_billing_invoices where store_id=s and id=i for update;
 if v.voided_at is not null or day_value<(v.created_at at time zone 'Asia/Damascus')::date then raise exception 'Void invoice or receipt predates issue';end if;
 net:=tenant_private.offline_invoice_balance(s,i);
 if net<>expected then raise exception 'Invoice balance changed; reload';end if;
 if k='payment' then
  if net+amount>v.amount_cents then raise exception 'Payment exceeds balance';end if;
 else
  select * into strict o from tenant_private.offline_billing_payments where store_id=s and invoice_id=i and id=orig and kind='payment';
  select coalesce(sum(amount_cents),0) into returned from tenant_private.offline_billing_payments where store_id=s and invoice_id=i and kind='refund' and original_id=orig;
  if amount+returned>o.amount_cents or amount>net or day_value<o.occurred_on then raise exception 'Refund exceeds original receipt';end if;
 end if;
 insert into tenant_private.offline_billing_payments(id,store_id,invoice_id,kind,original_id,amount_cents,channel,document_ref,occurred_on,actor) values(req,s,i,k,orig,amount,method,btrim(proof),day_value,auth.uid());
 if k='refund' and exists(select 1 from tenant_private.admin_manual_licenses where store_id=s and offline_invoice_id=i) then
  update public.saas_subscriptions set state=case when state in ('suspended','cancelled') then state else 'pending' end,valid_until=null,updated_at=now() where store_id=s;
  delete from tenant_private.admin_manual_licenses where store_id=s and offline_invoice_id=i;
 end if;
 return req;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_billing_action(s uuid, req uuid, i uuid, k text, proof text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v tenant_private.offline_billing_invoices%rowtype;e tenant_private.offline_billing_actions%rowtype;sub public.saas_subscriptions%rowtype;expiry timestamptz;net bigint;
begin
 perform tenant_private.offline_billing_lock(s);
 if req is null or i is null or k is null or k not in ('activate','void') or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid billing action';end if;
 select * into e from tenant_private.offline_billing_actions where id=req;
 if found then if e.store_id<>s or e.invoice_id<>i or e.kind<>k or e.reference<>btrim(proof) or e.actor<>auth.uid() then raise exception 'Conflicting action';end if;return req;end if;
 select * into strict v from tenant_private.offline_billing_invoices where store_id=s and id=i for update;
 if v.voided_at is not null then raise exception 'Invoice void';end if;
 net:=tenant_private.offline_invoice_balance(s,i);
 if k='void' then
  if net<>0 or exists(select 1 from tenant_private.admin_manual_licenses where store_id=s and offline_invoice_id=i and tenant_private.shared_licensed(s)) then raise exception 'Refund all external receipts before voiding';end if;
  delete from tenant_private.admin_manual_licenses where store_id=s and offline_invoice_id=i;
  update tenant_private.offline_billing_invoices set voided_at=now(),voided_by=auth.uid(),void_reference=btrim(proof) where id=i;
 else
  select * into strict sub from public.saas_subscriptions where store_id=s;
  expiry:=v.period_end::timestamp at time zone 'Asia/Damascus';
  if net<>v.amount_cents or now()<v.period_start::timestamp at time zone 'Asia/Damascus' or now()>=expiry or sub.plan_code<>v.plan_code or sub.state not in ('pending','trial','active','past_due') or (sub.valid_until is not null and sub.valid_until>expiry) or exists(select 1 from tenant_private.admin_manual_licenses where store_id=s and offline_invoice_id=i and tenant_private.shared_licensed(s)) or not exists(select 1 from public.saas_stores st join tenant_private.placements p on p.store_id=st.id join tenant_private.shards sh on sh.code=p.shard_code and sh.state='local' where st.id=s and st.state='provisioning' and st.project_ref is null and st.origin is null) then raise exception 'Paid current period and compatible subscription required';end if;
  update public.saas_subscriptions set state='active',valid_until=expiry,updated_at=now() where store_id=s;
  insert into tenant_private.admin_manual_licenses(store_id,plan_code,valid_until,request_id,actor,reference,offline_invoice_id) values(s,v.plan_code,expiry,req,auth.uid(),btrim(proof),i)
  on conflict(store_id) do update set plan_code=excluded.plan_code,valid_until=excluded.valid_until,request_id=excluded.request_id,actor=excluded.actor,reference=excluded.reference,offline_invoice_id=excluded.offline_invoice_id,issued_at=now();
 end if;
 insert into tenant_private.offline_billing_actions(id,store_id,invoice_id,kind,reference,actor) values(req,s,i,k,btrim(proof),auth.uid());return req;
end $function$;

create function tenant_private.admin_commercial_register(m date,state_filter text,off integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;day_now date:=(now() at time zone 'Asia/Damascus')::date;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if m is null or extract(day from m)<>1 or m<date '2020-01-01' or m>day_now+interval '2 years' or state_filter is null or state_filter not in ('all','unpaid','partial','paid','refunded','void','overdue','paid_unlicensed') or off is null or off not between 0 and 100000 then raise exception 'Invalid billing register filter';end if;
 with payments as (
  select p.store_id,p.invoice_id,coalesce(sum(p.amount_cents) filter(where kind='payment'),0)::bigint collected,coalesce(sum(p.amount_cents) filter(where kind='refund'),0)::bigint refunded
  from tenant_private.offline_billing_payments p join tenant_private.offline_billing_invoices i on i.store_id=p.store_id and i.id=p.invoice_id where i.period_start=m group by p.store_id,p.invoice_id
 ), basis as (
  select i.id,i.store_id,i.store_name,i.plan_name,i.period_start,i.period_end,i.amount_cents,coalesce(p.collected,0) collected,coalesce(p.refunded,0) refunded,coalesce(p.collected,0)-coalesce(p.refunded,0) net,i.voided_at,
  exists(select 1 from tenant_private.admin_manual_licenses l where l.store_id=i.store_id and l.offline_invoice_id=i.id and tenant_private.shared_licensed(i.store_id)) licensed
  from tenant_private.offline_billing_invoices i left join payments p on p.store_id=i.store_id and p.invoice_id=i.id where i.period_start=m
 ), classified as (
  select b.*,case when voided_at is not null then 'void' when net=amount_cents then 'paid' when net>0 then 'partial' when refunded>0 then 'refunded' else 'unpaid' end state,case when voided_at is null then amount_cents-net else 0 end outstanding from basis b
 ), marked as (
  select c.*,period_end<=day_now and outstanding>0 overdue,state='paid' and period_start<=day_now and period_end>day_now and not licensed paid_unlicensed from classified c
 ), filtered as (
  select * from marked where state_filter='all' or state=state_filter or (state_filter='overdue' and overdue) or (state_filter='paid_unlicensed' and paid_unlicensed)
 ), page as (select * from filtered order by store_name,id offset off limit 51)
 select jsonb_build_object('month',m,'currency','USD','count',(select count(*) from filtered),'summary',(select jsonb_build_object('invoices',count(*),'billed',coalesce(sum(amount_cents) filter(where state<>'void'),0)::text,'collected',coalesce(sum(collected),0)::text,'refunded',coalesce(sum(refunded),0)::text,'net',coalesce(sum(net),0)::text,'outstanding',coalesce(sum(outstanding),0)::text,'overdue',count(*) filter(where overdue),'paid_unlicensed',count(*) filter(where paid_unlicensed)) from marked),'rows',coalesce((select jsonb_agg(jsonb_build_object('id',id,'store_id',store_id,'store_name',store_name,'plan_name',plan_name,'period_start',period_start,'period_end',period_end,'amount_cents',amount_cents,'collected',collected::text,'refunded',refunded::text,'net',net::text,'outstanding',outstanding::text,'state',state,'licensed',licensed,'overdue',overdue,'paid_unlicensed',paid_unlicensed) order by store_name,id) from page),'[]'::jsonb)) into result;
 return result||jsonb_build_object('more',jsonb_array_length(result->'rows')>50,'rows',case when jsonb_array_length(result->'rows')>50 then result->'rows'-50 else result->'rows' end);
end $$;
create function public.mt_admin_commercial_register(m date,state_filter text,off integer) returns jsonb language sql stable set search_path='' as $$select tenant_private.admin_commercial_register(m,state_filter,off)$$;
revoke all on function tenant_private.admin_commercial_register(date,text,integer),public.mt_admin_commercial_register(date,text,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.admin_commercial_register(date,text,integer),public.mt_admin_commercial_register(date,text,integer) to authenticated;
commit;
