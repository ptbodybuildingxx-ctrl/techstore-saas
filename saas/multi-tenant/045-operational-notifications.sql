-- Live derived work alerts. No paid transport, no invented event records.
begin;
create function public.mt_work_alerts(p_store uuid) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);r jsonb:='{}'::jsonb;
begin
 if role_now is null then raise exception 'Tenant access denied' using errcode='42501';end if;
 if role_now in ('owner','stock') then r:=r||jsonb_build_object('low_stock',(select count(*) from public.mt_products where store_id=p_store and quantity<=5));end if;
 if role_now in ('owner','tech') then r:=r||jsonb_build_object('repairs_ready',(select count(*) from public.mt_repairs where store_id=p_store and state='ready'),'repairs_received',(select count(*) from public.mt_repairs where store_id=p_store and state='received'));end if;
 if role_now='owner' then r:=r||jsonb_build_object('orders_pending',(select count(*) from public.mt_online_orders where store_id=p_store and state='pending'),'installments_overdue',(select count(*) from public.mt_installments where store_id=p_store and due_date<(now() at time zone 'Asia/Damascus')::date and paid_minor+waived_minor<amount_minor));end if;
 return r;
end $$;
revoke all on function public.mt_work_alerts(uuid) from public,anon,authenticated,service_role;
grant execute on function public.mt_work_alerts(uuid) to authenticated;
commit;
