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
commit;
