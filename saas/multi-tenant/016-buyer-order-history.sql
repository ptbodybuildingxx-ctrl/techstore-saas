begin;
create function tenant_private.my_online_orders(p_slug text,p_after uuid,p_limit integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;t uuid;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid order page' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug;
 select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb) into r from (select store_id,id,request_id,currency,total_minor,state,sale_id,created_at from public.mt_online_orders where store_id=t and buyer=auth.uid() and (p_after is null or id>p_after) order by id limit p_limit) x;return r;
end $$;
create function public.mt_my_online_orders(p_slug text,p_after uuid default null,p_limit integer default 50) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.my_online_orders(p_slug,p_after,p_limit)$$;
revoke all on function tenant_private.my_online_orders(text,uuid,integer),public.mt_my_online_orders(text,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.my_online_orders(text,uuid,integer),public.mt_my_online_orders(text,uuid,integer) to authenticated;
commit;