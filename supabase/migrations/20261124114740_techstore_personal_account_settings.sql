begin;
alter table public.ts_profiles
 add column if not exists phone text not null default '',
 add column if not exists avatar text not null default '';
alter table public.ts_profiles add constraint ts_profile_phone_length check (char_length(phone)<=40);
alter table public.ts_profiles add constraint ts_profile_name_length check (char_length(name)<=200);
alter table public.ts_profiles add constraint ts_profile_avatar_format check (
 avatar='' or (octet_length(avatar)<=180000 and avatar ~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$')
);
alter table public.ts_profiles enable row level security;
revoke all on public.ts_profiles from anon, authenticated;
grant select(user_id,name,email,role,active,phone,avatar) on public.ts_profiles to authenticated;
grant update(name,phone,avatar) on public.ts_profiles to authenticated;
create policy ts_profile_self_read on public.ts_profiles for select to authenticated
 using ((select auth.uid())=user_id and active);
create policy ts_profile_self_update on public.ts_profiles for update to authenticated
 using ((select auth.uid())=user_id and active)
 with check ((select auth.uid())=user_id and active);
commit;