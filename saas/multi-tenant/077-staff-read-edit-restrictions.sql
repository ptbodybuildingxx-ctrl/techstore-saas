-- Denials supplement existing roles. Financial documents remain immutable.
begin;
alter table tenant_private.staff_denials drop constraint staff_denials_action_check;
alter table tenant_private.staff_denials add constraint staff_denials_action_check check(action in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish'));
create or replace function tenant_private.staff_permission_set(p_store uuid,p_user uuid,p_action text,p_allowed boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_allowed is null or p_action is null or p_action not in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish') or not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role<>'owner') then raise exception 'Invalid permission' using errcode='22023';end if;
 if p_allowed then delete from tenant_private.staff_denials where store_id=p_store and user_id=p_user and action=p_action;
 else insert into tenant_private.staff_denials(store_id,user_id,action,actor) values(p_store,p_user,p_action,auth.uid()) on conflict do nothing;end if;return p_allowed;
end $$;
-- RLS policy predicates need EXECUTE; this function discloses only the caller's own eligibility.
grant execute on function tenant_private.staff_action_allowed(uuid,text) to authenticated;
create policy mt_staff_catalog_restrict on public.mt_products as restrictive for select to authenticated using(tenant_private.staff_action_allowed(store_id,'catalog_read'));
create policy mt_staff_price_restrict on public.mt_product_prices as restrictive for select to authenticated using(tenant_private.staff_action_allowed(store_id,'catalog_read'));
create policy mt_staff_stock_history_restrict on public.mt_stock_events as restrictive for select to authenticated using(tenant_private.staff_action_allowed(store_id,'catalog_read') and tenant_private.staff_action_allowed(store_id,'stock_history_read'));
create policy mt_staff_sales_restrict on public.mt_sales as restrictive for select to authenticated using(tenant_private.staff_action_allowed(store_id,'sales_read'));
create policy mt_staff_sale_lines_restrict on public.mt_sale_lines as restrictive for select to authenticated using(tenant_private.staff_action_allowed(store_id,'sales_read'));
create or replace function tenant_private.scoped_products(p_store uuid,p_currency text,p_query text,p_after uuid,p_limit integer,p_low boolean)
returns table(store_id uuid,id uuid,sku text,name text,quantity bigint,unit_price_minor bigint,specs jsonb) language plpgsql stable security definer set search_path='' as $$
declare b uuid:=tenant_private.current_branch_scope(p_store);
begin
 if not tenant_private.staff_action_allowed(p_store,'catalog_read') or not coalesce(tenant_private.member_role(p_store) in ('owner','stock','cashier'),false) then return;end if;
 if p_query is null or length(p_query)>100 or p_low is null or p_limit is null or p_limit not between 1 and 100 or (p_currency is not null and p_currency not in ('SYP','USD','EUR')) then raise exception 'Invalid query' using errcode='22023';end if;
 return query select p.store_id,p.id,p.sku,p.name,case when b is null then p.quantity else bs.units end,pp.price_minor,p.specs from public.mt_products p left join tenant_private.branch_stock bs on bs.store_id=p.store_id and bs.product_id=p.id and bs.branch_id=b left join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and (b is null or bs.branch_id=b) and (p_after is null or p.id>p_after) and (not p_low or (case when b is null then p.quantity else bs.units end)<=5) and (btrim(p_query)='' or strpos(lower(concat_ws(' ',p.name,p.sku,p.catalog->>'name_en',p.catalog->>'type',p.catalog->>'brand',p.catalog->>'category',p.catalog->>'model',p.catalog->>'variant')),lower(btrim(p_query)))>0) order by p.id limit p_limit;
end $$;
create or replace function tenant_private.branch_overview(p_store uuid,p_product uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;role_now text:=tenant_private.member_role(p_store);b uuid:=tenant_private.current_branch_scope(p_store);
begin
 if not coalesce(role_now in ('owner','stock','cashier'),false) then raise exception 'Branch access denied' using errcode='42501';end if;
 if p_product is not null and not tenant_private.staff_action_allowed(p_store,'catalog_read') then raise exception 'Catalog read denied' using errcode='42501';end if;
 select jsonb_build_object('branches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by name) from tenant_private.branches where store_id=p_store and (b is null or id=b)),'[]'::jsonb),'stock',case when p_product is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('branch_id',branch_id,'units',units)) from tenant_private.branch_stock where store_id=p_store and product_id=p_product and (b is null or branch_id=b)),'[]'::jsonb) end,'main',case when p_product is null or b is not null then null else (select quantity-tenant_private.branch_allocated(p_store,p_product) from public.mt_products where store_id=p_store and id=p_product) end,'transfers',case when p_product is null or role_now='cashier' then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id desc) from (select request_id,source,target,units,created_at from tenant_private.branch_transfers where store_id=p_store and product_id=p_product and (b is null or source=b or target=b) order by created_at desc,request_id desc limit 50)x),'[]'::jsonb) end) into r;return r;
end $$;
create or replace function tenant_private.pos_scan(p_store uuid,p_currency text,p_branch uuid,p_sku text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b uuid:=tenant_private.current_branch_scope(p_store);r jsonb;
begin
 if not tenant_private.staff_action_allowed(p_store,'catalog_read') or not tenant_private.staff_action_allowed(p_store,'sell') or not coalesce(tenant_private.member_role(p_store) in ('owner','cashier'),false) or (b is not null and b is distinct from p_branch) then raise exception 'Branch denied' using errcode='42501';end if;
 if p_sku is null or length(btrim(p_sku)) not between 1 and 80 or p_currency not in ('SYP','USD','EUR') then raise exception 'Invalid scan' using errcode='22023';end if;
 if p_branch is not null then perform tenant_private.require_branch(p_store,p_branch);end if;
 select jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'price_minor',pp.price_minor,'quantity',case when p_branch is null then tenant_private.main_available(p_store,p.id) else coalesce(bs.units,0) end) into r from public.mt_products p join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency left join tenant_private.branch_stock bs on bs.store_id=p.store_id and bs.product_id=p.id and bs.branch_id=p_branch where p.store_id=p_store and p.sku=btrim(p_sku);return r;
end $$;
create or replace function tenant_private.repair_scope_allowed(p_store uuid,p_repair uuid) returns boolean language sql stable security definer set search_path='' as $$
 select tenant_private.staff_action_allowed(p_store,'repair_read') and coalesce(tenant_private.member_role(p_store) in ('owner','tech'),false) and (tenant_private.member_role(p_store)='owner' or not exists(select 1 from tenant_private.repair_assignments where store_id=p_store and repair_id=p_repair) or exists(select 1 from tenant_private.repair_assignments where store_id=p_store and repair_id=p_repair and technician=auth.uid())) and (tenant_private.current_branch_scope(p_store) is null or exists(select 1 from tenant_private.branch_repairs where store_id=p_store and repair_id=p_repair and branch_id=tenant_private.current_branch_scope(p_store)))
$$;
create or replace function tenant_private.repair_task_finish(p_store uuid,p_id uuid,p_next text) returns boolean language plpgsql security definer set search_path='' as $$
declare v tenant_private.repair_tasks%rowtype;begin
 perform 1 from public.saas_stores where id=p_store for update;
 select * into v from tenant_private.repair_tasks where store_id=p_store and id=p_id for update;
 if not found then raise exception 'Unknown task' using errcode='22023';end if;
 perform tenant_private.require_repair(p_store,v.repair_id,true);
 if p_next is null or p_next not in ('done','cancelled') or (p_next='cancelled' and tenant_private.member_role(p_store)<>'owner') or not tenant_private.staff_action_allowed(p_store,'repair_transition') or not tenant_private.staff_action_allowed(p_store,'repair_task_finish') then raise exception 'Task action denied' using errcode='42501';end if;
 if v.state=p_next then return true;end if;
 if v.state<>'pending' or (p_next='done' and not tenant_private.repair_approved(p_store,v.repair_id)) or not exists(select 1 from public.mt_repairs where store_id=p_store and id=v.repair_id and state not in ('delivered','cancelled')) then raise exception 'Task not actionable' using errcode='22023';end if;
 update tenant_private.repair_tasks set state=p_next,finished_at=now() where store_id=p_store and id=p_id;return true;
end $$;
create function tenant_private.guard_staff_product_edit() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(new.store_id)='stock' and (new.specs is distinct from old.specs or new.name is distinct from old.name or new.sku is distinct from old.sku or new.catalog is distinct from old.catalog) and not tenant_private.staff_action_allowed(new.store_id,'product_edit') then raise exception 'Product editing restricted' using errcode='42501';end if;
 return new;
end $$;
create trigger mt_staff_product_edit before update on public.mt_products for each row execute function tenant_private.guard_staff_product_edit();
revoke all on function tenant_private.guard_staff_product_edit() from public,anon,authenticated,service_role;
commit;
