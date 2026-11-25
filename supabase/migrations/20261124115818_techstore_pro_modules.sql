begin;
create table public.ts_pro_grants(
 user_id uuid not null references public.ts_profiles(user_id) on delete cascade,
 module text not null check(module in ('branches','cash','vouchers','quotes','payroll','bank','repair_tasks','campaigns','shipping','tradein','reviews','memberships','alerts')),
 can_read boolean not null default true, can_create boolean not null default false,
 primary key(user_id,module)
);
create table public.ts_pro_entries(
 id uuid primary key default gen_random_uuid(),
 actor uuid not null default auth.uid() references public.ts_profiles(user_id),
 kind text not null check(kind in ('branches','cash','vouchers','quotes','payroll','bank','repair_tasks','campaigns','shipping','tradein','reviews','memberships','alerts','favorites','builds')),
 title text not null check(char_length(btrim(title)) between 1 and 200),
 reference text not null default '' check(char_length(reference)<=200),
 notes text not null default '' check(char_length(notes)<=4000),
 amount numeric(16,2) not null default 0 check(amount>=0),
 currency text not null default 'USD' check(currency in ('USD','SYP')),
 details jsonb not null default '{}'::jsonb check(jsonb_typeof(details)='object' and octet_length(details::text)<=20000),
 created_at timestamptz not null default now(),
 archived boolean not null default false
);
create index ts_pro_entries_kind_created_idx on public.ts_pro_entries(kind,created_at desc);
create index ts_pro_entries_actor_kind_idx on public.ts_pro_entries(actor,kind,created_at desc);
alter table public.ts_pro_grants enable row level security;
alter table public.ts_pro_entries enable row level security;
revoke all on public.ts_pro_grants,public.ts_pro_entries from public,anon,authenticated;
grant select,insert,update,delete on public.ts_pro_grants to authenticated;
grant select on public.ts_pro_entries to authenticated;
grant insert(kind,title,reference,notes,amount,currency,details) on public.ts_pro_entries to authenticated;
grant update(archived) on public.ts_pro_entries to authenticated;
create policy ts_pro_grants_read on public.ts_pro_grants for select to authenticated using (
 exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active and (p.role='admin' or p.user_id=ts_pro_grants.user_id))
);
create policy ts_pro_grants_admin on public.ts_pro_grants for all to authenticated using (
 exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active and p.role='admin')
) with check (
 exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active and p.role='admin')
);
create policy ts_pro_entries_read on public.ts_pro_entries for select to authenticated using (
 exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active and (
 p.role='admin' or (p.role='customer' and actor=p.user_id and kind in ('reviews','alerts','favorites','builds'))
 or (p.role in ('cashier','stock','tech') and exists(select 1 from public.ts_pro_grants g where g.user_id=p.user_id and g.module=kind and g.can_read))
 ))
);
create policy ts_pro_entries_insert on public.ts_pro_entries for insert to authenticated with check (
 actor=(select auth.uid()) and not archived and exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active and (
 p.role='admin' or (p.role='customer' and kind in ('reviews','alerts','favorites','builds'))
 or (p.role in ('cashier','stock','tech') and exists(select 1 from public.ts_pro_grants g where g.user_id=p.user_id and g.module=kind and g.can_create and g.can_read))
 ))
);
create policy ts_pro_entries_archive on public.ts_pro_entries for update to authenticated using (
 kind not in ('cash','vouchers','payroll','bank') and exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active and (p.role='admin' or (p.role='customer' and actor=p.user_id and kind in ('reviews','alerts','favorites','builds'))))
) with check (
 kind not in ('cash','vouchers','payroll','bank') and exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active and (p.role='admin' or (p.role='customer' and actor=p.user_id and kind in ('reviews','alerts','favorites','builds'))))
);
commit;