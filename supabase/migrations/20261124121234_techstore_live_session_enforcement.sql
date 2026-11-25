begin;
create or replace function techstore_private.live_session() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.sessions s join auth.users u on u.id=s.user_id
 where s.user_id=auth.uid() and s.id::text=auth.jwt()->>'session_id'
 and (s.not_after is null or s.not_after>now()) and u.deleted_at is null
 and (u.banned_until is null or u.banned_until<=now()) and u.email_confirmed_at is not null);
$$;
revoke all on function techstore_private.live_session() from public,anon;
grant usage on schema techstore_private to authenticated;
grant execute on function techstore_private.live_session() to authenticated;
create policy ts_profile_live_session on public.ts_profiles as restrictive for all to authenticated using ((select techstore_private.live_session())) with check ((select techstore_private.live_session()));
create policy ts_grants_live_session on public.ts_pro_grants as restrictive for all to authenticated using ((select techstore_private.live_session())) with check ((select techstore_private.live_session()));
create policy ts_entries_live_session on public.ts_pro_entries as restrictive for all to authenticated using ((select techstore_private.live_session())) with check ((select techstore_private.live_session()));
create or replace function public.ts_session_valid(p_user uuid,p_session uuid) returns boolean
language sql stable security invoker set search_path='' as $$
 select exists(select 1 from auth.sessions s join auth.users u on u.id=s.user_id where s.user_id=p_user and s.id=p_session and (s.not_after is null or s.not_after>now()) and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and u.email_confirmed_at is not null);
$$;
revoke all on function public.ts_session_valid(uuid,uuid) from public,anon,authenticated;
grant execute on function public.ts_session_valid(uuid,uuid) to service_role;
-- Service role is only allowed to read required session columns.
grant usage on schema auth to service_role;
grant select(id,user_id,not_after) on auth.sessions to service_role;
grant select(id,deleted_at,banned_until,email_confirmed_at) on auth.users to service_role;
commit;