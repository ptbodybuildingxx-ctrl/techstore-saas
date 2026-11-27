-- 148: conservative review of legacy operations, storage metadata fencing and observed performance indexes.
begin;
set local lock_timeout='5s';

create index mt_offline_devices_actor_state_idx on tenant_private.offline_devices(store_id,actor,state,id);
create index mt_offline_receipts_actor_device_idx on tenant_private.offline_reviewed_requests(store_id,actor,device_id,created_at desc);
create index mt_offline_original_upload_product_idx on tenant_private.offline_original_uploads(store_id,product_id,request_id);
create index mt_offline_original_delete_device_idx on tenant_private.offline_original_deletions(store_id,device_id,state,created_at);
create index mt_product_original_product_idx on tenant_private.product_originals(store_id,product_id,id);

-- The preview is not a historical snapshot. It binds the exact serialized request
-- to the current store revision and live access scope. Never returns private rows.
create function tenant_private.offline_legacy_review(s uuid,d uuid,secret uuid,req uuid,method text,args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare stamp jsonb;prior tenant_private.offline_reviewed_requests%rowtype;payload jsonb;digest text;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 if req is null or method is null or method not in ('mt_accounting_adjust','mt_add_customer','mt_add_repair','mt_add_supplier','mt_branch_add_repair','mt_branch_cash_sale','mt_branch_credit_sale','mt_branch_mixed_sale','mt_branch_purchase','mt_branch_purchase_batch','mt_branch_transfer','mt_branch_voucher','mt_campaign_create','mt_count_commit','mt_edit_customer','mt_issue_sale_invoice','mt_local_membership_sale','mt_pay_debt','mt_pay_supplier','mt_payroll_adjust','mt_payroll_adjust_reverse','mt_payroll_partial','mt_procurement_due','mt_procurement_receive','mt_purchase','mt_purchase_batch','mt_quote_create','mt_receive_costed_stock','mt_record_cash','mt_record_credit_sale','mt_record_currency_sale','mt_record_mixed_sale','mt_repair_checkout','mt_repair_refund','mt_repair_transition','mt_sale_claim_open','mt_sale_claim_transition','mt_standalone_open','mt_standalone_pay','mt_supplier_return','mt_supplier_save','mt_tradein_create','mt_tradein_execute','mt_tradein_execute_invoice','mt_warranty_open','mt_warranty_part','mt_warranty_transition') or jsonb_typeof(args) is distinct from 'object' or octet_length(args::text)>100000 or (args->>'p_store')::uuid is distinct from s then raise exception 'Invalid legacy review' using errcode='22023';end if;
 payload:=jsonb_build_object('method',method,'args',args);
 select * into prior from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if prior.actor<>auth.uid() or prior.device_id<>d or prior.payload is distinct from payload then raise exception 'Request identity conflict' using errcode='22023';end if;
  return jsonb_build_object('status','existing','requestId',req,'receiptStatus',case when prior.result->>'status'='conflict' then 'conflict' else 'confirmed' end);
 end if;
 stamp:=tenant_private.offline_snapshot_stamp(s,d,secret);
 digest:=tenant_private.finance_review_digest(jsonb_build_object('store',s,'actor',auth.uid(),'device',d,'requestId',req,'payload',payload,'revision',stamp->>'revision','access',stamp->>'access','originals',stamp->'originals'));
 return jsonb_build_object('status','review','requestId',req,'digest',digest,'revision',stamp->>'revision','capturedAt',stamp->>'captured_at');
end $$;
create function tenant_private.offline_dispatch_v3(s uuid,d uuid,secret uuid,req uuid,method text,args jsonb,review_digest text) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $$
declare preview jsonb;prior_digest text;result jsonb;
begin
 -- A short, bounded commit fence; never held while a human reviews a dialog.
 perform 1 from public.saas_stores where id=s for update;
 perform tenant_private.offline_device_require(s,d,secret);
 preview:=tenant_private.offline_legacy_review(s,d,secret,req,method,args);
 if preview->>'status'='existing' then return tenant_private.offline_dispatch_v2(s,d,secret,req,method,args);end if;
 if review_digest is null or review_digest !~ '^[a-f0-9]{64}$' or preview->>'digest' is distinct from review_digest then return jsonb_build_object('status','review_required','requestId',req);end if;
 -- Establish a row even for a store with no writes since migration 147.
 insert into tenant_private.offline_snapshot_revisions(store_id,revision,last_tx) values(s,gen_random_uuid(),'review-initial') on conflict(store_id) do nothing;
 perform 1 from tenant_private.offline_snapshot_revisions where store_id=s for update nowait;
 -- Initial sentinel creation is itself a harmless revision change. Requiring a
 -- second preview for the first operation avoids treating a race as reviewed.
 preview:=tenant_private.offline_legacy_review(s,d,secret,req,method,args);
 if preview->>'status'='existing' then return tenant_private.offline_dispatch_v2(s,d,secret,req,method,args);end if;
 if preview->>'digest' is distinct from review_digest then return jsonb_build_object('status','review_required','requestId',req);end if;
 perform set_config('techstore.offline_review_request',req::text,true);
 result:=tenant_private.offline_dispatch_v2(s,d,secret,req,method,args);
 perform set_config('techstore.offline_review_request','',true);
 return result;
exception when lock_not_available or serialization_failure or deadlock_detected then
 return jsonb_build_object('status','review_required','requestId',req);
end $$;
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
 if current_setting('techstore.offline_review_request',true) is distinct from req::text then raise exception 'Fresh online review required' using errcode='40001';end if;
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
create function public.mt_offline_legacy_review(s uuid,d uuid,secret uuid,req uuid,method text,args jsonb) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_legacy_review(s,d,secret,req,method,args)$$;
create function public.mt_offline_dispatch_v3(s uuid,d uuid,secret uuid,req uuid,method text,args jsonb,review_digest text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_dispatch_v3(s,d,secret,req,method,args,review_digest)$$;
revoke all on function tenant_private.offline_legacy_review(uuid,uuid,uuid,uuid,text,jsonb),tenant_private.offline_dispatch_v3(uuid,uuid,uuid,uuid,text,jsonb,text),public.mt_offline_legacy_review(uuid,uuid,uuid,uuid,text,jsonb),public.mt_offline_dispatch_v3(uuid,uuid,uuid,uuid,text,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_legacy_review(uuid,uuid,uuid,uuid,text,jsonb),tenant_private.offline_dispatch_v3(uuid,uuid,uuid,uuid,text,jsonb,text),public.mt_offline_legacy_review(uuid,uuid,uuid,uuid,text,jsonb),public.mt_offline_dispatch_v3(uuid,uuid,uuid,uuid,text,jsonb,text) to authenticated;

-- Serialize metadata insertion permission with the deletion reservation's row
-- lock. Restrict pending offline uploads to the reserving live approved device's
-- actor. This does not claim atomicity of the underlying object-store bytes.
create or replace function tenant_private.product_original_access(p_path text,p_write boolean) returns boolean
language plpgsql volatile security definer set search_path='' set lock_timeout='1500ms' as $$
declare m tenant_private.product_originals%rowtype;u tenant_private.offline_original_uploads%rowtype;
begin
 if auth.uid() is null or p_path is null then return false;end if;
 if not p_write then
  return exists(select 1 from tenant_private.product_originals r where r.object_path=p_path and tenant_private.member_role(r.store_id)='owner' and tenant_private.central_read_permitted(r.store_id,'all_catalog_read'));
 end if;
 select * into m from tenant_private.product_originals where object_path=p_path for update;
 if not found or tenant_private.member_role(m.store_id) is distinct from 'owner'
 or not coalesce(tenant_private.shared_licensed(m.store_id),false)
 or not coalesce(tenant_private.central_read_permitted(m.store_id,'all_catalog_read'),false)
 or tenant_private.central_action_denied(m.store_id,'product_profile_edit')
 or exists(select 1 from tenant_private.offline_original_deletions x where x.store_id=m.store_id and x.asset_id=m.id) then return false;end if;
 select * into u from tenant_private.offline_original_uploads where store_id=m.store_id and request_id=m.id;
 if found then
  if u.actor is distinct from auth.uid() then return false;end if;
  perform 1 from tenant_private.offline_devices where store_id=m.store_id and id=u.device_id and actor=auth.uid() and state='approved' for share;
  if not found then return false;end if;
 end if;
 return true;
end $$;
CREATE OR REPLACE FUNCTION tenant_private.product_original_publish(p_store uuid, p_id uuid, p_enabled boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r tenant_private.product_originals%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if tenant_private.central_action_denied(p_store,'product_profile_edit') then raise exception 'Product edit denied' using errcode='42501';end if;
 select * into r from tenant_private.product_originals where store_id=p_store and id=p_id for update;
 if not found or p_enabled is null or exists(select 1 from tenant_private.offline_original_deletions where store_id=p_store and asset_id=p_id) then raise exception 'Invalid or retired asset' using errcode='22023';end if;
 if p_enabled and exists(select 1 from tenant_private.offline_original_uploads u where u.store_id=p_store and u.request_id=p_id and not exists(select 1 from tenant_private.offline_reviewed_requests r where r.store_id=u.store_id and r.request_id=u.request_id and r.result->>'status'='confirmed')) then raise exception 'Offline file verification pending' using errcode='22023';end if;
 if p_enabled and not exists(select 1 from storage.objects where bucket_id='saas-design-originals' and name=r.object_path) then raise exception 'Upload first' using errcode='22023';end if;
 update tenant_private.product_originals set published=p_enabled where store_id=p_store and id=p_id;return p_enabled;
end $function$;

-- Read-only repair dashboard for reservations: no object deletion, no receipt
-- mutation and no cross-tenant read. Continue an exact operation on its device.
create function tenant_private.offline_image_jobs(s uuid,d uuid,secret uuid,after_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 if tenant_private.member_role(s) is distinct from 'owner' or auth.jwt()->>'aal' is distinct from 'aal2' or not coalesce(tenant_private.central_read_permitted(s,'all_catalog_read'),false) then raise exception 'Owner AAL2 required' using errcode='42501';end if;
 with jobs as (
 select u.request_id,u.product_id,u.request_id asset_id,u.device_id,u.created_at,'upload'::text kind,
 case when r.result->>'status'='confirmed' then 'confirmed' when r.result->>'status'='conflict' then 'conflict' when m.id is null then 'metadata_missing' when exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=m.object_path) then 'verification_pending' else 'upload_pending' end state
 from tenant_private.offline_original_uploads u left join tenant_private.product_originals m on m.store_id=u.store_id and m.id=u.request_id left join tenant_private.offline_reviewed_requests r on r.store_id=u.store_id and r.request_id=u.request_id where u.store_id=s
 union all
 select x.request_id,x.product_id,x.asset_id,x.device_id,x.created_at,'delete',
 case when x.state='deleted' and exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=s::text||'/'||x.asset_id::text||'.jpg') then 'storage_mismatch'
 when x.state='deleted' then 'confirmed' when exists(select 1 from storage.objects o where o.bucket_id='saas-design-originals' and o.name=s::text||'/'||x.asset_id::text||'.jpg') then 'delete_pending' else 'finalization_pending' end
 from tenant_private.offline_original_deletions x where x.store_id=s
 ) select coalesce(jsonb_agg(to_jsonb(j) order by j.request_id),'[]'::jsonb) into result from (select * from jobs where after_id is null or request_id>after_id order by request_id limit 50) j;
 return result;
end $$;
create function public.mt_offline_image_jobs(s uuid,d uuid,secret uuid,after_id uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_image_jobs(s,d,secret,after_id)$$;
revoke all on function tenant_private.offline_image_jobs(uuid,uuid,uuid,uuid),public.mt_offline_image_jobs(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_image_jobs(uuid,uuid,uuid,uuid),public.mt_offline_image_jobs(uuid,uuid,uuid,uuid) to authenticated;
commit;
