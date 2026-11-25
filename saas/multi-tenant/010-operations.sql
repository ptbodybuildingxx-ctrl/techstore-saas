-- Operational modules: procurement, staff and repair tickets.
begin;
do $$ begin
 if to_regclass('tenant_private.stock_layers') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
end $$;
create table public.mt_suppliers(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,
 name text not null check(length(btrim(name)) between 1 and 160),contact text not null check(length(contact)<=160),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id)
);
create table public.mt_purchases(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,supplier_id uuid not null,product_id uuid not null,
 currency text not null,units bigint not null check(units between 1 and 1000000),unit_cost_minor bigint not null check(unit_cost_minor between 1 and 100000000),
 total_minor bigint generated always as (units*unit_cost_minor) stored,paid_minor bigint not null check(paid_minor>=0 and paid_minor<=units*unit_cost_minor),
 initial_paid_minor bigint not null check(initial_paid_minor>=0 and initial_paid_minor<=paid_minor),note text not null check(length(btrim(note)) between 1 and 300),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,supplier_id) references public.mt_suppliers(store_id,id),foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
create index mt_purchases_supplier_idx on public.mt_purchases(store_id,supplier_id,id);
create table public.mt_supplier_payments(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,purchase_id uuid not null,
 amount_minor bigint not null check(amount_minor between 1 and 100000000000000),is_initial boolean not null default false,
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,purchase_id) references public.mt_purchases(store_id,id)
);
create unique index mt_supplier_initial_idx on public.mt_supplier_payments(store_id,purchase_id) where is_initial;
create index mt_supplier_payments_purchase_idx on public.mt_supplier_payments(store_id,purchase_id,id);
alter table public.mt_cash_movements drop constraint mt_cash_movements_kind_check;
alter table public.mt_cash_movements add constraint mt_cash_movements_kind_check check(kind in ('sale','funding','expense','exchange','debt_payment','return_refund','supplier_payment'));
alter table public.mt_cash_movements add column supplier_payment_id uuid;
alter table public.mt_cash_movements add foreign key(store_id,supplier_payment_id) references public.mt_supplier_payments(store_id,id);
alter table public.mt_cash_movements add unique(store_id,supplier_payment_id);
alter table public.mt_cash_movements add check((kind='supplier_payment')=(supplier_payment_id is not null));
create table public.mt_repairs(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,
 customer_id uuid not null,device text not null check(length(btrim(device)) between 1 and 160),
 imei text check(imei is null or imei ~ '^[0-9]{15}$'),fault text not null check(length(btrim(fault)) between 1 and 300),
 state text not null default 'received' check(state in ('received','diagnosing','repairing','ready','delivered','cancelled')),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,customer_id) references public.mt_customers(store_id,id)
);
create index mt_repair_state_idx on public.mt_repairs(store_id,state,id);
create table public.mt_repair_events(
 store_id uuid not null,request_id uuid not null,repair_id uuid not null,prior_state text not null,next_state text not null,
 note text not null check(length(btrim(note)) between 1 and 300),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,request_id),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id)
);
create index mt_repair_events_ticket_idx on public.mt_repair_events(store_id,repair_id,created_at);
create table tenant_private.staff_events(
 store_id uuid not null references tenant_private.workspaces(store_id),request_id uuid not null,user_id uuid not null,
 role text not null check(role in ('stock','cashier','tech')),active boolean not null,actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,request_id)
);
alter table tenant_private.staff_events enable row level security;
revoke all on tenant_private.staff_events from public,anon,authenticated,service_role;
do $$ declare t text; begin
 foreach t in array array['mt_suppliers','mt_purchases','mt_supplier_payments','mt_repairs','mt_repair_events'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
  execute format('grant select on public.%I to authenticated',t);
  if t in ('mt_repairs','mt_repair_events') then
   execute format('create policy mt_read on public.%I for select to authenticated using (tenant_private.member_role(store_id) in (''owner'',''tech''))',t);
  else
   execute format('create policy mt_read on public.%I for select to authenticated using (tenant_private.member_role(store_id)=''owner'')',t);
  end if;
 end loop;
end $$;
create function tenant_private.owner_write(p_store uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
end $$;
create function tenant_private.add_supplier(p_store uuid,p_request uuid,p_name text,p_contact text) returns uuid language plpgsql security definer set search_path='' as $$
declare s public.mt_suppliers%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_contact is null or length(btrim(p_contact))>160 then raise exception 'Invalid supplier' using errcode='22023';end if;
 select * into s from public.mt_suppliers where store_id=p_store and request_id=p_request;
 if found then
  if s.actor<>auth.uid() or s.name<>btrim(p_name) or s.contact<>btrim(p_contact) then raise exception 'Conflicting supplier request' using errcode='22023';end if;
  return s.id;
 end if;
 insert into public.mt_suppliers(store_id,request_id,name,contact,actor) values(p_store,p_request,btrim(p_name),btrim(p_contact),auth.uid()) returning * into s;
 return s.id;
end $$;
create function tenant_private.purchase(p_store uuid,p_request uuid,p_supplier uuid,p_product uuid,p_currency text,p_units bigint,p_cost bigint,p_paid bigint,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.mt_purchases%rowtype; v_payment uuid;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_supplier is null or p_product is null or p_currency is null or p_units is null or p_units not between 1 and 1000000 or p_cost is null or p_cost not between 1 and 100000000 or p_paid is null or p_paid<0 or p_paid>p_units*p_cost or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid purchase' using errcode='22023';end if;
 select * into r from public.mt_purchases where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.supplier_id<>p_supplier or r.product_id<>p_product or r.currency<>p_currency or r.units<>p_units or r.unit_cost_minor<>p_cost or r.initial_paid_minor<>p_paid or r.note<>btrim(p_note) then raise exception 'Conflicting purchase request' using errcode='22023';end if;
  return r.id;
 end if;
 if not exists(select 1 from public.mt_suppliers where store_id=p_store and id=p_supplier) or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Invalid purchase references' using errcode='22023';end if;
 -- A dedicated internal stock event ID cannot alias a prior standalone intake.
 perform tenant_private.receive_costed_stock(p_store,p_product,gen_random_uuid(),p_units,p_currency,p_cost,btrim(p_note));
 insert into public.mt_purchases(store_id,request_id,supplier_id,product_id,currency,units,unit_cost_minor,paid_minor,initial_paid_minor,note,actor) values(p_store,p_request,p_supplier,p_product,p_currency,p_units,p_cost,p_paid,p_paid,btrim(p_note),auth.uid()) returning * into r;
 if p_paid>0 then
  insert into public.mt_supplier_payments(store_id,request_id,purchase_id,amount_minor,is_initial,actor) values(p_store,gen_random_uuid(),r.id,p_paid,true,auth.uid()) returning id into v_payment;
  insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,supplier_payment_id) values(p_store,gen_random_uuid(),'supplier_payment',p_currency,p_paid,'Purchase initial payment',auth.uid(),v_payment);
 end if;
 return r.id;
end $$;
create function tenant_private.pay_supplier(p_store uuid,p_request uuid,p_purchase uuid,p_currency text,p_amount bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.mt_purchases%rowtype; v public.mt_supplier_payments%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_purchase is null or p_currency is null or p_amount is null or p_amount not between 1 and 100000000000000 then raise exception 'Invalid payment' using errcode='22023';end if;
 select * into r from public.mt_purchases where store_id=p_store and id=p_purchase for update;
 if not found or r.currency<>p_currency then raise exception 'Purchase or currency mismatch' using errcode='22023';end if;
 select * into v from public.mt_supplier_payments where store_id=p_store and request_id=p_request;
 if found then
  if v.is_initial or v.actor<>auth.uid() or v.purchase_id<>p_purchase or v.amount_minor<>p_amount then raise exception 'Conflicting payment' using errcode='22023';end if;
  return v.id;
 end if;
 if p_amount>r.total_minor-r.paid_minor then raise exception 'Payment exceeds payable' using errcode='22023';end if;
 insert into public.mt_supplier_payments(store_id,request_id,purchase_id,amount_minor,actor) values(p_store,p_request,p_purchase,p_amount,auth.uid()) returning * into v;
 update public.mt_purchases set paid_minor=paid_minor+p_amount where store_id=p_store and id=p_purchase;
 insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,supplier_payment_id) values(p_store,gen_random_uuid(),'supplier_payment',r.currency,p_amount,'Supplier settlement',auth.uid(),v.id);
 return v.id;
end $$;
create function tenant_private.add_repair(p_store uuid,p_request uuid,p_customer uuid,p_device text,p_imei text,p_fault text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.mt_repairs%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_customer is null or p_device is null or length(btrim(p_device)) not between 1 and 160 or p_fault is null or length(btrim(p_fault)) not between 1 and 300 or (p_imei is not null and p_imei !~ '^[0-9]{15}$') or not exists(select 1 from public.mt_customers where store_id=p_store and id=p_customer) then raise exception 'Invalid repair' using errcode='22023';end if;
 select * into r from public.mt_repairs where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.customer_id<>p_customer or r.device<>btrim(p_device) or r.imei is distinct from p_imei or r.fault<>btrim(p_fault) then raise exception 'Conflicting repair request' using errcode='22023';end if;
  return r.id;
 end if;
 insert into public.mt_repairs(store_id,request_id,customer_id,device,imei,fault,actor) values(p_store,p_request,p_customer,btrim(p_device),p_imei,btrim(p_fault),auth.uid()) returning * into r;
 return r.id;
end $$;
create function tenant_private.repair_transition(p_store uuid,p_request uuid,p_repair uuid,p_next text,p_note text) returns text language plpgsql security definer set search_path='' as $$
declare r public.mt_repairs%rowtype; e public.mt_repair_events%rowtype; role_now text;
begin
 role_now:=tenant_private.member_role(p_store);
 if coalesce(role_now,'') not in ('owner','tech') then raise exception 'Repair role required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 role_now:=tenant_private.member_role(p_store);
 if coalesce(role_now,'') not in ('owner','tech') or not exists(select 1 from public.saas_stores s join public.saas_subscriptions sub on sub.store_id=s.id where s.id=p_store and s.state='provisioning' and s.project_ref is null and s.origin is null and sub.state='trial' and sub.valid_until>now()) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_repair is null or p_next is null or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid transition' using errcode='22023';end if;
 if p_next in ('delivered','cancelled') and role_now<>'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into e from public.mt_repair_events where store_id=p_store and request_id=p_request;
 if found then
  if e.actor<>auth.uid() or e.repair_id<>p_repair or e.next_state<>p_next or e.note<>btrim(p_note) then raise exception 'Conflicting repair transition' using errcode='22023';end if;
  return e.next_state;
 end if;
 select * into r from public.mt_repairs where store_id=p_store and id=p_repair for update;
 if not found or not ((r.state='received' and p_next in ('diagnosing','cancelled')) or (r.state='diagnosing' and p_next in ('repairing','cancelled')) or (r.state='repairing' and p_next in ('ready','cancelled')) or (r.state='ready' and p_next in ('delivered','repairing','cancelled'))) then raise exception 'Invalid repair transition' using errcode='22023';end if;
 update public.mt_repairs set state=p_next where store_id=p_store and id=p_repair;
 insert into public.mt_repair_events(store_id,request_id,repair_id,prior_state,next_state,note,actor) values(p_store,p_request,p_repair,r.state,p_next,btrim(p_note),auth.uid());
 return p_next;
end $$;
create function tenant_private.staff_set(p_store uuid,p_request uuid,p_user uuid,p_role text,p_active boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare e tenant_private.staff_events%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_user is null or p_role is null or p_role not in ('stock','cashier','tech') or p_active is null or exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and role='owner') or exists(select 1 from saas_private.operators where user_id=p_user) then raise exception 'Invalid employee or role' using errcode='22023';end if;
 if p_active and not exists(select 1 from auth.users where id=p_user and email_confirmed_at is not null and not is_anonymous and (banned_until is null or banned_until<=now())) then raise exception 'Confirmed account required' using errcode='22023';end if;
 select * into e from tenant_private.staff_events where store_id=p_store and request_id=p_request;
 if found then
  if e.actor<>auth.uid() or e.user_id<>p_user or e.role<>p_role or e.active<>p_active then raise exception 'Conflicting staff request' using errcode='22023';end if;
  return p_user;
 end if;
 if not p_active and not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user) then raise exception 'Unknown employee' using errcode='22023';end if;
 insert into tenant_private.members(store_id,user_id,role,active) values(p_store,p_user,p_role,p_active) on conflict(store_id,user_id) do update set role=excluded.role,active=excluded.active;
 insert into tenant_private.staff_events(store_id,request_id,user_id,role,active,actor) values(p_store,p_request,p_user,p_role,p_active,auth.uid());
 return p_user;
end $$;
create function tenant_private.staff_list(p_store uuid,p_after uuid,p_limit integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by user_id),'[]'::jsonb) into r from (select user_id,role,active from tenant_private.members where store_id=p_store and (p_after is null or user_id>p_after) order by user_id limit p_limit) x;
 return r;
end $$;
create function public.mt_add_supplier(p_store uuid,p_request uuid,p_name text,p_contact text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.add_supplier(p_store,p_request,p_name,p_contact)$$;
create function public.mt_purchase(p_store uuid,p_request uuid,p_supplier uuid,p_product uuid,p_currency text,p_units bigint,p_cost bigint,p_paid bigint,p_note text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.purchase(p_store,p_request,p_supplier,p_product,p_currency,p_units,p_cost,p_paid,p_note)$$;
create function public.mt_pay_supplier(p_store uuid,p_request uuid,p_purchase uuid,p_currency text,p_amount bigint) returns uuid language sql security invoker set search_path='' as $$select tenant_private.pay_supplier(p_store,p_request,p_purchase,p_currency,p_amount)$$;
create function public.mt_add_repair(p_store uuid,p_request uuid,p_customer uuid,p_device text,p_imei text,p_fault text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.add_repair(p_store,p_request,p_customer,p_device,p_imei,p_fault)$$;
create function public.mt_repair_transition(p_store uuid,p_request uuid,p_repair uuid,p_next text,p_note text) returns text language sql security invoker set search_path='' as $$select tenant_private.repair_transition(p_store,p_request,p_repair,p_next,p_note)$$;
create function public.mt_staff_set(p_store uuid,p_request uuid,p_user uuid,p_role text,p_active boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.staff_set(p_store,p_request,p_user,p_role,p_active)$$;
create function public.mt_staff_list(p_store uuid,p_after uuid default null,p_limit integer default 50) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.staff_list(p_store,p_after,p_limit)$$;
-- Bounded keyset lists, RLS enforced by security invoker.
do $$ declare t text; f text; begin
 foreach t in array array['suppliers','purchases','repairs'] loop
  f:='mt_list_'||t;
  execute format('create function public.%I(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.%I language plpgsql stable security invoker set search_path='''' as $body$ begin if p_limit is null or p_limit not between 1 and 100 then raise exception ''Invalid page'' using errcode=''22023'';end if;return query select * from public.%I where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $body$',f,'mt_'||t,'mt_'||t);
 end loop;
end $$;
do $$ declare f record; begin
 for f in select p.oid::regprocedure as sig,n.nspname,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where (n.nspname='tenant_private' and p.proname in ('owner_write','add_supplier','purchase','pay_supplier','add_repair','repair_transition','staff_set','staff_list')) or (n.nspname='public' and p.proname in ('mt_add_supplier','mt_purchase','mt_pay_supplier','mt_add_repair','mt_repair_transition','mt_staff_set','mt_staff_list','mt_list_suppliers','mt_list_purchases','mt_list_repairs')) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);
  if f.proname<>'owner_write' then execute format('grant execute on function %s to authenticated',f.sig);end if;
 end loop;
end $$;
commit;