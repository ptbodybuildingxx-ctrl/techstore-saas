begin;
create schema if not exists techstore_private;
revoke all on schema techstore_private from public, anon, authenticated;
alter table public.ts_profiles add column if not exists email text not null default '';
alter table public.ts_profiles enable row level security;
alter table public.ts_workspace enable row level security;
alter table public.ts_audit enable row level security;
revoke all on public.ts_profiles, public.ts_workspace, public.ts_audit from public, anon, authenticated;
grant select,insert,update,delete on public.ts_profiles, public.ts_workspace, public.ts_audit to service_role;
grant usage,select on sequence public.ts_audit_id_seq to service_role;
revoke all on function public.ts_commit(bigint,jsonb,uuid,text) from public, anon, authenticated;
grant execute on function public.ts_commit(bigint,jsonb,uuid,text) to service_role;
create or replace function techstore_private.on_auth_user() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.ts_profiles(user_id,name,email,role)
  values(new.id,left(coalesce(new.raw_user_meta_data->>'name',''),200),coalesce(new.email,''),'customer')
  on conflict(user_id) do update set email=excluded.email;
  return new;
end;
$$;
revoke all on function techstore_private.on_auth_user() from public, anon, authenticated;
create trigger techstore_profile_on_insert after insert on auth.users for each row execute function techstore_private.on_auth_user();
create trigger techstore_profile_on_email_change after update of email on auth.users for each row execute function techstore_private.on_auth_user();
insert into public.ts_profiles(user_id,name,email,role)
select id,left(coalesce(raw_user_meta_data->>'name',''),200),coalesce(email,''),'customer' from auth.users
on conflict(user_id) do update set email=excluded.email;
commit;