-- Independent receivables and payables, with immutable opening values and payment history.
-- Private operations become callable only after accounting integration is installed by migration 102.
create table tenant_private.standalone_debts(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null,
 customer_id uuid,branch_id uuid,direction text not null check(direction in ('receivable','payable')),
 party text not null check(length(btrim(party)) between 1 and 160),phone text not null check(length(phone)<=60),
 currency text not null,principal_minor bigint not null check(principal_minor between 1 and 100000000000000),
 remaining_minor bigint not null check(remaining_minor between 0 and principal_minor),
 installment_count integer not null check(installment_count between 1 and 120),
 first_due date not null,notes text not null check(length(notes)<=300),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),
 foreign key(store_id,customer_id) references public.mt_customers(store_id,id),
 foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 check(installment_count<=principal_minor),check(direction='receivable' or installment_count=1));
create table tenant_private.standalone_installments(
 store_id uuid not null,debt_id uuid not null,number integer not null check(number between 1 and 120),due_date date not null,
 amount_minor bigint not null check(amount_minor>0),paid_minor bigint not null default 0 check(paid_minor between 0 and amount_minor),
 primary key(store_id,debt_id,number),foreign key(store_id,debt_id) references tenant_private.standalone_debts(store_id,id));
create table tenant_private.standalone_debt_payments(
 store_id uuid not null,id uuid not null,debt_id uuid not null,cash_id uuid not null,
 amount_minor bigint not null check(amount_minor between 1 and 100000000000000),memo text not null check(length(memo)<=300),
 actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,cash_id),unique(store_id,id,debt_id),
 foreign key(store_id,debt_id) references tenant_private.standalone_debts(store_id,id),
 foreign key(store_id,cash_id) references public.mt_cash_movements(store_id,id));
create table tenant_private.standalone_payment_allocations(
 store_id uuid not null,payment_id uuid not null,debt_id uuid not null,number integer not null,amount_minor bigint not null check(amount_minor>0),
 primary key(store_id,payment_id,number),
 foreign key(store_id,payment_id,debt_id) references tenant_private.standalone_debt_payments(store_id,id,debt_id),
 foreign key(store_id,debt_id,number) references tenant_private.standalone_installments(store_id,debt_id,number));
create index standalone_debts_store_customer on tenant_private.standalone_debts(store_id,customer_id,created_at,id);
create index standalone_debt_payments_debt on tenant_private.standalone_debt_payments(store_id,debt_id,created_at,id);
alter table tenant_private.standalone_debts enable row level security;
alter table tenant_private.standalone_installments enable row level security;
alter table tenant_private.standalone_debt_payments enable row level security;
alter table tenant_private.standalone_payment_allocations enable row level security;
revoke all on tenant_private.standalone_debts,tenant_private.standalone_installments,tenant_private.standalone_debt_payments,tenant_private.standalone_payment_allocations from public,anon,authenticated,service_role;
create trigger standalone_open_period before insert on tenant_private.standalone_debts for each row execute function tenant_private.guard_closed_period();
create trigger standalone_pay_period before insert on tenant_private.standalone_debt_payments for each row execute function tenant_private.guard_closed_period();

create function tenant_private.standalone_open(p_store uuid,p_request uuid,p_customer uuid,p_branch uuid,p_direction text,p_party text,p_phone text,p_currency text,p_amount bigint,p_count integer,p_due date,p_notes text)
returns uuid language plpgsql security definer set search_path='' as $$
declare d tenant_private.standalone_debts%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_direction is null or p_direction not in ('receivable','payable') or p_party is null or length(btrim(p_party)) not between 1 and 160 or p_phone is null or length(p_phone)>60 or p_amount is null or p_amount not between 1 and 100000000000000 or p_count is null or p_count not between 1 and 120 or p_count>p_amount or (p_direction='payable' and p_count<>1) or p_due is null or p_due not between date '1900-01-01' and date '2200-01-01' or p_notes is null or length(p_notes)>300 then raise exception 'Invalid standalone debt' using errcode='22023';end if;
 select * into d from tenant_private.standalone_debts where store_id=p_store and id=p_request;
 if found then
  if d.actor<>auth.uid() or d.customer_id is distinct from p_customer or d.branch_id is distinct from p_branch or d.direction<>p_direction or d.party<>btrim(p_party) or d.phone<>btrim(p_phone) or d.currency is distinct from p_currency or d.principal_minor<>p_amount or d.installment_count<>p_count or d.first_due<>p_due or d.notes<>btrim(p_notes) then raise exception 'Conflicting request' using errcode='22023';end if;
  return d.id;
 end if;
 if exists(select 1 from tenant_private.standalone_debt_payments where store_id=p_store and id=p_request) then raise exception 'Conflicting request';end if;
 insert into tenant_private.standalone_debts(store_id,id,customer_id,branch_id,direction,party,phone,currency,principal_minor,remaining_minor,installment_count,first_due,notes,actor)
 values(p_store,p_request,p_customer,p_branch,p_direction,btrim(p_party),btrim(p_phone),p_currency,p_amount,p_amount,p_count,p_due,btrim(p_notes),auth.uid());
 insert into tenant_private.standalone_installments(store_id,debt_id,number,due_date,amount_minor)
 select p_store,p_request,i,(p_due+make_interval(months=>i-1))::date,p_amount/p_count+case when i<=p_amount%p_count then 1 else 0 end from generate_series(1,p_count) i;
 return p_request;
end $$;

create function tenant_private.standalone_pay(p_store uuid,p_request uuid,p_debt uuid,p_amount bigint,p_memo text)
returns uuid language plpgsql security definer set search_path='' as $$
declare d tenant_private.standalone_debts%rowtype;p tenant_private.standalone_debt_payments%rowtype;i tenant_private.standalone_installments%rowtype;cash uuid;left_amount bigint;allocated bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_debt is null or p_amount is null or p_amount not between 1 and 100000000000000 or p_memo is null or length(p_memo)>300 then raise exception 'Invalid payment' using errcode='22023';end if;
 select * into p from tenant_private.standalone_debt_payments where store_id=p_store and id=p_request;
 if found then
  if p.actor<>auth.uid() or p.debt_id<>p_debt or p.amount_minor<>p_amount or p.memo<>btrim(p_memo) then raise exception 'Conflicting request' using errcode='22023';end if;
  return p.id;
 end if;
 if exists(select 1 from tenant_private.standalone_debts where store_id=p_store and id=p_request) then raise exception 'Conflicting request';end if;
 select * into strict d from tenant_private.standalone_debts where store_id=p_store and id=p_debt for update;
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
end $$;

create function tenant_private.standalone_list(p_store uuid,p_query text,p_customer uuid,p_direction text,p_offset integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_query is null or length(p_query)>160 or p_offset is null or p_offset not between 0 and 100000 or (p_direction is not null and p_direction not in ('receivable','payable')) then raise exception 'Invalid filters' using errcode='22023';end if;
 return (with base as (
  select d.*,coalesce(b.name,'المستودع الرئيسي') branch_name,case when d.remaining_minor=0 then 'settled' when exists(select 1 from tenant_private.standalone_installments i where i.store_id=d.store_id and i.debt_id=d.id and i.paid_minor<i.amount_minor and i.due_date<(now() at time zone 'Asia/Damascus')::date) then 'overdue' else 'open' end status
  from tenant_private.standalone_debts d left join tenant_private.branches b on b.store_id=d.store_id and b.id=d.branch_id
  left join public.mt_customers c on c.store_id=d.store_id and c.id=d.customer_id
  where d.store_id=p_store and (p_customer is null or d.customer_id=p_customer) and (p_direction is null or d.direction=p_direction)
  and (p_query='' or strpos(lower(d.party),lower(p_query))>0 or strpos(d.phone,p_query)>0 or strpos(d.id::text,lower(p_query))>0 or strpos(lower(coalesce(c.name,'')),lower(p_query))>0 or strpos(coalesce(c.phone,''),p_query)>0)
 ),page as (select * from base order by created_at desc,id desc offset p_offset limit 51),
 totals as (select currency,direction,sum(principal_minor)::text principal,sum(remaining_minor)::text remaining from base group by currency,direction)
 select jsonb_build_object('store_id',p_store,'rows',coalesce((select jsonb_agg(to_jsonb(page) order by created_at desc,id desc) from page),'[]'::jsonb),'totals',coalesce((select jsonb_agg(to_jsonb(totals) order by currency,direction) from totals),'[]'::jsonb)));
end $$;

create function tenant_private.standalone_details(p_store uuid,p_debt uuid,p_offset integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d tenant_private.standalone_debts%rowtype;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_offset is null or p_offset not between 0 and 100000 then raise exception 'Invalid page';end if;
 select * into strict d from tenant_private.standalone_debts where store_id=p_store and id=p_debt;
 return jsonb_build_object('store_id',p_store,'debt',to_jsonb(d),'schedule',coalesce((select jsonb_agg(to_jsonb(i) order by number) from tenant_private.standalone_installments i where store_id=p_store and debt_id=p_debt),'[]'::jsonb),'payments',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from (select * from tenant_private.standalone_debt_payments where store_id=p_store and debt_id=p_debt order by created_at desc,id desc offset p_offset limit 51)p),'[]'::jsonb));
end $$;
revoke all on function tenant_private.standalone_open(uuid,uuid,uuid,uuid,text,text,text,text,bigint,integer,date,text),tenant_private.standalone_pay(uuid,uuid,uuid,bigint,text),tenant_private.standalone_list(uuid,text,uuid,text,integer),tenant_private.standalone_details(uuid,uuid,integer) from public,anon,authenticated,service_role;
