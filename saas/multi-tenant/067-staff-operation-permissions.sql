-- Restrict existing role permissions; never elevate privileges or bypass branch checks.
begin;
create table tenant_private.staff_denials(
 store_id uuid not null,user_id uuid not null,action text not null check(action in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance')),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,user_id,action),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id)
);
alter table tenant_private.staff_denials enable row level security;
revoke all on tenant_private.staff_denials from public,anon,authenticated,service_role;
create function tenant_private.staff_action_allowed(p_store uuid,p_action text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) is not null and (tenant_private.member_role(p_store)='owner' or not exists(select 1 from tenant_private.staff_denials where store_id=p_store and user_id=auth.uid() and action=p_action)),false)
$$;
create function tenant_private.staff_permission_set(p_store uuid,p_user uuid,p_action text,p_allowed boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_allowed is null or p_action is null or p_action not in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance') or not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role<>'owner') then raise exception 'Invalid permission' using errcode='22023';end if;
 if p_allowed then delete from tenant_private.staff_denials where store_id=p_store and user_id=p_user and action=p_action;
 else insert into tenant_private.staff_denials(store_id,user_id,action,actor) values(p_store,p_user,p_action,auth.uid()) on conflict do nothing;end if;return p_allowed;
end $$;
create function tenant_private.staff_permissions(p_store uuid,p_user uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r text:=tenant_private.member_role(p_store);u uuid:=coalesce(p_user,auth.uid());begin
 if r is null or (r<>'owner' and u<>auth.uid()) then raise exception 'Permission denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(action order by action) from tenant_private.staff_denials where store_id=p_store and user_id=u),'[]'::jsonb);
end $$;
create function tenant_private.guard_staff_action() returns trigger language plpgsql security definer set search_path='' as $$
declare r text:=tenant_private.member_role(new.store_id);a text:=tg_argv[0];
begin
 -- Buyer orders and system operations may have no tenant membership; their own RPC checks apply.
 -- The restriction is enforced for assigned staff on operational writes.
 if a='stock_adjust' and r is distinct from 'stock' then return new;end if;
 if r in ('cashier','stock','tech') and not tenant_private.staff_action_allowed(new.store_id,a) then raise exception 'Employee operation restricted' using errcode='42501';end if;return new;
end $$;
create trigger mt_staff_deny_sale before insert on public.mt_sales for each row execute function tenant_private.guard_staff_action('sell');
create trigger mt_staff_deny_adjust before insert on public.mt_stock_events for each row execute function tenant_private.guard_staff_action('stock_adjust');
create trigger mt_staff_deny_transfer before insert on tenant_private.branch_transfers for each row execute function tenant_private.guard_staff_action('stock_transfer');
create trigger mt_staff_deny_product before insert on public.mt_products for each row execute function tenant_private.guard_staff_action('product_create');
create trigger mt_staff_deny_repair before insert on public.mt_repair_events for each row execute function tenant_private.guard_staff_action('repair_transition');
create trigger mt_staff_deny_evidence before insert on tenant_private.repair_evidence for each row execute function tenant_private.guard_staff_action('repair_evidence');
create trigger mt_staff_deny_attendance before insert or update on tenant_private.staff_shifts for each row execute function tenant_private.guard_staff_action('attendance');
create function public.mt_staff_permission_set(p_store uuid,p_user uuid,p_action text,p_allowed boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.staff_permission_set(p_store,p_user,p_action,p_allowed)$$;
create function public.mt_staff_permissions(p_store uuid,p_user uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.staff_permissions(p_store,p_user)$$;
revoke all on function tenant_private.staff_action_allowed(uuid,text),tenant_private.staff_permission_set(uuid,uuid,text,boolean),tenant_private.staff_permissions(uuid,uuid),tenant_private.guard_staff_action(),public.mt_staff_permission_set(uuid,uuid,text,boolean),public.mt_staff_permissions(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.staff_permission_set(uuid,uuid,text,boolean),tenant_private.staff_permissions(uuid,uuid),public.mt_staff_permission_set(uuid,uuid,text,boolean),public.mt_staff_permissions(uuid,uuid) to authenticated;
commit;
