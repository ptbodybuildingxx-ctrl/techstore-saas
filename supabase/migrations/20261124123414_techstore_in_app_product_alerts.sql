begin;
create table public.ts_product_alert_events(
 id uuid primary key default gen_random_uuid(),
 subscription_id uuid not null unique references public.ts_pro_entries(id),
 user_id uuid not null references public.ts_profiles(user_id),
 product_id text not null,
 product_name text not null,
 kind text not null check(kind in ('price-drop','back-in-stock')),
 previous_price numeric, new_price numeric,
 created_at timestamptz not null default now(),
 seen boolean not null default false
);
create index ts_product_alert_user_idx on public.ts_product_alert_events(user_id,created_at desc);
create index ts_alert_subscription_idx on public.ts_pro_entries(reference) where kind='alerts' and not archived;
alter table public.ts_product_alert_events enable row level security;
revoke all on public.ts_product_alert_events from public,anon,authenticated;
grant select on public.ts_product_alert_events to authenticated;
grant update(seen) on public.ts_product_alert_events to authenticated;
create policy ts_product_alert_read on public.ts_product_alert_events for select to authenticated using(user_id=(select auth.uid()) and (select techstore_private.live_session()) and exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active));
create policy ts_product_alert_seen on public.ts_product_alert_events for update to authenticated using(user_id=(select auth.uid()) and (select techstore_private.live_session()) and exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active)) with check(user_id=(select auth.uid()) and (select techstore_private.live_session()) and exists(select 1 from public.ts_profiles p where p.user_id=(select auth.uid()) and p.active));
create function techstore_private.emit_product_alerts() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.payload->'data'->'products' is not distinct from new.payload->'data'->'products' or new.payload->'data'->'owner'->>'maintenance'='true' then return new;end if;
 with prev as (select p from jsonb_array_elements(coalesce(old.payload->'data'->'products','[]'::jsonb)) p),
 curr as (select p from jsonb_array_elements(coalesce(new.payload->'data'->'products','[]'::jsonb)) p)
 insert into public.ts_product_alert_events(subscription_id,user_id,product_id,product_name,kind,previous_price,new_price)
 select s.id,s.actor,s.reference,left(c.p->>'name',200),s.details->>'status',
 case when jsonb_typeof(o.p->'price')='number' then (o.p->>'price')::numeric end,
 case when jsonb_typeof(c.p->'price')='number' then (c.p->>'price')::numeric end
 from public.ts_pro_entries s join public.ts_profiles u on u.user_id=s.actor and u.active and u.role='customer'
 join curr c on c.p->>'id'=s.reference join prev o on o.p->>'id'=s.reference
 where s.kind='alerts' and not s.archived and c.p->>'hidden' is distinct from 'true'
 and not (coalesce(new.payload->'data'->'owner'->'hiddenCategories','[]'::jsonb) ? (c.p->>'type'))
 and (case when s.details->>'status'='price-drop' and jsonb_typeof(c.p->'price')='number' and jsonb_typeof(o.p->'price')='number' then (c.p->>'price')::numeric<(o.p->>'price')::numeric
 when s.details->>'status'='back-in-stock' and jsonb_typeof(c.p->'qty')='number' and jsonb_typeof(o.p->'qty')='number' then (o.p->>'qty')::numeric=0 and (c.p->>'qty')::numeric>0 else false end)
 on conflict(subscription_id) do nothing;
 return new;
end $$;
revoke all on function techstore_private.emit_product_alerts() from public,anon,authenticated;
create trigger ts_workspace_product_alerts after update of payload on public.ts_workspace for each row execute function techstore_private.emit_product_alerts();
create or replace function techstore_private.protect_branch_stock() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='ts_workspace' then
 if exists(select 1 from public.ts_branch_stock s where s.qty>0 and not exists(select 1 from jsonb_array_elements(coalesce(new.payload->'data'->'products','[]'::jsonb)) p where p->>'id'=s.product_id)) then raise exception 'Product still has branch stock';end if;
 elsif new.archived and not old.archived and old.kind='branches' then
 perform 1 from public.ts_workspace where id=1 for update;
 if exists(select 1 from public.ts_branch_stock where branch_id=old.id and qty>0) then raise exception 'Branch still has stock';end if;
 end if;
 return new;
end $$;
commit;