-- Additional independent restrictions; existing role and branch checks remain mandatory.
begin;
alter table tenant_private.staff_denials drop constraint staff_denials_action_check;
alter table tenant_private.staff_denials add constraint staff_denials_action_check check(action in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish','repair_create','product_price_edit'));
create or replace function tenant_private.staff_permission_set(p_store uuid,p_user uuid,p_action text,p_allowed boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_allowed is null or p_action is null or p_action not in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish','repair_create','product_price_edit') or not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role<>'owner') then raise exception 'Invalid permission' using errcode='22023';end if;
 if p_allowed then delete from tenant_private.staff_denials where store_id=p_store and user_id=p_user and action=p_action;
 else insert into tenant_private.staff_denials(store_id,user_id,action,actor) values(p_store,p_user,p_action,auth.uid()) on conflict do nothing;end if;return p_allowed;
end $$;
create function tenant_private.guard_staff_repair_create() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(new.store_id) in ('tech','cashier','stock') and not tenant_private.staff_action_allowed(new.store_id,'repair_create') then raise exception 'Repair intake restricted' using errcode='42501';end if;
 return new;
end $$;
create trigger mt_staff_repair_create before insert on public.mt_repairs for each row execute function tenant_private.guard_staff_repair_create();
create function tenant_private.guard_staff_price_edit() returns trigger language plpgsql security definer set search_path='' as $$
declare s uuid;
begin
 s:=case when tg_op='DELETE' then old.store_id else new.store_id end;
 if tenant_private.member_role(s) in ('tech','cashier','stock') and not tenant_private.staff_action_allowed(s,'product_price_edit') then raise exception 'Price editing restricted' using errcode='42501';end if;
 if tg_op='DELETE' then return old;end if;
 return new;
end $$;
create trigger mt_staff_price_edit before insert or update or delete on public.mt_product_prices for each row execute function tenant_private.guard_staff_price_edit();
revoke all on function tenant_private.guard_staff_repair_create(),tenant_private.guard_staff_price_edit() from public,anon,authenticated,service_role;
commit;
