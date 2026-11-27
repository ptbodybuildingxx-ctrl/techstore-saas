-- 147: transactional revision stamps for stable offline captures and scoped replay receipts.
-- No business data is deleted or updated. Existing receipt details become status-only
-- until the account reconciles them explicitly; new receipts bind current access scope.
begin;
set local lock_timeout='5s';

create table tenant_private.offline_snapshot_revisions(
 store_id uuid primary key,
 revision uuid not null,
 last_tx text not null,
 changed_at timestamptz not null default now()
);
alter table tenant_private.offline_snapshot_revisions enable row level security;
revoke all on tenant_private.offline_snapshot_revisions from public,anon,authenticated,service_role;

create function tenant_private.offline_snapshot_bump(s uuid) returns void
language plpgsql security definer set search_path='' as $$
declare tx text:=pg_current_xact_id()::text;
begin
 if s is null then return;end if;
 -- One revision per store per modifying transaction. Rollbacks cannot change a
 -- visible revision. This serializes the small revision row, not the capture.
 if exists(select 1 from tenant_private.offline_snapshot_revisions r where r.store_id=s and r.last_tx=tx) then return;end if;
 insert into tenant_private.offline_snapshot_revisions as r(store_id,revision,last_tx,changed_at)
 values(s,gen_random_uuid(),tx,clock_timestamp())
 on conflict(store_id) do update set revision=excluded.revision,last_tx=excluded.last_tx,changed_at=excluded.changed_at
 where r.last_tx is distinct from excluded.last_tx;
end $$;

create function tenant_private.offline_snapshot_touch() returns trigger
language plpgsql security definer set search_path='' as $$
declare previous_store uuid;next_store uuid;
begin
 if tg_op<>'INSERT' then
  if tg_nargs=1 and tg_argv[0]='id' then previous_store:=old.id;else previous_store:=old.store_id;end if;
 end if;
 if tg_op<>'DELETE' then
  if tg_nargs=1 and tg_argv[0]='id' then next_store:=new.id;else next_store:=new.store_id;end if;
 end if;
 -- Deterministic order if a maintenance operation moves a row between stores.
 if previous_store is not null and next_store is not null and previous_store<>next_store then
  perform tenant_private.offline_snapshot_bump(least(previous_store,next_store));
  perform tenant_private.offline_snapshot_bump(greatest(previous_store,next_store));
 else perform tenant_private.offline_snapshot_bump(coalesce(next_store,previous_store));end if;
 return null;
end $$;
revoke all on function tenant_private.offline_snapshot_bump(uuid),tenant_private.offline_snapshot_touch() from public,anon,authenticated,service_role;
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_accounting_adjustments for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_cash_movements for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_cash_receipts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_coupons for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_customers for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_debt_payments for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_debts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_fx_rates for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_indirect_tax_entries for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_installments for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_mixed_sales for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_mixed_tenders for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_online_orders for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_payment_allocations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_period_closes for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_product_prices for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_products for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_purchase_batches for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_purchases for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_repair_events for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_repair_invoice_lines for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_repair_invoices for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_repair_refunds for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_repairs for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_return_allocations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_returns for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_sale_lines for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_sales for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_stock_events for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_supplier_payments for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_supplier_returns for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_suppliers for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_warranty_claims for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_warranty_events for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.mt_warranty_parts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.saas_memberships for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.saas_subscriptions for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.admin_manual_licenses for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.admin_member_holds for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.admin_store_action_policy for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.admin_store_controls for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.bank_accounts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.bank_transfers for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_batches for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_cash_accounts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_cash_attribution for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_cash_transfers for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_expense_allocations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_fifo_enabled for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_fifo_lots for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_fifo_moves for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_opening_anchors for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_opening_checks for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_purchases for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_repairs for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_result_approvals for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_sales for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_stock for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_transfers for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_treasury_enabled for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branch_vouchers for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.branches for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.buyer_price_terms for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.buyer_product_prices for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.cash_balances for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.cashier_branch_scope for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.cost_intakes for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.cost_postings for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.customer_profile_edits for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.guest_orders for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.guest_settings for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.local_customer_prices for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.local_membership_sales for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.local_membership_terms for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.loyalty_settings for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.marketing_campaigns for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.members for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.membership_directory for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.membership_rates for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.offline_devices for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.offline_original_deletions for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.opening_debt_equity for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.order_discounts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.order_reservations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.pos_loyalty_sales for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.price_quotes for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.procurement_grants for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.procurement_requests for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.product_originals for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.product_tier_prices for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.receipt_settings for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.receipt_snapshots for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.receivable_grants for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.repair_assignments for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.repair_estimates for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.repair_paper_decisions for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.repair_tasks for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.return_cost_postings for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sale_currencies for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sale_invoice_details for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sale_warranty_claims for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sale_warranty_events for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sales_settings for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.shop_order_confirmations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.shop_order_history for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.shop_order_items for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.spend_checkout for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.spend_loyalty_policy for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.spend_loyalty_sales for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.spend_pos_redemptions for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_advance_offsets for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_advances for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_branch_scope for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_denials for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_payroll for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_payroll_adjustments for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_payroll_disbursements for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_payroll_finalizations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_payroll_reversals for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_profiles for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_shifts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.staff_terms for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.standalone_debt_payments for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.standalone_debts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.standalone_installments for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.standalone_payment_allocations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.stock_consumptions for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.stock_count_cancellations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.stock_count_lines for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.stock_counts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.stock_layers for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.storefront_products for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.storefronts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_credit_allocations for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_credit_events for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_filing_evidence for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_input_events for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_inventory_moves for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_inventory_parts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_inventory_releases for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_inventory_returns for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_mixed_parts for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_output for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_profiles for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.sy_tax_supplier_return_actions for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.tradein_estimates for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on tenant_private.tradein_settlements for each row execute function tenant_private.offline_snapshot_touch();
create trigger mt_offline_snapshot_revision after insert or update or delete on public.saas_stores for each row execute function tenant_private.offline_snapshot_touch('id');

create function tenant_private.offline_access_digest(s uuid) returns text
language sql stable security definer set search_path='' as $$
 select tenant_private.finance_review_digest(jsonb_build_object(
 'actor',auth.uid(),'role',tenant_private.member_role(s),'branch',tenant_private.current_branch_scope(s),
 'aal',auth.jwt()->>'aal','licensed',tenant_private.shared_licensed(s),'sell',tenant_private.can_sell(s),
 'central',to_jsonb(tenant_private.central_effective_denials(s)),
 'staff',coalesce((select jsonb_agg(distinct d.action order by d.action) from tenant_private.staff_all_denials(s,auth.uid()) d),'[]'::jsonb),
 'receivables',case when tenant_private.member_role(s) in ('owner','cashier') then tenant_private.receivable_grant_read(s,null)->'effective' else '[]'::jsonb end,
 'plan_revision',(select p.revision from public.saas_subscriptions sub join tenant_private.admin_action_policy p on p.plan_code=sub.plan_code where sub.store_id=s),
 'store_revision',(select p.revision from tenant_private.admin_store_action_policy p where p.store_id=s)
 ))
$$;
create function tenant_private.offline_snapshot_stamp(s uuid,d uuid,secret uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 select jsonb_build_object('store',s,'actor',auth.uid(),'device',d,
 'revision',coalesce((select r.revision::text from tenant_private.offline_snapshot_revisions r where r.store_id=s),'initial'),
 'access',tenant_private.offline_access_digest(s),
 'originals',case when tenant_private.member_role(s)='owner' and tenant_private.central_read_permitted(s,'all_catalog_read') then
 tenant_private.finance_review_digest(coalesce((select jsonb_agg(jsonb_build_array(m.id,exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=m.object_path)) order by m.id) from tenant_private.product_originals m where m.store_id=s),'[]'::jsonb))
 else null end,'captured_at',clock_timestamp()) into result;
 return result;
end $$;
create function public.mt_offline_snapshot_stamp(s uuid,d uuid,secret uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_snapshot_stamp(s,d,secret)$$;
revoke all on function tenant_private.offline_access_digest(uuid),tenant_private.offline_snapshot_stamp(uuid,uuid,uuid),public.mt_offline_snapshot_stamp(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_snapshot_stamp(uuid,uuid,uuid),public.mt_offline_snapshot_stamp(uuid,uuid,uuid) to authenticated;

alter table tenant_private.offline_reviewed_requests add column access_digest text check(access_digest is null or access_digest ~ '^[0-9a-f]{64}$');
create function tenant_private.offline_receipt_scope_capture() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or new.actor is distinct from auth.uid() or tenant_private.member_role(new.store_id) is null then raise exception 'Live receipt actor required' using errcode='42501';end if;
 new.access_digest:=tenant_private.offline_access_digest(new.store_id);return new;
end $$;
create trigger mt_offline_receipt_scope before insert on tenant_private.offline_reviewed_requests for each row execute function tenant_private.offline_receipt_scope_capture();
create function tenant_private.offline_receipt_scope_require(s uuid,prior text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if prior is null or prior is distinct from tenant_private.offline_access_digest(s) then raise exception 'Receipt scope changed; use status-only reconciliation' using errcode='42501';end if;
end $$;
revoke all on function tenant_private.offline_receipt_scope_capture(),tenant_private.offline_receipt_scope_require(uuid,text) from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION tenant_private.offline_dependency(s uuid, d uuid, secret uuid, parent uuid, entity text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare x tenant_private.offline_reviewed_requests%rowtype;rid uuid;method text;k text;action text;batch boolean;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 if parent is null or entity is null or entity not in ('operation','product','customer','supplier','repair','purchase','purchaseBatch','sale','invoiceDebt','standaloneDebt','repairInvoice','warrantyClaim','saleClaim','tradein','advance','payrollAdjustment','branchApproval','taxFiling','original') then raise exception 'Invalid dependency' using errcode='22023';end if;
 select * into x from tenant_private.offline_reviewed_requests where store_id=s and request_id=parent and actor=auth.uid();
 if not found or x.result is null or x.result->>'status'='conflict' or x.result->>'offline_terminal'='true' then return null;end if;
 if entity='operation' then return parent;end if;
 -- A historical receipt contains no recorded permission scope; only a current owner can resolve its typed entity after the existing entity-level read check.
 if x.access_digest is null then if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Historical dependency requires authorized reconciliation' using errcode='42501';end if;
 else perform tenant_private.offline_receipt_scope_require(s,x.access_digest);end if;
 method:=x.payload->>'method';k:=x.payload->>'kind';batch:=coalesce((x.payload#>>'{args,p_batch}')::boolean,false);
 action:=case entity when 'product' then 'all_catalog_read' when 'original' then 'all_catalog_read' when 'customer' then 'all_customer_read' when 'supplier' then 'all_supplier_read' when 'purchase' then 'all_purchase_read' when 'purchaseBatch' then 'all_purchase_read' when 'sale' then 'all_sales_read' when 'invoiceDebt' then 'all_debt_read' when 'standaloneDebt' then 'all_debt_read' when 'repair' then 'all_repair_read' when 'repairInvoice' then 'all_repair_read' when 'warrantyClaim' then 'all_warranty_read' when 'saleClaim' then 'all_warranty_read' when 'tradein' then 'all_customer_read' else 'all_finance_read' end;
 if not coalesce(tenant_private.central_read_permitted(s,action),false) then raise exception 'Dependency read denied' using errcode='42501';end if;
 if entity='product' and k='catalogCreate' then
  select (result->>'id')::uuid into rid from tenant_private.catalog_requests where store_id=s and request_id=parent and actor=auth.uid();
 elsif entity='customer' and method='mt_add_customer' then
  select id into rid from public.mt_customers where store_id=s and request_id=parent and actor=auth.uid();
 elsif entity='supplier' and (method='mt_add_supplier' or method='mt_supplier_save' and x.payload#>>'{args,p_supplier}' is null) then
  select id into rid from public.mt_suppliers where store_id=s and request_id=parent and actor=auth.uid();
 elsif entity='repair' and method in ('mt_add_repair','mt_branch_add_repair') then
  select id into rid from public.mt_repairs where store_id=s and request_id=parent and actor=auth.uid();
 elsif entity='purchase' and (method in ('mt_purchase','mt_branch_purchase') or method='mt_procurement_receive' and not batch) then
  if jsonb_typeof(x.result)='string' then select id into rid from public.mt_purchases where store_id=s and id=(x.result#>>'{}')::uuid;end if;
 elsif entity='purchaseBatch' and (method in ('mt_purchase_batch','mt_branch_purchase_batch') or method='mt_procurement_receive' and batch) then
  if jsonb_typeof(x.result)='string' then select id into rid from public.mt_purchase_batches where store_id=s and id=(x.result#>>'{}')::uuid;end if;
 elsif entity in ('sale','invoiceDebt') and method in ('mt_record_currency_sale','mt_branch_cash_sale','mt_record_credit_sale','mt_branch_credit_sale','mt_issue_sale_invoice','mt_local_membership_sale','mt_record_mixed_sale','mt_branch_mixed_sale','mt_tradein_execute','mt_tradein_execute_invoice') then
  if entity='sale' then select id into rid from public.mt_sales where store_id=s and request_id=parent and actor=auth.uid();
  else select debt.id into rid from public.mt_debts debt join public.mt_sales sale on sale.store_id=debt.store_id and sale.id=debt.sale_id where sale.store_id=s and sale.request_id=parent and sale.actor=auth.uid();end if;
 elsif entity='standaloneDebt' and method='mt_standalone_open' then
  select id into rid from tenant_private.standalone_debts where store_id=s and id=parent and actor=auth.uid();
 elsif entity='repairInvoice' and method='mt_repair_checkout' then
  select id into rid from public.mt_repair_invoices where store_id=s and request_id=parent and actor=auth.uid();
 elsif entity='warrantyClaim' and method='mt_warranty_open' then
  if jsonb_typeof(x.result)='string' then select id into rid from public.mt_warranty_claims where store_id=s and id=(x.result#>>'{}')::uuid;end if;
 elsif entity='saleClaim' and method='mt_sale_claim_open' then
  if jsonb_typeof(x.result)='string' then select id into rid from tenant_private.sale_warranty_claims where store_id=s and id=(x.result#>>'{}')::uuid;end if;
 elsif entity='tradein' and method='mt_tradein_create' then
  if jsonb_typeof(x.result)='string' then select id into rid from tenant_private.tradein_estimates where store_id=s and id=(x.result#>>'{}')::uuid;end if;
 elsif entity='advance' and (k='payrollAdvance' or method='mt_payroll_advance') then
  select id into rid from tenant_private.staff_advances where store_id=s and id=parent;
 elsif entity='payrollAdjustment' and method='mt_payroll_adjust' then
  select id into rid from tenant_private.staff_payroll_adjustments where store_id=s and id=parent;
 elsif entity='branchApproval' and k='branchApproval' then
  select request_id into rid from tenant_private.branch_result_approvals where store_id=s and request_id=parent;
 elsif entity='taxFiling' and k='taxFiling' then
  select request_id into rid from tenant_private.sy_tax_filing_evidence where store_id=s and request_id=parent;
 elsif entity='original' and k='originalUpload' and x.result->>'status'='confirmed' then
  select id into rid from tenant_private.product_originals where store_id=s and id=parent;
 end if;
 return rid;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_dispatch(s uuid, d uuid, secret uuid, req uuid, method text, args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old tenant_private.offline_reviewed_requests%rowtype;payload jsonb;result jsonb;
begin
 if tenant_private.member_role(s) is null then raise exception 'Membership required' using errcode='42501';end if;
 if req is null or method is null or jsonb_typeof(args) is distinct from 'object' or octet_length(args::text)>100000 or (args->>'p_store')::uuid is distinct from s then raise exception 'Invalid dispatch' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=s for update;
 perform tenant_private.offline_device_require(s,d,secret);
 payload:=jsonb_build_object('method',method,'args',args);
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from payload then raise exception 'Request identity conflict' using errcode='22023';end if;
  perform tenant_private.offline_receipt_scope_require(s,old.access_digest);
  return old.result;
 end if;
 case method
 when 'mt_accounting_adjust' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_kind','p_source','p_currency','p_amount','p_reference','p_note']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_kind','p_source','p_currency','p_amount','p_reference','p_note']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_accounting_adjust(s,req,args->>'p_kind',(args->>'p_source')::uuid,args->>'p_currency',(args->>'p_amount')::bigint,args->>'p_reference',args->>'p_note'));
 when 'mt_add_customer' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_name','p_phone']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_name','p_phone']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_add_customer(s,req,args->>'p_name',args->>'p_phone'));
 when 'mt_add_repair' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_customer','p_device','p_imei','p_fault']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_customer','p_device','p_imei','p_fault']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_add_repair(s,req,(args->>'p_customer')::uuid,args->>'p_device',args->>'p_imei',args->>'p_fault'));
 when 'mt_add_supplier' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_name','p_contact']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_name','p_contact']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_add_supplier(s,req,args->>'p_name',args->>'p_contact'));
 when 'mt_branch_add_repair' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_customer','p_device','p_imei','p_fault']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_customer','p_device','p_imei','p_fault']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_branch_add_repair(s,(args->>'p_branch')::uuid,req,(args->>'p_customer')::uuid,args->>'p_device',args->>'p_imei',args->>'p_fault'));
 when 'mt_branch_cash_sale' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_currency','p_lines']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_currency','p_lines']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_branch_cash_sale(s,(args->>'p_branch')::uuid,req,args->>'p_currency',nullif(args->'p_lines','null'::jsonb)));
 when 'mt_branch_credit_sale' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_currency','p_lines','p_customer','p_deposit','p_count','p_due']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_currency','p_lines','p_customer','p_deposit','p_count','p_due']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_branch_credit_sale(s,(args->>'p_branch')::uuid,req,args->>'p_currency',nullif(args->'p_lines','null'::jsonb),(args->>'p_customer')::uuid,(args->>'p_deposit')::bigint,(args->>'p_count')::integer,(args->>'p_due')::date));
 when 'mt_branch_mixed_sale' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_currency','p_lines','p_tenders','p_refund_policy']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_currency','p_lines','p_tenders','p_refund_policy']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_branch_mixed_sale(s,(args->>'p_branch')::uuid,req,args->>'p_currency',nullif(args->'p_lines','null'::jsonb),nullif(args->'p_tenders','null'::jsonb),args->>'p_refund_policy'));
 when 'mt_branch_purchase' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_supplier','p_product','p_currency','p_units','p_cost','p_paid','p_note']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_supplier','p_product','p_currency','p_units','p_cost','p_paid','p_note']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_branch_purchase(s,(args->>'p_branch')::uuid,req,(args->>'p_supplier')::uuid,(args->>'p_product')::uuid,args->>'p_currency',(args->>'p_units')::bigint,(args->>'p_cost')::bigint,(args->>'p_paid')::bigint,args->>'p_note'));
 when 'mt_branch_purchase_batch' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_supplier','p_currency','p_reference','p_lines','p_paid']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_supplier','p_currency','p_reference','p_lines','p_paid']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_branch_purchase_batch(s,(args->>'p_branch')::uuid,req,(args->>'p_supplier')::uuid,args->>'p_currency',args->>'p_reference',nullif(args->'p_lines','null'::jsonb),(args->>'p_paid')::bigint));
 when 'mt_branch_transfer' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_source','p_target','p_product','p_units']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_source','p_target','p_product','p_units']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_branch_transfer(s,req,(args->>'p_source')::uuid,(args->>'p_target')::uuid,(args->>'p_product')::uuid,(args->>'p_units')::bigint));
 when 'mt_branch_voucher' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_branch','p_kind','p_currency','p_amount','p_party','p_reference']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_branch','p_kind','p_currency','p_amount','p_party','p_reference']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_branch_voucher(s,req,(args->>'p_branch')::uuid,args->>'p_kind',args->>'p_currency',(args->>'p_amount')::bigint,args->>'p_party',args->>'p_reference'));
 when 'mt_campaign_create' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_title','p_body','p_from','p_to']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_title','p_body','p_from','p_to']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_campaign_create(s,req,args->>'p_title',args->>'p_body',(args->>'p_from')::date,(args->>'p_to')::date));
 when 'mt_count_commit' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_reason','p_items']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_reason','p_items']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_count_commit(s,(args->>'p_branch')::uuid,req,args->>'p_reason',nullif(args->'p_items','null'::jsonb)));
 when 'mt_edit_customer' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_customer','p_old_name','p_old_phone','p_name','p_phone']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_customer','p_old_name','p_old_phone','p_name','p_phone']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_edit_customer(s,req,(args->>'p_customer')::uuid,args->>'p_old_name',args->>'p_old_phone',args->>'p_name',args->>'p_phone'));
 when 'mt_issue_sale_invoice' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_currency','p_lines','p_metadata']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_currency','p_lines','p_metadata','p_terms']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_issue_sale_invoice(s,(args->>'p_branch')::uuid,req,args->>'p_currency',nullif(args->'p_lines','null'::jsonb),nullif(args->'p_metadata','null'::jsonb),nullif(args->'p_terms','null'::jsonb)));
 when 'mt_local_membership_sale' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_customer','p_currency','p_lines','p_metadata','p_terms','p_expected','p_prices']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_customer','p_currency','p_lines','p_metadata','p_terms','p_expected','p_prices']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_local_membership_sale(s,(args->>'p_branch')::uuid,req,(args->>'p_customer')::uuid,args->>'p_currency',nullif(args->'p_lines','null'::jsonb),nullif(args->'p_metadata','null'::jsonb),nullif(args->'p_terms','null'::jsonb),(args->>'p_expected')::bigint,nullif(args->'p_prices','null'::jsonb)));
 when 'mt_pay_debt' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_debt','p_request','p_currency','p_amount']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_debt','p_request','p_currency','p_amount']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_pay_debt(s,(args->>'p_debt')::uuid,req,args->>'p_currency',(args->>'p_amount')::bigint));
 when 'mt_pay_supplier' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_purchase','p_currency','p_amount']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_purchase','p_currency','p_amount']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_pay_supplier(s,req,(args->>'p_purchase')::uuid,args->>'p_currency',(args->>'p_amount')::bigint));
 when 'mt_payroll_adjust' then
  if (args->>'p_id')::uuid is distinct from req or not (args ?& array['p_store','p_id','p_payroll','p_kind','p_amount','p_reason']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_id','p_payroll','p_kind','p_amount','p_reason']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_payroll_adjust(s,req,(args->>'p_payroll')::uuid,args->>'p_kind',(args->>'p_amount')::bigint,args->>'p_reason'));
 when 'mt_payroll_adjust_reverse' then
  if (args->>'p_id')::uuid is distinct from req or not (args ?& array['p_store','p_id','p_original','p_reason']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_id','p_original','p_reason']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_payroll_adjust_reverse(s,req,(args->>'p_original')::uuid,args->>'p_reason'));
 when 'mt_payroll_partial' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_id','p_request','p_amount','p_confirm']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_id','p_request','p_amount','p_confirm']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_payroll_partial(s,(args->>'p_id')::uuid,req,(args->>'p_amount')::bigint,(args->>'p_confirm')::boolean));
 when 'mt_procurement_due' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_purchase','p_due']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_purchase','p_due']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_procurement_due(s,req,(args->>'p_purchase')::uuid,(args->>'p_due')::date));
 when 'mt_procurement_receive' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_branch','p_request','p_supplier','p_currency','p_reference','p_items','p_paid','p_due','p_batch']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_branch','p_request','p_supplier','p_currency','p_reference','p_items','p_paid','p_due','p_batch']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_procurement_receive(s,(args->>'p_branch')::uuid,req,(args->>'p_supplier')::uuid,args->>'p_currency',args->>'p_reference',nullif(args->'p_items','null'::jsonb),(args->>'p_paid')::bigint,(args->>'p_due')::date,(args->>'p_batch')::boolean));
 when 'mt_purchase' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_supplier','p_product','p_currency','p_units','p_cost','p_paid','p_note']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_supplier','p_product','p_currency','p_units','p_cost','p_paid','p_note']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_purchase(s,req,(args->>'p_supplier')::uuid,(args->>'p_product')::uuid,args->>'p_currency',(args->>'p_units')::bigint,(args->>'p_cost')::bigint,(args->>'p_paid')::bigint,args->>'p_note'));
 when 'mt_purchase_batch' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_supplier','p_currency','p_reference','p_lines','p_paid']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_supplier','p_currency','p_reference','p_lines','p_paid']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_purchase_batch(s,req,(args->>'p_supplier')::uuid,args->>'p_currency',args->>'p_reference',nullif(args->'p_lines','null'::jsonb),(args->>'p_paid')::bigint));
 when 'mt_quote_create' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_customer','p_currency','p_until','p_lines']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_customer','p_currency','p_until','p_lines']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_quote_create(s,req,args->>'p_customer',args->>'p_currency',(args->>'p_until')::date,nullif(args->'p_lines','null'::jsonb)));
 when 'mt_receive_costed_stock' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_product','p_request','p_units','p_currency','p_cost','p_note']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_product','p_request','p_units','p_currency','p_cost','p_note']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_receive_costed_stock(s,(args->>'p_product')::uuid,req,(args->>'p_units')::bigint,args->>'p_currency',(args->>'p_cost')::bigint,args->>'p_note'));
 when 'mt_record_cash' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_kind','p_currency','p_amount','p_note']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_kind','p_currency','p_amount','p_note','p_target_currency','p_target_amount']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_record_cash(s,req,args->>'p_kind',args->>'p_currency',(args->>'p_amount')::bigint,args->>'p_note',args->>'p_target_currency',(args->>'p_target_amount')::bigint));
 when 'mt_record_credit_sale' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_currency','p_lines','p_customer','p_deposit','p_count','p_due']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_currency','p_lines','p_customer','p_deposit','p_count','p_due']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_record_credit_sale(s,req,args->>'p_currency',nullif(args->'p_lines','null'::jsonb),(args->>'p_customer')::uuid,(args->>'p_deposit')::bigint,(args->>'p_count')::integer,(args->>'p_due')::date));
 when 'mt_record_currency_sale' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_currency','p_lines']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_currency','p_lines']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_record_currency_sale(s,req,args->>'p_currency',nullif(args->'p_lines','null'::jsonb)));
 when 'mt_record_mixed_sale' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_currency','p_lines','p_tenders','p_refund_policy']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_currency','p_lines','p_tenders','p_refund_policy']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_record_mixed_sale(s,req,args->>'p_currency',nullif(args->'p_lines','null'::jsonb),nullif(args->'p_tenders','null'::jsonb),args->>'p_refund_policy'));
 when 'mt_repair_checkout' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_repair','p_currency','p_service','p_lines','p_warranty']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_repair','p_currency','p_service','p_lines','p_warranty']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_repair_checkout(s,req,(args->>'p_repair')::uuid,args->>'p_currency',(args->>'p_service')::bigint,nullif(args->'p_lines','null'::jsonb),(args->>'p_warranty')::integer));
 when 'mt_repair_refund' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_invoice','p_amount','p_reason','p_confirm']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_invoice','p_amount','p_reason','p_confirm']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_repair_refund(s,req,(args->>'p_invoice')::uuid,(args->>'p_amount')::bigint,args->>'p_reason',(args->>'p_confirm')::boolean));
 when 'mt_repair_transition' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_repair','p_next','p_note']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_repair','p_next','p_note']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_repair_transition(s,req,(args->>'p_repair')::uuid,args->>'p_next',args->>'p_note'));
 when 'mt_sale_claim_open' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_sale','p_product','p_units','p_reason']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_sale','p_product','p_units','p_reason']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_sale_claim_open(s,req,(args->>'p_sale')::uuid,(args->>'p_product')::uuid,(args->>'p_units')::bigint,args->>'p_reason'));
 when 'mt_sale_claim_transition' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_claim','p_next','p_note']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_claim','p_next','p_note']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_sale_claim_transition(s,req,(args->>'p_claim')::uuid,args->>'p_next',args->>'p_note'));
 when 'mt_standalone_open' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_customer','p_branch','p_direction','p_party','p_phone','p_currency','p_amount','p_count','p_due','p_notes']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_customer','p_branch','p_direction','p_party','p_phone','p_currency','p_amount','p_count','p_due','p_notes']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_standalone_open(s,req,(args->>'p_customer')::uuid,(args->>'p_branch')::uuid,args->>'p_direction',args->>'p_party',args->>'p_phone',args->>'p_currency',(args->>'p_amount')::bigint,(args->>'p_count')::integer,(args->>'p_due')::date,args->>'p_notes'));
 when 'mt_standalone_pay' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_debt','p_amount','p_memo']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_debt','p_amount','p_memo']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_standalone_pay(s,req,(args->>'p_debt')::uuid,(args->>'p_amount')::bigint,args->>'p_memo'));
 when 'mt_supplier_return' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_purchase','p_units','p_reason','p_confirm_refund']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_purchase','p_units','p_reason','p_confirm_refund']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_supplier_return(s,req,(args->>'p_purchase')::uuid,(args->>'p_units')::bigint,args->>'p_reason',(args->>'p_confirm_refund')::boolean));
 when 'mt_supplier_save' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_supplier','p_name','p_contact','p_phone','p_email','p_address','p_archived']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_supplier','p_name','p_contact','p_phone','p_email','p_address','p_archived']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_supplier_save(s,req,(args->>'p_supplier')::uuid,args->>'p_name',args->>'p_contact',args->>'p_phone',args->>'p_email',args->>'p_address',(args->>'p_archived')::boolean));
 when 'mt_tradein_create' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_branch','p_customer','p_device','p_serial','p_note','p_currency','p_amount']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_branch','p_customer','p_device','p_serial','p_note','p_currency','p_amount']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_tradein_create(s,req,(args->>'p_branch')::uuid,(args->>'p_customer')::uuid,args->>'p_device',args->>'p_serial',args->>'p_note',args->>'p_currency',(args->>'p_amount')::bigint));
 when 'mt_tradein_execute' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_id','p_used_product','p_currency','p_lines','p_difference','p_confirm']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_id','p_used_product','p_currency','p_lines','p_difference','p_confirm']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_tradein_execute(s,req,(args->>'p_id')::uuid,(args->>'p_used_product')::uuid,args->>'p_currency',nullif(args->'p_lines','null'::jsonb),(args->>'p_difference')::bigint,(args->>'p_confirm')::boolean));
 when 'mt_tradein_execute_invoice' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_id','p_used_product','p_currency','p_lines','p_difference','p_confirm','p_meta']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_id','p_used_product','p_currency','p_lines','p_difference','p_confirm','p_meta']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_tradein_execute_invoice(s,req,(args->>'p_id')::uuid,(args->>'p_used_product')::uuid,args->>'p_currency',nullif(args->'p_lines','null'::jsonb),(args->>'p_difference')::bigint,(args->>'p_confirm')::boolean,nullif(args->'p_meta','null'::jsonb)));
 when 'mt_warranty_open' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_invoice','p_reason']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_invoice','p_reason']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_warranty_open(s,req,(args->>'p_invoice')::uuid,args->>'p_reason'));
 when 'mt_warranty_part' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_claim','p_product','p_units','p_reason']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_claim','p_product','p_units','p_reason']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_warranty_part(s,req,(args->>'p_claim')::uuid,(args->>'p_product')::uuid,(args->>'p_units')::bigint,args->>'p_reason'));
 when 'mt_warranty_transition' then
  if (args->>'p_request')::uuid is distinct from req or not (args ?& array['p_store','p_request','p_claim','p_next','p_note']) or exists(select 1 from jsonb_object_keys(args) j(key) where not (j.key=any(array['p_store','p_request','p_claim','p_next','p_note']))) then raise exception 'Invalid request arguments' using errcode='22023';end if;
  result:=to_jsonb(public.mt_warranty_transition(s,req,(args->>'p_claim')::uuid,args->>'p_next',args->>'p_note'));
 else raise exception 'Offline method not permitted' using errcode='22023';
 end case;
 if result is null or result='null'::jsonb then raise exception 'Operation unconfirmed' using errcode='22023';end if;
 insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,payload,result);
 return result;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_dispatch_v2(s uuid, d uuid, secret uuid, req uuid, method text, args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;payload jsonb;old tenant_private.offline_reviewed_requests%rowtype;
begin
 if tenant_private.member_role(s) is null then raise exception 'Membership required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=s for update;
 perform tenant_private.offline_device_require(s,d,secret);
 if req is null or method is null or jsonb_typeof(args) is distinct from 'object' or octet_length(args::text)>100000 or (args->>'p_store')::uuid is distinct from s then raise exception 'Invalid dispatch' using errcode='22023';end if;
 payload:=jsonb_build_object('method',method,'args',args);
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from payload then raise exception 'Request identity conflict' using errcode='22023';end if;
  perform tenant_private.offline_receipt_scope_require(s,old.access_digest);
  result:=old.result;
 else
  begin
   result:=tenant_private.offline_dispatch(s,d,secret,req,method,args);
  exception when sqlstate '22023' or unique_violation or check_violation or foreign_key_violation then
   result:=jsonb_build_object('offline_terminal',true,'status','conflict','requestId',req,'code',SQLSTATE);
   insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,payload,result);
  end;
 end if;
 if result->>'offline_terminal'='true' then return result;end if;
 return jsonb_build_object('status','confirmed','requestId',req,'value',result);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_inventory_write(s uuid, d uuid, secret uuid, op jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare req uuid;k text;pid uuid;old tenant_private.offline_reviewed_requests%rowtype;res jsonb;item jsonb;desired jsonb;expected jsonb;actual jsonb;cur text;subject text;price bigint;minimum integer;enabled boolean;rid uuid;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Catalog denied' using errcode='42501';end if;
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>300000 or (op->>'store')::uuid is distinct from s then raise exception 'Invalid inventory payload' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;k:=op->>'kind';pid:=(op->>'product')::uuid;
 if req is null or pid is null or k is null or k not in ('catalogEdit','retailPrice','tierPrice','customerPrice','buyerPrice','originalPublish') then raise exception 'Invalid inventory action' using errcode='22023';end if;
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
  perform tenant_private.offline_receipt_scope_require(s,old.access_digest);
  return old.result;
 end if;
 if k='originalPublish' then
  if tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Product edit denied' using errcode='42501';end if;
  rid:=(op->>'asset')::uuid;
  if rid is null or (op->>'expected')::boolean is null or (op->>'enabled')::boolean is null then raise exception 'Image review required' using errcode='22023';end if;
  select jsonb_build_object('published',published) into actual from tenant_private.product_originals where store_id=s and id=rid and product_id=pid for update;
  if actual is null or (actual->>'published')::boolean is distinct from (op->>'expected')::boolean then res:=jsonb_build_object('status','conflict','requestId',req,'current',actual);
  elsif public.mt_product_original_publish(s,rid,(op->>'enabled')::boolean) is distinct from (op->>'enabled')::boolean then raise exception 'Image publication unconfirmed';end if;
 elsif k='catalogEdit' then
  if tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Product edit denied' using errcode='42501';end if;
  desired:=op->'desired';
  if op->>'digest' is null or op->>'digest' !~ '^[a-f0-9]{64}$' or jsonb_typeof(desired) is distinct from 'object' then raise exception 'Review required' using errcode='22023';end if;
  perform 1 from public.mt_products where store_id=s and id=pid for update;
  if not found then res:=jsonb_build_object('status','conflict','requestId',req,'current','missing');
  else
   item:=tenant_private.catalog_item(s,pid);
   if tenant_private.finance_review_digest(item) is distinct from op->>'digest' then res:=jsonb_build_object('status','conflict','requestId',req,'current',tenant_private.finance_review_digest(item));
   else
    rid:=public.mt_catalog_save(s,req,pid,desired->>'name',desired->>'sku',desired->'profile',desired->'specs',(desired->>'listed')::boolean,null,null);
    if rid is distinct from pid then raise exception 'Catalog unconfirmed';end if;
   end if;
  end if;
 else
  if tenant_private.central_action_denied(s,'product_price_change') then raise exception 'Price edit denied' using errcode='42501';end if;
  cur:=op->>'currency';subject:=op->>'subject';expected:=nullif(op->'expected','null'::jsonb);desired:=nullif(op->'desired','null'::jsonb);
  if not (op ?& array['expected','desired']) or cur is null or cur not in ('USD','SYP','EUR') then raise exception 'Invalid price review' using errcode='22023';end if;
  if k in ('customerPrice','buyerPrice') and not tenant_private.central_read_permitted(s,'all_customer_read') then raise exception 'Customer access denied' using errcode='42501';end if;
  perform 1 from public.mt_products where store_id=s and id=pid for update;
  if not found then res:=jsonb_build_object('status','conflict','requestId',req,'current','missing');
  else
   if k='retailPrice' then
    select jsonb_build_object('price',price_minor) into actual from public.mt_product_prices where store_id=s and product_id=pid and currency=cur;
   elsif k='tierPrice' then
    if subject is null or subject not in ('standard','member','silver','gold','vip','wholesale') then raise exception 'Invalid tier' using errcode='22023';end if;
    select jsonb_build_object('price',price_minor,'min',min_units) into actual from tenant_private.product_tier_prices where store_id=s and product_id=pid and tier=subject and currency=cur;
   elsif k='customerPrice' then
    if subject is null or not exists(select 1 from public.mt_customers where store_id=s and id=subject::uuid) then raise exception 'Invalid customer' using errcode='22023';end if;
    select jsonb_build_object('price',price_minor,'min',min_units) into actual from tenant_private.local_customer_prices where store_id=s and product_id=pid and customer_id=subject::uuid and currency=cur;
   else
    if subject is null or not tenant_private.known_membership_buyer(s,subject::uuid) then raise exception 'Invalid buyer' using errcode='22023';end if;
    select jsonb_build_object('price',price_minor,'min',min_units) into actual from tenant_private.buyer_product_prices where store_id=s and product_id=pid and buyer=subject::uuid and currency=cur;
   end if;
   if actual is distinct from expected then res:=jsonb_build_object('status','conflict','requestId',req,'current',actual);
   else
    enabled:=desired is not null;
    price:=(desired->>'price')::bigint;minimum:=(desired->>'min')::integer;
    if enabled and (price is null or price not between 1 and 100000000 or k<>'retailPrice' and (minimum is null or minimum not between 1 and 100)) then raise exception 'Invalid special price' using errcode='22023';end if;
    if k='retailPrice' then
     if not enabled then raise exception 'Retail removal not supported' using errcode='22023';end if;
     if public.mt_set_currency_price(s,pid,cur,price) is distinct from price then raise exception 'Price unconfirmed';end if;
    elsif k='tierPrice' then
     if public.mt_product_tier_set(s,pid,subject,cur,price,minimum,enabled) is distinct from enabled then raise exception 'Tier unconfirmed';end if;
    elsif k='customerPrice' then
     if public.mt_local_customer_price_set(s,subject::uuid,pid,cur,price,minimum,enabled) is distinct from enabled then raise exception 'Customer price unconfirmed';end if;
    else
     if public.mt_buyer_product_price_set(s,subject::uuid,pid,cur,price,minimum,enabled) is distinct from enabled then raise exception 'Buyer price unconfirmed';end if;
    end if;
   end if;
  end if;
 end if;
 if res is null then res:=jsonb_build_object('status','confirmed','requestId',req,'resultId',pid);end if;
 insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,res);
 return res;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_original_delete_begin(s uuid, d uuid, secret uuid, op jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare req uuid;asset uuid;pid uuid;original tenant_private.product_originals%rowtype;prior tenant_private.offline_reviewed_requests%rowtype;pending tenant_private.offline_original_deletions%rowtype;uploaded boolean;res jsonb;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if auth.jwt()->>'aal' is distinct from 'aal2' or tenant_private.central_action_denied(s,'product_profile_edit') or not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Owner AAL2 catalog permission required' using errcode='42501';end if;
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>4000 or op->>'kind' is distinct from 'originalDelete' or (op->>'store')::uuid is distinct from s or (op->>'confirm')::boolean is distinct from true then raise exception 'Explicit image deletion required' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;asset:=(op->>'asset')::uuid;pid:=(op->>'product')::uuid;
 if req is null or asset is null or pid is null or op->>'alt' is null or (op->>'published')::boolean is null or (op->>'uploaded')::boolean is null then raise exception 'Invalid image review' using errcode='22023';end if;
 select * into prior from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then if prior.actor<>auth.uid() or prior.device_id<>d or prior.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;perform tenant_private.offline_receipt_scope_require(s,prior.access_digest);return prior.result;end if;
 select * into pending from tenant_private.offline_original_deletions where store_id=s and request_id=req;
 if found then
  if pending.actor<>auth.uid() or pending.device_id<>d or pending.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
 else
  select * into original from tenant_private.product_originals where store_id=s and id=asset and product_id=pid for update;
  if found then select exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=original.object_path) into uploaded;end if;
  if original.id is null or original.alt is distinct from op->>'alt' or original.published is distinct from (op->>'published')::boolean or uploaded is distinct from (op->>'uploaded')::boolean or exists(select 1 from tenant_private.offline_original_deletions where store_id=s and asset_id=asset) then
   res:=jsonb_build_object('status','conflict','requestId',req,'current','image_changed');
   insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,res);return res;
  end if;
  insert into tenant_private.offline_original_deletions(store_id,request_id,asset_id,product_id,actor,device_id,payload) values(s,req,asset,pid,auth.uid(),d,op);
  update tenant_private.product_originals set published=false where store_id=s and id=asset;
 end if;
 return jsonb_build_object('status','reserved','requestId',req,'id',asset,'path',s::text||'/'||asset::text||'.jpg','uploaded',exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=s::text||'/'||asset::text||'.jpg'));
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_original_reserve(s uuid, d uuid, secret uuid, op jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare req uuid;pid uuid;old tenant_private.offline_original_uploads%rowtype;reserved jsonb;prior tenant_private.offline_reviewed_requests%rowtype;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if not tenant_private.central_read_permitted(s,'all_catalog_read') or tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Product access denied' using errcode='42501';end if;
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>4000 or op->>'kind' is distinct from 'originalUpload' or (op->>'store')::uuid is distinct from s then raise exception 'Invalid image request' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;pid:=(op->>'product')::uuid;
 if req is null or pid is null or op->>'digest' is null or op->>'digest' !~ '^[a-f0-9]{64}$' or (op->>'bytes')::integer is null or (op->>'bytes')::integer not between 12 and 2000000 or op->>'alt' is null or length(btrim(op->>'alt')) not between 1 and 100 then raise exception 'Invalid image metadata' using errcode='22023';end if;
 select * into prior from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if prior.actor<>auth.uid() or prior.device_id<>d or prior.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
  perform tenant_private.offline_receipt_scope_require(s,prior.access_digest);return prior.result;
 end if;
 select * into old from tenant_private.offline_original_uploads where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.product_id<>pid or old.alt<>btrim(op->>'alt') or old.digest<>op->>'digest' or old.bytes<>(op->>'bytes')::integer then raise exception 'Image request conflict' using errcode='22023';end if;
 else
  if exists(select 1 from tenant_private.product_originals where store_id=s and id=req) then raise exception 'Image reference in use' using errcode='22023';end if;
  insert into tenant_private.offline_original_uploads(store_id,request_id,actor,device_id,product_id,alt,digest,bytes) values(s,req,auth.uid(),d,pid,btrim(op->>'alt'),op->>'digest',(op->>'bytes')::integer);
 end if;
 reserved:=public.mt_product_original_reserve(s,req,pid,op->>'alt');
 return reserved||jsonb_build_object('status','reserved','requestId',req);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_review_v2(s uuid, d uuid, secret uuid, op jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;req uuid;old tenant_private.offline_reviewed_requests%rowtype;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>300000 or (op->>'store')::uuid is distinct from s then raise exception 'Invalid operation' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;if req is null then raise exception 'Request required' using errcode='22023';end if;
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
  perform tenant_private.offline_receipt_scope_require(s,old.access_digest);
  return old.result;
 end if;
 begin
  if op->>'kind' in ('catalogEdit','retailPrice','tierPrice','customerPrice','buyerPrice','originalPublish') then result:=tenant_private.offline_inventory_write(s,d,secret,op);
  else result:=tenant_private.offline_reviewed_write(s,d,secret,op);end if;
 exception when sqlstate '22023' or unique_violation or check_violation or foreign_key_violation then
  result:=jsonb_build_object('offline_terminal',true,'status','conflict','requestId',req,'code',SQLSTATE);
  insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,result);
 end;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_reviewed_write(s uuid, d uuid, secret uuid, op jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare req uuid;k text;old tenant_private.offline_reviewed_requests%rowtype;res jsonb;pid uuid;expected bigint;actual bigint;rid uuid;cur text;ch text;st text;delivery text;details jsonb;name_now text;sku_now text;review jsonb;day1 date;day2 date;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>18000 or (op->>'store')::uuid is distinct from s then raise exception 'Invalid offline payload' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;k:=op->>'kind';
 if req is null or k is null or k not in ('reviewedPrice','payrollFinal','payrollAdvance','payrollOffset','orderConfirm','orderCancel','orderFulfill','taxFiling','branchApproval','periodClose','catalogCreate','catalogRename') then raise exception 'Unknown reviewed operation' using errcode='22023';end if;
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
  perform tenant_private.offline_receipt_scope_require(s,old.access_digest);
  return old.result;
 end if;
 if k='catalogCreate' then
  if tenant_private.central_action_denied(s,'all_catalog_create') or not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Catalog access denied' using errcode='42501';end if;
  cur:=op->>'currency';actual:=(op->>'price')::bigint;
  if cur is null or cur not in ('USD','SYP','EUR') or actual is null or actual not between 1 and 100000000 then raise exception 'Invalid product price' using errcode='22023';end if;
  if tenant_private.central_action_denied(s,'product_price_change') then raise exception 'Price access denied' using errcode='42501';end if;
  if exists(select 1 from public.mt_products where store_id=s and sku=btrim(op->>'sku')) then res:=jsonb_build_object('status','conflict','requestId',req,'current','sku_exists');
  else
   rid:=public.mt_catalog_save(s,req,null,op->>'name',op->>'sku','{"name_en":"","type":"","brand":"","category":"","model":"","variant":"","description":"","video":"","photos":[]}'::jsonb,'{}'::jsonb,false,cur,actual);
   if rid is null then raise exception 'Product unconfirmed';end if;
  end if;
 elsif k='catalogRename' then
  if tenant_private.central_action_denied(s,'product_profile_edit') or not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Catalog access denied' using errcode='42501';end if;
  pid:=(op->>'product')::uuid;
  select name,sku into name_now,sku_now from public.mt_products where store_id=s and id=pid for update;
  if not found or name_now is distinct from op->>'oldName' or sku_now is distinct from op->>'oldSku' then res:=jsonb_build_object('status','conflict','requestId',req,'current',jsonb_build_object('name',name_now,'sku',sku_now));
  elsif exists(select 1 from public.mt_products where store_id=s and id<>pid and sku=btrim(op->>'sku')) then res:=jsonb_build_object('status','conflict','requestId',req,'current','sku_exists');
  else
   details:=tenant_private.catalog_item(s,pid);
   rid:=public.mt_catalog_save(s,req,pid,op->>'name',op->>'sku',details->'profile',details->'specs',(details->>'listed')::boolean,null,null);
   if rid is distinct from pid then raise exception 'Product unconfirmed';end if;
  end if;
 elsif k='periodClose' then
  if (op->>'confirm')::boolean is distinct from true or op->>'digest' is null or op->>'digest' !~ '^[0-9a-f]{64}$' then raise exception 'Reviewed close evidence required' using errcode='22023';end if;
  day1:=(op->>'from')::date;day2:=(op->>'to')::date;
  review:=tenant_private.offline_close_review(s,day1,day2);
  if review->>'digest' is distinct from op->>'digest' or (review->>'ready')::boolean is distinct from true then res:=jsonb_build_object('status','conflict','requestId',req,'current',review->>'digest');
  else rid:=public.mt_close_period(s,req,day1,day2,op->>'note',true);if rid is null then raise exception 'Close unconfirmed';end if;end if;
 elsif k='reviewedPrice' then
  pid:=(op->>'product')::uuid;cur:=op->>'currency';expected:=(op->>'expected')::bigint;
  if pid is null or cur is null or cur not in ('USD','SYP','EUR') or expected is null or expected not between 1 and 100000000 or (op->>'price')::bigint is null or (op->>'price')::bigint not between 1 and 100000000 then raise exception 'Invalid price review' using errcode='22023';end if;
  if tenant_private.central_action_denied(s,'product_price_change') or not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Price access denied' using errcode='42501';end if;
  select price_minor into actual from public.mt_product_prices where store_id=s and product_id=pid and currency=cur for update;
  if actual is distinct from expected then res:=jsonb_build_object('status','conflict','requestId',req,'current',actual);
  else perform public.mt_set_currency_price(s,pid,cur,(op->>'price')::bigint);end if;
 elsif k='payrollFinal' then
  pid:=(op->>'payroll')::uuid;expected:=(op->>'expected')::bigint;cur:=op->>'currency';
  if pid is null or expected is null or expected not between 0 and 100000000000000 or cur is null or cur not in ('USD','SYP','EUR') or (op->>'confirm')::boolean is distinct from true then raise exception 'Confirm exact physical settlement' using errcode='22023';end if;
  if not tenant_private.central_read_permitted(s,'all_finance_read') then raise exception 'Finance access denied' using errcode='42501';end if;
  perform 1 from tenant_private.staff_payroll where store_id=s and id=pid and currency=cur and paid_at is null for update;
  if found then actual:=tenant_private.payroll_due(s,pid);else actual:=null;end if;
  if actual is distinct from expected then res:=jsonb_build_object('status','conflict','requestId',req,'current',actual);
  else rid:=public.mt_staff_payroll_pay(s,pid,req,true);if rid is distinct from pid then raise exception 'Settlement unconfirmed';end if;end if;
 elsif k='payrollAdvance' then
  rid:=public.mt_payroll_advance(s,req,(op->>'user')::uuid,(op->>'branch')::uuid,op->>'currency',(op->>'amount')::bigint,op->>'reference',(op->>'confirm')::boolean);
  if rid is distinct from req then raise exception 'Advance unconfirmed';end if;
 elsif k='payrollOffset' then
  rid:=public.mt_payroll_offset(s,req,(op->>'payroll')::uuid,(op->>'advance')::uuid,(op->>'amount')::bigint);
  if rid is distinct from req then raise exception 'Offset unconfirmed';end if;
 elsif k in ('orderConfirm','orderCancel','orderFulfill') then
  pid:=(op->>'order')::uuid;ch:=op->>'channel';
  if pid is null or ch is null or ch not in ('online','guest') then raise exception 'Invalid order' using errcode='22023';end if;
  if tenant_private.central_action_denied(s,'all_order_edit') or not tenant_private.central_read_permitted(s,'all_order_read') then raise exception 'Order access denied' using errcode='42501';end if;
  if ch='online' then select state,currency,total_minor,delivery_state into st,cur,actual,delivery from public.mt_online_orders where store_id=s and id=pid for update;
  else select state,currency,total_minor,null::text into st,cur,actual,delivery from tenant_private.guest_orders where store_id=s and id=pid for update;end if;
  if st is distinct from 'pending' then res:=jsonb_build_object('status','conflict','requestId',req,'current',st);
  elsif k='orderConfirm' then
   if public.mt_confirm_shop_order(s,pid,ch) is distinct from true then raise exception 'Order unconfirmed';end if;
  elsif k='orderCancel' then
   if (op->>'confirm')::boolean is distinct from true then raise exception 'Confirm cancellation' using errcode='22023';end if;
   if delivery='dispatched' then res:=jsonb_build_object('status','conflict','requestId',req,'current','dispatched');
   elsif ch='online' then perform public.mt_finish_order_invoice(s,pid,'cancel',null);
   else rid:=public.mt_guest_finish_invoice(s,pid,'cancel',true,null);if rid is distinct from pid then raise exception 'Order unconfirmed';end if;end if;
  else
   expected:=(op->>'expected')::bigint;
   if expected is null or expected not between 1 and 100000000000000 or (op->>'confirm')::boolean is distinct from true or op->>'currency' is null then raise exception 'Confirm actual handover and cash amount' using errcode='22023';end if;
   if expected is distinct from actual or cur is distinct from op->>'currency' or delivery is distinct from op->>'delivery' then res:=jsonb_build_object('status','conflict','requestId',req,'current',jsonb_build_object('currency',cur,'amount',actual,'delivery',delivery));
   elsif ch='online' then rid:=public.mt_finish_order_invoice(s,pid,'fulfill',null);if rid is null then raise exception 'Order unconfirmed';end if;
   else rid:=public.mt_guest_finish_invoice(s,pid,'fulfill',true,null);if rid is distinct from pid then raise exception 'Order unconfirmed';end if;end if;
  end if;
 elsif k='taxFiling' then
  if not tenant_private.central_read_permitted(s,'all_finance_read') then raise exception 'Finance access denied' using errcode='42501';end if;
  review:=tenant_private.sy_tax_settlement_review(s,op->>'taxKind',op->>'currency',(op->>'from')::date,(op->>'to')::date);
  if review->>'review_digest' is distinct from op->>'digest' or (review->>'latest')::uuid is distinct from (op->>'previous')::uuid then res:=jsonb_build_object('status','conflict','requestId',req,'current',review->>'review_digest');
  else rid:=public.mt_sy_tax_filing_record(s,req,op->>'taxKind',op->>'currency',(op->>'from')::date,(op->>'to')::date,(op->>'previous')::uuid,op->>'digest',(op->>'filedOn')::date,op->>'authority',op->>'reference',op->>'legal',(op->>'declared')::bigint,op->>'explanation',(op->>'confirm')::boolean);
  if rid is distinct from req then raise exception 'Filing evidence unconfirmed';end if;end if;
 elsif k='branchApproval' then
  if not tenant_private.central_read_permitted(s,'all_finance_read') then raise exception 'Finance access denied' using errcode='42501';end if;
  review:=tenant_private.branch_result_review(s,(op->>'from')::date,(op->>'to')::date);
  if review->>'review_digest' is distinct from op->>'digest' or (review->>'approval')::uuid is distinct from (op->>'previous')::uuid then res:=jsonb_build_object('status','conflict','requestId',req,'current',review->>'review_digest');
  else rid:=public.mt_branch_result_approve_reviewed(s,req,(op->>'from')::date,(op->>'to')::date,(op->>'previous')::uuid,op->>'proof',(op->>'confirm')::boolean,op->>'digest');
  if rid is distinct from req then raise exception 'Approval unconfirmed';end if;end if;
 end if;
 if res is null then res:=jsonb_build_object('status','confirmed','requestId',req);end if;
 insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,res);
 return res;
end $function$;

commit;
