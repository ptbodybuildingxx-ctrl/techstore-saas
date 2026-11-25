begin;
create table public.ts_push_subscriptions(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.ts_profiles(user_id) on delete cascade,
 session_id uuid not null, endpoint text not null unique check(length(endpoint) between 20 and 2048),
 p256dh text not null check(p256dh ~ '^[A-Za-z0-9_-]{87}$'), auth_key text not null check(auth_key ~ '^[A-Za-z0-9_-]{22}$'),
 created_at timestamptz not null default now()
);
create table public.ts_push_outbox(
 id uuid primary key default gen_random_uuid(), subscription_id uuid not null references public.ts_push_subscriptions(id) on delete cascade,
 event_key text not null, created_at timestamptz not null default now(), next_attempt timestamptz not null default now(),
 attempts smallint not null default 0, lease_id uuid, sent_at timestamptz, failed boolean not null default false,
 unique(subscription_id,event_key)
);
create index ts_push_due_idx on public.ts_push_outbox(next_attempt) where sent_at is null and not failed;
create index ts_push_user_idx on public.ts_push_subscriptions(user_id);
alter table public.ts_push_subscriptions enable row level security;
alter table public.ts_push_outbox enable row level security;
revoke all on public.ts_push_subscriptions,public.ts_push_outbox from public,anon,authenticated;
grant select,insert,update,delete on public.ts_push_subscriptions,public.ts_push_outbox to service_role;
create function techstore_private.push_enqueue(p_user uuid,p_event text) returns void language sql security definer set search_path='' as $$
 insert into public.ts_push_outbox(subscription_id,event_key)
 select s.id,p_event from public.ts_push_subscriptions s join public.ts_profiles p on p.user_id=s.user_id and p.active
 join auth.sessions a on a.id=s.session_id and a.user_id=s.user_id and (a.not_after is null or a.not_after>now())
 where s.user_id=p_user on conflict do nothing;
$$;
revoke all on function techstore_private.push_enqueue(uuid,text) from public,anon,authenticated;
create function techstore_private.push_alert_trigger() returns trigger language plpgsql security definer set search_path='' as $$
begin perform techstore_private.push_enqueue(new.user_id,'alert:'||new.id);return new;end $$;
revoke all on function techstore_private.push_alert_trigger() from public,anon,authenticated;
create trigger ts_push_product_alert after insert on public.ts_product_alert_events for each row execute function techstore_private.push_alert_trigger();
create function techstore_private.push_guest_trigger() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.ts_push_outbox(subscription_id,event_key)
 select s.id,'guest:'||new.id from public.ts_push_subscriptions s join public.ts_profiles p on p.user_id=s.user_id and p.active and p.role in ('admin','cashier')
 join auth.sessions a on a.id=s.session_id and a.user_id=s.user_id and (a.not_after is null or a.not_after>now()) on conflict do nothing;
 return new;
end $$;
revoke all on function techstore_private.push_guest_trigger() from public,anon,authenticated;
create trigger ts_push_guest_request after insert on public.ts_guest_requests for each row execute function techstore_private.push_guest_trigger();
create function techstore_private.push_workspace_trigger() returns trigger language plpgsql security definer set search_path='' as $$
declare r jsonb;
begin
 if old.payload->'records'->'notifications' is not distinct from new.payload->'records'->'notifications' then return new;end if;
 for r in select n from jsonb_array_elements(coalesce(new.payload->'records'->'notifications','[]'::jsonb)) n where n->>'owner' ~ '^[0-9a-fA-F-]{36}$' and n->>'id' is not null and not exists(select 1 from jsonb_array_elements(coalesce(old.payload->'records'->'notifications','[]'::jsonb)) o where o->>'id'=n->>'id') loop
 if exists(select 1 from public.ts_profiles p where p.user_id::text=r->>'owner' and p.active) then perform techstore_private.push_enqueue((r->>'owner')::uuid,'notification:'||left(r->>'id',100));end if;
 end loop;return new;
end $$;
revoke all on function techstore_private.push_workspace_trigger() from public,anon,authenticated;
create trigger ts_push_workspace after update of payload on public.ts_workspace for each row execute function techstore_private.push_workspace_trigger();
-- Service-only vault helpers. Keys never reach clients, SQL tool output or repository.
create function techstore_private.push_secret(p_name text,p_value text default null) returns text language plpgsql security definer set search_path='' as $$
declare v text;
begin
 if p_name not in ('techstore_push_vapid_public','techstore_push_vapid_private','techstore_push_worker_token') then raise exception 'Invalid secret';end if;
 perform pg_catalog.pg_advisory_xact_lock(593227503);
 select decrypted_secret into v from vault.decrypted_secrets where name=p_name;
 if v is null and p_value is not null then perform vault.create_secret(p_value,p_name,'TechStore Web Push');v:=p_value;end if;
 return v;
end $$;
revoke all on function techstore_private.push_secret(text,text) from public,anon,authenticated;
grant usage on schema techstore_private to service_role;
grant execute on function techstore_private.push_secret(text,text) to service_role;
create function public.ts_push_secret(p_name text,p_value text default null) returns text language sql security invoker set search_path='' as $$ select techstore_private.push_secret(p_name,p_value); $$;
revoke all on function public.ts_push_secret(text,text) from public,anon,authenticated;
grant execute on function public.ts_push_secret(text,text) to service_role;
create function public.ts_push_claim(p_lease uuid) returns table(job_id uuid,subscription_id uuid,endpoint text,p256dh text,auth_key text,event_key text) language sql security invoker set search_path='' as $$
 with due as (
 select o.id from public.ts_push_outbox o join public.ts_push_subscriptions s on s.id=o.subscription_id join public.ts_profiles p on p.user_id=s.user_id and p.active
 join auth.sessions a on a.id=s.session_id and a.user_id=s.user_id and (a.not_after is null or a.not_after>now())
 where o.sent_at is null and not o.failed and o.attempts<5 and o.next_attempt<=now() and o.created_at>now()-interval '1 day'
 order by o.next_attempt limit 10 for update of o skip locked
 ), claimed as (
 update public.ts_push_outbox o set attempts=o.attempts+1,lease_id=p_lease,next_attempt=now()+interval '5 minutes' from due where o.id=due.id returning o.*
 )
 select c.id,s.id,s.endpoint,s.p256dh,s.auth_key,c.event_key from claimed c join public.ts_push_subscriptions s on s.id=c.subscription_id;
$$;
revoke all on function public.ts_push_claim(uuid) from public,anon,authenticated;
grant execute on function public.ts_push_claim(uuid) to service_role;
-- Initialize worker authentication server-side, without returning the value.
do $$ begin perform techstore_private.push_secret('techstore_push_worker_token',encode(extensions.gen_random_bytes(32),'hex'));end $$;
commit;