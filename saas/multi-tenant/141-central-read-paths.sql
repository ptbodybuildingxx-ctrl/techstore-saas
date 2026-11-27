-- 141: explicit alternate read paths; navigation and account metadata remain available.
begin;
create function tenant_private.central_read_rejected() returns jsonb language plpgsql stable set search_path='' as $$
begin raise exception 'Central record read restriction' using errcode='42501';end $$;
revoke all on function tenant_private.central_read_rejected() from public,anon,authenticated,service_role;
grant execute on function tenant_private.central_read_rejected() to authenticated;
create or replace function tenant_private.member_central_actions(s uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin if tenant_private.member_role(s) is null then raise exception 'Tenant access required' using errcode='42501';end if;return to_jsonb(tenant_private.central_effective_denials(s));end $$;
CREATE OR REPLACE FUNCTION tenant_private.procurement_access(s uuid, u uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target uuid:=coalesce(u,auth.uid());g tenant_private.procurement_grants%rowtype;r text;sr boolean;pr boolean;
begin
 r:=tenant_private.member_role(s);
 if r is null or (target<>auth.uid() and r<>'owner') then raise exception 'Access denied' using errcode='42501';end if;
 if target=auth.uid() and r='owner' then
 sr:=tenant_private.central_read_permitted(s,'all_supplier_read');pr:=sr and tenant_private.central_read_permitted(s,'all_purchase_read') and tenant_private.central_read_permitted(s,'all_catalog_read');
 return jsonb_build_object('read',sr or pr,'supplier_read',sr,'purchase_read',pr,'supplier',sr,'receive',sr and pr,'licensed',tenant_private.shared_licensed(s),'branch',null);end if;
 select * into g from tenant_private.procurement_grants where store_id=s and user_id=target and exists(select 1 from tenant_private.members m where m.store_id=s and m.user_id=target and m.active and m.role='stock');
 sr:=coalesce(g.read_allowed,false) and not exists(select 1 from tenant_private.staff_all_denials(s,target) where action in ('procurement_read','supplier_read'));
 pr:=coalesce(g.read_allowed,false) and not exists(select 1 from tenant_private.staff_all_denials(s,target) where action in ('procurement_read','purchase_read'));
 sr:=sr and tenant_private.central_read_permitted(s,'all_supplier_read');pr:=pr and sr and tenant_private.central_read_permitted(s,'all_purchase_read') and tenant_private.central_read_permitted(s,'all_catalog_read');
 return jsonb_build_object('read',sr or pr,'supplier_read',sr,'purchase_read',pr,'supplier',sr and coalesce(g.manage_suppliers,false) and not exists(select 1 from tenant_private.staff_all_denials(s,target) where action='supplier_write'),'receive',sr and pr and coalesce(g.receive_credit,false) and not exists(select 1 from tenant_private.staff_all_denials(s,target) where action in ('purchase_write','catalog_read','stock_adjust')),'licensed',tenant_private.shared_licensed(s),'branch',case when target=auth.uid() then tenant_private.current_branch_scope(s) end);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.branch_overview(p_store uuid, p_product uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;role_now text:=tenant_private.member_role(p_store);b uuid:=tenant_private.current_branch_scope(p_store);
begin
 if not coalesce(role_now in ('owner','stock','cashier'),false) then raise exception 'Branch access denied' using errcode='42501';end if;
 if p_product is not null and (not tenant_private.central_read_permitted(p_store,'all_catalog_read') or not tenant_private.staff_action_allowed(p_store,'catalog_read')) then raise exception 'Catalog read denied' using errcode='42501';end if;
 select jsonb_build_object('branches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by name) from tenant_private.branches where store_id=p_store and (b is null or id=b)),'[]'::jsonb),'stock',case when p_product is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('branch_id',branch_id,'units',units)) from tenant_private.branch_stock where store_id=p_store and product_id=p_product and (b is null or branch_id=b)),'[]'::jsonb) end,'main',case when p_product is null or b is not null then null else (select quantity-tenant_private.branch_allocated(p_store,p_product) from public.mt_products where store_id=p_store and id=p_product) end,'transfers',case when p_product is null or role_now='cashier' or not tenant_private.staff_action_allowed(p_store,'stock_history_read') then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id desc) from (select request_id,source,target,units,created_at from tenant_private.branch_transfers where store_id=p_store and product_id=p_product and (b is null or source=b or target=b) order by created_at desc,request_id desc limit 50)x),'[]'::jsonb) end) into r;return r;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_work_alerts(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare role_now text:=tenant_private.member_role(p_store);r jsonb:='{}'::jsonb;
begin
 if role_now is null then raise exception 'Tenant access denied' using errcode='42501';end if;
 if not tenant_private.staff_action_allowed(p_store,'notifications_read') then return r;end if;
 if role_now in ('owner','stock') and tenant_private.staff_action_allowed(p_store,'catalog_read') then r:=r||jsonb_build_object('low_stock',tenant_private.staff_low_stock_count(p_store));end if;
 if role_now in ('owner','tech') and tenant_private.staff_action_allowed(p_store,'repair_read') then r:=r||jsonb_build_object('repairs_ready',(select count(*) from public.mt_repairs where store_id=p_store and state='ready'),'repairs_received',(select count(*) from public.mt_repairs where store_id=p_store and state='received'));end if;
 if role_now='owner' then r:=r||jsonb_build_object('orders_pending',(select count(*) from public.mt_online_orders where store_id=p_store and state='pending'),'installments_overdue',(select count(*) from public.mt_installments where store_id=p_store and due_date<(now() at time zone 'Asia/Damascus')::date and paid_minor+waived_minor<amount_minor));end if;
 if not tenant_private.central_read_permitted(p_store,'all_catalog_read') then r:=r-'low_stock';end if;
 if not tenant_private.central_read_permitted(p_store,'all_repair_read') then r:=r-'repairs_ready'-'repairs_received';end if;
 if not tenant_private.central_read_permitted(p_store,'all_order_read') then r:=r-'orders_pending';end if;
 if not tenant_private.central_read_permitted(p_store,'all_debt_read') then r:=r-'installments_overdue';end if;
 return r;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_list_fx_rates(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS SETOF mt_fx_rates
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not tenant_private.central_read_permitted(p_store,'all_finance_read') then return;end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_fx_rates where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_fifo_report(p_store uuid, p_product uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.branch_fifo_report(p_store,p_product)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_catalog_item(p_store uuid, p_product uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.catalog_item(p_store,p_product)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_count_history(p_store uuid, p_branch uuid, p_offset integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.count_history(p_store,p_branch,p_offset)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_count_snapshot(p_store uuid, p_branch uuid, p_ids uuid[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.count_snapshot(p_store,p_branch,p_ids)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_pos_quote(p_store uuid, p_branch uuid, p_token uuid, p_currency text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.pos_quote(p_store,p_branch,p_token,p_currency,p_lines)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_pos_scan(p_store uuid, p_currency text, p_branch uuid, p_sku text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.pos_scan(p_store,p_currency,p_branch,p_sku)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_product_original_list(p_store uuid, p_product uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.product_original_list(p_store,p_product)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_product_tier_list(p_store uuid, p_product uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.product_tier_list(p_store,p_product)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_search_products(p_store uuid, p_currency text, p_query text, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50, p_low boolean DEFAULT false)
 RETURNS TABLE(store_id uuid, id uuid, sku text, name text, quantity bigint, unit_price_minor bigint, specs jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select q.* from (select * from tenant_private.scoped_products(p_store,p_currency,p_query,p_after,p_limit,p_low)) q where tenant_private.central_read_permitted(p_store,'all_catalog_read') $function$;

CREATE OR REPLACE FUNCTION public.mt_stock_history(p_store uuid, p_product uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS TABLE(store_id uuid, request_id uuid, product_id uuid, delta bigint, balance bigint, created_at timestamp with time zone, kind text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not (tenant_private.central_read_permitted(p_store,'all_catalog_read')) then return;end if;
 if not coalesce(tenant_private.member_role(p_store) in ('owner','stock'),false) then raise exception 'Stock access denied' using errcode='42501';end if;
 if p_product is null or p_limit is null or p_limit not between 1 and 100 or (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page' using errcode='22023';end if;
 return query select e.store_id,e.request_id,e.product_id,e.delta,e.balance,e.created_at,case when e.sale_id is not null then 'sale' when e.return_id is not null then 'return' when e.supplier_return_id is not null then 'supplier_return' when e.delta>0 then 'intake' else 'other_out' end from public.mt_stock_events e where e.store_id=p_store and e.product_id=p_product and (p_before is null or (e.created_at,e.request_id)<(p_before,p_before_id)) order by e.created_at desc,e.request_id desc limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_sales_report(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_sales_read') then (select tenant_private.branch_sales_report(p_store,p_from,p_to)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sale_invoice_read(p_store uuid, p_sale uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_sales_read') then (select tenant_private.sale_invoice_read(p_store,p_sale)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sale_margin(p_store uuid, p_sale uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_sales_read') and tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.sale_margin(p_store,p_sale)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sale_receipt_lines(p_store uuid, p_sale uuid)
 RETURNS SETOF mt_sale_lines
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select q.* from (select * from public.mt_sale_lines where store_id=p_store and sale_id=p_sale and tenant_private.staff_action_allowed(p_store,'receipt_read') order by product_id limit 100) q where tenant_private.central_read_permitted(p_store,'all_sales_read') $function$;

CREATE OR REPLACE FUNCTION public.mt_sale_tenders(p_store uuid, p_sale uuid)
 RETURNS SETOF mt_mixed_tenders
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select q.* from (select * from public.mt_mixed_tenders where store_id=p_store and sale_id=p_sale order by currency) q where tenant_private.central_read_permitted(p_store,'all_sales_read') $function$;

CREATE OR REPLACE FUNCTION public.mt_quote_list(p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_sales_read') then (select tenant_private.quote_list(p_store,p_before,p_before_id)) else '[]'::jsonb end $function$;

CREATE OR REPLACE FUNCTION public.mt_quote_read(p_store uuid, p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_sales_read') then (select tenant_private.quote_read(p_store,p_id)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_procurement_aging(p_store uuid, p_currency text, p_branch uuid, p_all boolean, p_asof date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_purchase_read') and tenant_private.central_read_permitted(p_store,'all_supplier_read') then (select tenant_private.procurement_aging(p_store,p_currency,p_branch,p_all,p_asof)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_supplier_statement(p_store uuid, p_supplier uuid, p_currency text, p_all boolean, p_branch uuid, p_from date, p_to date, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_purchase_read') and tenant_private.central_read_permitted(p_store,'all_supplier_read') then (select tenant_private.supplier_statement(p_store,p_supplier,p_currency,p_all,p_branch,p_from,p_to,p_offset)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_local_customer_price_list(p_store uuid, p_customer uuid, p_product uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_customer_read') and tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.local_customer_price_list(p_store,p_customer,p_product)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_local_membership_directory(p_store uuid, p_query text, p_after uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_customer_read') then (select tenant_private.local_membership_directory(p_store,p_query,p_after)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_local_membership_quote(p_store uuid, p_branch uuid, p_customer uuid, p_currency text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_customer_read') and tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.local_membership_quote(p_store,p_branch,p_customer,p_currency,p_lines)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_local_membership_snapshot(p_store uuid, p_branch uuid, p_currency text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_customer_read') and tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.local_membership_snapshot(p_store,p_branch,p_currency)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_membership_buyer_directory(p_store uuid, p_query text, p_after uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_customer_read') then (select tenant_private.membership_buyer_directory(p_store,p_query,p_after)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_search_customers(p_store uuid, p_query text, p_after uuid, p_limit integer)
 RETURNS SETOF mt_customers
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select q.* from (select * from tenant_private.receivable_customers(p_store,p_query,p_after,p_limit)) q where tenant_private.central_read_permitted(p_store,'all_customer_read') $function$;

CREATE OR REPLACE FUNCTION public.mt_debt_schedule(p_store uuid, p_debt uuid)
 RETURNS SETOF mt_installments
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select q.* from (select * from tenant_private.receivable_schedule(p_store,p_debt)) q where tenant_private.central_read_permitted(p_store,'all_debt_read') $function$;

CREATE OR REPLACE FUNCTION public.mt_receivable_register(p_store uuid, p_mode text, p_query text, p_customer uuid, p_currency text, p_status text, p_offset integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_debt_read') and tenant_private.central_read_permitted(p_store,'all_customer_read') then (select tenant_private.receivable_register(p_store,p_mode,p_query,p_customer,p_currency,p_status,p_offset)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_standalone_details(p_store uuid, p_debt uuid, p_offset integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_debt_read') and tenant_private.central_read_permitted(p_store,'all_customer_read') then (select tenant_private.standalone_details(p_store,p_debt,p_offset)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_standalone_list(p_store uuid, p_query text, p_customer uuid, p_direction text, p_offset integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_debt_read') and tenant_private.central_read_permitted(p_store,'all_customer_read') then (select tenant_private.standalone_list(p_store,p_query,p_customer,p_direction,p_offset)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_repair_case_review(s uuid, r uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(s,'all_repair_read') then (select tenant_private.repair_case_review(s,r)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_repair_receipt_lines(p_store uuid, p_invoice uuid)
 RETURNS SETOF mt_repair_invoice_lines
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select q.* from (select * from public.mt_repair_invoice_lines where store_id=p_store and invoice_id=p_invoice order by product_id limit 50) q where tenant_private.central_read_permitted(p_store,'all_repair_read') $function$;

CREATE OR REPLACE FUNCTION public.mt_repair_task_list(p_store uuid, p_repair uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_repair_read') then (select tenant_private.repair_task_list(p_store,p_repair)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_repair_evidence_list(p_store uuid, p_repair uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_repair_read') then (select tenant_private.repair_evidence_list(p_store,p_repair)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_returnable_lines(p_store uuid, p_sale uuid)
 RETURNS TABLE(product_id uuid, sku text, product_name text, units bigint, returned_units bigint, unit_price_minor bigint, currency text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin if not (tenant_private.central_read_permitted(p_store,'all_returns_read') and tenant_private.central_read_permitted(p_store,'all_sales_read')) then return;end if;
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return query select l.product_id,l.sku,l.product_name,l.units,coalesce((select sum(r.units)::bigint from public.mt_returns r where r.store_id=l.store_id and r.sale_id=l.sale_id and r.product_id=l.product_id),0),l.unit_price_minor,s.currency
 from public.mt_sale_lines l join public.mt_sales s on s.store_id=l.store_id and s.id=l.sale_id where l.store_id=p_store and l.sale_id=p_sale order by l.product_id;
end $function$;

CREATE OR REPLACE FUNCTION public.mt_shop_order_details(s uuid, o uuid, ch text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(s,'all_order_read') then (select tenant_private.shop_order_details(s,o,ch)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_guest_list(p_store uuid, p_after uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_order_read') then (select tenant_private.guest_list(p_store,p_after)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_repair_warranty_register(s uuid, q text, filter_state text, off integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(s,'all_warranty_read') and tenant_private.central_read_permitted(s,'all_repair_read') then (select tenant_private.repair_warranty_register(s,q,filter_state,off)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sale_claims(p_store uuid, p_offset integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_warranty_read') and tenant_private.central_read_permitted(p_store,'all_sales_read') then (select tenant_private.sale_claim_list(p_store,false,p_offset)) else '[]'::jsonb end $function$;

CREATE OR REPLACE FUNCTION public.mt_sale_warranty_register(p_store uuid, p_query text, p_state text, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_warranty_read') and tenant_private.central_read_permitted(p_store,'all_sales_read') then (select tenant_private.sale_warranty_register(p_store,p_query,p_state,p_offset)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_bank_overview(p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.bank_overview(p_store,p_before,p_before_id)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_account_balances(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.branch_account_balances(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_expense_list(p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.branch_expense_list(p_store,p_before,p_before_id)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_journal_projection(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.branch_journal_projection(p_store,p_from,p_to)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_opening_latest(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.branch_opening_latest(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_opening_review(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.branch_opening_review(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_operating_result(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.branch_operating_result(p_store,p_from,p_to)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_result_review(s uuid, d1 date, d2 date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(s,'all_finance_read') then (select tenant_private.branch_result_review(s,d1,d2)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_treasury_read(p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.branch_treasury_read(p_store,p_before,p_before_id)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_branch_voucher_list(p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.branch_voucher_list(p_store,p_before,p_before_id)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_cash_overview(p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.cash_overview(p_store,p_before,p_before_id,p_limit)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_cash_reconciliation(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.cash_reconciliation(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_cash_report(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.cash_report(p_store,p_from,p_to)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_financial_reconciliation(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.financial_reconciliation(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_indirect_tax_quote(p_store uuid, p_kind text, p_source uuid, p_rate integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.indirect_tax_quote(p_store,p_kind,p_source,p_rate)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_indirect_tax_summary(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.indirect_tax_summary(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_management_statements(p_store uuid, p_from date, p_to date, p_currency text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.management_statements(p_store,p_from,p_to,p_currency)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_operating_report(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.operating_report(p_store,p_from,p_to)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_period_snapshot(p_store uuid, p_close uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select jsonb_build_object('trial_balance',c.trial_balance,'operating_report',c.operating_report,'cash_report',c.cash_report,'period_from',c.period_from,'period_to',c.period_to) from public.mt_period_closes c where c.store_id=p_store and c.id=p_close) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sy_tax_credit_review(s uuid, purchase uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(s,'all_finance_read') and tenant_private.central_read_permitted(s,'all_purchase_read') then (select tenant_private.sy_tax_credit_review(s,purchase)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sy_tax_mixed_quote(p_store uuid, p_kind text, p_source uuid, p_parts jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') and tenant_private.central_read_permitted(p_store,'all_sales_read') and tenant_private.central_read_permitted(p_store,'all_repair_read') and tenant_private.central_read_permitted(p_store,'all_returns_read') then (select tenant_private.sy_tax_mixed_quote(p_store,p_kind,p_source,p_parts)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sy_tax_output_preview(s uuid, k text, source uuid, profile uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(s,'all_finance_read') and tenant_private.central_read_permitted(s,'all_sales_read') and tenant_private.central_read_permitted(s,'all_repair_read') and tenant_private.central_read_permitted(s,'all_returns_read') then (select tenant_private.sy_tax_output_preview(s,k,source,profile)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sy_tax_profile_list(s uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(s,'all_finance_read') then (select tenant_private.sy_tax_profile_list(s)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sy_tax_queue(s uuid, d1 date, d2 date, filter_kind text, missing_only boolean, off integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(s,'all_finance_read') and tenant_private.central_read_permitted(s,'all_sales_read') and tenant_private.central_read_permitted(s,'all_repair_read') and tenant_private.central_read_permitted(s,'all_purchase_read') and tenant_private.central_read_permitted(s,'all_returns_read') then (select tenant_private.sy_tax_queue(s,d1,d2,filter_kind,missing_only,off)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_sy_tax_settlement_review(p_store uuid, p_kind text, p_currency text, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.sy_tax_settlement_review(p_store,p_kind,p_currency,p_from,p_to)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_trial_balance(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_finance_read') then (select tenant_private.trial_balance(p_store,p_from,p_to)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_tradein_list(p_store uuid, p_after uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_customer_read') and tenant_private.central_read_permitted(p_store,'all_purchase_read') and tenant_private.central_read_permitted(p_store,'all_sales_read') then (select tenant_private.tradein_list(p_store,p_after)) else '[]'::jsonb end $function$;

CREATE OR REPLACE FUNCTION public.mt_tradein_result(p_store uuid, p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_customer_read') and tenant_private.central_read_permitted(p_store,'all_purchase_read') and tenant_private.central_read_permitted(p_store,'all_sales_read') then (select tenant_private.tradein_result(p_store,p_id)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_review_queue(p_store uuid, p_after uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.review_queue(p_store,p_after)) else '[]'::jsonb end $function$;

CREATE OR REPLACE FUNCTION public.mt_business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') and tenant_private.central_read_permitted(p_store,'all_sales_read') and tenant_private.central_read_permitted(p_store,'all_purchase_read') and tenant_private.central_read_permitted(p_store,'all_customer_read') and tenant_private.central_read_permitted(p_store,'all_debt_read') and tenant_private.central_read_permitted(p_store,'all_repair_read') and tenant_private.central_read_permitted(p_store,'all_returns_read') and tenant_private.central_read_permitted(p_store,'all_order_read') and tenant_private.central_read_permitted(p_store,'all_warranty_read') and tenant_private.central_read_permitted(p_store,'all_finance_read') and tenant_private.central_read_permitted(p_store,'all_supplier_read') and tenant_private.central_read_permitted(p_store,'all_coupon_read') then (select tenant_private.business_export(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_loyalty_settings(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_coupon_read') then (select tenant_private.loyalty_settings_read(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_spend_loyalty_read(p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select case when tenant_private.central_read_permitted(p_store,'all_coupon_read') then (select tenant_private.spend_loyalty_read(p_store)) else tenant_private.central_read_rejected() end $function$;

CREATE OR REPLACE FUNCTION public.mt_receipt_snapshot(p_store uuid, p_kind text, p_document uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$select case when tenant_private.central_read_permitted(p_store,case when p_kind='repair' then 'all_repair_read' else 'all_sales_read' end) then tenant_private.receipt_snapshot(p_store,p_kind,p_document) else tenant_private.central_read_rejected() end$function$;

CREATE OR REPLACE FUNCTION public.mt_procurement_list(p_store uuid, p_kind text, p_after uuid, p_limit integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$select case when (p_kind='suppliers' and tenant_private.central_read_permitted(p_store,'all_supplier_read')) or (p_kind in ('purchases','batches','returns') and tenant_private.central_read_permitted(p_store,'all_purchase_read') and tenant_private.central_read_permitted(p_store,'all_supplier_read') and tenant_private.central_read_permitted(p_store,'all_catalog_read')) then tenant_private.procurement_list(p_store,p_kind,p_after,p_limit) else tenant_private.central_read_rejected() end$function$;

CREATE OR REPLACE FUNCTION public.mt_storefront_status(p_store uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$select case when tenant_private.central_read_permitted(p_store,'all_catalog_read') then (select tenant_private.storefront_status(p_store,p_after,p_limit)) else tenant_private.central_read_rejected() end$function$;

commit;
