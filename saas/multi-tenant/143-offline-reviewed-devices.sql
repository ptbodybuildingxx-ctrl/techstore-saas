-- Staged migration: enrolled browser installations and request-bound reviewed writes.
-- Install only after verified recoverability and approval. No Auth or existing data mutation.
begin;
create table tenant_private.offline_devices(
 store_id uuid not null references public.saas_stores(id), actor uuid not null,
 id uuid not null, secret_hash text not null check(secret_hash ~ '^[0-9a-f]{64}$'),
 label text not null check(length(label) between 1 and 100),
 state text not null default 'pending' check(state in ('pending','approved','revoked')),
 created_at timestamptz not null default now(), changed_at timestamptz not null default now(),
 changed_by uuid, primary key(store_id,id)
);
create table tenant_private.offline_reviewed_requests(
 store_id uuid not null references public.saas_stores(id), request_id uuid not null, actor uuid not null,
 device_id uuid not null, payload jsonb not null, result jsonb not null,
 created_at timestamptz not null default now(), primary key(store_id,request_id),
 foreign key(store_id,device_id) references tenant_private.offline_devices(store_id,id)
);
alter table tenant_private.offline_devices enable row level security;
alter table tenant_private.offline_reviewed_requests enable row level security;
revoke all on tenant_private.offline_devices,tenant_private.offline_reviewed_requests from public,anon,authenticated,service_role;

create function tenant_private.offline_device_register(s uuid,d uuid,secret uuid,n text) returns text
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); old tenant_private.offline_devices%rowtype;
begin
 if u is null or tenant_private.member_role(s) is null then raise exception 'Membership required' using errcode='42501';end if;
 if d is null or secret is null or n is null or length(btrim(n)) not between 1 and 100 then raise exception 'Invalid device' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into old from tenant_private.offline_devices where store_id=s and id=d;
 if found then
  if old.actor<>u or old.secret_hash<>encode(sha256(convert_to(secret::text,'UTF8')),'hex') then raise exception 'Device identity mismatch' using errcode='42501';end if;
  return old.state;
 end if;
 if (select count(*) from tenant_private.offline_devices where store_id=s and actor=u and state<>'revoked')>=10 then raise exception 'Device limit reached' using errcode='22023';end if;
 insert into tenant_private.offline_devices(store_id,actor,id,secret_hash,label) values(s,u,d,encode(sha256(convert_to(secret::text,'UTF8')),'hex'),btrim(n));
 return 'pending';
end $$;

create function tenant_private.offline_device_list(s uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(s);
begin
 if role_now is null then raise exception 'Membership required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id) from (
 select id,actor,label,state,created_at,changed_at from tenant_private.offline_devices
 where store_id=s and (actor=auth.uid() or role_now='owner') order by created_at desc,id limit 100)x),'[]'::jsonb);
end $$;

create function tenant_private.offline_device_change(s uuid,d uuid,desired text) returns text
language plpgsql security definer set search_path='' as $$
declare x tenant_private.offline_devices%rowtype;
begin
 if tenant_private.member_role(s) is distinct from 'owner' or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner AAL2 required' using errcode='42501';end if;
 if desired is null or desired not in ('approved','revoked') then raise exception 'Invalid state' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into x from tenant_private.offline_devices where store_id=s and id=d for update;
 if not found or x.state='revoked' and desired='approved' then raise exception 'Device missing or permanently revoked' using errcode='22023';end if;
 if x.state=desired then return desired;end if;
 if desired='approved' and not exists(select 1 from tenant_private.members m where m.store_id=s and m.user_id=x.actor and m.active) then raise exception 'Active membership required' using errcode='42501';end if;
 update tenant_private.offline_devices set state=desired,changed_at=now(),changed_by=auth.uid() where store_id=s and id=d;
 return desired;
end $$;

create function tenant_private.offline_device_require(s uuid,d uuid,secret uuid) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is null or d is null or secret is null then raise exception 'Live membership and device required' using errcode='42501';end if;
 perform 1 from tenant_private.offline_devices where store_id=s and id=d and actor=auth.uid() and state='approved' and secret_hash=encode(sha256(convert_to(secret::text,'UTF8')),'hex') for share;
 if not found then raise exception 'Device not approved' using errcode='42501';end if;
 return true;
end $$;

-- Existing owner_write takes the store lock. This serializes price/payroll checks and
-- writes with ordinary store writes and device approval/revocation. A receipt is atomic.
create function tenant_private.offline_reviewed_write(s uuid,d uuid,secret uuid,op jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare req uuid;k text;old tenant_private.offline_reviewed_requests%rowtype;res jsonb;pid uuid;expected bigint;actual bigint;rid uuid;cur text;ch text;st text;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>18000 or (op->>'store')::uuid is distinct from s then raise exception 'Invalid offline payload' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;k:=op->>'kind';
 if req is null or k is null or k not in ('reviewedPrice','payrollFinal','payrollAdvance','payrollOffset','orderConfirm','taxFiling','branchApproval') then raise exception 'Unknown reviewed operation' using errcode='22023';end if;
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
  return old.result;
 end if;
 if k='reviewedPrice' then
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
 elsif k='orderConfirm' then
  pid:=(op->>'order')::uuid;ch:=op->>'channel';
  if pid is null or ch is null or ch not in ('online','guest') then raise exception 'Invalid order' using errcode='22023';end if;
  if tenant_private.central_action_denied(s,'all_order_edit') or not tenant_private.central_read_permitted(s,'all_order_read') then raise exception 'Order access denied' using errcode='42501';end if;
  if ch='online' then select state into st from public.mt_online_orders where store_id=s and id=pid for update;
  else select state into st from tenant_private.guest_orders where store_id=s and id=pid for update;end if;
  if st is distinct from 'pending' then res:=jsonb_build_object('status','conflict','requestId',req,'current',st);
  elsif public.mt_confirm_shop_order(s,pid,ch) is distinct from true then raise exception 'Order unconfirmed';end if;
 elsif k='taxFiling' then
  rid:=public.mt_sy_tax_filing_record(s,req,op->>'taxKind',op->>'currency',(op->>'from')::date,(op->>'to')::date,(op->>'previous')::uuid,op->>'digest',(op->>'filedOn')::date,op->>'authority',op->>'reference',op->>'legal',(op->>'declared')::bigint,op->>'explanation',(op->>'confirm')::boolean);
  if rid is distinct from req then raise exception 'Filing evidence unconfirmed';end if;
 elsif k='branchApproval' then
  rid:=public.mt_branch_result_approve_reviewed(s,req,(op->>'from')::date,(op->>'to')::date,(op->>'previous')::uuid,op->>'proof',(op->>'confirm')::boolean,op->>'digest');
  if rid is distinct from req then raise exception 'Approval unconfirmed';end if;
 end if;
 if res is null then res:=jsonb_build_object('status','confirmed','requestId',req);end if;
 insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,res);
 return res;
end $$;
create function public.mt_offline_device_register(s uuid,d uuid,secret uuid,n text) returns text language sql set search_path='' as $$select tenant_private.offline_device_register(s,d,secret,n)$$;
create function public.mt_offline_device_list(s uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.offline_device_list(s)$$;
create function public.mt_offline_device_change(s uuid,d uuid,desired text) returns text language sql set search_path='' as $$select tenant_private.offline_device_change(s,d,desired)$$;
create function public.mt_offline_device_require(s uuid,d uuid,secret uuid) returns boolean language sql set search_path='' as $$select tenant_private.offline_device_require(s,d,secret)$$;
create function public.mt_offline_reviewed_write(s uuid,d uuid,secret uuid,op jsonb) returns jsonb language sql set search_path='' as $$select tenant_private.offline_reviewed_write(s,d,secret,op)$$;
revoke all on function tenant_private.offline_device_register(uuid,uuid,uuid,text),tenant_private.offline_device_list(uuid),tenant_private.offline_device_change(uuid,uuid,text),tenant_private.offline_device_require(uuid,uuid,uuid),tenant_private.offline_reviewed_write(uuid,uuid,uuid,jsonb),public.mt_offline_device_register(uuid,uuid,uuid,text),public.mt_offline_device_list(uuid),public.mt_offline_device_change(uuid,uuid,text),public.mt_offline_device_require(uuid,uuid,uuid),public.mt_offline_reviewed_write(uuid,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_device_register(uuid,uuid,uuid,text),tenant_private.offline_device_list(uuid),tenant_private.offline_device_change(uuid,uuid,text),tenant_private.offline_device_require(uuid,uuid,uuid),tenant_private.offline_reviewed_write(uuid,uuid,uuid,jsonb),public.mt_offline_device_register(uuid,uuid,uuid,text),public.mt_offline_device_list(uuid),public.mt_offline_device_change(uuid,uuid,text),public.mt_offline_device_require(uuid,uuid,uuid),public.mt_offline_reviewed_write(uuid,uuid,uuid,jsonb) to authenticated;
-- Every existing queued RPC is a fixed, typed branch; no dynamic SQL or arbitrary calls.
-- Each public RPC delegates to its original permission-checking private function.
-- Ordinary online APIs remain unchanged. The store/device locks and receipt are atomic.
create function tenant_private.offline_dispatch(s uuid,d uuid,secret uuid,req uuid,method text,args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $
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
end $;
create function public.mt_offline_dispatch(s uuid,d uuid,secret uuid,req uuid,method text,args jsonb) returns jsonb language sql set search_path='' as $select tenant_private.offline_dispatch(s,d,secret,req,method,args)$;
revoke all on function tenant_private.offline_dispatch(uuid,uuid,uuid,uuid,text,jsonb),public.mt_offline_dispatch(uuid,uuid,uuid,uuid,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_dispatch(uuid,uuid,uuid,uuid,text,jsonb),public.mt_offline_dispatch(uuid,uuid,uuid,uuid,text,jsonb) to authenticated;

commit;
