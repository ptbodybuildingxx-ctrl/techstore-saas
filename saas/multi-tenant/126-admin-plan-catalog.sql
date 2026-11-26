-- 126: managed catalog of subscription plans, retaining all financial references.
begin;
alter table public.saas_plans drop constraint saas_plans_code_check;
alter table public.saas_plans add constraint saas_plans_code_check check(code ~ '^[a-z][a-z0-9-]{2,39}$');
create table tenant_private.admin_plan_catalog_events(
 request_id uuid primary key,plan_code text not null,actor uuid not null,
 action text not null check(action in ('create','rename','delete')),
 reference text not null check(length(btrim(reference)) between 1 and 200),
 params jsonb not null,before_state jsonb,after_state jsonb,created_at timestamptz not null default now()
);
alter table tenant_private.admin_plan_catalog_events enable row level security;
revoke all on tenant_private.admin_plan_catalog_events from public,anon,authenticated;
CREATE OR REPLACE FUNCTION tenant_private.admin_plan_policy_change(req uuid, plan text, expected bigint, flags jsonb, proof text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p tenant_private.admin_plan_policy%rowtype;e tenant_private.admin_plan_policy_events%rowtype;nextp tenant_private.admin_plan_policy%rowtype;v jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if req is null or plan is null or not exists(select 1 from public.saas_plans where code=plan) or expected is null or expected<1 or jsonb_typeof(flags) is distinct from 'object' or octet_length(flags::text)>1000 or (select count(*) from jsonb_object_keys(flags))<>5 or not(flags ?& array['enrollment','storefront','orders','guest','delivery']) or exists(select 1 from jsonb_each(flags) where jsonb_typeof(value)<>'boolean') or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid policy change' using errcode='22023';end if;
 select * into strict p from tenant_private.admin_plan_policy where plan_code=plan for update;
 select * into e from tenant_private.admin_plan_policy_events where request_id=req;
 if found then
  if e.plan_code<>plan or e.actor<>auth.uid() or e.reference<>btrim(proof) or (e.before_state->>'revision')::bigint<>expected or (e.after_state - array['plan_code','revision','updated_at'])<>flags then raise exception 'Conflicting policy request';end if;
  return req;
 end if;
 if p.revision<>expected or (to_jsonb(p)-array['plan_code','revision','updated_at'])=flags then raise exception 'Policy changed or unchanged';end if;
 update tenant_private.admin_plan_policy set enrollment=(flags->>'enrollment')::boolean,storefront=(flags->>'storefront')::boolean,orders=(flags->>'orders')::boolean,guest=(flags->>'guest')::boolean,delivery=(flags->>'delivery')::boolean,revision=revision+1,updated_at=now() where plan_code=plan returning * into nextp;
 insert into tenant_private.admin_plan_policy_events(request_id,plan_code,actor,reference,before_state,after_state) values(req,plan,auth.uid(),btrim(proof),to_jsonb(p),to_jsonb(nextp));
 return req;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.admin_plan_price_change(p_request uuid, p_plan text, p_expected integer, p_price integer, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v integer;r tenant_private.plan_price_history%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_request is null or p_plan is null or not exists(select 1 from public.saas_plans where code=p_plan) or p_expected is null or p_price is null or p_price not between 100 and 10000000 or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid price change' using errcode='22023';end if;
 perform 1 from tenant_private.billing_configuration where singleton for update;
 lock table tenant_private.payment_bindings in share mode;
 select * into r from tenant_private.plan_price_history where request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.plan_code<>p_plan or r.previous_cents<>p_expected or r.new_cents<>p_price or r.note<>btrim(p_note) then raise exception 'Conflicting request' using errcode='22023';end if;return r.id;
 end if;
 if exists(select 1 from tenant_private.billing_configuration where live_enabled) or exists(select 1 from tenant_private.payment_bindings) then raise exception 'Provider price version migration required' using errcode='22023';end if;
 select monthly_usd_cents into strict v from public.saas_plans where code=p_plan for update;
 if v<>p_expected or v=p_price then raise exception 'Price changed or unchanged' using errcode='22023';end if;
 update public.saas_plans set monthly_usd_cents=p_price where code=p_plan;
 insert into tenant_private.plan_price_history(request_id,plan_code,previous_cents,new_cents,actor,note) values(p_request,p_plan,v,p_price,auth.uid(),btrim(p_note)) returning * into r;
 return r.id;
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
  if action='renew' and (not manual or v->>'subscription_state'<>'active') then raise exception 'Manual license required';end if;
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
create function tenant_private.admin_plan_catalog_review() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return jsonb_build_object('editable',not exists(select 1 from tenant_private.billing_configuration where live_enabled) and not exists(select 1 from tenant_private.payment_bindings),
 'plans',coalesce((select jsonb_agg(to_jsonb(x) order by code) from (select p.code,p.name,p.monthly_usd_cents,q.enrollment,q.revision,(select count(*) from public.saas_subscriptions where plan_code=p.code) subscribers,
 (not exists(select 1 from public.saas_subscriptions where plan_code=p.code) and not exists(select 1 from tenant_private.plan_price_history where plan_code=p.code) and not exists(select 1 from tenant_private.admin_plan_policy_events where plan_code=p.code) and not exists(select 1 from saas_private.billing_sandbox_invoices where plan_code=p.code) and not exists(select 1 from tenant_private.paid_periods where plan_code=p.code) and not exists(select 1 from tenant_private.admin_manual_licenses where plan_code=p.code) and p.code not in ('basic','business','pro')) deletable
 from public.saas_plans p join tenant_private.admin_plan_policy q on q.plan_code=p.code)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id) from (select request_id,plan_code,actor,action,reference,before_state,after_state,created_at from tenant_private.admin_plan_catalog_events order by created_at desc,request_id limit 50)x),'[]'::jsonb));
end $$;

create function tenant_private.admin_plan_catalog_change(req uuid,action text,code_value text,expected jsonb,params jsonb,proof text)
returns uuid language plpgsql security definer set search_path='' as $$
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
  if exists(select 1 from public.saas_subscriptions where plan_code=code_value) or exists(select 1 from tenant_private.admin_plan_policy_events where plan_code=code_value) or exists(select 1 from tenant_private.plan_price_history where plan_code=code_value) or exists(select 1 from saas_private.billing_sandbox_invoices where plan_code=code_value) or exists(select 1 from tenant_private.paid_periods where plan_code=code_value) or exists(select 1 from tenant_private.admin_manual_licenses where plan_code=code_value) then raise exception 'Referenced plan must be retired by closing enrollment';end if;
  delete from tenant_private.admin_plan_policy where plan_code=code_value;
  delete from public.saas_plans where code=code_value;
 end if;
 select to_jsonb(p0) into afterv from public.saas_plans p0 where code=code_value;
 insert into tenant_private.admin_plan_catalog_events(request_id,plan_code,actor,action,reference,params,before_state,after_state) values(req,code_value,auth.uid(),action,btrim(proof),params,beforev,afterv);
 return req;
end $$;
create function public.mt_admin_plan_catalog_review() returns jsonb language sql stable set search_path='' as $$select tenant_private.admin_plan_catalog_review()$$;
create function public.mt_admin_plan_catalog_change(req uuid,action text,code_value text,expected jsonb,params jsonb,proof text) returns uuid language sql set search_path='' as $$select tenant_private.admin_plan_catalog_change(req,action,code_value,expected,params,proof)$$;
revoke all on function tenant_private.admin_plan_catalog_review(),public.mt_admin_plan_catalog_review(),tenant_private.admin_plan_catalog_change(uuid,text,text,jsonb,jsonb,text),public.mt_admin_plan_catalog_change(uuid,text,text,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function tenant_private.admin_plan_catalog_review(),public.mt_admin_plan_catalog_review(),tenant_private.admin_plan_catalog_change(uuid,text,text,jsonb,jsonb,text),public.mt_admin_plan_catalog_change(uuid,text,text,jsonb,jsonb,text) to authenticated;
commit;
