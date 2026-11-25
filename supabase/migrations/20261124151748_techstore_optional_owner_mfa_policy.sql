begin;
create table public.ts_mfa_policy(id int primary key check(id=1), mode text not null check(mode in ('optional','admin','staff')), updated_at timestamptz not null default now(), updated_by uuid references public.ts_profiles(user_id));
insert into public.ts_mfa_policy(id,mode) values(1,'optional');
alter table public.ts_mfa_policy enable row level security;
revoke all on public.ts_mfa_policy from public,anon,authenticated;
create function techstore_private.base_live_session(p_user uuid,p_sid text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.sessions s join auth.users u on u.id=s.user_id where s.user_id=p_user and s.id::text=p_sid and (s.not_after is null or s.not_after>now()) and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and u.email_confirmed_at is not null)
$$;
revoke all on function techstore_private.base_live_session(uuid,text) from public,anon,authenticated;
create function techstore_private.mfa_required(p_user uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.mfa_factors f where f.user_id=p_user and f.status='verified') or exists(select 1 from public.ts_profiles p cross join public.ts_mfa_policy m where p.user_id=p_user and p.active and ((m.mode='admin' and p.role='admin') or (m.mode='staff' and p.role in ('admin','cashier','stock','tech'))))
$$;
revoke all on function techstore_private.mfa_required(uuid) from public,anon,authenticated;
create function techstore_private.mfa_session_verified(p_user uuid,p_sid text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.sessions s where s.user_id=p_user and s.id::text=p_sid and s.aal='aal2') and exists(select 1 from auth.mfa_factors f where f.user_id=p_user and f.status='verified')
$$;
revoke all on function techstore_private.mfa_session_verified(uuid,text) from public,anon,authenticated;
create or replace function techstore_private.live_session() returns boolean language sql stable security definer set search_path='' as $$
 select techstore_private.base_live_session(auth.uid(),auth.jwt()->>'session_id') and (not techstore_private.mfa_required(auth.uid()) or (auth.jwt()->>'aal'='aal2' and techstore_private.mfa_session_verified(auth.uid(),auth.jwt()->>'session_id')))
$$;
-- Legacy Edge servers currently pass user and session only; check server-side session AAL here.
create function techstore_private.legacy_session_valid(p_user uuid,p_session uuid) returns boolean language sql stable security definer set search_path='' as $$
 select techstore_private.base_live_session(p_user,p_session::text) and (not techstore_private.mfa_required(p_user) or techstore_private.mfa_session_verified(p_user,p_session::text))
$$;
revoke all on function techstore_private.legacy_session_valid(uuid,uuid) from public,anon,authenticated;
grant execute on function techstore_private.legacy_session_valid(uuid,uuid) to service_role;
create or replace function public.ts_session_valid(p_user uuid,p_session uuid) returns boolean language sql stable security invoker set search_path='' as $$ select techstore_private.legacy_session_valid(p_user,p_session) $$;
revoke all on function public.ts_session_valid(uuid,uuid) from public,anon,authenticated;
grant execute on function public.ts_session_valid(uuid,uuid) to service_role;
create function techstore_private.mfa_settings(p_action text,p_mode text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; mode_value text; verified boolean; needed boolean; elevated boolean; factors jsonb;
begin
 if techstore_private.base_live_session(auth.uid(),auth.jwt()->>'session_id') is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found then raise exception 'Access denied' using errcode='42501';end if;
 select mode into mode_value from public.ts_mfa_policy where id=1;
 verified:=exists(select 1 from auth.mfa_factors where user_id=u.user_id and status='verified');
 needed:=techstore_private.mfa_required(u.user_id);
 elevated:=coalesce(auth.jwt()->>'aal'='aal2',false) and techstore_private.mfa_session_verified(u.user_id,auth.jwt()->>'session_id');
 if p_action='save' then
 if u.role<>'admin' or not elevated then raise exception 'Owner MFA verification required' using errcode='42501';end if;
 if p_mode is null or p_mode not in ('optional','admin','staff') then raise exception 'Invalid MFA mode';end if;
 update public.ts_mfa_policy set mode=p_mode,updated_at=now(),updated_by=u.user_id where id=1;
 insert into public.ts_audit(actor,action) values(u.user_id,'MFA policy changed to '||p_mode);
 mode_value:=p_mode;
 elsif p_action is distinct from 'get' then raise exception 'Unknown action';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.friendly_name,'type',f.factor_type,'status',f.status) order by f.created_at),'[]'::jsonb) into factors from auth.mfa_factors f where f.user_id=u.user_id;
 return jsonb_build_object('mode',mode_value,'role',u.role,'required',needed,'verified',verified,'elevated',elevated,'factors',factors);
end $$;
revoke all on function techstore_private.mfa_settings(text,text) from public,anon,authenticated;
grant execute on function techstore_private.mfa_settings(text,text) to authenticated;
create function public.ts_mfa_settings(p_action text,p_mode text default null) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.mfa_settings(p_action,p_mode) $$;
revoke all on function public.ts_mfa_settings(text,text) from public,anon,authenticated;
grant execute on function public.ts_mfa_settings(text,text) to authenticated;
commit;