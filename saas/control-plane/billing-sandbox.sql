-- SANDBOX ONLY. No real invoices, money, payment credentials or operational entitlements.
begin;
do $$ begin
 if to_regclass('saas_private.backup_catalog') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Dedicated control plane required'; end if;
end $$;
create table saas_private.billing_sandbox_invoices(
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null references public.saas_stores(id),
 plan_code text not null references public.saas_plans(code),
 period_start date not null check(extract(day from period_start)=1),
 period_end date not null check(period_end=(period_start+interval '1 month')::date),
 amount_cents integer not null check(amount_cents>0),
 currency text not null default 'USD' check(currency='USD'),
 state text not null default 'draft' check(state in ('draft','failed','paid','refunded','void')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(store_id,period_start)
);
create table saas_private.billing_sandbox_events(
 request_id uuid primary key,
 invoice_id uuid not null references saas_private.billing_sandbox_invoices(id),
 actor uuid not null,
 action text not null check(action in ('paid','failed','refunded','void')),
 prior_state text not null,
 recorded_at timestamptz not null default now()
);
create index saas_billing_event_invoice on saas_private.billing_sandbox_events(invoice_id,recorded_at desc);
alter table saas_private.billing_sandbox_invoices enable row level security;
alter table saas_private.billing_sandbox_events enable row level security;
revoke all on saas_private.billing_sandbox_invoices,saas_private.billing_sandbox_events from public,anon,authenticated,service_role;
create function saas_private.billing_draft(p_store uuid,p_month date) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_plan text; v_price int; v_now date:=date_trunc('month',now() at time zone 'UTC')::date;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_store is null or p_month is null or p_month not in (v_now,(v_now+interval '1 month')::date) then raise exception 'Current or next UTC month required' using errcode='22023'; end if;
 perform 1 from public.saas_stores where id=p_store and state in ('provisioning','ready') and (project_ref is null or not exists(select 1 from saas_private.protected_projects p where p.project_ref=saas_stores.project_ref)) for update;
 if not found then raise exception 'Eligible store required' using errcode='22023'; end if;
 select sub.plan_code,p.monthly_usd_cents into v_plan,v_price from public.saas_subscriptions sub join public.saas_plans p on p.code=sub.plan_code where sub.store_id=p_store and sub.state not in ('cancelled','suspended');
 if not found then raise exception 'Eligible subscription required' using errcode='22023'; end if;
 insert into saas_private.billing_sandbox_invoices(store_id,plan_code,period_start,period_end,amount_cents) values(p_store,v_plan,p_month,(p_month+interval '1 month')::date,v_price)
 on conflict(store_id,period_start) do nothing returning id into v_id;
 if v_id is null then select id into v_id from saas_private.billing_sandbox_invoices where store_id=p_store and period_start=p_month; end if;
 return v_id;
end $$;
create function saas_private.billing_simulate(p_invoice uuid,p_action text,p_request uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare inv saas_private.billing_sandbox_invoices%rowtype; prev saas_private.billing_sandbox_events%rowtype; v_store uuid; v_now date:=date_trunc('month',now() at time zone 'UTC')::date;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_invoice is null or p_request is null or p_action is null or p_action not in ('paid','failed','refunded','void') then raise exception 'Invalid sandbox event' using errcode='22023'; end if;
 select store_id into v_store from saas_private.billing_sandbox_invoices where id=p_invoice;
 if not found then raise exception 'Unknown sandbox invoice' using errcode='22023'; end if;
 perform 1 from public.saas_stores where id=v_store for update;
 select * into inv from saas_private.billing_sandbox_invoices where id=p_invoice for update;
 select * into prev from saas_private.billing_sandbox_events where request_id=p_request;
 if found then
   if prev.invoice_id<>p_invoice or prev.action<>p_action or prev.actor<>auth.uid() then raise exception 'Request identifier conflict' using errcode='22023';end if;
   return p_invoice;
 end if;
 if (p_action='paid' and inv.state in ('draft','failed') and inv.period_start=v_now) or
 (p_action='failed' and inv.state='draft' and inv.period_start=v_now) or
 (p_action='refunded' and inv.state='paid') or
 (p_action='void' and inv.state in ('draft','failed')) then
   insert into saas_private.billing_sandbox_events(request_id,invoice_id,actor,action,prior_state) values(p_request,p_invoice,auth.uid(),p_action,inv.state);
   update saas_private.billing_sandbox_invoices set state=p_action,updated_at=now() where id=p_invoice;
 else raise exception 'Invalid sandbox transition' using errcode='22023';end if;
 -- Simulate a renewal draft only; never make charges or modify saas_subscriptions.
 if p_action='paid' and exists(select 1 from public.saas_stores s join public.saas_subscriptions sub on sub.store_id=s.id where s.id=v_store and s.state in ('provisioning','ready') and sub.state not in ('cancelled','suspended') and (s.project_ref is null or not exists(select 1 from saas_private.protected_projects p where p.project_ref=s.project_ref))) then
   perform saas_private.billing_draft(v_store,inv.period_end);
 end if;
 return p_invoice;
end $$;
create function saas_private.billing_overview(p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid limit' using errcode='22023';end if;
 select jsonb_build_object('mode','sandbox','month',date_trunc('month',now() at time zone 'UTC')::date,
 'stores',coalesce((select jsonb_agg(to_jsonb(s) order by s.name,s.id) from (select s.id,s.name,s.slug,sub.plan_code,p.monthly_usd_cents from public.saas_stores s join public.saas_subscriptions sub on sub.store_id=s.id join public.saas_plans p on p.code=sub.plan_code where s.state in ('provisioning','ready') and sub.state not in ('cancelled','suspended') and (s.project_ref is null or not exists(select 1 from saas_private.protected_projects pp where pp.project_ref=s.project_ref)) order by s.name,s.id limit p_limit) s),'[]'::jsonb),
 'invoices',coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc,i.id) from (select i.id,i.store_id,s.name as store_name,i.plan_code,i.period_start,i.period_end,i.amount_cents,i.currency,i.state,i.created_at from saas_private.billing_sandbox_invoices i join public.saas_stores s on s.id=i.store_id order by i.created_at desc,i.id limit p_limit) i),'[]'::jsonb)
 ) into r;return r;
end $$;
create function public.saas_admin_billing_draft(p_store uuid,p_month date) returns uuid
language sql security invoker set search_path='' as $$ select saas_private.billing_draft(p_store,p_month) $$;
create function public.saas_admin_billing_simulate(p_invoice uuid,p_action text,p_request uuid) returns uuid
language sql security invoker set search_path='' as $$ select saas_private.billing_simulate(p_invoice,p_action,p_request) $$;
create function public.saas_admin_billing_overview(p_limit integer default 50) returns jsonb
language sql stable security invoker set search_path='' as $$ select saas_private.billing_overview(p_limit) $$;
revoke all on function saas_private.billing_draft(uuid,date),saas_private.billing_simulate(uuid,text,uuid),saas_private.billing_overview(integer),public.saas_admin_billing_draft(uuid,date),public.saas_admin_billing_simulate(uuid,text,uuid),public.saas_admin_billing_overview(integer) from public,anon,authenticated,service_role;
grant execute on function saas_private.billing_draft(uuid,date),saas_private.billing_simulate(uuid,text,uuid),saas_private.billing_overview(integer),public.saas_admin_billing_draft(uuid,date),public.saas_admin_billing_simulate(uuid,text,uuid),public.saas_admin_billing_overview(integer) to authenticated;
commit;
