-- 129: actual external-payment documentation, not a payment provider or simulated payment.
begin;
create table tenant_private.offline_billing_invoices(
 id uuid primary key,store_id uuid not null references tenant_private.workspaces(store_id),
 plan_code text not null references public.saas_plans(code),plan_name text not null,store_name text not null,
 period_start date not null,period_end date not null,currency text not null default 'USD' check(currency='USD'),
 amount_cents integer not null check(amount_cents between 100 and 10000000),reference text not null check(length(btrim(reference)) between 1 and 200),
 actor uuid not null,created_at timestamptz not null default now(),voided_at timestamptz,voided_by uuid,void_reference text,
 unique(store_id,id),unique(store_id,period_start),check(period_end=(period_start+interval '1 month')::date and extract(day from period_start)=1)
);
create table tenant_private.offline_billing_payments(
 id uuid primary key,store_id uuid not null,invoice_id uuid not null,
 kind text not null check(kind in ('payment','refund')),original_id uuid,
 amount_cents integer not null check(amount_cents between 1 and 10000000),
 channel text not null check(channel in ('cash','bank_transfer','other_external')),
 document_ref text not null check(length(btrim(document_ref)) between 1 and 160),
 occurred_on date not null,actor uuid not null,created_at timestamptz not null default now(),
 foreign key(store_id,invoice_id) references tenant_private.offline_billing_invoices(store_id,id),
 foreign key(original_id) references tenant_private.offline_billing_payments(id),
 unique(store_id,document_ref),check((kind='refund')=(original_id is not null))
);
create index offline_billing_payment_invoice on tenant_private.offline_billing_payments(store_id,invoice_id,created_at,id);
create table tenant_private.offline_billing_actions(
 id uuid primary key,store_id uuid not null,invoice_id uuid not null,kind text not null check(kind in ('activate','void')),
 reference text not null check(length(btrim(reference)) between 1 and 200),actor uuid not null,created_at timestamptz not null default now(),
 foreign key(store_id,invoice_id) references tenant_private.offline_billing_invoices(store_id,id)
);
alter table tenant_private.offline_billing_invoices enable row level security;
alter table tenant_private.offline_billing_payments enable row level security;
alter table tenant_private.offline_billing_actions enable row level security;
revoke all on tenant_private.offline_billing_invoices,tenant_private.offline_billing_payments,tenant_private.offline_billing_actions from public,anon,authenticated;
alter table tenant_private.admin_manual_licenses add column offline_invoice_id uuid;
alter table tenant_private.admin_manual_licenses add foreign key(store_id,offline_invoice_id) references tenant_private.offline_billing_invoices(store_id,id);

create function tenant_private.offline_invoice_balance(s uuid,i uuid) returns bigint language sql stable security definer set search_path='' as $$
 select coalesce(sum(case when kind='payment' then amount_cents else -amount_cents end),0)::bigint from tenant_private.offline_billing_payments where store_id=s and invoice_id=i
$$;
create function tenant_private.offline_invoice_settled(s uuid,i uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from tenant_private.offline_billing_invoices v where v.store_id=s and v.id=i and v.voided_at is null and v.amount_cents=tenant_private.offline_invoice_balance(s,i))
$$;
revoke all on function tenant_private.offline_invoice_balance(uuid,uuid),tenant_private.offline_invoice_settled(uuid,uuid) from public,anon,authenticated;

create function tenant_private.offline_billing_lock(s uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Operator MFA required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=s for update;
 if not exists(select 1 from tenant_private.workspaces where store_id=s) then raise exception 'Shared store required';end if;
 perform 1 from public.saas_subscriptions where store_id=s for update;
 perform 1 from tenant_private.billing_configuration where singleton for update;
 lock table tenant_private.payment_bindings in share mode;
 if exists(select 1 from tenant_private.billing_configuration where live_enabled) or exists(select 1 from tenant_private.payment_bindings where store_id=s) then raise exception 'External provider-linked billing requires a separate workflow';end if;
end $$;
revoke all on function tenant_private.offline_billing_lock(uuid) from public,anon,authenticated;

create function tenant_private.offline_billing_create(s uuid,req uuid,month_value date,expected_plan text,expected_price integer,proof text) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.offline_billing_invoices%rowtype;st public.saas_stores%rowtype;p public.saas_plans%rowtype;today date:=(now() at time zone 'Asia/Damascus')::date;
begin
 perform tenant_private.offline_billing_lock(s);
 if req is null or month_value is null or extract(day from month_value)<>1 or month_value<date_trunc('month',today)::date or month_value>(date_trunc('month',today)+interval '1 month')::date or expected_plan is null or expected_price is null or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid invoice period or reference';end if;
 select * into v from tenant_private.offline_billing_invoices where id=req;
 if found then
  if v.store_id<>s or v.period_start<>month_value or v.plan_code<>expected_plan or v.amount_cents<>expected_price or v.reference<>btrim(proof) or v.actor<>auth.uid() then raise exception 'Conflicting invoice request';end if;return req;
 end if;
 select * into strict st from public.saas_stores where id=s;
 if st.state<>'provisioning' or st.project_ref is not null or st.origin is not null then raise exception 'Open shared store required';end if;
 select p0.* into strict p from public.saas_subscriptions sub join public.saas_plans p0 on p0.code=sub.plan_code where sub.store_id=s for share of p0;
 if p.code<>expected_plan or p.monthly_usd_cents<>expected_price then raise exception 'Plan or price changed; reload';end if;
 insert into tenant_private.offline_billing_invoices(id,store_id,plan_code,plan_name,store_name,period_start,period_end,amount_cents,reference,actor) values(req,s,p.code,p.name,st.name,month_value,(month_value+interval '1 month')::date,p.monthly_usd_cents,btrim(proof),auth.uid());
 return req;
end $$;

create function tenant_private.offline_billing_record(s uuid,req uuid,i uuid,k text,orig uuid,amount integer,method text,proof text,day_value date,expected bigint) returns uuid language plpgsql security definer set search_path='' as $$
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
  update public.saas_subscriptions set state='pending',valid_until=null,updated_at=now() where store_id=s;
 end if;
 return req;
end $$;

create function tenant_private.offline_billing_action(s uuid,req uuid,i uuid,k text,proof text) returns uuid language plpgsql security definer set search_path='' as $$
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
  if net<>0 or exists(select 1 from tenant_private.admin_manual_licenses where store_id=s and offline_invoice_id=i) then raise exception 'Refund all external receipts before voiding';end if;
  update tenant_private.offline_billing_invoices set voided_at=now(),voided_by=auth.uid(),void_reference=btrim(proof) where id=i;
 else
  select * into strict sub from public.saas_subscriptions where store_id=s;
  expiry:=v.period_end::timestamp at time zone 'Asia/Damascus';
  if net<>v.amount_cents or now()<v.period_start::timestamp at time zone 'Asia/Damascus' or now()>=expiry or sub.plan_code<>v.plan_code or sub.state not in ('pending','trial','active','past_due') or (sub.valid_until is not null and sub.valid_until>expiry) or exists(select 1 from tenant_private.admin_manual_licenses where store_id=s and offline_invoice_id=i) or not exists(select 1 from public.saas_stores st join tenant_private.placements p on p.store_id=st.id join tenant_private.shards sh on sh.code=p.shard_code and sh.state='local' where st.id=s and st.state='provisioning' and st.project_ref is null and st.origin is null) then raise exception 'Paid current period and compatible subscription required';end if;
  update public.saas_subscriptions set state='active',valid_until=expiry,updated_at=now() where store_id=s;
  insert into tenant_private.admin_manual_licenses(store_id,plan_code,valid_until,request_id,actor,reference,offline_invoice_id) values(s,v.plan_code,expiry,req,auth.uid(),btrim(proof),i)
  on conflict(store_id) do update set plan_code=excluded.plan_code,valid_until=excluded.valid_until,request_id=excluded.request_id,actor=excluded.actor,reference=excluded.reference,offline_invoice_id=excluded.offline_invoice_id,issued_at=now();
 end if;
 insert into tenant_private.offline_billing_actions(id,store_id,invoice_id,kind,reference,actor) values(req,s,i,k,btrim(proof),auth.uid());return req;
end $$;

create function tenant_private.offline_billing_review(s uuid,off integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare data jsonb;v jsonb;op boolean:=coalesce(saas_private.is_operator(),false);
begin
 if not op and tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Billing access denied' using errcode='42501';end if;
 if off is null or off not between 0 and 100000 then raise exception 'Invalid page';end if;
 select jsonb_build_object('plan',p.code,'name',p.name,'price',p.monthly_usd_cents,'editable',op and not exists(select 1 from tenant_private.billing_configuration where live_enabled) and not exists(select 1 from tenant_private.payment_bindings where store_id=s)) into v from public.saas_subscriptions sub join public.saas_plans p on p.code=sub.plan_code where sub.store_id=s;
 if v is null then raise exception 'No subscription';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by period_start desc,id),'[]'::jsonb) into data from (
 select i.id,i.store_id,i.store_name,i.plan_name,i.plan_code,i.period_start,i.period_end,i.amount_cents,i.currency,i.reference,i.created_at,i.voided_at,i.void_reference,tenant_private.offline_invoice_balance(s,i.id) net_cents,
 exists(select 1 from tenant_private.admin_manual_licenses m where m.store_id=s and m.offline_invoice_id=i.id and tenant_private.shared_licensed(s)) licensed,
 case when i.voided_at is not null then 'void' when tenant_private.offline_invoice_settled(s,i.id) then 'paid' when tenant_private.offline_invoice_balance(s,i.id)>0 then 'partial' when exists(select 1 from tenant_private.offline_billing_payments where store_id=s and invoice_id=i.id and kind='refund') then 'refunded' else 'unpaid' end state
 from tenant_private.offline_billing_invoices i where i.store_id=s order by period_start desc,id offset off limit 51)x;
 return v||jsonb_build_object('rows',case when jsonb_array_length(data)>50 then data-50 else data end,'more',jsonb_array_length(data)>50);
end $$;

create function tenant_private.offline_billing_details(s uuid,i uuid,off integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare data jsonb;v jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) and tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Billing access denied' using errcode='42501';end if;
 if off is null or off not between 0 and 100000 or not exists(select 1 from tenant_private.offline_billing_invoices where store_id=s and id=i) then raise exception 'Invalid invoice';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc,id),'[]'::jsonb) into data from (select p.id,p.kind,p.original_id,p.amount_cents,p.channel,p.document_ref,p.occurred_on,p.created_at,case when p.kind='payment' then p.amount_cents-(select coalesce(sum(amount_cents),0) from tenant_private.offline_billing_payments r where r.store_id=s and r.original_id=p.id and r.kind='refund') else 0 end refundable from tenant_private.offline_billing_payments p where p.store_id=s and p.invoice_id=i order by p.created_at desc,p.id offset off limit 51)x;
 return jsonb_build_object('net_cents',tenant_private.offline_invoice_balance(s,i),'rows',case when jsonb_array_length(data)>50 then data-50 else data end,'more',jsonb_array_length(data)>50,'actions',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id) from (select id,kind,reference,created_at from tenant_private.offline_billing_actions where store_id=s and invoice_id=i order by created_at desc,id limit 50)x),'[]'::jsonb));
end $$;

CREATE OR REPLACE FUNCTION tenant_private.admin_plan_catalog_change(req uuid, action text, code_value text, expected jsonb, params jsonb, proof text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.saas_plans%rowtype;e tenant_private.admin_plan_catalog_events%rowtype;beforev jsonb;afterv jsonb;name_value text;price integer;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if req is null or action is null or action not in ('create','rename','delete') or code_value is null or code_value !~ '^[a-z][a-z0-9-]{2,39}$' or jsonb_typeof(params) is distinct from 'object' or octet_length(params::text)>1000 or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid catalog action' using errcode='22023';end if;
 perform 1 from tenant_private.billing_configuration where singleton for update;
 lock table tenant_private.payment_bindings in share mode;
 select * into e from tenant_private.admin_plan_catalog_events where request_id=req;
 if found then
  if e.plan_code<>code_value or e.actor<>auth.uid() or e.action<>action or e.reference<>btrim(proof) or e.params<>params or e.before_state is distinct from expected then raise exception 'Conflicting catalog request';end if;return req;
 end if;
 if exists(select 1 from tenant_private.billing_configuration where live_enabled) or exists(select 1 from tenant_private.payment_bindings) then raise exception 'Managed provider catalog required';end if;
 select * into p from public.saas_plans where code=code_value for update;
 if found then beforev:=to_jsonb(p);end if;
 if beforev is distinct from expected then raise exception 'Plan changed; reload';end if;
 if action='create' then
  if beforev is not null or (select count(*) from public.saas_plans)>=50 or exists(select 1 from tenant_private.admin_plan_catalog_events where plan_code=code_value) or (select count(*) from jsonb_object_keys(params))<>2 or not (params ?& array['name','price']) or coalesce(params->>'price','') !~ '^[0-9]{1,8}$' then raise exception 'Unavailable plan code or capacity';end if;
  name_value:=btrim(coalesce(params->>'name',''));price:=(params->>'price')::integer;
  if length(name_value) not between 1 and 100 or price not between 100 and 10000000 then raise exception 'Invalid plan name or price';end if;
  insert into public.saas_plans(code,name,monthly_usd_cents) values(code_value,name_value,price);
  insert into tenant_private.admin_plan_policy(plan_code,enrollment) values(code_value,false);
 elsif action='rename' then
  if beforev is null or (select count(*) from jsonb_object_keys(params))<>1 or length(btrim(coalesce(params->>'name',''))) not between 1 and 100 then raise exception 'Invalid plan name';end if;
  name_value:=btrim(params->>'name');if name_value=p.name then raise exception 'Name unchanged';end if;
  update public.saas_plans set name=name_value where code=code_value;
 else
  if beforev is null or params<>'{}'::jsonb or code_value in ('basic','business','pro') then raise exception 'Built-in or missing plan cannot be deleted';end if;
  perform 1 from tenant_private.admin_plan_policy where plan_code=code_value for update;
  if exists(select 1 from public.saas_subscriptions where plan_code=code_value) or exists(select 1 from tenant_private.admin_plan_policy_events where plan_code=code_value) or exists(select 1 from tenant_private.plan_price_history where plan_code=code_value) or exists(select 1 from saas_private.billing_sandbox_invoices where plan_code=code_value) or exists(select 1 from tenant_private.paid_periods where plan_code=code_value) or exists(select 1 from tenant_private.admin_manual_licenses where plan_code=code_value) or exists(select 1 from tenant_private.offline_billing_invoices where plan_code=code_value) then raise exception 'Referenced plan must be retired by closing enrollment';end if;
  delete from tenant_private.admin_plan_policy where plan_code=code_value;
  delete from public.saas_plans where code=code_value;
 end if;
 select to_jsonb(p0) into afterv from public.saas_plans p0 where code=code_value;
 insert into tenant_private.admin_plan_catalog_events(request_id,plan_code,actor,action,reference,params,before_state,after_state) values(req,code_value,auth.uid(),action,btrim(proof),params,beforev,afterv);
 return req;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.admin_plan_catalog_review()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return jsonb_build_object('editable',not exists(select 1 from tenant_private.billing_configuration where live_enabled) and not exists(select 1 from tenant_private.payment_bindings),
 'plans',coalesce((select jsonb_agg(to_jsonb(x) order by code) from (select p.code,p.name,p.monthly_usd_cents,q.enrollment,q.revision,(select count(*) from public.saas_subscriptions where plan_code=p.code) subscribers,
 (not exists(select 1 from public.saas_subscriptions where plan_code=p.code) and not exists(select 1 from tenant_private.plan_price_history where plan_code=p.code) and not exists(select 1 from tenant_private.admin_plan_policy_events where plan_code=p.code) and not exists(select 1 from saas_private.billing_sandbox_invoices where plan_code=p.code) and not exists(select 1 from tenant_private.paid_periods where plan_code=p.code) and not exists(select 1 from tenant_private.admin_manual_licenses where plan_code=p.code) and not exists(select 1 from tenant_private.offline_billing_invoices where plan_code=p.code) and p.code not in ('basic','business','pro')) deletable
 from public.saas_plans p join tenant_private.admin_plan_policy q on q.plan_code=p.code)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id) from (select request_id,plan_code,actor,action,reference,before_state,after_state,created_at from tenant_private.admin_plan_catalog_events order by created_at desc,request_id limit 50)x),'[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.admin_store_change(s uuid, req uuid, action text, expected jsonb, params jsonb, proof text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old tenant_private.admin_store_events%rowtype;v jsonb;nextv jsonb;days integer;expiry timestamptz;plan text;title text;manual boolean;bound boolean;live boolean;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if s is null or req is null or action is null or action not in ('grant','renew','revoke','plan','pause_shop','resume_shop','rename','trial','suspend','cancel','reopen') or jsonb_typeof(expected) is distinct from 'object' or octet_length(expected::text)>10000 or jsonb_typeof(params) is distinct from 'object' or octet_length(params::text)>2000 or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid administrative request' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=s for update;
 if not found then raise exception 'Store unavailable';end if;
 perform 1 from public.saas_subscriptions where store_id=s for update;
 select * into old from tenant_private.admin_store_events where request_id=req;
 if found then
  if old.store_id<>s or old.actor<>auth.uid() or old.action<>action or old.reference<>btrim(proof) or old.params<>params or old.before_state<>expected then raise exception 'Conflicting administrative request' using errcode='22023';end if;
  return req;
 end if;
 v:=tenant_private.admin_store_snapshot(s);
 if v is null or v<>expected then raise exception 'Store state changed; reload before confirmation' using errcode='22023';end if;
 manual:=v->>'manual_request' is not null;
 bound:=(v->>'provider_bound')::boolean;
 live:=(v->>'live_billing')::boolean;
 if action in ('grant','renew','trial') then
  if not (params ? 'days') or (select count(*) from jsonb_object_keys(params))<>1 or coalesce(params->>'days','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid duration';end if;
  days:=(params->>'days')::integer;
  if days<1 or days>365 or (action='trial' and days>30) then raise exception 'Invalid duration';end if;
 elsif action='plan' then
  if (select count(*) from jsonb_object_keys(params))<>1 or not exists(select 1 from public.saas_plans where code=params->>'plan') then raise exception 'Invalid plan';end if;
  plan:=params->>'plan';
 elsif action='rename' then
  if (select count(*) from jsonb_object_keys(params))<>1 or length(btrim(coalesce(params->>'name',''))) not between 1 and 160 then raise exception 'Invalid name';end if;
  title:=btrim(params->>'name');
 elsif params<>'{}'::jsonb then raise exception 'Unexpected parameters';end if;
 if action in ('grant','renew','revoke','plan','trial') then
  perform 1 from tenant_private.billing_configuration where singleton for update;
  lock table tenant_private.payment_bindings in share mode;
  if bound or live or exists(select 1 from tenant_private.payment_bindings where store_id=s) or exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled) then raise exception 'Provider-linked billing requires a separate managed workflow' using errcode='22023';end if;
  if v->>'state'<>'provisioning' or not (v->>'local')::boolean then raise exception 'Open local shared store required';end if;
 end if;
 if action in ('grant','renew') then
  if action='grant' and (manual or v->>'subscription_state' not in ('pending','trial','past_due')) then raise exception 'Use renewal or revoke existing license first';end if;
  if action='renew' and (v->>'offline_invoice' is not null or not manual or v->>'subscription_state'<>'active') then raise exception 'Manual license required';end if;
  expiry:=case when action='renew' then greatest(now(),(v->>'manual_until')::timestamptz) else now() end +make_interval(days=>days);
  if expiry>now()+interval '730 days' then raise exception 'Manual validity cannot exceed 730 days';end if;
  update public.saas_subscriptions set state='active',valid_until=expiry,updated_at=now() where store_id=s;
  insert into tenant_private.admin_manual_licenses(store_id,plan_code,valid_until,request_id,actor,reference) values(s,v->>'plan',expiry,req,auth.uid(),btrim(proof));
 elsif action='revoke' then
  if not manual then raise exception 'Manual license required';end if;
  update public.saas_subscriptions set state='pending',valid_until=null,updated_at=now() where store_id=s;
 elsif action='plan' then
  if v->>'plan'=plan or (v->>'subscription_state' not in ('pending','trial','past_due') and not manual) then raise exception 'Plan change unavailable';end if;
  -- Explicitly revoke old entitlement; a new license must be issued for the new plan.
  update public.saas_subscriptions set plan_code=plan,state='pending',valid_until=null,updated_at=now() where store_id=s;
 elsif action in ('pause_shop','resume_shop') then
  if (v->>'storefront_paused')::boolean=(action='pause_shop') then raise exception 'Visibility unchanged';end if;
  insert into tenant_private.admin_store_controls(store_id,storefront_paused) values(s,action='pause_shop') on conflict(store_id) do update set storefront_paused=excluded.storefront_paused,updated_at=now();
 elsif action='rename' then
  if v->>'name'=title then raise exception 'Name unchanged';end if;
  update public.saas_stores set name=title where id=s;
 else
  perform saas_private.manage_store(s,action,days);
 end if;
 nextv:=tenant_private.admin_store_snapshot(s);
 insert into tenant_private.admin_store_events(request_id,store_id,actor,action,reference,params,before_state,after_state) values(req,s,auth.uid(),action,btrim(proof),params,v,nextv);
 return req;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.admin_store_snapshot(s uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select jsonb_build_object('id',st.id,'name',st.name,'slug',st.slug,'state',st.state,'plan',sub.plan_code,'subscription_state',sub.state,'valid_until',sub.valid_until,'subscription_updated',sub.updated_at,
 'manual_request',m.request_id,'manual_reference',m.reference,'manual_until',m.valid_until,'offline_invoice',m.offline_invoice_id,
 'storefront_paused',coalesce(c.storefront_paused,false),'control_updated',c.updated_at,
 'provider_bound',exists(select 1 from tenant_private.payment_bindings where store_id=s),
 'live_billing',exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled),
 'local',exists(select 1 from tenant_private.placements p join tenant_private.shards sh on sh.code=p.shard_code and sh.state='local' where p.store_id=s))
 from tenant_private.workspaces w join public.saas_stores st on st.id=w.store_id join public.saas_subscriptions sub on sub.store_id=w.store_id
 left join tenant_private.admin_manual_licenses m on m.store_id=w.store_id left join tenant_private.admin_store_controls c on c.store_id=w.store_id
 where w.store_id=s and st.project_ref is null and st.origin is null
$function$
;

CREATE OR REPLACE FUNCTION tenant_private.shared_licensed(p_store uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(
 select 1 from tenant_private.workspaces w join tenant_private.placements p on p.store_id=w.store_id join tenant_private.shards sh on sh.code=p.shard_code and sh.state='local'
 join public.saas_stores s on s.id=w.store_id join public.saas_subscriptions sub on sub.store_id=s.id
 where w.store_id=p_store and s.state='provisioning' and s.project_ref is null and s.origin is null and sub.valid_until>now()
 and (sub.state='trial' or (sub.state='active' and exists(select 1 from tenant_private.admin_manual_licenses m where m.store_id=w.store_id and m.plan_code=sub.plan_code and m.valid_until=sub.valid_until and m.valid_until>now() and (m.offline_invoice_id is null or tenant_private.offline_invoice_settled(m.store_id,m.offline_invoice_id))) and not exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled) and not exists(select 1 from tenant_private.payment_bindings where store_id=w.store_id)) or (sub.state='active' and exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled)
 and exists(select 1 from tenant_private.payment_bindings b join tenant_private.paid_periods pp on pp.store_id=b.store_id and pp.provider=b.provider and pp.account_id=b.account_id and pp.plan_code=b.plan_code
 where b.store_id=p_store and b.enabled and b.plan_code=sub.plan_code and pp.state='paid' and pp.period_start<=now() and pp.period_end>now() and pp.period_end>=sub.valid_until)))
 )
$function$
;
create function public.mt_offline_billing_review(s uuid,off integer) returns jsonb language sql stable set search_path='' as $$select tenant_private.offline_billing_review(s,off)$$;
create function public.mt_offline_billing_details(s uuid,i uuid,off integer) returns jsonb language sql stable set search_path='' as $$select tenant_private.offline_billing_details(s,i,off)$$;
create function public.mt_offline_billing_create(s uuid,req uuid,month_value date,expected_plan text,expected_price integer,proof text) returns uuid language sql set search_path='' as $$select tenant_private.offline_billing_create(s,req,month_value,expected_plan,expected_price,proof)$$;
create function public.mt_offline_billing_record(s uuid,req uuid,i uuid,k text,orig uuid,amount integer,method text,proof text,day_value date,expected bigint) returns uuid language sql set search_path='' as $$select tenant_private.offline_billing_record(s,req,i,k,orig,amount,method,proof,day_value,expected)$$;
create function public.mt_offline_billing_action(s uuid,req uuid,i uuid,k text,proof text) returns uuid language sql set search_path='' as $$select tenant_private.offline_billing_action(s,req,i,k,proof)$$;
revoke all on function tenant_private.offline_billing_review(uuid,integer),public.mt_offline_billing_review(uuid,integer) from public,anon,authenticated;
grant execute on function tenant_private.offline_billing_review(uuid,integer),public.mt_offline_billing_review(uuid,integer) to authenticated;
revoke all on function tenant_private.offline_billing_details(uuid,uuid,integer),public.mt_offline_billing_details(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function tenant_private.offline_billing_details(uuid,uuid,integer),public.mt_offline_billing_details(uuid,uuid,integer) to authenticated;
revoke all on function tenant_private.offline_billing_create(uuid,uuid,date,text,integer,text),public.mt_offline_billing_create(uuid,uuid,date,text,integer,text) from public,anon,authenticated;
grant execute on function tenant_private.offline_billing_create(uuid,uuid,date,text,integer,text),public.mt_offline_billing_create(uuid,uuid,date,text,integer,text) to authenticated;
revoke all on function tenant_private.offline_billing_record(uuid,uuid,uuid,text,uuid,integer,text,text,date,bigint),public.mt_offline_billing_record(uuid,uuid,uuid,text,uuid,integer,text,text,date,bigint) from public,anon,authenticated;
grant execute on function tenant_private.offline_billing_record(uuid,uuid,uuid,text,uuid,integer,text,text,date,bigint),public.mt_offline_billing_record(uuid,uuid,uuid,text,uuid,integer,text,text,date,bigint) to authenticated;
revoke all on function tenant_private.offline_billing_action(uuid,uuid,uuid,text,text),public.mt_offline_billing_action(uuid,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function tenant_private.offline_billing_action(uuid,uuid,uuid,text,text),public.mt_offline_billing_action(uuid,uuid,uuid,text,text) to authenticated;
commit;
