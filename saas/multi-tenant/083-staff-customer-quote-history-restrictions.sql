-- Preserve role, branch and licensing checks. Restrict previously permitted operations only.
begin;
alter table tenant_private.staff_denials drop constraint staff_denials_action_check;
alter table tenant_private.staff_denials add constraint staff_denials_action_check check(action in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish','repair_create','product_price_edit','customer_create','debt_payment','quote_create'));
create or replace function tenant_private.staff_permission_set(p_store uuid,p_user uuid,p_action text,p_allowed boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_allowed is null or p_action is null or p_action not in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish','repair_create','product_price_edit','customer_create','debt_payment','quote_create') or not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role<>'owner') then raise exception 'Invalid permission' using errcode='22023';end if;
 if p_allowed then delete from tenant_private.staff_denials where store_id=p_store and user_id=p_user and action=p_action;
 else insert into tenant_private.staff_denials(store_id,user_id,action,actor) values(p_store,p_user,p_action,auth.uid()) on conflict do nothing;end if;return p_allowed;
end $$;

-- The existing guard is already private and revoked. Deposits are part of an atomic credit sale,
-- not independent debt payments. Do not cause an otherwise allowed credit sale to fail.
create trigger mt_staff_deny_customer before insert on public.mt_customers
 for each row execute function tenant_private.guard_staff_action('customer_create');
create trigger mt_staff_deny_debt_payment before insert on public.mt_debt_payments
 for each row when (not new.is_deposit) execute function tenant_private.guard_staff_action('debt_payment');
create trigger mt_staff_deny_quote before insert on tenant_private.price_quotes
 for each row execute function tenant_private.guard_staff_action('quote_create');
-- The security-definer branch overview had an alternate route to transfer history.
create or replace function tenant_private.branch_overview(p_store uuid,p_product uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;role_now text:=tenant_private.member_role(p_store);b uuid:=tenant_private.current_branch_scope(p_store);
begin
 if not coalesce(role_now in ('owner','stock','cashier'),false) then raise exception 'Branch access denied' using errcode='42501';end if;
 if p_product is not null and not tenant_private.staff_action_allowed(p_store,'catalog_read') then raise exception 'Catalog read denied' using errcode='42501';end if;
 select jsonb_build_object('branches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by name) from tenant_private.branches where store_id=p_store and (b is null or id=b)),'[]'::jsonb),'stock',case when p_product is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('branch_id',branch_id,'units',units)) from tenant_private.branch_stock where store_id=p_store and product_id=p_product and (b is null or branch_id=b)),'[]'::jsonb) end,'main',case when p_product is null or b is not null then null else (select quantity-tenant_private.branch_allocated(p_store,p_product) from public.mt_products where store_id=p_store and id=p_product) end,'transfers',case when p_product is null or role_now='cashier' or not tenant_private.staff_action_allowed(p_store,'stock_history_read') then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id desc) from (select request_id,source,target,units,created_at from tenant_private.branch_transfers where store_id=p_store and product_id=p_product and (b is null or source=b or target=b) order by created_at desc,request_id desc limit 50)x),'[]'::jsonb) end) into r;return r;
end $$;

commit;
