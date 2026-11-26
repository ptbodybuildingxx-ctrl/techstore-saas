-- Shared application-level session revocation and optional buyer/staff TOTP.
-- Operators continue to require AAL2. No writes to managed Auth tables.
begin;
create table saas_private.revoked_app_sessions(
 session_id uuid primary key,user_id uuid not null,revoked_at timestamptz not null default now()
);
alter table saas_private.revoked_app_sessions enable row level security;
revoke all on saas_private.revoked_app_sessions from public,anon,authenticated,service_role;
create or replace function saas_private.live_session() returns boolean
language sql stable security definer set search_path='' as $$
 select exists (
  select 1 from auth.sessions s join auth.users u on u.id=s.user_id
  where s.user_id=auth.uid() and s.id::text=auth.jwt()->>'session_id'
  and (s.not_after is null or s.not_after>now())
  and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until<=now())
  and not u.is_anonymous
  and not exists(select 1 from saas_private.revoked_app_sessions r where r.session_id=s.id)
  and (not exists(select 1 from auth.mfa_factors f where f.user_id=u.id and f.factor_type::text='totp' and f.status::text='verified') or auth.jwt()->>'aal'='aal2')
 )
$$;
create function saas_private.account_sessions() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not saas_private.live_session() then raise exception 'Live session required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.current desc,x.id) from (
  select s.id,s.id::text=auth.jwt()->>'session_id' as current,s.aal::text as aal,
    left(coalesce(to_jsonb(s)->>'user_agent',''),300) as device,to_jsonb(s)->>'created_at' as created_at
  from auth.sessions s where s.user_id=auth.uid() and (s.not_after is null or s.not_after>now())
  and not exists(select 1 from saas_private.revoked_app_sessions r where r.session_id=s.id)
  order by (s.id::text=auth.jwt()->>'session_id') desc,s.id limit 50
 )x),'[]'::jsonb);
end $$;
create function saas_private.revoke_app_session(p_session uuid) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if not saas_private.live_session() or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'AAL2 required' using errcode='42501';end if;
 if p_session is null or p_session::text=auth.jwt()->>'session_id' or not exists(select 1 from auth.sessions s where s.id=p_session and s.user_id=auth.uid()) then raise exception 'Invalid other session' using errcode='22023';end if;
 insert into saas_private.revoked_app_sessions(session_id,user_id) values(p_session,auth.uid()) on conflict do nothing;
 return true;
end $$;
create function public.mt_account_sessions() returns jsonb language sql stable security invoker set search_path='' as $$select saas_private.account_sessions()$$;
create function public.mt_account_revoke_session(p_session uuid) returns boolean language sql security invoker set search_path='' as $$select saas_private.revoke_app_session(p_session)$$;
revoke all on function saas_private.account_sessions(),saas_private.revoke_app_session(uuid),public.mt_account_sessions(),public.mt_account_revoke_session(uuid) from public,anon,authenticated,service_role;
grant execute on function saas_private.account_sessions(),saas_private.revoke_app_session(uuid),public.mt_account_sessions(),public.mt_account_revoke_session(uuid) to authenticated;
create or replace function tenant_private.my_staff_sessions(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Membership required' using errcode='42501';end if;
 return saas_private.account_sessions();
end $$;
commit;
