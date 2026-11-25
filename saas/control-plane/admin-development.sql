-- Dedicated SaaS control plane only. Development administration, no paid entitlement.
begin;
do $$ begin
  if to_regclass('public.ts_workspace') is not null or to_regclass('public.saas_stores') is null or to_regclass('saas_private.operators') is null then
    raise exception 'Dedicated control plane required';
  end if;
end $$;
alter table saas_private.operators add column mfa_required boolean not null default true;
create or replace function saas_private.is_operator() returns boolean
language sql stable security definer set search_path='' as $$
 select saas_private.live_session()
 and exists(select 1 from saas_private.operators o join auth.users u on u.id=o.user_id
 where o.user_id=auth.uid() and o.active and not u.is_anonymous
 and (not o.mfa_required or coalesce(auth.jwt()->>'aal'='aal2',false)))
$$;
-- An unprovisioned registration has no real project or origin. Never mark it ready.
alter table public.saas_stores alter column project_ref drop not null, alter column origin drop not null;
alter table public.saas_stores add constraint saas_store_provisioning_pair check
 ((project_ref is null and origin is null and state in ('provisioning','suspended','closed')) or (project_ref is not null and origin is not null));
create table saas_private.admin_audit (
 id uuid primary key default gen_random_uuid(),
 actor uuid not null, store_id uuid not null,
 action text not null check(action in ('register','trial','suspend','cancel','reopen')),
 recorded_at timestamptz not null default now()
);
alter table saas_private.admin_audit enable row level security;
revoke all on saas_private.admin_audit from public,anon,authenticated;
create function public.saas_admin_overview(p_offset integer default 0,p_limit integer default 25,p_query text default '',p_state text default '')
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or p_query is null or length(p_query)>160 or p_state is null or p_state not in ('','provisioning','ready','suspended','closed') then raise exception 'Invalid filters' using errcode='22023'; end if;
 with filtered as (
   select s.id,s.name,s.slug,s.state,s.created_at,sub.plan_code,sub.state as subscription_state,sub.valid_until,(s.project_ref is not null) as provisioned
   from public.saas_stores s left join public.saas_subscriptions sub on sub.store_id=s.id
   where (p_state='' or s.state=p_state) and (p_query='' or strpos(lower(s.name),lower(p_query))>0 or strpos(lower(s.slug),lower(p_query))>0)
 ), page as (select * from filtered order by created_at desc,id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from public.saas_stores),'ready',(select count(*) from public.saas_stores where state='ready'),'suspended',(select count(*) from public.saas_stores where state='suspended'),'active_subscriptions',(select count(*) from public.saas_subscriptions where state='active' and valid_until>now()),'matched',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(page) order by created_at desc,id) from page),'[]'::jsonb)) into result;
 return result;
end $$;
create function saas_private.register_store(p_name text,p_slug text,p_plan text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_name is null or length(btrim(p_name)) not between 1 and 160 or p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_plan is null or not exists(select 1 from public.saas_plans where code=p_plan) then raise exception 'Invalid store details' using errcode='22023'; end if;
 insert into public.saas_stores(name,slug,project_ref,origin) values(btrim(p_name),p_slug,null,null) returning id into v_id;
 insert into public.saas_subscriptions(store_id,plan_code) values(v_id,p_plan);
 insert into saas_private.admin_audit(actor,store_id,action) values(auth.uid(),v_id,'register');
 return v_id;
end $$;
create function saas_private.manage_store(p_store uuid,p_action text,p_days integer default null) returns void
language plpgsql security definer set search_path='' as $$
declare v_state text; v_plan_state text;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_store is null or p_action is null or p_action not in ('trial','suspend','cancel','reopen') or (p_action='trial' and (p_days is null or p_days not between 1 and 30)) or (p_action<>'trial' and p_days is not null) then raise exception 'Invalid action' using errcode='22023'; end if;
 select state into v_state from public.saas_stores where id=p_store and project_ref is null and origin is null for update;
 if not found then raise exception 'Unprovisioned development store required' using errcode='22023'; end if;
 select state into v_plan_state from public.saas_subscriptions where store_id=p_store for update;
 if not found or v_plan_state not in ('pending','trial','suspended','cancelled') then raise exception 'Development subscription required' using errcode='22023'; end if;
 if p_action='trial' and v_state='provisioning' and v_plan_state in ('pending','trial') then
   update public.saas_subscriptions set state='trial',valid_until=now()+make_interval(days=>p_days),updated_at=now() where store_id=p_store;
 elsif p_action='suspend' and v_state='provisioning' then
   update public.saas_stores set state='suspended' where id=p_store;
   update public.saas_subscriptions set state='suspended',valid_until=null,updated_at=now() where store_id=p_store;
 elsif p_action='cancel' and v_state in ('provisioning','suspended') then
   update public.saas_stores set state='closed' where id=p_store;
   update public.saas_subscriptions set state='cancelled',valid_until=null,updated_at=now() where store_id=p_store;
 elsif p_action='reopen' and v_state in ('suspended','closed') then
   update public.saas_stores set state='provisioning' where id=p_store;
   update public.saas_subscriptions set state='pending',valid_until=null,updated_at=now() where store_id=p_store;
 else raise exception 'Invalid state transition' using errcode='22023';
 end if;
 insert into saas_private.admin_audit(actor,store_id,action) values(auth.uid(),p_store,p_action);
end $$;
create function public.saas_admin_register(p_name text,p_slug text,p_plan text) returns uuid
language sql security invoker set search_path='' as $$ select saas_private.register_store(p_name,p_slug,p_plan) $$;
create function public.saas_admin_manage(p_store uuid,p_action text,p_days integer default null) returns void
language sql security invoker set search_path='' as $$ select saas_private.manage_store(p_store,p_action,p_days) $$;
revoke all on function saas_private.register_store(text,text,text),saas_private.manage_store(uuid,text,integer),public.saas_admin_overview(integer,integer,text,text),public.saas_admin_register(text,text,text),public.saas_admin_manage(uuid,text,integer) from public,anon,authenticated;
grant execute on function saas_private.register_store(text,text,text),saas_private.manage_store(uuid,text,integer),public.saas_admin_overview(integer,integer,text,text),public.saas_admin_register(text,text,text),public.saas_admin_manage(uuid,text,integer) to authenticated;
commit;
