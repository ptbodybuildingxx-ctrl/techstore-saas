begin;
create table public.ts_ai_usage (
 usage_day date not null,
 user_id uuid not null references public.ts_profiles(user_id) on delete cascade,
 requests integer not null check(requests between 0 and 10),
 primary key(usage_day,user_id)
);
alter table public.ts_ai_usage enable row level security;
revoke all on public.ts_ai_usage from public,anon,authenticated;
grant select,insert,update on public.ts_ai_usage to service_role;
create function public.ts_ai_reserve(p_user uuid) returns boolean language plpgsql security invoker set search_path='' as $$
declare d date:=(now() at time zone 'UTC')::date; n integer;
begin
 perform pg_catalog.pg_advisory_xact_lock(593227501);
 if not exists(select 1 from public.ts_profiles where user_id=p_user and active) then return false; end if;
 select coalesce(sum(requests),0) into n from public.ts_ai_usage where usage_day=d;
 if n>=60 then return false; end if;
 insert into public.ts_ai_usage(usage_day,user_id,requests) values(d,p_user,1)
 on conflict(usage_day,user_id) do update set requests=public.ts_ai_usage.requests+1
 where public.ts_ai_usage.requests<10;
 return found;
end; $$;
revoke all on function public.ts_ai_reserve(uuid) from public,anon,authenticated;
grant execute on function public.ts_ai_reserve(uuid) to service_role;
commit;