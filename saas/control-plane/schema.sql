-- CONTROL PLANE ONLY: apply to a newly created, dedicated Supabase project.
-- Never apply to a shop database. No store operational data is collected here.
begin;
do $$ begin
  if to_regclass('public.ts_workspace') is not null then
    raise exception 'Refusing to install control plane on a TechStore shop';
  end if;
end $$;
create schema saas_private;
revoke all on schema saas_private from public,anon,authenticated;
create table saas_private.operators (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active boolean not null default true
);
alter table saas_private.operators enable row level security;
revoke all on saas_private.operators from public,anon,authenticated;
create table public.saas_plans (
  code text primary key check (code in ('basic','business','pro')),
  name text not null,
  monthly_usd_cents integer not null check (monthly_usd_cents>0)
);
insert into public.saas_plans values ('basic','Basic',2500),('business','Business',4900),('pro','Business Pro',9900);
create table public.saas_stores (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null check (slug ~ '^[a-z][a-z0-9-]{2,39}$'),
  name text not null check (length(btrim(name)) between 1 and 160),
  project_ref text unique not null check (project_ref ~ '^[a-z0-9]{20}$' and project_ref <> 'jtjnbeywpfdtgohffanl'),
  origin text unique not null check (origin ~ '^https://[a-z0-9][a-z0-9.-]*[.][a-z]+$' and origin !~ '[.](github[.]io|supabase[.]co)$'),
  state text not null default 'provisioning' check (state in ('provisioning','ready','suspended','closed')),
  created_at timestamptz not null default now()
);
create table public.saas_memberships (
  store_id uuid not null references public.saas_stores(id),
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','billing')),
  active boolean not null default true,
  primary key(store_id,user_id)
);
create index saas_memberships_user_idx on public.saas_memberships(user_id);
create table public.saas_subscriptions (
  store_id uuid primary key references public.saas_stores(id),
  plan_code text not null references public.saas_plans(code),
  state text not null default 'pending' check (state in ('pending','trial','active','past_due','suspended','cancelled')),
  valid_until timestamptz,
  updated_at timestamptz not null default now(),
  check (state not in ('trial','active') or valid_until is not null)
);
create index saas_subscriptions_plan_idx on public.saas_subscriptions(plan_code);
-- Administrative metadata only. A store must not be unlocked by this record alone.
create function saas_private.live_session() returns boolean
language sql stable security definer set search_path='' as $$
  select exists (
    select 1 from auth.sessions s join auth.users u on u.id=s.user_id
    where s.user_id=auth.uid() and s.id::text=auth.jwt()->>'session_id'
    and (s.not_after is null or s.not_after>now())
    and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until<=now())
  )
$$;
create function saas_private.is_operator() returns boolean
language sql stable security definer set search_path='' as $$
  select coalesce(auth.jwt()->>'aal'='aal2',false)
    and saas_private.live_session()
    and exists(select 1 from saas_private.operators o where o.user_id=auth.uid() and o.active)
$$;
create function saas_private.can_read_store(p_store uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select saas_private.is_operator() or (saas_private.live_session() and exists(
    select 1 from public.saas_memberships m where m.store_id=p_store and m.user_id=auth.uid() and m.active
  ))
$$;
revoke all on function saas_private.live_session(),saas_private.is_operator(),saas_private.can_read_store(uuid) from public,anon,authenticated;
grant usage on schema saas_private to authenticated;
grant execute on function saas_private.live_session(),saas_private.is_operator(),saas_private.can_read_store(uuid) to authenticated;
alter table public.saas_plans enable row level security;
alter table public.saas_stores enable row level security;
alter table public.saas_memberships enable row level security;
alter table public.saas_subscriptions enable row level security;
revoke all on public.saas_plans,public.saas_stores,public.saas_memberships,public.saas_subscriptions from public,anon,authenticated;
grant select on public.saas_plans,public.saas_stores,public.saas_memberships,public.saas_subscriptions to authenticated;
create policy saas_plans_read on public.saas_plans for select to authenticated using ((select saas_private.live_session()));
create policy saas_stores_read on public.saas_stores for select to authenticated using (saas_private.can_read_store(id));
create policy saas_memberships_read on public.saas_memberships for select to authenticated using ((select saas_private.is_operator()) or (active and user_id=(select auth.uid()) and (select saas_private.live_session())));
create policy saas_subscriptions_read on public.saas_subscriptions for select to authenticated using (saas_private.can_read_store(store_id));
-- No browser INSERT/UPDATE/DELETE policy or grant. Provisioning and billing
-- changes require a trusted backend, not a client-supplied role or payment state.
grant select,insert,update,delete on public.saas_stores,public.saas_memberships,public.saas_subscriptions to service_role;
grant select on public.saas_plans to service_role;
commit;
