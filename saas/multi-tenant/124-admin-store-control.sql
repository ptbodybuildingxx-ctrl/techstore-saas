-- 124: central administration of shared-store licenses, lifecycle and visibility.
-- Manual operation grants are not payment evidence and cannot coexist with provider bindings.
begin;
create table tenant_private.admin_manual_licenses(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 plan_code text not null references public.saas_plans(code),
 valid_until timestamptz not null,issued_at timestamptz not null default now(),
 request_id uuid not null unique,actor uuid not null,
 reference text not null check(length(btrim(reference)) between 1 and 200)
);
create table tenant_private.admin_store_controls(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 storefront_paused boolean not null default false,updated_at timestamptz not null default now()
);
create table tenant_private.admin_store_events(
 request_id uuid primary key,store_id uuid not null references tenant_private.workspaces(store_id),
 actor uuid not null,action text not null check(action in ('grant','renew','revoke','plan','pause_shop','resume_shop','rename','trial','suspend','cancel','reopen')),
 reference text not null check(length(btrim(reference)) between 1 and 200),
 params jsonb not null,before_state jsonb not null,after_state jsonb not null,created_at timestamptz not null default now()
);
create index admin_store_events_history on tenant_private.admin_store_events(store_id,created_at desc,request_id);
alter table tenant_private.admin_manual_licenses enable row level security;
alter table tenant_private.admin_store_controls enable row level security;
alter table tenant_private.admin_store_events enable row level security;
revoke all on tenant_private.admin_manual_licenses,tenant_private.admin_store_controls,tenant_private.admin_store_events from public,anon,authenticated;

create function tenant_private.clear_changed_manual_license()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.state<>'active' or new.plan_code is distinct from old.plan_code or new.valid_until is distinct from old.valid_until then
  delete from tenant_private.admin_manual_licenses where store_id=new.store_id;
 end if;
 return new;
end $$;
revoke all on function tenant_private.clear_changed_manual_license() from public,anon,authenticated;
create trigger mt_clear_manual_license after update on public.saas_subscriptions for each row execute function tenant_private.clear_changed_manual_license();

CREATE OR REPLACE FUNCTION tenant_private.admin_operations_overview(p_stores uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;summary jsonb;details jsonb;live boolean;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_stores is null or cardinality(p_stores)>100 or array_position(p_stores,null::uuid) is not null then raise exception 'Invalid page' using errcode='22023';end if;
 select live_enabled into live from tenant_private.billing_configuration where singleton;
 with states as (
 select w.store_id,sub.state,sub.valid_until,p.shard_code,exists(select 1 from tenant_private.admin_manual_licenses m where m.store_id=w.store_id and m.plan_code=sub.plan_code and m.valid_until=sub.valid_until) as manual,
 tenant_private.shared_licensed(w.store_id) licensed
 from tenant_private.workspaces w join public.saas_stores s on s.id=w.store_id left join public.saas_subscriptions sub on sub.store_id=w.store_id left join tenant_private.placements p on p.store_id=w.store_id left join tenant_private.shards sh on sh.code=p.shard_code
 ) select jsonb_build_object('shared',count(*),'licensed',count(*) filter(where licensed),'trials',count(*) filter(where licensed and state='trial'),'paid',count(*) filter(where licensed and state='active' and not manual),'manual',count(*) filter(where licensed and state='active' and manual),'blocked',count(*) filter(where not coalesce(licensed,false)),'expiring',count(*) filter(where licensed and valid_until<=now()+interval '7 days'),'pending_domains',(select count(*) from tenant_private.custom_domains where state='pending'),'active_domains',(select count(*) from tenant_private.custom_domains where state='active'),'queued_recovery',(select count(*) from tenant_private.shared_recovery_requests where state='queued'),'planned_releases',(select count(*) from tenant_private.shared_release_plans where state='planned'),'local_shards',(select count(*) from tenant_private.shards where state='local'),'verified_shards',(select count(*) from tenant_private.shards sh where sh.state='local' and exists(select 1 from tenant_private.shared_backup_evidence e where e.shard_code=sh.code and tenant_private.shared_verified_backup(sh.code,e.id)))) into summary from states;
 select coalesce(jsonb_agg(jsonb_build_object('id',w.store_id,'shard',p.shard_code,'licensed',tenant_private.shared_licensed(w.store_id),'storefront_active',tenant_private.storefront_active(w.store_id),'domain_state',coalesce((select state from tenant_private.custom_domains d where d.store_id=w.store_id and d.state in ('pending','active')),'none'),'pending_orders',(select count(*) from public.mt_online_orders o where o.store_id=w.store_id and o.state='pending'),'dispatched_orders',(select count(*) from public.mt_online_orders o where o.store_id=w.store_id and o.state='pending' and o.delivery_state='dispatched'),'backup_verified',exists(select 1 from tenant_private.shared_backup_evidence e where e.shard_code=p.shard_code and tenant_private.shared_verified_backup(p.shard_code,e.id))) order by w.store_id),'[]'::jsonb) into details from tenant_private.workspaces w left join tenant_private.placements p on p.store_id=w.store_id where w.store_id=any(p_stores);
 return jsonb_build_object('as_of',now(),'live_billing_enabled',coalesce(live,false),'summary',summary,'stores',details);
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.admin_shared_license_status(p_stores uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_stores is null or cardinality(p_stores)>100 or array_position(p_stores,null::uuid) is not null then raise exception 'Invalid store page' using errcode='22023';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',w.store_id,'state',sub.state,'plan',sub.plan_code,'valid_until',sub.valid_until,'license_source',case when sub.state='trial' then 'trial' when sub.state='active' and exists(select 1 from tenant_private.admin_manual_licenses m where m.store_id=w.store_id and m.plan_code=sub.plan_code and m.valid_until=sub.valid_until) then 'manual' when sub.state='active' then 'provider' else 'none' end,'write_entitlement',tenant_private.shared_licensed(w.store_id)) order by w.store_id),'[]'::jsonb) into r from tenant_private.workspaces w join public.saas_subscriptions sub on sub.store_id=w.store_id where w.store_id=any(p_stores);
 return r;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.license_status(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' and not coalesce(saas_private.is_operator(),false) then raise exception 'License access denied' using errcode='42501';end if;
 select jsonb_build_object('state',sub.state,'plan',sub.plan_code,'valid_until',sub.valid_until,'license_source',case when sub.state='trial' then 'trial' when sub.state='active' and exists(select 1 from tenant_private.admin_manual_licenses m where m.store_id=w.store_id and m.plan_code=sub.plan_code and m.valid_until=sub.valid_until) then 'manual' when sub.state='active' then 'provider' else 'none' end,'write_entitlement',tenant_private.shared_licensed(p_store),'live_billing_enabled',exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled)) into r from public.saas_subscriptions sub join tenant_private.workspaces w on w.store_id=sub.store_id where sub.store_id=p_store;
 return r;
end $function$
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
 and (sub.state='trial' or (sub.state='active' and exists(select 1 from tenant_private.admin_manual_licenses m where m.store_id=w.store_id and m.plan_code=sub.plan_code and m.valid_until=sub.valid_until and m.valid_until>now()) and not exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled) and not exists(select 1 from tenant_private.payment_bindings where store_id=w.store_id)) or (sub.state='active' and exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled)
 and exists(select 1 from tenant_private.payment_bindings b join tenant_private.paid_periods pp on pp.store_id=b.store_id and pp.provider=b.provider and pp.account_id=b.account_id and pp.plan_code=b.plan_code
 where b.store_id=p_store and b.enabled and b.plan_code=sub.plan_code and pp.state='paid' and pp.period_start<=now() and pp.period_end>now() and pp.period_end>=sub.valid_until)))
 )
$function$
;

CREATE OR REPLACE FUNCTION tenant_private.storefront_active(p_store uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select tenant_private.shared_licensed(p_store) and not exists(select 1 from tenant_private.admin_store_controls where store_id=p_store and storefront_paused) and exists(select 1 from tenant_private.storefronts where store_id=p_store and enabled)
$function$
;

create function tenant_private.admin_store_snapshot(s uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',st.id,'name',st.name,'slug',st.slug,'state',st.state,'plan',sub.plan_code,'subscription_state',sub.state,'valid_until',sub.valid_until,'subscription_updated',sub.updated_at,
 'manual_request',m.request_id,'manual_reference',m.reference,'manual_until',m.valid_until,
 'storefront_paused',coalesce(c.storefront_paused,false),'control_updated',c.updated_at,
 'provider_bound',exists(select 1 from tenant_private.payment_bindings where store_id=s),
 'live_billing',exists(select 1 from tenant_private.billing_configuration where singleton and live_enabled),
 'local',exists(select 1 from tenant_private.placements p join tenant_private.shards sh on sh.code=p.shard_code and sh.state='local' where p.store_id=s))
 from tenant_private.workspaces w join public.saas_stores st on st.id=w.store_id join public.saas_subscriptions sub on sub.store_id=w.store_id
 left join tenant_private.admin_manual_licenses m on m.store_id=w.store_id left join tenant_private.admin_store_controls c on c.store_id=w.store_id
 where w.store_id=s and st.project_ref is null and st.origin is null
$$;
revoke all on function tenant_private.admin_store_snapshot(uuid) from public,anon,authenticated;

create function tenant_private.admin_store_review(s uuid,off integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v jsonb;h jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if s is null or off is null or off not between 0 and 100000 then raise exception 'Invalid store review';end if;
 v:=tenant_private.admin_store_snapshot(s);
 if v is null then raise exception 'Shared store required' using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc,request_id),'[]'::jsonb) into h from (
  select request_id,actor,action,reference,before_state,after_state,created_at from tenant_private.admin_store_events where store_id=s order by created_at desc,request_id offset off limit 51
 )x;
 return jsonb_build_object('snapshot',v,'licensed',tenant_private.shared_licensed(s),'storefront_visible',tenant_private.storefront_active(s),
 'owner_count',(select count(*) from tenant_private.members where store_id=s and role='owner' and active),
 'staff_count',(select count(*) from tenant_private.members where store_id=s and role<>'owner' and active),
 'product_count',(select count(*) from public.mt_products where store_id=s),
 'pending_orders',(select count(*) from public.mt_online_orders where store_id=s and state='pending')+(select count(*) from tenant_private.guest_orders where store_id=s and state='pending'),
 'history',case when jsonb_array_length(h)>50 then h-50 else h end,'more',jsonb_array_length(h)>50,
 'legacy_history',coalesce((select jsonb_agg(to_jsonb(x) order by recorded_at desc,id) from (select id,actor,action,recorded_at from saas_private.admin_audit where store_id=s order by recorded_at desc,id limit 50)x),'[]'::jsonb));
end $$;

create function tenant_private.admin_store_change(s uuid,req uuid,action text,expected jsonb,params jsonb,proof text)
returns uuid language plpgsql security definer set search_path='' as $$
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
  if days not between 1 and case when action='trial' then 30 else 365 end then raise exception 'Invalid duration';end if;
 elsif action='plan' then
  if (select count(*) from jsonb_object_keys(params))<>1 or coalesce(params->>'plan','') not in ('basic','business','pro') then raise exception 'Invalid plan';end if;
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
end $$;

create function public.mt_admin_store_review(s uuid,off integer default 0) returns jsonb language sql stable set search_path='' as $$select tenant_private.admin_store_review(s,off)$$;
create function public.mt_admin_store_change(s uuid,req uuid,action text,expected jsonb,params jsonb,proof text) returns uuid language sql set search_path='' as $$select tenant_private.admin_store_change(s,req,action,expected,params,proof)$$;
revoke all on function tenant_private.admin_store_review(uuid,integer),public.mt_admin_store_review(uuid,integer),tenant_private.admin_store_change(uuid,uuid,text,jsonb,jsonb,text),public.mt_admin_store_change(uuid,uuid,text,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function tenant_private.admin_store_review(uuid,integer),public.mt_admin_store_review(uuid,integer),tenant_private.admin_store_change(uuid,uuid,text,jsonb,jsonb,text),public.mt_admin_store_change(uuid,uuid,text,jsonb,jsonb,text) to authenticated;
commit;
