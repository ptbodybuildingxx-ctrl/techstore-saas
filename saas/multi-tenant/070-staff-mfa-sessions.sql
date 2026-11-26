-- Staff with verified TOTP must use an AAL2 session for all tenant membership access.
begin;
create or replace function tenant_private.member_role(p_store uuid) returns text language sql stable security definer set search_path='' as $$
 select m.role from tenant_private.members m join auth.users u on u.id=m.user_id where m.store_id=p_store and m.user_id=auth.uid() and m.active and not u.is_anonymous and saas_private.live_session()
 and (not exists(select 1 from auth.mfa_factors f where f.user_id=m.user_id and f.factor_type::text='totp' and f.status::text='verified') or auth.jwt()->>'aal'='aal2')
$$;
create function tenant_private.my_staff_sessions(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Membership required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.current desc,x.id) from (select s.id,s.id::text=auth.jwt()->>'session_id' as current,s.aal::text as aal,s.not_after, left(coalesce(to_jsonb(s)->>'user_agent',''),300) as device,to_jsonb(s)->>'created_at' as created_at from auth.sessions s where s.user_id=auth.uid() and (s.not_after is null or s.not_after>now()) order by (s.id::text=auth.jwt()->>'session_id') desc,s.id limit 50)x),'[]'::jsonb);
end $$;
create function public.mt_my_staff_sessions(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.my_staff_sessions(p_store)$$;
revoke all on function tenant_private.my_staff_sessions(uuid),public.mt_my_staff_sessions(uuid) from public,anon,authenticated,service_role;grant execute on function tenant_private.my_staff_sessions(uuid),public.mt_my_staff_sessions(uuid) to authenticated;
commit;
