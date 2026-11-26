-- 130: central fine-grained restrictions for existing employee operations and mutable record actions.
begin;
create table tenant_private.admin_action_policy(
 plan_code text primary key references public.saas_plans(code) on delete cascade,revision bigint not null check(revision>=1),denied text[] not null,updated_at timestamptz not null default now()
);
create table tenant_private.admin_action_events(
 request_id uuid primary key,plan_code text not null,actor uuid not null,reference text not null check(length(btrim(reference)) between 1 and 200),
 previous_revision bigint not null,before_denied text[] not null,after_denied text[] not null,created_at timestamptz not null default now()
);
alter table tenant_private.admin_action_policy enable row level security;
alter table tenant_private.admin_action_events enable row level security;
revoke all on tenant_private.admin_action_policy,tenant_private.admin_action_events from public,anon,authenticated;
create function tenant_private.central_action_denied(s uuid,k text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select k=any(p.denied) from public.saas_subscriptions sub join tenant_private.admin_action_policy p on p.plan_code=sub.plan_code where sub.store_id=s),false)
$$;
create function tenant_private.staff_central_denials(s uuid) returns text[] language sql stable security definer set search_path='' as $$
 select coalesce((select array_agg(substr(k,7) order by k) from public.saas_subscriptions sub join tenant_private.admin_action_policy p on p.plan_code=sub.plan_code cross join lateral unnest(p.denied) k where sub.store_id=s and left(k,6)='staff_'),'{}'::text[])
$$;
create function tenant_private.staff_all_denials(s uuid,u uuid) returns table(action text) language sql stable security definer set search_path='' as $$
 select d.action from tenant_private.staff_denials d where d.store_id=s and d.user_id=u
 union select k from unnest(tenant_private.staff_central_denials(s)) k
$$;
revoke all on function tenant_private.central_action_denied(uuid,text),tenant_private.staff_central_denials(uuid),tenant_private.staff_all_denials(uuid,uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION tenant_private.procurement_access(s uuid, u uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target uuid:=coalesce(u,auth.uid());g tenant_private.procurement_grants%rowtype;r text;sr boolean;pr boolean;
begin
 r:=tenant_private.member_role(s);
 if r is null or (target<>auth.uid() and r<>'owner') then raise exception 'Access denied' using errcode='42501';end if;
 if target=auth.uid() and r='owner' then return jsonb_build_object('read',true,'supplier_read',true,'purchase_read',true,'supplier',true,'receive',true,'licensed',tenant_private.shared_licensed(s),'branch',null);end if;
 select * into g from tenant_private.procurement_grants where store_id=s and user_id=target and exists(select 1 from tenant_private.members m where m.store_id=s and m.user_id=target and m.active and m.role='stock');
 sr:=coalesce(g.read_allowed,false) and not exists(select 1 from tenant_private.staff_all_denials(s,target) where action in ('procurement_read','supplier_read'));
 pr:=coalesce(g.read_allowed,false) and not exists(select 1 from tenant_private.staff_all_denials(s,target) where action in ('procurement_read','purchase_read'));
 return jsonb_build_object('read',sr or pr,'supplier_read',sr,'purchase_read',pr,'supplier',sr and coalesce(g.manage_suppliers,false) and not exists(select 1 from tenant_private.staff_all_denials(s,target) where action='supplier_write'),'receive',sr and pr and coalesce(g.receive_credit,false) and not exists(select 1 from tenant_private.staff_all_denials(s,target) where action in ('purchase_write','catalog_read','stock_adjust')),'licensed',tenant_private.shared_licensed(s),'branch',case when target=auth.uid() then tenant_private.current_branch_scope(s) end);
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.receivable_grant_read(p_store uuid, p_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid:=coalesce(p_user,auth.uid());b uuid;granted text[]:='{}';effective text[]:='{}';role_now text:=tenant_private.member_role(p_store);
begin
 if role_now is null or (u is distinct from auth.uid() and role_now<>'owner') then raise exception 'Access denied' using errcode='42501';end if;
 if u=auth.uid() and role_now='owner' then
 granted:=array['read','customer_create','customer_edit','credit_sale','debt_payment','standalone_open','standalone_payment','payable_manage'];effective:=granted;
 elsif exists(select 1 from tenant_private.members where store_id=p_store and user_id=u and active and role='cashier') then
 select branch_id into b from tenant_private.cashier_branch_scope where store_id=p_store and user_id=u;
 select coalesce((select actions from tenant_private.receivable_grants where store_id=p_store and user_id=u and branch_id is not distinct from b),'{}'::text[]) into granted;
 select coalesce(array_agg(a order by a),'{}'::text[]) into effective from unnest(granted) a where tenant_private.shared_licensed(p_store) and not exists(select 1 from tenant_private.staff_all_denials(p_store,u) d where (d.action='receivable_read' or d.action=a or (a='credit_sale' and d.action='sell') or (a='standalone_payment' and d.action='debt_payment') or (a in ('customer_create','customer_edit','credit_sale') and d.action='customer_read') or (a in ('credit_sale','debt_payment','standalone_open','standalone_payment','payable_manage') and d.action='debt_read')));
 elsif p_user is not null then raise exception 'Unknown active cashier' using errcode='22023';
 end if;
 return jsonb_build_object('user',u,'branch',b,'granted',to_jsonb(granted),'effective',to_jsonb(effective));
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.staff_access_matrix(s uuid, u uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r text;enabled boolean;b uuid;licensed boolean;d text[];central text[];rg text[];pg tenant_private.procurement_grants%rowtype;items jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select role,active into r,enabled from tenant_private.members where store_id=s and user_id=u;
 if not found then raise exception 'Unknown employee' using errcode='22023';end if;
 select coalesce((select branch_id from tenant_private.cashier_branch_scope where store_id=s and user_id=u),(select branch_id from tenant_private.staff_branch_scope where store_id=s and user_id=u)) into b;
 licensed:=coalesce(tenant_private.shared_licensed(s),false);
 select coalesce(array_agg(action order by action),'{}'::text[]) into d from tenant_private.staff_denials where store_id=s and user_id=u;
 central:=case when r='owner' then '{}'::text[] else tenant_private.staff_central_denials(s) end;
 enabled:=enabled and not exists(select 1 from tenant_private.admin_member_holds where store_id=s and user_id=u and blocked);
 select coalesce((select actions from tenant_private.receivable_grants where store_id=s and user_id=u and branch_id is not distinct from b),'{}'::text[]) into rg;
 select * into pg from tenant_private.procurement_grants where store_id=s and user_id=u;
 with matrix(action,role_access,grant_access,write_action,depends,editable) as (values
 ('sell',r='cashier',true,true,array[]::text[],true),
 ('stock_adjust',r='stock' and b is null,true,true,array['catalog_read'],true),
 ('stock_transfer',r='stock',true,true,array[]::text[],true),
 ('product_create',r='stock' and b is null,true,true,array[]::text[],true),
 ('repair_transition',r='tech',true,true,array['repair_read'],true),
 ('repair_evidence',r='tech',true,true,array['repair_read'],true),
 ('attendance',r in ('cashier','stock','tech'),true,true,array[]::text[],true),
 ('catalog_read',r in ('cashier','stock'),true,false,array[]::text[],true),
 ('stock_history_read',r='stock',true,false,array['catalog_read'],true),
 ('sales_read',r='cashier',true,false,array[]::text[],true),
 ('repair_read',r='tech',true,false,array[]::text[],true),
 ('product_edit',r='stock' and b is null,true,true,array[]::text[],true),
 ('repair_task_finish',r='tech',true,true,array['repair_read','repair_transition'],true),
 ('repair_create',false,true,true,array[]::text[],false),
 ('product_price_edit',false,true,true,array[]::text[],false),
 ('customer_create',r='cashier','read'=any(rg) and 'customer_create'=any(rg),true,array['receivable_read','customer_read'],true),
 ('debt_payment',r='cashier','read'=any(rg) and 'debt_payment'=any(rg),true,array['receivable_read','debt_read'],true),
 ('quote_create',r='cashier',true,true,array['catalog_read'],true),
 ('quote_read',r='cashier',true,false,array[]::text[],true),
 ('receipt_read',r in ('cashier','tech'),true,false,case when r='tech' then array['repair_read'] else array['sales_read'] end,true),
 ('warranty_read',r='cashier',true,false,array['sales_read'],true),
 ('receivable_read',r='cashier','read'=any(rg),true,array[]::text[],true),
 ('customer_edit',r='cashier','read'=any(rg) and 'customer_edit'=any(rg),true,array['receivable_read','customer_read'],true),
 ('credit_sale',r='cashier','read'=any(rg) and 'credit_sale'=any(rg),true,array['receivable_read','customer_read','debt_read','sell'],true),
 ('standalone_open',r='cashier','read'=any(rg) and 'standalone_open'=any(rg),true,array['receivable_read','debt_read'],true),
 ('standalone_payment',r='cashier','read'=any(rg) and 'standalone_payment'=any(rg),true,array['receivable_read','debt_read','debt_payment'],true),
 ('payable_manage',r='cashier','read'=any(rg) and 'payable_manage'=any(rg),true,array['receivable_read','debt_read'],true),
 ('procurement_read',r='stock',coalesce(pg.read_allowed,false),false,array[]::text[],true),
 ('supplier_write',r='stock',coalesce(pg.read_allowed and pg.manage_suppliers,false),true,array['procurement_read','supplier_read'],true),
 ('purchase_write',r='stock',coalesce(pg.read_allowed and pg.receive_credit,false),true,array['procurement_read','supplier_read','purchase_read','catalog_read','stock_adjust'],true),
 ('notifications_read',r in ('stock','tech'),true,false,array[]::text[],true),
 ('customer_read',r='cashier','read'=any(rg),true,array['receivable_read'],true),
 ('debt_read',r='cashier','read'=any(rg),true,array['receivable_read'],true),
 ('installment_read',r='cashier','read'=any(rg),true,array['receivable_read','debt_read'],true),
 ('supplier_read',r='stock',coalesce(pg.read_allowed,false),false,array['procurement_read'],true),
 ('purchase_read',r='stock',coalesce(pg.read_allowed,false),false,array['procurement_read'],true),
 ('orders_read',false,true,false,array[]::text[],false),('orders_write',false,true,true,array[]::text[],false),
 ('warranty_write',false,true,true,array[]::text[],false),('returns_read',false,true,false,array[]::text[],false),('returns_write',false,true,true,array[]::text[],false),
 ('used_read',false,true,false,array[]::text[],false),('used_write',false,true,true,array[]::text[],false),
 ('loyalty_read',false,true,false,array[]::text[],false),('invoice_repair',false,true,true,array[]::text[],false),('receipt_write',false,true,true,array[]::text[],false),
 ('finance_read',false,true,false,array[]::text[],false),('finance_write',false,true,true,array[]::text[],false),
 ('staff_admin',false,true,true,array[]::text[],false),('store_admin',false,true,true,array[]::text[],false),('backup_admin',false,true,true,array[]::text[],false)
 )
 select jsonb_agg(jsonb_build_object('action',action,'editable',enabled and r<>'owner' and editable and role_access,'denied',action=any(d),'effective',enabled and ((r='owner' and (not write_action or licensed)) or (role_access and grant_access and (not write_action or licensed) and not (action=any(d)) and not (depends&&d) and not (action=any(central)) and not (depends&&central))),'reason',case when not enabled then 'inactive' when r='owner' then case when write_action and not licensed then 'license' else 'allowed' end when not role_access then 'role' when not grant_access then 'grant' when write_action and not licensed then 'license' when action=any(central) or depends&&central then 'central' when action=any(d) then 'denied' when depends&&d then 'dependency' else 'allowed' end) order by action) into items from matrix;
 return jsonb_build_object('user',u,'role',r,'active',enabled,'branch',b,'denials',to_jsonb(d),'operations',items);
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.staff_action_allowed(p_store uuid, p_action text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(tenant_private.member_role(p_store) is not null and (tenant_private.member_role(p_store)='owner' or not exists(select 1 from tenant_private.staff_all_denials(p_store,auth.uid()) d where d.action=p_action)),false)
$function$
;

CREATE OR REPLACE FUNCTION tenant_private.staff_permissions(p_store uuid, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r text:=tenant_private.member_role(p_store);u uuid:=coalesce(p_user,auth.uid());begin
 if r is null or (r<>'owner' and u<>auth.uid()) then raise exception 'Permission denied' using errcode='42501';end if;
 if u=auth.uid() and r<>'owner' then return coalesce((select jsonb_agg(action order by action) from tenant_private.staff_all_denials(p_store,u)),'[]'::jsonb);end if;
 return coalesce((select jsonb_agg(action order by action) from tenant_private.staff_denials where store_id=p_store and user_id=u),'[]'::jsonb);
end $function$
;

create function tenant_private.guard_record_action() returns trigger language plpgsql security definer set search_path='' as $$
declare s uuid:=case when tg_op='DELETE' then old.store_id else new.store_id end;k text;
begin
 if tg_table_name='mt_products' then
  if new.name is distinct from old.name or new.sku is distinct from old.sku or new.specs is distinct from old.specs or new.catalog is distinct from old.catalog then
   if tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Product profile editing disabled by plan' using errcode='22023';end if;
  end if;
  if new.unit_price_minor is distinct from old.unit_price_minor and tenant_private.central_action_denied(s,'product_price_change') then raise exception 'Product price change disabled by plan' using errcode='22023';end if;
 elsif tg_table_name='mt_product_prices' then k:='product_price_change';
 elsif tg_table_name='mt_customers' then
  if new.name is distinct from old.name or new.phone is distinct from old.phone then k:='customer_profile_edit';end if;
 elsif tg_table_name='mt_suppliers' then
  if new.archived is distinct from old.archived and tenant_private.central_action_denied(s,'supplier_archive') then raise exception 'Supplier archive disabled by plan' using errcode='22023';end if;
  if (new.name,new.contact,new.phone,new.email,new.address) is distinct from (old.name,old.contact,old.phone,old.email,old.address) then k:='supplier_profile_edit';end if;
 elsif tg_table_name='mt_coupons' then
  if new.enabled is distinct from old.enabled and tenant_private.central_action_denied(s,'coupon_disable') then raise exception 'Coupon enable/disable blocked by plan' using errcode='22023';end if;
  if (new.code,new.basis_points,new.min_prior_orders,new.max_uses,new.expires_at) is distinct from (old.code,old.basis_points,old.min_prior_orders,old.max_uses,old.expires_at) then k:='coupon_edit';end if;
 elsif tg_table_name='mt_repairs' and new.state='cancelled' and new.state is distinct from old.state then k:='repair_cancel';
 end if;
 if k is not null and tenant_private.central_action_denied(s,k) then raise exception 'Record action disabled by plan: %',k using errcode='22023';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function tenant_private.guard_record_action() from public,anon,authenticated;
create trigger mt_admin_product_edit before update on public.mt_products for each row execute function tenant_private.guard_record_action();
create trigger mt_admin_product_price before insert or update or delete on public.mt_product_prices for each row execute function tenant_private.guard_record_action();
create trigger mt_admin_customer_edit before update on public.mt_customers for each row execute function tenant_private.guard_record_action();
create trigger mt_admin_supplier_edit before update on public.mt_suppliers for each row execute function tenant_private.guard_record_action();
create trigger mt_admin_coupon_edit before update on public.mt_coupons for each row execute function tenant_private.guard_record_action();
create trigger mt_admin_repair_cancel before update on public.mt_repairs for each row execute function tenant_private.guard_record_action();

create function tenant_private.admin_actions_review() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return jsonb_build_object('plans',coalesce((select jsonb_agg(to_jsonb(x) order by code) from (select p.code,p.name,coalesce(a.revision,1) revision,coalesce(a.denied,'{}'::text[]) denied from public.saas_plans p left join tenant_private.admin_action_policy a on a.plan_code=p.code)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id) from (select request_id,plan_code,actor,reference,before_denied,after_denied,created_at from tenant_private.admin_action_events order by created_at desc,request_id limit 50)x),'[]'::jsonb));
end $$;
create function tenant_private.admin_actions_change(req uuid,plan text,expected bigint,desired text[],proof text) returns uuid language plpgsql security definer set search_path='' as $$
declare previous text[];rev bigint;e tenant_private.admin_action_events%rowtype;normalized text[];
begin
 if not coalesce(saas_private.is_operator(),false) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Operator MFA required' using errcode='42501';end if;
 if req is null or plan is null or expected is null or expected<1 or desired is null or cardinality(desired)>42 or array_position(desired,null) is not null or not desired <@ array['staff_sell','staff_stock_adjust','staff_stock_transfer','staff_product_create','staff_repair_transition','staff_repair_evidence','staff_attendance','staff_catalog_read','staff_stock_history_read','staff_sales_read','staff_repair_read','staff_product_edit','staff_repair_task_finish','staff_customer_create','staff_debt_payment','staff_quote_create','staff_quote_read','staff_receipt_read','staff_warranty_read','staff_receivable_read','staff_customer_edit','staff_credit_sale','staff_standalone_open','staff_standalone_payment','staff_payable_manage','staff_procurement_read','staff_supplier_write','staff_purchase_write','staff_notifications_read','staff_customer_read','staff_debt_read','staff_installment_read','staff_supplier_read','staff_purchase_read','product_profile_edit','product_price_change','customer_profile_edit','supplier_profile_edit','supplier_archive','coupon_edit','coupon_disable','repair_cancel']::text[] or cardinality(desired)<>(select count(distinct k) from unnest(desired) k) or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid action policy';end if;
 select coalesce(array_agg(k order by k),'{}'::text[]) into normalized from unnest(desired) k;
 perform 1 from public.saas_plans where code=plan for update;if not found then raise exception 'Unknown plan';end if;
 select * into e from tenant_private.admin_action_events where request_id=req;
 if found then
  if e.plan_code<>plan or e.actor<>auth.uid() or e.reference<>btrim(proof) or e.previous_revision<>expected or e.after_denied<>normalized then raise exception 'Conflicting policy request';end if;return req;
 end if;
 select revision,denied into rev,previous from tenant_private.admin_action_policy where plan_code=plan;
 rev:=coalesce(rev,1);previous:=coalesce(previous,'{}'::text[]);
 if rev<>expected or previous=normalized then raise exception 'Policy changed or unchanged';end if;
 insert into tenant_private.admin_action_policy(plan_code,revision,denied) values(plan,rev+1,normalized) on conflict(plan_code) do update set revision=excluded.revision,denied=excluded.denied,updated_at=now();
 insert into tenant_private.admin_action_events(request_id,plan_code,actor,reference,previous_revision,before_denied,after_denied) values(req,plan,auth.uid(),btrim(proof),rev,previous,normalized);
 return req;
end $$;
create function public.mt_admin_actions_review() returns jsonb language sql stable set search_path='' as $$select tenant_private.admin_actions_review()$$;
create function public.mt_admin_actions_change(req uuid,plan text,expected bigint,desired text[],proof text) returns uuid language sql set search_path='' as $$select tenant_private.admin_actions_change(req,plan,expected,desired,proof)$$;
revoke all on function tenant_private.admin_actions_review(),public.mt_admin_actions_review(),tenant_private.admin_actions_change(uuid,text,bigint,text[],text),public.mt_admin_actions_change(uuid,text,bigint,text[],text) from public,anon,authenticated;
grant execute on function tenant_private.admin_actions_review(),public.mt_admin_actions_review(),tenant_private.admin_actions_change(uuid,text,bigint,text[],text),public.mt_admin_actions_change(uuid,text,bigint,text[],text) to authenticated;

create function tenant_private.member_central_actions(s uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select to_jsonb(p.denied) from public.saas_subscriptions sub join tenant_private.admin_action_policy p on p.plan_code=sub.plan_code where sub.store_id=s),'[]'::jsonb);
end $$;
create function public.mt_member_central_actions(s uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.member_central_actions(s)$$;
revoke all on function tenant_private.member_central_actions(uuid),public.mt_member_central_actions(uuid) from public,anon,authenticated;
grant execute on function tenant_private.member_central_actions(uuid),public.mt_member_central_actions(uuid) to authenticated;
CREATE OR REPLACE FUNCTION tenant_private.admin_plan_catalog_change(req uuid, action text, code_value text, expected jsonb, params jsonb, proof text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.saas_plans%rowtype;e tenant_private.admin_plan_catalog_events%rowtype;beforev jsonb;afterv jsonb;name_value text;price integer;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if req is null or action is null or action not in ('create','rename','delete') or code_value is null or code_value !~ '^[a-z][a-z0-9-]{2,39}$' or jsonb_typeof(params) is distinct from 'object' or octet_length(params::text)>1000 or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid catalog action' using errcode='22023';end if;
 perform 1 from tenant_private.billing_configuration where singleton for update;
 lock table tenant_private.payment_bindings in share mode;
 select * into e from tenant_private.admin_plan_catalog_events where request_id=req;
 if found then
  if e.plan_code<>code_value or e.actor<>auth.uid() or e.action<>action or e.reference<>btrim(proof) or e.params<>params or e.before_state is distinct from expected then raise exception 'Conflicting catalog request';end if;return req;
 end if;
 if exists(select 1 from tenant_private.billing_configuration where live_enabled) or exists(select 1 from tenant_private.payment_bindings) then raise exception 'Managed provider catalog required';end if;
 select * into p from public.saas_plans where code=code_value for update;
 if found then beforev:=to_jsonb(p);end if;
 if beforev is distinct from expected then raise exception 'Plan changed; reload';end if;
 if action='create' then
  if beforev is not null or (select count(*) from public.saas_plans)>=50 or exists(select 1 from tenant_private.admin_plan_catalog_events where plan_code=code_value) or (select count(*) from jsonb_object_keys(params))<>2 or not (params ?& array['name','price']) or coalesce(params->>'price','') !~ '^[0-9]{1,8}$' then raise exception 'Unavailable plan code or capacity';end if;
  name_value:=btrim(coalesce(params->>'name',''));price:=(params->>'price')::integer;
  if length(name_value) not between 1 and 100 or price not between 100 and 10000000 then raise exception 'Invalid plan name or price';end if;
  insert into public.saas_plans(code,name,monthly_usd_cents) values(code_value,name_value,price);
  insert into tenant_private.admin_plan_policy(plan_code,enrollment) values(code_value,false);
 elsif action='rename' then
  if beforev is null or (select count(*) from jsonb_object_keys(params))<>1 or length(btrim(coalesce(params->>'name',''))) not between 1 and 100 then raise exception 'Invalid plan name';end if;
  name_value:=btrim(params->>'name');if name_value=p.name then raise exception 'Name unchanged';end if;
  update public.saas_plans set name=name_value where code=code_value;
 else
  if beforev is null or params<>'{}'::jsonb or code_value in ('basic','business','pro') then raise exception 'Built-in or missing plan cannot be deleted';end if;
  perform 1 from tenant_private.admin_plan_policy where plan_code=code_value for update;
  if exists(select 1 from public.saas_subscriptions where plan_code=code_value) or exists(select 1 from tenant_private.admin_plan_policy_events where plan_code=code_value) or exists(select 1 from tenant_private.plan_price_history where plan_code=code_value) or exists(select 1 from saas_private.billing_sandbox_invoices where plan_code=code_value) or exists(select 1 from tenant_private.paid_periods where plan_code=code_value) or exists(select 1 from tenant_private.admin_manual_licenses where plan_code=code_value) or exists(select 1 from tenant_private.offline_billing_invoices where plan_code=code_value) or exists(select 1 from tenant_private.admin_action_events where plan_code=code_value) then raise exception 'Referenced plan must be retired by closing enrollment';end if;
  delete from tenant_private.admin_plan_policy where plan_code=code_value;
  delete from public.saas_plans where code=code_value;
 end if;
 select to_jsonb(p0) into afterv from public.saas_plans p0 where code=code_value;
 insert into tenant_private.admin_plan_catalog_events(request_id,plan_code,actor,action,reference,params,before_state,after_state) values(req,code_value,auth.uid(),action,btrim(proof),params,beforev,afterv);
 return req;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.admin_plan_catalog_review()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return jsonb_build_object('editable',not exists(select 1 from tenant_private.billing_configuration where live_enabled) and not exists(select 1 from tenant_private.payment_bindings),
 'plans',coalesce((select jsonb_agg(to_jsonb(x) order by code) from (select p.code,p.name,p.monthly_usd_cents,q.enrollment,q.revision,(select count(*) from public.saas_subscriptions where plan_code=p.code) subscribers,
 (not exists(select 1 from public.saas_subscriptions where plan_code=p.code) and not exists(select 1 from tenant_private.plan_price_history where plan_code=p.code) and not exists(select 1 from tenant_private.admin_plan_policy_events where plan_code=p.code) and not exists(select 1 from saas_private.billing_sandbox_invoices where plan_code=p.code) and not exists(select 1 from tenant_private.paid_periods where plan_code=p.code) and not exists(select 1 from tenant_private.admin_manual_licenses where plan_code=p.code) and not exists(select 1 from tenant_private.offline_billing_invoices where plan_code=p.code) and not exists(select 1 from tenant_private.admin_action_events where plan_code=p.code) and p.code not in ('basic','business','pro')) deletable
 from public.saas_plans p join tenant_private.admin_plan_policy q on q.plan_code=p.code)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id) from (select request_id,plan_code,actor,action,reference,before_state,after_state,created_at from tenant_private.admin_plan_catalog_events order by created_at desc,request_id limit 50)x),'[]'::jsonb));
end $function$
;

commit;
