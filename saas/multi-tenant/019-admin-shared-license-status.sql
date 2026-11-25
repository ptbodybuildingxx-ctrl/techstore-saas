begin;
create function tenant_private.admin_shared_license_status(p_stores uuid[]) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_stores is null or cardinality(p_stores)>100 or array_position(p_stores,null::uuid) is not null then raise exception 'Invalid store page' using errcode='22023';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',w.store_id,'state',sub.state,'plan',sub.plan_code,'valid_until',sub.valid_until,'write_entitlement',tenant_private.shared_licensed(w.store_id)) order by w.store_id),'[]'::jsonb) into r from tenant_private.workspaces w join public.saas_subscriptions sub on sub.store_id=w.store_id where w.store_id=any(p_stores);
 return r;
end $$;
create function public.mt_admin_shared_license_status(p_stores uuid[]) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.admin_shared_license_status(p_stores)$$;
revoke all on function tenant_private.admin_shared_license_status(uuid[]),public.mt_admin_shared_license_status(uuid[]) from public,anon,authenticated,service_role;
grant execute on function tenant_private.admin_shared_license_status(uuid[]),public.mt_admin_shared_license_status(uuid[]) to authenticated;
commit;