-- Paid entitlement boundary. Disabled by default; no live provider binding is created.
begin;
do $$ begin if to_regclass('tenant_private.cost_postings') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;end $$;
create table tenant_private.billing_configuration(
 singleton boolean primary key default true check(singleton),live_enabled boolean not null default false
);
insert into tenant_private.billing_configuration(singleton,live_enabled) values(true,false);
create table tenant_private.payment_bindings(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 provider text not null check(provider in ('stripe')),account_id text not null check(length(account_id) between 4 and 200),
 subscription_id text not null check(length(subscription_id) between 4 and 200),customer_id text not null check(length(customer_id) between 4 and 200),
 plan_code text not null references public.saas_plans(code),enabled boolean not null default false,
 unique(provider,account_id,subscription_id)
);
create table tenant_private.paid_periods(
 store_id uuid not null references tenant_private.payment_bindings(store_id),provider text not null,account_id text not null,invoice_id text not null,
 plan_code text not null references public.saas_plans(code),period_start timestamptz not null,period_end timestamptz not null,
 amount_cents integer not null check(amount_cents>0),state text not null check(state in ('paid','revoked')),
 evidence_sha256 text not null check(evidence_sha256 ~ '^[0-9a-f]{64}$'),recorded_at timestamptz not null default now(),revoked_at timestamptz,
 primary key(provider,account_id,invoice_id),check(period_end>period_start and period_end<=period_start+interval '32 days'),check((state='revoked')=(revoked_at is not null))
);
create index mt_paid_store_period_idx on tenant_private.paid_periods(store_id,period_end) where state='paid';
create table tenant_private.payment_events(
 provider text not null,account_id text not null,event_id text not null,store_id uuid not null references tenant_private.payment_bindings(store_id),invoice_id text not null,
 action text not null check(action in ('paid','revoked')),evidence_sha256 text not null check(evidence_sha256 ~ '^[0-9a-f]{64}$'),
 recorded_at timestamptz not null default now(),primary key(provider,account_id,event_id)
);
do $$ declare t text;begin foreach t in array array['billing_configuration','payment_bindings','paid_periods','payment_events'] loop
 execute format('alter table tenant_private.%I enable row level security',t);
 execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);
end loop;end $$;
create function tenant_private.shared_licensed(p_store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(
 select 1 from tenant_private.workspaces w join tenant_private.placements p on p.store_id=w.store_id join tenant_private.shards sh on sh.code=p.shard_code and sh.state='local'
 join public.saas_stores s on s.id=w.store_id join public.saas_subscriptions sub on sub.store_id=s.id
 where w.store_id=p_store and s.state='provisioning' and s.project_ref is null and s.origin is null and sub.valid_until>now()
 and (sub.state='trial' or (sub.state='active' and exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled)
 and exists(select 1 from tenant_private.payment_bindings b join tenant_private.paid_periods pp on pp.store_id=b.store_id and pp.provider=b.provider and pp.account_id=b.account_id and pp.plan_code=b.plan_code
 where b.store_id=p_store and b.enabled and b.plan_code=sub.plan_code and pp.state='paid' and pp.period_start<=now() and pp.period_end>now() and pp.period_end>=sub.valid_until))))
 )
$$;
create or replace function tenant_private.can_write(p_store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) in ('owner','stock'),false) and tenant_private.shared_licensed(p_store)
$$;
create or replace function tenant_private.can_sell(p_store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) in ('owner','cashier'),false) and tenant_private.shared_licensed(p_store)
$$;
create or replace function tenant_private.storefront_active(p_store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select tenant_private.shared_licensed(p_store) and exists(select 1 from tenant_private.storefronts where store_id=p_store and enabled)
$$;
create or replace function tenant_private.repair_transition(p_store uuid,p_request uuid,p_repair uuid,p_next text,p_note text) returns text language plpgsql security definer set search_path='' as $$
declare r public.mt_repairs%rowtype; e public.mt_repair_events%rowtype; role_now text;
begin
 role_now:=tenant_private.member_role(p_store);
 if coalesce(role_now,'') not in ('owner','tech') then raise exception 'Repair role required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 role_now:=tenant_private.member_role(p_store);
 if coalesce(role_now,'') not in ('owner','tech') or not tenant_private.shared_licensed(p_store) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_repair is null or p_next is null or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid transition' using errcode='22023';end if;
 if p_next in ('delivered','cancelled') and role_now<>'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into e from public.mt_repair_events where store_id=p_store and request_id=p_request;
 if found then
  if e.actor<>auth.uid() or e.repair_id<>p_repair or e.next_state<>p_next or e.note<>btrim(p_note) then raise exception 'Conflicting repair transition' using errcode='22023';end if;
  return e.next_state;
 end if;
 select * into r from public.mt_repairs where store_id=p_store and id=p_repair for update;
 if not found or not ((r.state='received' and p_next in ('diagnosing','cancelled')) or (r.state='diagnosing' and p_next in ('repairing','cancelled')) or (r.state='repairing' and p_next in ('ready','cancelled')) or (r.state='ready' and p_next in ('delivered','repairing','cancelled'))) then raise exception 'Invalid repair transition' using errcode='22023';end if;
 update public.mt_repairs set state=p_next where store_id=p_store and id=p_repair;
 insert into public.mt_repair_events(store_id,request_id,repair_id,prior_state,next_state,note,actor) values(p_store,p_request,p_repair,r.state,p_next,btrim(p_note),auth.uid());
 return p_next;
end $$;
create function tenant_private.revoke_store_license(p_store uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 update tenant_private.payment_bindings set enabled=false where store_id=p_store;
 update tenant_private.paid_periods set state='revoked',revoked_at=now() where store_id=p_store and state='paid';
end $$;
create or replace function saas_private.manage_store(p_store uuid,p_action text,p_days integer default null) returns void
language plpgsql security definer set search_path='' as $$
declare v_state text; v_plan_state text;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_store is null or p_action is null or p_action not in ('trial','suspend','cancel','reopen') or (p_action='trial' and (p_days is null or p_days not between 1 and 30)) or (p_action<>'trial' and p_days is not null) then raise exception 'Invalid action' using errcode='22023'; end if;
 select state into v_state from public.saas_stores where id=p_store and project_ref is null and origin is null for update;
 if not found then raise exception 'Unprovisioned development store required' using errcode='22023'; end if;
 select state into v_plan_state from public.saas_subscriptions where store_id=p_store for update;
 if not found or v_plan_state not in ('pending','trial','active','past_due','suspended','cancelled') then raise exception 'Development subscription required' using errcode='22023'; end if;
 if p_action='trial' and v_state='provisioning' and v_plan_state in ('pending','trial') then
   update public.saas_subscriptions set state='trial',valid_until=now()+make_interval(days=>p_days),updated_at=now() where store_id=p_store;
 elsif p_action='suspend' and v_state='provisioning' then
   perform tenant_private.revoke_store_license(p_store);
   update public.saas_stores set state='suspended' where id=p_store;
   update public.saas_subscriptions set state='suspended',valid_until=null,updated_at=now() where store_id=p_store;
 elsif p_action='cancel' and v_state in ('provisioning','suspended') then
   perform tenant_private.revoke_store_license(p_store);
   update public.saas_stores set state='closed' where id=p_store;
   update public.saas_subscriptions set state='cancelled',valid_until=null,updated_at=now() where store_id=p_store;
 elsif p_action='reopen' and v_state in ('suspended','closed') then
   update public.saas_stores set state='provisioning' where id=p_store;
   update public.saas_subscriptions set state='pending',valid_until=null,updated_at=now() where store_id=p_store;
 else raise exception 'Invalid state transition' using errcode='22023';
 end if;
 insert into saas_private.admin_audit(actor,store_id,action) values(auth.uid(),p_store,p_action);
end $$;
-- Only a trusted backend with independently reconciled provider evidence may call this boundary.
-- Never grant to browsers. The binding and global live switch are database-admin controlled.
create function tenant_private.apply_verified_period(p_store uuid,p_provider text,p_account text,p_subscription text,p_customer text,p_invoice text,p_event text,p_action text,p_start timestamptz,p_end timestamptz,p_amount integer,p_currency text,p_hash text) returns text
language plpgsql security definer set search_path='' as $$
declare b tenant_private.payment_bindings%rowtype;pp tenant_private.paid_periods%rowtype;e tenant_private.payment_events%rowtype;sub public.saas_subscriptions%rowtype;v_end timestamptz;
begin
 if not exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled) then raise exception 'Live billing disabled' using errcode='42501';end if;
 if p_store is null or p_provider is null or p_provider<>'stripe' or p_account is null or p_subscription is null or p_customer is null or p_invoice is null or length(p_invoice) not between 4 and 200 or p_event is null or length(p_event) not between 4 and 200 or p_action is null or p_action not in ('paid','revoked') or p_start is null or p_end is null or p_end<=p_start or p_end>p_start+interval '32 days' or p_start>now()+interval '32 days' or p_amount is null or p_amount<=0 or p_currency is distinct from 'USD' or p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then raise exception 'Invalid verified period' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store and state='provisioning' and project_ref is null and origin is null for update;
 if not found then raise exception 'Shared active store required' using errcode='22023';end if;
 select * into b from tenant_private.payment_bindings where store_id=p_store and enabled for update;
 if not found or b.provider<>p_provider or b.account_id<>p_account or b.subscription_id<>p_subscription or b.customer_id<>p_customer then raise exception 'Provider binding mismatch' using errcode='22023';end if;
 select * into sub from public.saas_subscriptions where store_id=p_store for update;
 if not found or sub.plan_code<>b.plan_code or sub.state not in ('pending','trial','active','past_due') or not exists(select 1 from public.saas_plans where code=b.plan_code and monthly_usd_cents=p_amount) then raise exception 'Plan or payment amount mismatch' using errcode='22023';end if;
 select * into e from tenant_private.payment_events where provider=p_provider and account_id=p_account and event_id=p_event;
 if found then
  if e.store_id<>p_store or e.invoice_id<>p_invoice or e.action<>p_action or e.evidence_sha256<>p_hash then raise exception 'Conflicting payment event' using errcode='22023';end if;
  select state into strict p_action from tenant_private.paid_periods where provider=p_provider and account_id=p_account and invoice_id=p_invoice;
  return p_action;
 end if;
 select * into pp from tenant_private.paid_periods where provider=p_provider and account_id=p_account and invoice_id=p_invoice for update;
 if found then
  if pp.store_id<>p_store or pp.plan_code<>b.plan_code or pp.period_start<>p_start or pp.period_end<>p_end or pp.amount_cents<>p_amount then raise exception 'Conflicting invoice identity' using errcode='22023';end if;
  if p_action='revoked' and pp.state='paid' then update tenant_private.paid_periods set state='revoked',revoked_at=now() where provider=p_provider and account_id=p_account and invoice_id=p_invoice;end if;
 else
  insert into tenant_private.paid_periods(store_id,provider,account_id,invoice_id,plan_code,period_start,period_end,amount_cents,state,evidence_sha256,revoked_at) values(p_store,p_provider,p_account,p_invoice,b.plan_code,p_start,p_end,p_amount,p_action,p_hash,case when p_action='revoked' then now() else null end);
 end if;
 insert into tenant_private.payment_events(provider,account_id,event_id,store_id,invoice_id,action,evidence_sha256) values(p_provider,p_account,p_event,p_store,p_invoice,p_action,p_hash);
 select max(period_end) into v_end from tenant_private.paid_periods where store_id=p_store and provider=p_provider and account_id=p_account and plan_code=b.plan_code and state='paid' and period_start<=now() and period_end>now();
 if v_end is not null then update public.saas_subscriptions set state='active',valid_until=v_end,updated_at=now() where store_id=p_store;
 elsif sub.state='active' then update public.saas_subscriptions set state='past_due',valid_until=null,updated_at=now() where store_id=p_store;
 end if;
 select state into strict p_action from tenant_private.paid_periods where provider=p_provider and account_id=p_account and invoice_id=p_invoice;
 return p_action;
end $$;
create function public.mt_service_verified_period(p_store uuid,p_provider text,p_account text,p_subscription text,p_customer text,p_invoice text,p_event text,p_action text,p_start timestamptz,p_end timestamptz,p_amount integer,p_currency text,p_hash text) returns text
language sql security invoker set search_path='' as $$select tenant_private.apply_verified_period(p_store,p_provider,p_account,p_subscription,p_customer,p_invoice,p_event,p_action,p_start,p_end,p_amount,p_currency,p_hash)$$;
create function tenant_private.license_status(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' and not coalesce(saas_private.is_operator(),false) then raise exception 'License access denied' using errcode='42501';end if;
 select jsonb_build_object('state',sub.state,'plan',sub.plan_code,'valid_until',sub.valid_until,'write_entitlement',tenant_private.shared_licensed(p_store),'live_billing_enabled',exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled)) into r from public.saas_subscriptions sub join tenant_private.workspaces w on w.store_id=sub.store_id where sub.store_id=p_store;
 return r;
end $$;
create function public.mt_license_status(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.license_status(p_store)$$;
revoke all on function tenant_private.shared_licensed(uuid),tenant_private.revoke_store_license(uuid),tenant_private.apply_verified_period(uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,integer,text,text),public.mt_service_verified_period(uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,integer,text,text),tenant_private.license_status(uuid),public.mt_license_status(uuid) from public,anon,authenticated,service_role;
grant usage on schema tenant_private to service_role;
grant execute on function tenant_private.apply_verified_period(uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,integer,text,text),public.mt_service_verified_period(uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,integer,text,text) to service_role;
grant execute on function tenant_private.license_status(uuid),public.mt_license_status(uuid) to authenticated;
commit;