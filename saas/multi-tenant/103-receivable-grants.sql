-- Explicit positive receivable grants. Financial records are scoped to one current cashier branch.
-- Customer names/phones are a shared store directory; granting read explicitly shares that directory.
create table tenant_private.receivable_grants(
 store_id uuid not null,user_id uuid not null,branch_id uuid,
 actions text[] not null check(actions <@ array['read','customer_create','customer_edit','credit_sale','debt_payment','standalone_open','standalone_payment','payable_manage']::text[] and array_position(actions,null) is null and (cardinality(actions)=0 or 'read'=any(actions))),
 actor uuid not null,updated_at timestamptz not null default now(),primary key(store_id,user_id),
 foreign key(store_id,user_id) references tenant_private.members(store_id,user_id),
 foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
alter table tenant_private.receivable_grants enable row level security;
revoke all on tenant_private.receivable_grants from public,anon,authenticated,service_role;

create function tenant_private.receivable_allowed(p_store uuid,p_action text)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store)='owner' or (
 tenant_private.member_role(p_store)='cashier' and tenant_private.shared_licensed(p_store) and
 exists(select 1 from tenant_private.receivable_grants g where g.store_id=p_store and g.user_id=auth.uid()
 and g.branch_id is not distinct from tenant_private.current_branch_scope(p_store)
 and 'read'=any(g.actions) and p_action=any(g.actions)) and
 case p_action when 'customer_create' then tenant_private.staff_action_allowed(p_store,'customer_create')
 when 'debt_payment' then tenant_private.staff_action_allowed(p_store,'debt_payment')
 when 'standalone_payment' then tenant_private.staff_action_allowed(p_store,'debt_payment')
 when 'credit_sale' then tenant_private.staff_action_allowed(p_store,'sell')
 else true end),false)
$$;
create function tenant_private.receivable_branch_allowed(p_store uuid,p_branch uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store)='owner' or (tenant_private.receivable_allowed(p_store,'read')
 and tenant_private.current_branch_scope(p_store) is not distinct from p_branch),false)
$$;
create function tenant_private.receivable_write(p_store uuid,p_action text)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.saas_stores where id=p_store for update;
 if not tenant_private.receivable_allowed(p_store,p_action) or not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Receivable write denied' using errcode='42501';end if;
end $$;
create function tenant_private.receivable_require_sale_scope(p_store uuid,p_sale uuid,p_cash boolean)
returns void language plpgsql security definer set search_path='' as $$
declare b uuid;
begin
 if tenant_private.member_role(p_store)='owner' then return;end if;
 select branch_id into b from tenant_private.branch_sales where store_id=p_store and sale_id=p_sale;
 if not tenant_private.receivable_branch_allowed(p_store,b) then raise exception 'Debt branch denied' using errcode='42501';end if;
 if p_cash and b is not null and not exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then raise exception 'Enable branch treasury first' using errcode='22023';end if;
end $$;
create function tenant_private.receivable_require_credit_scope(p_store uuid,p_request uuid,p_deposit bigint)
returns void language plpgsql security definer set search_path='' as $$
declare b uuid;sid uuid;
begin
 if tenant_private.member_role(p_store)='owner' then return;end if;
 select id into sid from public.mt_sales where store_id=p_store and request_id=p_request;
 if sid is not null then perform tenant_private.receivable_require_sale_scope(p_store,sid,false);return;end if;
 select branch_id into b from tenant_private.branch_sale_context where store_id=p_store and request_id=p_request and actor=auth.uid();
 if not tenant_private.receivable_branch_allowed(p_store,b) then raise exception 'Credit branch denied' using errcode='42501';end if;
 if p_deposit>0 and b is not null and not exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then raise exception 'Enable branch treasury first' using errcode='22023';end if;
end $$;

create function tenant_private.receivable_grant_read(p_store uuid,p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=coalesce(p_user,auth.uid());b uuid;granted text[]:='{}';effective text[]:='{}';role_now text:=tenant_private.member_role(p_store);
begin
 if role_now is null or (u is distinct from auth.uid() and role_now<>'owner') then raise exception 'Access denied' using errcode='42501';end if;
 if u=auth.uid() and role_now='owner' then
 granted:=array['read','customer_create','customer_edit','credit_sale','debt_payment','standalone_open','standalone_payment','payable_manage'];effective:=granted;
 elsif exists(select 1 from tenant_private.members where store_id=p_store and user_id=u and active and role='cashier') then
 select branch_id into b from tenant_private.cashier_branch_scope where store_id=p_store and user_id=u;
 select coalesce((select actions from tenant_private.receivable_grants where store_id=p_store and user_id=u and branch_id is not distinct from b),'{}'::text[]) into granted;
 select coalesce(array_agg(a order by a),'{}'::text[]) into effective from unnest(granted) a where u<>auth.uid() or tenant_private.receivable_allowed(p_store,a);
 elsif p_user is not null then raise exception 'Unknown active cashier' using errcode='22023';
 end if;
 return jsonb_build_object('user',u,'branch',b,'granted',to_jsonb(granted),'effective',to_jsonb(effective));
end $$;
create function tenant_private.receivable_grant_set(p_store uuid,p_user uuid,p_actions text[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid;clean text[];
begin
 perform tenant_private.owner_write(p_store);
 if p_user is null or p_actions is null or cardinality(p_actions)>8 or array_position(p_actions,null) is not null or not p_actions <@ array['read','customer_create','customer_edit','credit_sale','debt_payment','standalone_open','standalone_payment','payable_manage']::text[] or (cardinality(p_actions)>0 and not 'read'=any(p_actions)) or not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role='cashier') then raise exception 'Invalid grant' using errcode='22023';end if;
 select coalesce(array_agg(distinct a order by a),'{}'::text[]) into clean from unnest(p_actions) a;
 select branch_id into b from tenant_private.cashier_branch_scope where store_id=p_store and user_id=p_user;
 insert into tenant_private.receivable_grants(store_id,user_id,branch_id,actions,actor) values(p_store,p_user,b,clean,auth.uid()) on conflict(store_id,user_id) do update set branch_id=excluded.branch_id,actions=excluded.actions,actor=excluded.actor,updated_at=now();
 return tenant_private.receivable_grant_read(p_store,p_user);
end $$;
create function public.mt_receivable_grants(p_store uuid,p_user uuid default null) returns jsonb language sql stable set search_path='' as $$select tenant_private.receivable_grant_read(p_store,p_user)$$;
create function public.mt_receivable_grant_set(p_store uuid,p_user uuid,p_actions text[]) returns jsonb language sql set search_path='' as $$select tenant_private.receivable_grant_set(p_store,p_user,p_actions)$$;
revoke all on function tenant_private.receivable_allowed(uuid,text),tenant_private.receivable_branch_allowed(uuid,uuid),tenant_private.receivable_write(uuid,text),tenant_private.receivable_require_sale_scope(uuid,uuid,boolean),tenant_private.receivable_require_credit_scope(uuid,uuid,bigint),tenant_private.receivable_grant_read(uuid,uuid),tenant_private.receivable_grant_set(uuid,uuid,text[]),public.mt_receivable_grants(uuid,uuid),public.mt_receivable_grant_set(uuid,uuid,text[]) from public,anon,authenticated,service_role;
grant execute on function tenant_private.receivable_grant_read(uuid,uuid),tenant_private.receivable_grant_set(uuid,uuid,text[]),public.mt_receivable_grants(uuid,uuid),public.mt_receivable_grant_set(uuid,uuid,text[]) to authenticated;

-- Private security-definer reads retain owner semantics and apply branch filtering before pagination.
create function tenant_private.receivable_customers(p_store uuid,p_query text,p_after uuid,p_limit integer) returns setof public.mt_customers language plpgsql stable security definer set search_path='' as $$
begin
 if not tenant_private.receivable_allowed(p_store,'read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_query is null or length(p_query)>160 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid filters' using errcode='22023';end if;
 return query select c.* from public.mt_customers c where c.store_id=p_store and (p_after is null or c.id>p_after) and (p_query='' or strpos(lower(c.name),lower(p_query))>0 or strpos(c.phone,p_query)>0) order by c.id limit p_limit;
end $$;
create function tenant_private.receivable_debts(p_store uuid,p_after uuid,p_limit integer) returns setof public.mt_debts language plpgsql stable security definer set search_path='' as $$
begin
 if not tenant_private.receivable_allowed(p_store,'read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select d.* from public.mt_debts d left join tenant_private.branch_sales b on b.store_id=d.store_id and b.sale_id=d.sale_id where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,b.branch_id) and (p_after is null or d.id>p_after) order by d.id limit p_limit;
end $$;
create function tenant_private.receivable_schedule(p_store uuid,p_debt uuid) returns setof public.mt_installments language plpgsql stable security definer set search_path='' as $$
begin
 if not tenant_private.receivable_allowed(p_store,'read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if not exists(select 1 from public.mt_debts d left join tenant_private.branch_sales b on b.store_id=d.store_id and b.sale_id=d.sale_id where d.store_id=p_store and d.id=p_debt and tenant_private.receivable_branch_allowed(p_store,b.branch_id)) then raise exception 'Unknown debt or scope denied' using errcode='42501';end if;
 return query select i.* from public.mt_installments i where i.store_id=p_store and i.debt_id=p_debt order by i.number;
end $$;

CREATE FUNCTION tenant_private.receivable_register(p_store uuid, p_mode text, p_query text, p_customer uuid, p_currency text, p_status text, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb; totals jsonb; today date:=(now() at time zone 'Asia/Damascus')::date;
begin
 if not tenant_private.receivable_allowed(p_store,'read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_mode is null or p_mode not in ('debts','schedule','payments') or p_query is null or length(p_query)>160 or p_status is null or p_status not in ('all','open','overdue','settled') or p_offset is null or p_offset not between 0 and 100000 or (p_currency is not null and p_currency not in ('SYP','USD','EUR')) then raise exception 'Invalid filters' using errcode='22023';end if;
 with base as (
 select d.*,c.name,c.phone,s.number invoice_number from public.mt_debts d join public.mt_customers c on (c.store_id,c.id)=(d.store_id,d.customer_id) join public.mt_sales s on (s.store_id,s.id)=(d.store_id,d.sale_id)
 left join tenant_private.branch_sales bs on bs.store_id=d.store_id and bs.sale_id=d.sale_id
 where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,bs.branch_id) and (p_customer is null or c.id=p_customer) and (p_currency is null or d.currency=p_currency)
 and (p_query='' or strpos(lower(c.name),lower(p_query))>0 or strpos(c.phone,p_query)>0 or strpos(s.number::text,p_query)>0)
 ), balances as (
 select currency,sum(principal_minor)::text principal,sum(deposit_minor)::text deposit,sum(remaining_minor)::text remaining from base group by currency
 ), items as (
 select b.id debt_id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,b.id item_id,0 installment_number,b.created_at::text recorded_at,b.first_due due_date,b.principal_minor amount_minor,b.deposit_minor paid_minor,0::bigint waived_minor,b.remaining_minor,
 case when b.remaining_minor=0 then 'settled' when exists(select 1 from public.mt_installments i where i.store_id=p_store and i.debt_id=b.id and i.due_date<today and i.paid_minor+i.waived_minor<i.amount_minor) then 'overdue' else 'open' end status,null::text method,false is_deposit from base b where p_mode='debts'
 union all
 select b.id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,b.id,i.number,null,i.due_date,i.amount_minor,i.paid_minor,i.waived_minor,i.amount_minor-i.paid_minor-i.waived_minor,case when i.paid_minor+i.waived_minor=i.amount_minor then 'settled' when i.due_date<today then 'overdue' else 'open' end,null,false from base b join public.mt_installments i on (i.store_id,i.debt_id)=(b.store_id,b.id) where p_mode='schedule'
 union all
 select b.id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,p.id,0,p.created_at::text,null,p.amount_minor,0::bigint,0::bigint,0::bigint,'recorded',p.settlement_method,p.is_deposit from base b join public.mt_debt_payments p on (p.store_id,p.debt_id)=(b.store_id,b.id) where p_mode='payments'
 ), page as (
 select * from items where p_mode='payments' or p_status='all' or status=p_status or (p_status='open' and status='overdue')
 order by due_date asc nulls last,recorded_at desc nulls last,debt_id,installment_number,item_id offset p_offset limit 51
 )
 select (select coalesce(jsonb_agg(to_jsonb(b) order by b.currency),'[]'::jsonb) from balances b),
 (select coalesce(jsonb_agg(to_jsonb(x) order by x.due_date asc nulls last,x.recorded_at desc nulls last,x.debt_id,x.installment_number,x.item_id),'[]'::jsonb) from page x) into totals,rows;
 return jsonb_build_object('store_id',p_store,'mode',p_mode,'today',today,'totals',totals,'rows',rows);
end $function$;

create or replace function public.mt_list_customers(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_customers language sql stable set search_path='' as $$select * from tenant_private.receivable_customers(p_store,'',p_after,p_limit)$$;
create or replace function public.mt_search_customers(p_store uuid,p_query text,p_after uuid,p_limit integer) returns setof public.mt_customers language sql stable set search_path='' as $$select * from tenant_private.receivable_customers(p_store,p_query,p_after,p_limit)$$;
create or replace function public.mt_list_debts(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_debts language sql stable set search_path='' as $$select * from tenant_private.receivable_debts(p_store,p_after,p_limit)$$;
create or replace function public.mt_debt_schedule(p_store uuid,p_debt uuid) returns setof public.mt_installments language sql stable set search_path='' as $$select * from tenant_private.receivable_schedule(p_store,p_debt)$$;
create or replace function public.mt_receivable_register(p_store uuid,p_mode text,p_query text,p_customer uuid,p_currency text,p_status text,p_offset integer) returns jsonb language sql stable set search_path='' as $$select tenant_private.receivable_register(p_store,p_mode,p_query,p_customer,p_currency,p_status,p_offset)$$;
revoke all on function tenant_private.receivable_customers(uuid,text,uuid,integer),tenant_private.receivable_debts(uuid,uuid,integer),tenant_private.receivable_schedule(uuid,uuid),tenant_private.receivable_register(uuid,text,text,uuid,text,text,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.receivable_customers(uuid,text,uuid,integer),tenant_private.receivable_debts(uuid,uuid,integer),tenant_private.receivable_schedule(uuid,uuid),tenant_private.receivable_register(uuid,text,text,uuid,text,text,integer) to authenticated;

CREATE OR REPLACE FUNCTION tenant_private.add_customer(p_store uuid, p_request uuid, p_name text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.mt_customers%rowtype;original_name text;original_phone text;
begin
 if not tenant_private.receivable_allowed(p_store,'customer_create') then raise exception 'Customer creation denied' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_phone is null or length(btrim(p_phone))>60 then raise exception 'Invalid customer' using errcode='22023';end if;
 select * into c from public.mt_customers where store_id=p_store and request_id=p_request;
 if found then
  select old_name,old_phone into original_name,original_phone from tenant_private.customer_profile_edits where store_id=p_store and customer_id=c.id order by revision limit 1;
  if c.actor<>auth.uid() or coalesce(original_name,c.name)<>btrim(p_name) or coalesce(original_phone,c.phone)<>btrim(p_phone) then raise exception 'Conflicting customer request' using errcode='22023';end if;
  return c.id;
 end if;
 insert into public.mt_customers(store_id,request_id,name,phone,actor) values(p_store,p_request,btrim(p_name),btrim(p_phone),auth.uid()) returning * into c;
 return c.id;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.edit_customer(p_store uuid, p_request uuid, p_customer uuid, p_old_name text, p_old_phone text, p_name text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.mt_customers%rowtype;e tenant_private.customer_profile_edits%rowtype;v_revision bigint;
begin
 perform tenant_private.receivable_write(p_store,'customer_edit');
 if p_request is null or p_customer is null or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_phone is null or length(btrim(p_phone))>60 or p_old_name is null or p_old_phone is null then raise exception 'Invalid customer profile' using errcode='22023';end if;
 select * into e from tenant_private.customer_profile_edits where store_id=p_store and id=p_request;
 if found then
  if e.actor<>auth.uid() or e.customer_id<>p_customer or e.old_name<>p_old_name or e.old_phone<>p_old_phone or e.new_name<>btrim(p_name) or e.new_phone<>btrim(p_phone) then raise exception 'Conflicting request' using errcode='22023';end if;
  return e.customer_id;
 end if;
 select * into strict c from public.mt_customers where store_id=p_store and id=p_customer for update;
 if c.name<>p_old_name or c.phone<>p_old_phone then raise exception 'Customer profile has changed; reload first' using errcode='22023';end if;
 select coalesce(max(revision),0)+1 into v_revision from tenant_private.customer_profile_edits where store_id=p_store and customer_id=p_customer;
 insert into tenant_private.customer_profile_edits(store_id,id,customer_id,revision,old_name,old_phone,new_name,new_phone,actor) values(p_store,p_request,p_customer,v_revision,c.name,c.phone,btrim(p_name),btrim(p_phone),auth.uid());
 update public.mt_customers set name=btrim(p_name),phone=btrim(p_phone) where store_id=p_store and id=p_customer;
 return p_customer;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.pay_debt(p_store uuid, p_debt uuid, p_request uuid, p_currency text, p_amount bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d public.mt_debts%rowtype; p public.mt_debt_payments%rowtype; i public.mt_installments%rowtype; left_amount bigint; applied bigint;
begin
 if not tenant_private.receivable_allowed(p_store,'debt_payment') then raise exception 'Debt collection denied' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_debt is null or p_currency is null or p_amount is null or p_amount not between 1 and 100000000000000 then raise exception 'Invalid payment' using errcode='22023';end if;
 select * into d from public.mt_debts where store_id=p_store and id=p_debt for update;
 if not found or d.currency<>p_currency then raise exception 'Debt or currency mismatch' using errcode='22023';end if;
 perform tenant_private.receivable_require_sale_scope(p_store,d.sale_id,true);
 select * into p from public.mt_debt_payments where store_id=p_store and request_id=p_request;
 if found then
  if p.is_deposit or p.actor<>auth.uid() or p.debt_id<>p_debt or p.amount_minor<>p_amount then raise exception 'Conflicting payment request' using errcode='22023';end if;
  return p.id;
 end if;
 if p_amount>d.remaining_minor then raise exception 'Payment exceeds debt' using errcode='22023';end if;
 insert into public.mt_debt_payments(store_id,debt_id,request_id,amount_minor,actor) values(p_store,p_debt,p_request,p_amount,auth.uid()) returning * into p;
 left_amount:=p_amount;
 for i in select * from public.mt_installments where store_id=p_store and debt_id=p_debt and paid_minor+waived_minor<amount_minor order by number for update loop
  exit when left_amount=0;
  applied:=least(left_amount,i.amount_minor-i.paid_minor-i.waived_minor);
  update public.mt_installments set paid_minor=paid_minor+applied where store_id=p_store and debt_id=p_debt and number=i.number;
  insert into public.mt_payment_allocations(store_id,payment_id,debt_id,installment_number,amount_minor) values(p_store,p.id,p_debt,i.number,applied);
  left_amount:=left_amount-applied;
 end loop;
 if left_amount<>0 then raise exception 'Installment allocation mismatch';end if;
 update public.mt_debts set remaining_minor=remaining_minor-p_amount where store_id=p_store and id=p_debt;
 insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,debt_payment_id) values(p_store,gen_random_uuid(),'debt_payment',d.currency,p_amount,'Debt collection',auth.uid(),p.id);
 return p.id;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.standalone_open(p_store uuid, p_request uuid, p_customer uuid, p_branch uuid, p_direction text, p_party text, p_phone text, p_currency text, p_amount bigint, p_count integer, p_due date, p_notes text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d tenant_private.standalone_debts%rowtype;
begin
 perform tenant_private.receivable_write(p_store,'standalone_open');
 if not tenant_private.receivable_branch_allowed(p_store,p_branch) or (p_direction='payable' and not tenant_private.receivable_allowed(p_store,'payable_manage')) then raise exception 'Standalone debt scope denied' using errcode='42501';end if;
 if p_request is null or p_direction is null or p_direction not in ('receivable','payable') or p_party is null or length(btrim(p_party)) not between 1 and 160 or p_phone is null or length(p_phone)>60 or p_amount is null or p_amount not between 1 and 100000000000000 or p_count is null or p_count not between 1 and 120 or p_count>p_amount or (p_direction='payable' and p_count<>1) or p_due is null or p_due not between date '1900-01-01' and date '2200-01-01' or p_notes is null or length(p_notes)>300 then raise exception 'Invalid standalone debt' using errcode='22023';end if;
 select * into d from tenant_private.standalone_debts where store_id=p_store and id=p_request;
 if found then
  if d.actor<>auth.uid() or d.customer_id is distinct from p_customer or d.branch_id is distinct from p_branch or d.direction<>p_direction or d.party<>btrim(p_party) or d.phone<>btrim(p_phone) or d.currency is distinct from p_currency or d.principal_minor<>p_amount or d.installment_count<>p_count or d.first_due<>p_due or d.notes<>btrim(p_notes) then raise exception 'Conflicting request' using errcode='22023';end if;
  return d.id;
 end if;
 if exists(select 1 from tenant_private.standalone_debt_payments where store_id=p_store and id=p_request) then raise exception 'Conflicting request';end if;
 if p_customer is not null and not exists(select 1 from public.mt_customers where store_id=p_store and id=p_customer and name=btrim(p_party) and phone=btrim(p_phone)) then raise exception 'Customer profile has changed; reload first' using errcode='22023';end if;
 insert into tenant_private.standalone_debts(store_id,id,customer_id,branch_id,direction,party,phone,currency,principal_minor,remaining_minor,installment_count,first_due,notes,actor)
 values(p_store,p_request,p_customer,p_branch,p_direction,btrim(p_party),btrim(p_phone),p_currency,p_amount,p_amount,p_count,p_due,btrim(p_notes),auth.uid());
 insert into tenant_private.standalone_installments(store_id,debt_id,number,due_date,amount_minor)
 select p_store,p_request,i,(p_due+make_interval(months=>i-1))::date,p_amount/p_count+case when i<=p_amount%p_count then 1 else 0 end from generate_series(1,p_count) i;
 return p_request;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.standalone_pay(p_store uuid, p_request uuid, p_debt uuid, p_amount bigint, p_memo text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d tenant_private.standalone_debts%rowtype;p tenant_private.standalone_debt_payments%rowtype;i tenant_private.standalone_installments%rowtype;cash uuid;left_amount bigint;allocated bigint;
begin
 perform tenant_private.receivable_write(p_store,'standalone_payment');
 if p_request is null or p_debt is null or p_amount is null or p_amount not between 1 and 100000000000000 or p_memo is null or length(p_memo)>300 then raise exception 'Invalid payment' using errcode='22023';end if;
 select * into strict d from tenant_private.standalone_debts where store_id=p_store and id=p_debt for update;
 if not tenant_private.receivable_branch_allowed(p_store,d.branch_id) or (d.direction='payable' and not tenant_private.receivable_allowed(p_store,'payable_manage')) then raise exception 'Standalone debt scope denied' using errcode='42501';end if;
 select * into p from tenant_private.standalone_debt_payments where store_id=p_store and id=p_request;
 if found then
  if p.actor<>auth.uid() or p.debt_id<>p_debt or p.amount_minor<>p_amount or p.memo<>btrim(p_memo) then raise exception 'Conflicting request' using errcode='22023';end if;
  return p.id;
 end if;
 if exists(select 1 from tenant_private.standalone_debts where store_id=p_store and id=p_request) then raise exception 'Conflicting request';end if;
 if p_amount>d.remaining_minor then raise exception 'Payment exceeds remaining debt' using errcode='22023';end if;
 if d.branch_id is not null and not exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then raise exception 'Branch treasury must be enabled' using errcode='22023';end if;
 insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor)
 values(p_store,p_request,case when d.direction='receivable' then 'funding' else 'expense' end,d.currency,p_amount,left(case when d.direction='receivable' then 'Standalone debt receipt / قبض دين مستقل: ' else 'Standalone debt payment / سداد دين مستقل: ' end||d.id::text||' '||btrim(p_memo),300),auth.uid()) returning id into cash;
 insert into tenant_private.standalone_debt_payments(store_id,id,debt_id,cash_id,amount_minor,memo,actor) values(p_store,p_request,p_debt,cash,p_amount,btrim(p_memo),auth.uid());
 left_amount:=p_amount;
 for i in select * from tenant_private.standalone_installments where store_id=p_store and debt_id=p_debt and paid_minor<amount_minor order by number for update loop
  exit when left_amount=0;
  allocated:=least(left_amount,i.amount_minor-i.paid_minor);
  update tenant_private.standalone_installments set paid_minor=paid_minor+allocated where store_id=p_store and debt_id=p_debt and number=i.number;
  insert into tenant_private.standalone_payment_allocations values(p_store,p_request,p_debt,i.number,allocated);
  left_amount:=left_amount-allocated;
 end loop;
 if left_amount<>0 then raise exception 'Schedule is inconsistent';end if;
 update tenant_private.standalone_debts set remaining_minor=remaining_minor-p_amount where store_id=p_store and id=p_debt;
 return p_request;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.standalone_list(p_store uuid, p_query text, p_customer uuid, p_direction text, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not tenant_private.receivable_allowed(p_store,'read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_query is null or length(p_query)>160 or p_offset is null or p_offset not between 0 and 100000 or (p_direction is not null and p_direction not in ('receivable','payable')) then raise exception 'Invalid filters' using errcode='22023';end if;
 return (with base as (
  select d.*,coalesce(b.name,'المستودع الرئيسي') branch_name,case when d.remaining_minor=0 then 'settled' when exists(select 1 from tenant_private.standalone_installments i where i.store_id=d.store_id and i.debt_id=d.id and i.paid_minor<i.amount_minor and i.due_date<(now() at time zone 'Asia/Damascus')::date) then 'overdue' else 'open' end status
  from tenant_private.standalone_debts d left join tenant_private.branches b on b.store_id=d.store_id and b.id=d.branch_id
  left join public.mt_customers c on c.store_id=d.store_id and c.id=d.customer_id
  where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,d.branch_id) and (d.direction='receivable' or tenant_private.receivable_allowed(p_store,'payable_manage')) and (p_customer is null or d.customer_id=p_customer) and (p_direction is null or d.direction=p_direction)
  and (p_query='' or strpos(lower(d.party),lower(p_query))>0 or strpos(d.phone,p_query)>0 or strpos(d.id::text,lower(p_query))>0 or strpos(lower(coalesce(c.name,'')),lower(p_query))>0 or strpos(coalesce(c.phone,''),p_query)>0)
 ),page as (select * from base order by created_at desc,id desc offset p_offset limit 51),
 totals as (select currency,direction,sum(principal_minor)::text principal,sum(remaining_minor)::text remaining from base group by currency,direction)
 select jsonb_build_object('store_id',p_store,'rows',coalesce((select jsonb_agg(to_jsonb(page) order by created_at desc,id desc) from page),'[]'::jsonb),'totals',coalesce((select jsonb_agg(to_jsonb(totals) order by currency,direction) from totals),'[]'::jsonb)));
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.standalone_details(p_store uuid, p_debt uuid, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d tenant_private.standalone_debts%rowtype;
begin
 if not tenant_private.receivable_allowed(p_store,'read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_offset is null or p_offset not between 0 and 100000 then raise exception 'Invalid page';end if;
 select * into strict d from tenant_private.standalone_debts where store_id=p_store and id=p_debt;
 if not tenant_private.receivable_branch_allowed(p_store,d.branch_id) or (d.direction='payable' and not tenant_private.receivable_allowed(p_store,'payable_manage')) then raise exception 'Standalone debt scope denied' using errcode='42501';end if;
 return jsonb_build_object('store_id',p_store,'debt',to_jsonb(d),'schedule',coalesce((select jsonb_agg(to_jsonb(i) order by number) from tenant_private.standalone_installments i where store_id=p_store and debt_id=p_debt),'[]'::jsonb),'payments',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from (select * from tenant_private.standalone_debt_payments where store_id=p_store and debt_id=p_debt order by created_at desc,id desc offset p_offset limit 51)p),'[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.record_sale_core(p_store uuid, p_request uuid, p_currency text, p_lines jsonb, p_customer uuid, p_deposit bigint, p_count integer, p_due date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare x jsonb; v_product uuid; v_units bigint; v_expected bigint; v_price bigint; v_sum bigint:=0; v_norm jsonb; v_previous jsonb; v_settings tenant_private.sales_settings%rowtype; v_sale public.mt_sales%rowtype; pr public.mt_products%rowtype; d public.mt_debts%rowtype; v_payment uuid; v_remaining bigint; v_part bigint; i integer;
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Sale not permitted' using errcode='42501';end if;
 if p_customer is not null then
  if not tenant_private.receivable_allowed(p_store,'credit_sale') then raise exception 'Credit sale denied' using errcode='42501';end if;
  perform tenant_private.receivable_require_credit_scope(p_store,p_request,p_deposit);
  if p_deposit is null or p_deposit<0 or p_count is null or p_count not between 1 and 60 or p_due is null then raise exception 'Invalid credit terms' using errcode='22023';end if;
 elsif p_deposit is not null or p_count is not null or p_due is not null then raise exception 'Unexpected credit terms' using errcode='22023';end if;
 if p_currency is null or p_currency not in ('SYP','USD','EUR') or p_request is null or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid sale' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>50000 then raise exception 'Invalid sale size' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid line' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line values' using errcode='22023';end if;
  v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  if v_units not between 1 and 10000 or v_expected not between 1 and 100000000 then raise exception 'Invalid line amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into v_norm from jsonb_array_elements(p_lines);
 select * into v_sale from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then
  select jsonb_agg(jsonb_build_object('product_id',l.product_id,'units',l.units,'expected_price_minor',l.unit_price_minor) order by l.product_id) into v_previous from public.mt_sale_lines l where l.store_id=p_store and l.sale_id=v_sale.id;
  if v_sale.payment_mode<>(case when p_customer is null then 'cash' else 'credit' end) then raise exception 'Conflicting payment mode' using errcode='22023';end if;
  if p_customer is not null then
   select * into d from public.mt_debts where store_id=p_store and sale_id=v_sale.id;
   if not found or d.customer_id<>p_customer or d.deposit_minor<>p_deposit or d.installment_count<>p_count or d.first_due<>p_due then raise exception 'Conflicting credit terms' using errcode='22023';end if;
  end if;
  if v_sale.actor<>auth.uid() or v_sale.currency<>p_currency or v_previous is distinct from v_norm then raise exception 'Conflicting sale request' using errcode='22023';end if;
  return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
 end if;
 select * into v_settings from tenant_private.sales_settings where store_id=p_store for update;
 if not found or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Enable sale currency first' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=v_product for update;
  if not found or pr.quantity<v_units then raise exception 'Insufficient stock or unknown product' using errcode='22023';end if;
  select price_minor into v_price from public.mt_product_prices where store_id=p_store and product_id=v_product and currency=p_currency;
  if not found or v_price is distinct from v_expected then raise exception 'Unavailable product, price changed or insufficient stock' using errcode='22023';end if;
  v_sum:=v_sum+v_units*v_price;
 end loop;
 if p_customer is not null then
  if not exists(select 1 from public.mt_customers where store_id=p_store and id=p_customer) or p_deposit>=v_sum or v_sum-p_deposit<p_count or p_due<(now() at time zone 'UTC')::date or p_due>(now() at time zone 'UTC')::date+366 then raise exception 'Invalid customer, deposit or due date' using errcode='22023';end if;
 end if;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(p_store,v_settings.next_number,p_request,auth.uid(),p_currency,v_sum,case when p_customer is null then 'cash' else 'credit' end) returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;
  update public.mt_products set quantity=quantity-v_units where store_id=p_store and id=v_product returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,v_sale.id,pr.id,pr.sku,pr.name,v_units,(x->>'expected_price_minor')::bigint);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pr.id,-v_units,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 if p_customer is null then
  insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(p_store,v_sale.id,v_sale.currency,v_sum);
 else
  v_remaining:=v_sum-p_deposit;
  insert into public.mt_debts(store_id,sale_id,customer_id,currency,principal_minor,deposit_minor,remaining_minor,installment_count,first_due) values(p_store,v_sale.id,p_customer,p_currency,v_sum,p_deposit,v_remaining,p_count,p_due) returning * into d;
  for i in 1..p_count loop
   v_part:=v_remaining/p_count+case when i<=v_remaining%p_count then 1 else 0 end;
   insert into public.mt_installments(store_id,debt_id,number,due_date,amount_minor) values(p_store,d.id,i,(p_due+make_interval(months=>i-1))::date,v_part);
  end loop;
  if p_deposit>0 then
   insert into public.mt_debt_payments(store_id,debt_id,request_id,amount_minor,is_deposit,actor) values(p_store,d.id,gen_random_uuid(),p_deposit,true,auth.uid()) returning id into v_payment;
   insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,debt_payment_id) values(p_store,gen_random_uuid(),'debt_payment',p_currency,p_deposit,'Credit sale deposit',auth.uid(),v_payment);
  end if;
 end if;
 return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.branch_credit_sale(p_store uuid, p_branch uuid, p_request uuid, p_currency text, p_lines jsonb, p_customer uuid, p_deposit bigint, p_count integer, p_due date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s uuid;r jsonb;
begin
 perform tenant_private.receivable_write(p_store,'credit_sale');perform tenant_private.require_branch(p_store,p_branch);
 if not tenant_private.receivable_branch_allowed(p_store,p_branch) then raise exception 'Credit branch denied' using errcode='42501';end if;
 select id into s from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then
 if not exists(select 1 from tenant_private.branch_sales where store_id=p_store and sale_id=s and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;
 return tenant_private.record_credit_sale(p_store,p_request,p_currency,p_lines,p_customer,p_deposit,p_count,p_due);
 end if;
 perform tenant_private.branch_take(p_store,p_branch,p_lines);
 insert into tenant_private.branch_sale_context values(p_store,p_request,p_branch,auth.uid());
 r:=tenant_private.record_credit_sale(p_store,p_request,p_currency,p_lines,p_customer,p_deposit,p_count,p_due);
 delete from tenant_private.branch_sale_context where store_id=p_store and request_id=p_request;
 insert into tenant_private.branch_sales values(p_store,(r->>'id')::uuid,p_branch);return r;
end
$function$;

CREATE OR REPLACE FUNCTION tenant_private.issue_sale_invoice(s uuid, b uuid, r uuid, c text, items jsonb, meta jsonb, terms jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prev tenant_private.sale_invoice_details%rowtype;payload jsonb;doc jsonb;result jsonb;ln jsonb;p uuid;months integer;serial text;customer uuid;customer_name text;customer_phone text;title text;note text;issued date;sid uuid;warranties jsonb:='[]';
begin
 perform 1 from public.saas_stores where id=s for update;
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.current_branch_scope(s) is not null and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 if r is null or c is null or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or jsonb_typeof(meta) is distinct from 'object' or octet_length(meta::text)>40000 or (select count(*) from jsonb_object_keys(meta))<>5 or not(meta ?& array['title','customer','phone','terms','lines']) then raise exception 'Invalid invoice metadata';end if;
 if jsonb_typeof(meta->'title') is distinct from 'string' or jsonb_typeof(meta->'customer') is distinct from 'string' or jsonb_typeof(meta->'phone') is distinct from 'string' or jsonb_typeof(meta->'terms') is distinct from 'string' or jsonb_typeof(meta->'lines') is distinct from 'array' then raise exception 'Invalid invoice metadata';end if;
 title:=btrim(meta->>'title');customer_name:=btrim(meta->>'customer');customer_phone:=btrim(meta->>'phone');note:=btrim(meta->>'terms');
 if length(title)>100 or length(customer_name)>160 or length(customer_phone)>100 or length(note)>1000 or jsonb_array_length(meta->'lines')<>jsonb_array_length(items) then raise exception 'Invalid invoice metadata';end if;
 if terms is not null and (jsonb_typeof(terms) is distinct from 'object' or not (((select count(*) from jsonb_object_keys(terms))=4 and terms ?& array['customer','deposit','count','due']) or ((select count(*) from jsonb_object_keys(terms))=2 and terms ?& array['tenders','refund_policy']))) then raise exception 'Invalid credit terms';end if;
 if terms is not null and terms ? 'tenders' and tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required for mixed sale' using errcode='42501';end if;
 if terms is not null and terms ? 'customer' and (not tenant_private.receivable_allowed(s,'credit_sale') or not tenant_private.receivable_branch_allowed(s,b)) then raise exception 'Credit sale denied' using errcode='42501';end if;
 payload:=jsonb_build_object('branch',b,'currency',c,'items',items,'meta',meta,'terms',terms);
 select * into prev from tenant_private.sale_invoice_details where store_id=s and request_id=r;
 if found then if prev.actor<>auth.uid() or prev.payload is distinct from payload then raise exception 'Conflicting invoice request';end if;return prev.result;end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale cannot receive new invoice details';end if;
 issued:=(now() at time zone 'Asia/Damascus')::date;
 for ln in select value from jsonb_array_elements(meta->'lines') loop
  if jsonb_typeof(ln) is distinct from 'object' or (select count(*) from jsonb_object_keys(ln))<>3 or not (ln ?& array['product_id','months','serial']) or jsonb_typeof(ln->'product_id') is distinct from 'string' or jsonb_typeof(ln->'months') is distinct from 'number' or jsonb_typeof(ln->'serial') is distinct from 'string' or coalesce(ln->>'months','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid warranty line';end if;
  p:=(ln->>'product_id')::uuid;months:=(ln->>'months')::integer;serial:=btrim(ln->>'serial');
  if p is null or months not between 0 and 120 or length(serial)>150 or not exists(select 1 from jsonb_array_elements(items) i where (i->>'product_id')::uuid=p) or exists(select 1 from jsonb_array_elements(warranties) i where (i->>'product_id')::uuid=p) then raise exception 'Invalid warranty line';end if;
  warranties:=warranties||jsonb_build_array(jsonb_build_object('product_id',p,'months',months,'serial',serial,'until',case when months>0 then (issued+make_interval(months=>months))::date else null end));
 end loop;
 if terms is not null and terms ? 'tenders' then
  if b is null then result:=tenant_private.record_mixed_sale(s,r,c,items,terms->'tenders',terms->>'refund_policy');
  else result:=tenant_private.branch_mixed_sale(s,b,r,c,items,terms->'tenders',terms->>'refund_policy');end if;
 elsif terms is not null then
  customer:=(terms->>'customer')::uuid;
  select name,phone into customer_name,customer_phone from public.mt_customers where store_id=s and id=customer;
  if not found then raise exception 'Unknown customer';end if;
  if b is null then result:=tenant_private.record_credit_sale(s,r,c,items,customer,(terms->>'deposit')::bigint,(terms->>'count')::integer,(terms->>'due')::date);
  else result:=tenant_private.branch_credit_sale(s,b,r,c,items,customer,(terms->>'deposit')::bigint,(terms->>'count')::integer,(terms->>'due')::date);end if;
 else
  if b is null then result:=tenant_private.record_currency_sale(s,r,c,items);
  else result:=tenant_private.branch_cash_sale(s,b,r,c,items);end if;
 end if;
 sid:=(result->>'id')::uuid;
 doc:=jsonb_build_object('title',title,'customer',customer_name,'phone',customer_phone,'terms',note,'lines',warranties,'issued',issued);
 insert into tenant_private.sale_invoice_details values(s,sid,r,auth.uid(),payload,doc,result,now());return result;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t text;v jsonb;out_data jsonb:='{}';n bigint;total_rows bigint:=0;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not tenant_private.shared_licensed(p_store) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner and AAL2 required' using errcode='42501';end if;
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_debt_payments','tenant_private.standalone_payment_allocations','tenant_private.receivable_grants'] loop
 -- Fixed relation allowlist; no user-supplied table or SQL text.
 execute format('select count(*) from (select 1 from %I.%I where store_id=$1 limit 5001)x',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>5000 or total_rows+n>20000 then raise exception 'Export exceeds browser snapshot limit; use controlled server backup' using errcode='22023';end if;
 -- Limit before building the aggregate, including large image-containing product rows.
 execute format('select coalesce(sum(octet_length(to_jsonb(r)::text)),0) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>4000000 or octet_length(out_data::text)+n>8000000 then raise exception 'Export exceeds browser byte limit' using errcode='22023';end if;
 execute format('select coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into v using p_store;
 total_rows:=total_rows+jsonb_array_length(v);out_data:=out_data||jsonb_build_object(t,v);
 end loop;
 return jsonb_build_object('version',1,'scope','business_export_only','store',p_store,'captured_at',now(),'rows',total_rows,'tables',out_data);
end $function$;
