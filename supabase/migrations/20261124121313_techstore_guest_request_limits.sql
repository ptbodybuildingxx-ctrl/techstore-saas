begin;
create table public.ts_guest_quota(bucket timestamptz not null, identity_hash text not null check(length(identity_hash)=64), requests integer not null check(requests between 1 and 100), primary key(bucket,identity_hash));
alter table public.ts_guest_quota enable row level security;
revoke all on public.ts_guest_quota from public,anon,authenticated;
grant select,insert,update,delete on public.ts_guest_quota to service_role;
create function public.ts_guest_reserve(p_hash text) returns boolean language plpgsql security invoker set search_path='' as $$
declare h timestamptz:=date_trunc('hour',now()); n integer;
begin
 if p_hash !~ '^[0-9a-f]{64}$' then return false; end if;
 perform pg_catalog.pg_advisory_xact_lock(593227502);
 delete from public.ts_guest_quota where bucket<h-interval '24 hours';
 select coalesce(sum(requests),0) into n from public.ts_guest_quota where bucket=h;
 if n>=100 then return false; end if;
 insert into public.ts_guest_quota(bucket,identity_hash,requests) values(h,p_hash,1) on conflict(bucket,identity_hash) do update set requests=public.ts_guest_quota.requests+1 where public.ts_guest_quota.requests<3;
 return found;
end $$;
revoke all on function public.ts_guest_reserve(text) from public,anon,authenticated;
grant execute on function public.ts_guest_reserve(text) to service_role;
commit;