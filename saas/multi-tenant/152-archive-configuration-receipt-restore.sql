-- 152: configuration-inclusive archives, read-only comparison and narrowly audited receipt restoration.
begin;
set local lock_timeout='5s';
alter table tenant_private.tenant_backup_archives
 add column archive_version integer not null default 1 check(archive_version in (1,2)),
 add column plaintext_sha256 text check(plaintext_sha256 is null or plaintext_sha256 ~ '^[0-9a-f]{64}$'),
 add column table_counts jsonb check(table_counts is null or jsonb_typeof(table_counts)='object'),
 add column receipt_digest text check(receipt_digest is null or receipt_digest ~ '^[0-9a-f]{64}$');
alter table tenant_private.tenant_backup_archives add constraint mt_backup_v2_manifest check(archive_version=1 or (plaintext_sha256 is not null and table_counts is not null and receipt_digest is not null));

create function tenant_private.tenant_backup_relations(v integer) returns text[]
language sql immutable set search_path='' as $$
 select case v when 1 then array['public.mt_accounting_adjustments','public.mt_cash_movements','public.mt_cash_receipts','public.mt_coupons','public.mt_customers','public.mt_debt_payments','public.mt_debts','public.mt_fx_rates','public.mt_indirect_tax_entries','public.mt_installments','public.mt_mixed_sales','public.mt_mixed_tenders','public.mt_online_orders','public.mt_payment_allocations','public.mt_period_closes','public.mt_product_prices','public.mt_products','public.mt_purchase_batches','public.mt_purchases','public.mt_repair_events','public.mt_repair_invoice_lines','public.mt_repair_invoices','public.mt_repair_refunds','public.mt_repairs','public.mt_return_allocations','public.mt_returns','public.mt_sale_lines','public.mt_sales','public.mt_stock_events','public.mt_supplier_payments','public.mt_supplier_returns','public.mt_suppliers','public.mt_warranty_claims','public.mt_warranty_events','public.mt_warranty_parts','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.branch_batches','tenant_private.branch_cash_accounts','tenant_private.branch_cash_attribution','tenant_private.branch_cash_transfers','tenant_private.branch_expense_allocations','tenant_private.branch_fifo_lots','tenant_private.branch_fifo_moves','tenant_private.branch_opening_anchors','tenant_private.branch_opening_checks','tenant_private.branch_purchases','tenant_private.branch_repairs','tenant_private.branch_result_approvals','tenant_private.branch_sales','tenant_private.branch_stock','tenant_private.branch_transfers','tenant_private.branch_vouchers','tenant_private.branches','tenant_private.buyer_price_terms','tenant_private.buyer_product_prices','tenant_private.cash_balances','tenant_private.cost_intakes','tenant_private.cost_postings','tenant_private.customer_profile_edits','tenant_private.guest_orders','tenant_private.local_customer_prices','tenant_private.local_membership_sales','tenant_private.local_membership_terms','tenant_private.marketing_campaigns','tenant_private.membership_directory','tenant_private.membership_rates','tenant_private.opening_debt_equity','tenant_private.order_discounts','tenant_private.order_reservations','tenant_private.price_quotes','tenant_private.procurement_requests','tenant_private.product_originals','tenant_private.product_tier_prices','tenant_private.receipt_settings','tenant_private.receipt_snapshots','tenant_private.repair_assignments','tenant_private.repair_estimates','tenant_private.repair_paper_decisions','tenant_private.repair_tasks','tenant_private.return_cost_postings','tenant_private.sale_currencies','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.shop_order_confirmations','tenant_private.shop_order_history','tenant_private.shop_order_items','tenant_private.spend_checkout','tenant_private.spend_loyalty_policy','tenant_private.spend_loyalty_sales','tenant_private.staff_advance_offsets','tenant_private.staff_advances','tenant_private.staff_payroll','tenant_private.staff_payroll_adjustments','tenant_private.staff_payroll_disbursements','tenant_private.staff_payroll_finalizations','tenant_private.staff_payroll_reversals','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.standalone_debt_payments','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_payment_allocations','tenant_private.stock_consumptions','tenant_private.stock_count_cancellations','tenant_private.stock_count_lines','tenant_private.stock_counts','tenant_private.stock_layers','tenant_private.storefront_products','tenant_private.sy_tax_credit_allocations','tenant_private.sy_tax_credit_events','tenant_private.sy_tax_filing_evidence','tenant_private.sy_tax_input_events','tenant_private.sy_tax_inventory_moves','tenant_private.sy_tax_inventory_parts','tenant_private.sy_tax_inventory_releases','tenant_private.sy_tax_inventory_returns','tenant_private.sy_tax_mixed_parts','tenant_private.sy_tax_output','tenant_private.sy_tax_profiles','tenant_private.sy_tax_supplier_return_actions','tenant_private.tradein_estimates','tenant_private.tradein_settlements'] when 2 then array['public.mt_accounting_adjustments','public.mt_cash_movements','public.mt_cash_receipts','public.mt_coupons','public.mt_customers','public.mt_debt_payments','public.mt_debts','public.mt_fx_rates','public.mt_indirect_tax_entries','public.mt_installments','public.mt_mixed_sales','public.mt_mixed_tenders','public.mt_online_orders','public.mt_payment_allocations','public.mt_period_closes','public.mt_product_prices','public.mt_products','public.mt_purchase_batches','public.mt_purchases','public.mt_repair_events','public.mt_repair_invoice_lines','public.mt_repair_invoices','public.mt_repair_refunds','public.mt_repairs','public.mt_return_allocations','public.mt_returns','public.mt_sale_lines','public.mt_sales','public.mt_stock_events','public.mt_supplier_payments','public.mt_supplier_returns','public.mt_suppliers','public.mt_warranty_claims','public.mt_warranty_events','public.mt_warranty_parts','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.branch_batches','tenant_private.branch_cash_accounts','tenant_private.branch_cash_attribution','tenant_private.branch_cash_transfers','tenant_private.branch_expense_allocations','tenant_private.branch_fifo_enabled','tenant_private.branch_fifo_lots','tenant_private.branch_fifo_moves','tenant_private.branch_opening_anchors','tenant_private.branch_opening_checks','tenant_private.branch_purchases','tenant_private.branch_repairs','tenant_private.branch_result_approvals','tenant_private.branch_sales','tenant_private.branch_stock','tenant_private.branch_transfers','tenant_private.branch_treasury_enabled','tenant_private.branch_vouchers','tenant_private.branches','tenant_private.buyer_price_terms','tenant_private.buyer_product_prices','tenant_private.cash_balances','tenant_private.cashier_branch_scope','tenant_private.cost_intakes','tenant_private.cost_postings','tenant_private.customer_profile_edits','tenant_private.design_heads','tenant_private.design_originals','tenant_private.design_versions','tenant_private.guest_orders','tenant_private.guest_settings','tenant_private.local_customer_prices','tenant_private.local_membership_sales','tenant_private.local_membership_terms','tenant_private.loyalty_settings','tenant_private.marketing_campaigns','tenant_private.members','tenant_private.membership_directory','tenant_private.membership_rates','tenant_private.opening_debt_equity','tenant_private.order_discounts','tenant_private.order_reservations','tenant_private.price_quotes','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.product_originals','tenant_private.product_tier_prices','tenant_private.receipt_settings','tenant_private.receipt_snapshots','tenant_private.receivable_grants','tenant_private.repair_assignments','tenant_private.repair_estimates','tenant_private.repair_paper_decisions','tenant_private.repair_tasks','tenant_private.return_cost_postings','tenant_private.sale_currencies','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.sales_settings','tenant_private.shop_order_confirmations','tenant_private.shop_order_history','tenant_private.shop_order_items','tenant_private.spend_checkout','tenant_private.spend_loyalty_policy','tenant_private.spend_loyalty_sales','tenant_private.staff_advance_offsets','tenant_private.staff_advances','tenant_private.staff_branch_scope','tenant_private.staff_denials','tenant_private.staff_payroll','tenant_private.staff_payroll_adjustments','tenant_private.staff_payroll_disbursements','tenant_private.staff_payroll_finalizations','tenant_private.staff_payroll_reversals','tenant_private.staff_profiles','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.standalone_debt_payments','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_payment_allocations','tenant_private.stock_consumptions','tenant_private.stock_count_cancellations','tenant_private.stock_count_lines','tenant_private.stock_counts','tenant_private.stock_layers','tenant_private.storefront_products','tenant_private.storefronts','tenant_private.sy_tax_credit_allocations','tenant_private.sy_tax_credit_events','tenant_private.sy_tax_filing_evidence','tenant_private.sy_tax_input_events','tenant_private.sy_tax_inventory_moves','tenant_private.sy_tax_inventory_parts','tenant_private.sy_tax_inventory_releases','tenant_private.sy_tax_inventory_returns','tenant_private.sy_tax_mixed_parts','tenant_private.sy_tax_output','tenant_private.sy_tax_profiles','tenant_private.sy_tax_supplier_return_actions','tenant_private.tradein_estimates','tenant_private.tradein_settlements'] else null::text[] end
$$;
revoke all on function tenant_private.tenant_backup_relations(integer) from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_eligible(s uuid, u uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(tenant_private.shared_licensed(s),false)
 and exists(select 1 from tenant_private.members m join auth.users a on a.id=m.user_id where m.store_id=s and m.user_id=u and m.active and m.role='owner' and not a.is_anonymous and not exists(select 1 from tenant_private.admin_member_holds h where h.store_id=s and h.user_id=u and h.blocked))
 and exists(select 1 from auth.mfa_factors f where f.user_id=u and f.factor_type::text='totp' and f.status::text='verified')
 and not exists(select 1 from unnest(tenant_private.central_effective_denials(s)) k where k like 'all\_%\_read' escape '\')
 and not exists(select 1 from unnest(array['all_catalog_read','all_sales_read','all_purchase_read','all_customer_read','all_debt_read','all_repair_read','all_returns_read','all_order_read','all_warranty_read','all_finance_read','all_supplier_read','all_coupon_read']) a(action) where tenant_private.central_action_denied(s,a.action))
$function$;
CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_snapshot(s uuid, u uuid, bid uuid, fp text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rel text;data jsonb:='{}';part jsonb;n bigint;size_bytes bigint;total_bytes bigint:=0;total_rows bigint:=0;counts jsonb:='{}';receipt jsonb;projection text;
begin
 if not tenant_private.tenant_backup_eligible(s,u) then raise exception 'Backup permission changed' using errcode='42501';end if;
 foreach rel in array tenant_private.tenant_backup_relations(2) loop
  projection:=case when rel='tenant_private.design_originals' then '(to_jsonb(r)-''public_fingerprint'')' else 'to_jsonb(r)' end;
  execute format('select count(*),coalesce(sum(octet_length((%s)::text)::bigint+2),0) from %I.%I r where r.store_id=$1',projection,split_part(rel,'.',1),split_part(rel,'.',2)) into n,size_bytes using s;
  if total_bytes+size_bytes>8000000 or total_rows+n>100000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  execute format('select coalesce(jsonb_agg(%s order by (%s)::text),''[]''::jsonb) from %I.%I r where r.store_id=$1',projection,projection,split_part(rel,'.',1),split_part(rel,'.',2)) into part using s;
  counts:=counts||jsonb_build_object(rel,n);
  data:=data||jsonb_build_object(rel,part);total_bytes:=total_bytes+size_bytes;total_rows:=total_rows+n;
 end loop;
 receipt:=tenant_private.effective_receipt_settings(s);
 return jsonb_build_object('version',2,'scope','tenant_operational_archive','id',bid,'store',s,'captured_at',statement_timestamp(),'key_fingerprint',fp,'rows',total_rows,'relation_count',140,'table_counts',counts,'effective_receipt_settings',receipt,'configuration_evidence_only',to_jsonb(array['tenant_private.design_heads','tenant_private.design_versions','tenant_private.design_originals','tenant_private.storefronts','tenant_private.guest_settings','tenant_private.loyalty_settings','tenant_private.sales_settings','tenant_private.members','tenant_private.staff_profiles','tenant_private.staff_denials','tenant_private.staff_branch_scope','tenant_private.cashier_branch_scope','tenant_private.procurement_grants','tenant_private.receivable_grants','tenant_private.branch_fifo_enabled','tenant_private.branch_treasury_enabled']),'excluded_relations',to_jsonb(array['tenant_private.pos_loyalty_sales','tenant_private.spend_pos_redemptions']),'tables',data);
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '2s'
AS $function$
declare cfg tenant_private.tenant_backup_settings%rowtype;bid uuid:=gen_random_uuid();snapshot jsonb;plain text;encrypted bytea;retained bigint;status text:='error';
begin
 if not pg_try_advisory_xact_lock(894313,151) then return;end if;
 select * into cfg from tenant_private.tenant_backup_settings where enabled and next_due<=now() order by next_due,store_id limit 1 for update skip locked;
 if not found then return;end if;
 begin
  if not tenant_private.tenant_backup_eligible(cfg.store_id,cfg.configured_by) then raise exception 'Backup permission changed' using errcode='42501';end if;
  snapshot:=tenant_private.tenant_backup_snapshot(cfg.store_id,cfg.configured_by,bid,cfg.fingerprint);
  plain:=snapshot::text;
  if octet_length(plain)>8000000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  encrypted:=extensions.pgp_pub_encrypt(plain,cfg.public_key,'cipher-algo=aes256,compress-algo=0');
  if octet_length(encrypted)>9000000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  if not tenant_private.tenant_backup_eligible(cfg.store_id,cfg.configured_by) then raise exception 'Backup permission changed' using errcode='42501';end if;
  -- Keep the previous two snapshots plus the new one. Check global budget
  -- before committing; failed capture never prunes a previously saved archive.
  select coalesce(sum(a.bytes),0) into retained from tenant_private.tenant_backup_archives a
  where a.store_id<>cfg.store_id or a.id in (select b.id from tenant_private.tenant_backup_archives b where b.store_id=cfg.store_id order by b.captured_at desc,b.id limit 2);
  if retained+octet_length(encrypted)>64000000 then raise exception 'Archive quota exceeded' using errcode='54000';end if;
  insert into tenant_private.tenant_backup_archives(store_id,id,captured_at,key_fingerprint,relation_count,row_count,bytes,ciphertext,sha256,archive_version,plaintext_sha256,table_counts,receipt_digest)
  values(cfg.store_id,bid,(snapshot->>'captured_at')::timestamptz,cfg.fingerprint,(snapshot->>'relation_count')::int,(snapshot->>'rows')::bigint,octet_length(encrypted),encrypted,encode(sha256(encrypted),'hex'),2,encode(sha256(convert_to(plain,'UTF8')),'hex'),snapshot->'table_counts',tenant_private.finance_review_digest(snapshot->'effective_receipt_settings'));
  delete from tenant_private.tenant_backup_archives a where a.store_id=cfg.store_id and a.id not in (select b.id from tenant_private.tenant_backup_archives b where b.store_id=cfg.store_id order by b.captured_at desc,b.id limit 3);
  update tenant_private.tenant_backup_settings set last_attempt=clock_timestamp(),last_success=clock_timestamp(),last_status='saved',next_due=clock_timestamp()+interval '24 hours' where store_id=cfg.store_id;
 exception when others then
  status:=case sqlstate when '42501' then 'permission' when '54000' then 'capacity' else 'error' end;
  update tenant_private.tenant_backup_settings set last_attempt=clock_timestamp(),last_status=status,next_due=clock_timestamp()+case when status='error' then interval '1 hour' else interval '24 hours' end where store_id=cfg.store_id;
 end;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_overview(s uuid, d uuid, secret uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 return jsonb_build_object('store',s,'settings',(select jsonb_build_object('enabled',v.enabled,'fingerprint',v.fingerprint,'configured_by',v.configured_by,'next_due',v.next_due,'last_attempt',v.last_attempt,'last_success',v.last_success,'last_status',v.last_status) from tenant_private.tenant_backup_settings v where v.store_id=s),
 'pending',(select jsonb_build_object('proposal',k.proposal_id,'fingerprint',k.fingerprint,'expires_at',k.expires_at) from tenant_private.tenant_backup_keys k where k.store_id=s and k.actor=auth.uid() and k.expires_at>now()),
 'archives',coalesce((select jsonb_agg(to_jsonb(a) order by a.captured_at desc,a.id) from (select id,captured_at,key_fingerprint,relation_count,row_count,bytes,sha256,archive_version,plaintext_sha256 from tenant_private.tenant_backup_archives where store_id=s order by captured_at desc,id limit 3) a),'[]'::jsonb));
end $function$;

-- Restore only a supported configuration document through its existing validator
-- and write gateway. No generic INSERT/UPDATE/DELETE from backup JSON.
create table tenant_private.tenant_backup_restore_audit(
 store_id uuid not null references public.saas_stores(id),
 request_id uuid not null,
 archive_id uuid not null,
 actor uuid not null,
 device_id uuid not null,
 kind text not null check(kind='receipt_settings'),
 before_digest text not null check(before_digest ~ '^[0-9a-f]{64}$'),
 restored_digest text not null check(restored_digest ~ '^[0-9a-f]{64}$'),
 reason text not null check(length(btrim(reason)) between 5 and 500),
 created_at timestamptz not null default clock_timestamp(),
 primary key(store_id,request_id)
);
alter table tenant_private.tenant_backup_restore_audit enable row level security;
revoke all on tenant_private.tenant_backup_restore_audit from public,anon,authenticated,service_role;
create index mt_backup_restore_audit_history on tenant_private.tenant_backup_restore_audit(store_id,created_at desc,request_id);

create function tenant_private.tenant_backup_compare(s uuid,d uuid,secret uuid,bid uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare a tenant_private.tenant_backup_archives%rowtype;rel text;n bigint;counts jsonb:='{}';current_receipt jsonb;current_digest text;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 select * into a from tenant_private.tenant_backup_archives where store_id=s and id=bid;
 if not found then raise exception 'Archive missing' using errcode='22023';end if;
 foreach rel in array tenant_private.tenant_backup_relations(a.archive_version) loop
  execute format('select count(*) from %I.%I r where r.store_id=$1',split_part(rel,'.',1),split_part(rel,'.',2)) into n using s;
  counts:=counts||jsonb_build_object(rel,n);
 end loop;
 current_receipt:=tenant_private.effective_receipt_settings(s);
 current_digest:=tenant_private.finance_review_digest(current_receipt);
 return jsonb_build_object('id',a.id,'store',s,'archive_version',a.archive_version,'captured_at',a.captured_at,'plaintext_sha256',a.plaintext_sha256,'saved_counts',a.table_counts,'current_counts',counts,'receipt_current_digest',current_digest,'receipt_saved_digest',a.receipt_digest,'receipt_restore_available',a.archive_version=2 and a.receipt_digest is not null and coalesce(tenant_private.can_write(s),false),'count_comparison_only',true);
end $$;
create function tenant_private.tenant_backup_restore_receipt(s uuid,d uuid,secret uuid,bid uuid,req uuid,expected_digest text,settings jsonb,reason text) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $$
declare a tenant_private.tenant_backup_archives%rowtype;previous tenant_private.tenant_backup_restore_audit%rowtype;current_digest text;desired_digest text;result jsonb;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 if bid is null or req is null or expected_digest is null or expected_digest !~ '^[0-9a-f]{64}$' or reason is null or length(btrim(reason)) not between 5 and 500 or settings is null or octet_length(settings::text)>26000 or not tenant_private.valid_receipt_settings(settings) then raise exception 'Explicit valid restoration required' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=s for update;
 perform tenant_private.tenant_backup_require(s,d,secret);
 if not coalesce(tenant_private.can_write(s),false) then raise exception 'Write denied' using errcode='42501';end if;
 desired_digest:=tenant_private.finance_review_digest(settings);
 select * into previous from tenant_private.tenant_backup_restore_audit where store_id=s and request_id=req;
 if found then
  if previous.actor<>auth.uid() or previous.device_id<>d or previous.archive_id<>bid or previous.before_digest<>expected_digest or previous.restored_digest<>desired_digest or previous.reason<>btrim(reason) then raise exception 'Restoration request conflict' using errcode='22023';end if;
  return jsonb_build_object('status','confirmed','requestId',req,'restored_digest',previous.restored_digest,'replayed',true);
 end if;
 select * into a from tenant_private.tenant_backup_archives where store_id=s and id=bid and archive_version=2 for share;
 if not found or a.receipt_digest is distinct from desired_digest then raise exception 'Settings do not match selected archive' using errcode='22023';end if;
 current_digest:=tenant_private.finance_review_digest(tenant_private.effective_receipt_settings(s));
 if current_digest is distinct from expected_digest then return jsonb_build_object('status','conflict','requestId',req);end if;
 result:=tenant_private.receipt_config(s,settings);
 if tenant_private.finance_review_digest(result) is distinct from desired_digest then raise exception 'Restoration unconfirmed' using errcode='22023';end if;
 insert into tenant_private.tenant_backup_restore_audit(store_id,request_id,archive_id,actor,device_id,kind,before_digest,restored_digest,reason)
 values(s,req,bid,auth.uid(),d,'receipt_settings',current_digest,desired_digest,btrim(reason));
 return jsonb_build_object('status','confirmed','requestId',req,'restored_digest',desired_digest,'replayed',false);
end $$;
create function tenant_private.tenant_backup_restore_history(s uuid,d uuid,secret uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id) from (select request_id,archive_id,actor,kind,before_digest,restored_digest,reason,created_at from tenant_private.tenant_backup_restore_audit where store_id=s order by created_at desc,request_id limit 50) x),'[]'::jsonb);
end $$;

-- Central operator sees schedule health and aggregate metadata only.
-- Neither public/private encryption keys, ciphertext, row data nor restore
-- payloads are exposed to the central administration screen.
create function tenant_private.admin_tenant_backup_overview(after_store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare items jsonb;total_bytes bigint;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 select coalesce(sum(bytes),0) into total_bytes from tenant_private.tenant_backup_archives;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.store_id),'[]'::jsonb) into items from (
 select w.store_id,s.name,coalesce(v.enabled,false) enabled,v.next_due,v.last_attempt,v.last_success,coalesce(v.last_status,'not_configured') status,
 (select count(*) from tenant_private.tenant_backup_archives a where a.store_id=w.store_id) copies,
 (select coalesce(sum(a.bytes),0) from tenant_private.tenant_backup_archives a where a.store_id=w.store_id) bytes
 from tenant_private.workspaces w join public.saas_stores s on s.id=w.store_id left join tenant_private.tenant_backup_settings v on v.store_id=w.store_id
 where after_store is null or w.store_id>after_store order by w.store_id limit 50) x;
 return jsonb_build_object('as_of',now(),'capacity_bytes',64000000,'used_bytes',total_bytes,'stores',items,'scheduler_active',exists(select 1 from cron.job where jobname='techstore-tenant-encrypted-backup' and active));
end $$;

create function public.mt_tenant_backup_compare(s uuid,d uuid,secret uuid,bid uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_compare(s,d,secret,bid)$$;
revoke all on function tenant_private.tenant_backup_compare(uuid,uuid,uuid,uuid),public.mt_tenant_backup_compare(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_compare(uuid,uuid,uuid,uuid),public.mt_tenant_backup_compare(uuid,uuid,uuid,uuid) to authenticated;
create function public.mt_tenant_backup_restore_receipt(s uuid,d uuid,secret uuid,bid uuid,req uuid,expected_digest text,settings jsonb,reason text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_restore_receipt(s,d,secret,bid,req,expected_digest,settings,reason)$$;
revoke all on function tenant_private.tenant_backup_restore_receipt(uuid,uuid,uuid,uuid,uuid,text,jsonb,text),public.mt_tenant_backup_restore_receipt(uuid,uuid,uuid,uuid,uuid,text,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_restore_receipt(uuid,uuid,uuid,uuid,uuid,text,jsonb,text),public.mt_tenant_backup_restore_receipt(uuid,uuid,uuid,uuid,uuid,text,jsonb,text) to authenticated;
create function public.mt_tenant_backup_restore_history(s uuid,d uuid,secret uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_restore_history(s,d,secret)$$;
revoke all on function tenant_private.tenant_backup_restore_history(uuid,uuid,uuid),public.mt_tenant_backup_restore_history(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_restore_history(uuid,uuid,uuid),public.mt_tenant_backup_restore_history(uuid,uuid,uuid) to authenticated;
create function public.mt_admin_tenant_backup_overview(after_store uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.admin_tenant_backup_overview(after_store)$$;
revoke all on function tenant_private.admin_tenant_backup_overview(uuid),public.mt_admin_tenant_backup_overview(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.admin_tenant_backup_overview(uuid),public.mt_admin_tenant_backup_overview(uuid) to authenticated;
commit;
