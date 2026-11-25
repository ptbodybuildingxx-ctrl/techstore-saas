-- Repair billing: atomic part consumption, cash receipt and warranty record.
begin;
do $$ begin
 if to_regclass('public.mt_repairs') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
end $$;
create table public.mt_repair_invoices(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,repair_id uuid not null,
 currency text not null,service_minor bigint not null check(service_minor between 0 and 100000000000000),
 parts_minor bigint not null check(parts_minor between 0 and 100000000000000),
 total_minor bigint generated always as (service_minor+parts_minor) stored,
 lines jsonb not null check(jsonb_typeof(lines)='array' and jsonb_array_length(lines)<=50),
 warranty_days integer not null check(warranty_days between 0 and 730),
 warranty_until date not null,actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id),unique(store_id,repair_id),
 foreign key(store_id,repair_id) references public.mt_repairs(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 check(service_minor+parts_minor<=100000000000000)
);
create table public.mt_repair_invoice_lines(
 store_id uuid not null,invoice_id uuid not null,product_id uuid not null,
 stock_request uuid not null,product_name text not null,units bigint not null check(units between 1 and 10000),
 unit_price_minor bigint not null check(unit_price_minor between 1 and 100000000),
 primary key(store_id,invoice_id,product_id),unique(store_id,stock_request),
 foreign key(store_id,invoice_id) references public.mt_repair_invoices(store_id,id),
 foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,stock_request) references public.mt_stock_events(store_id,request_id)
);
create table public.mt_warranty_claims(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,invoice_id uuid not null,
 reason text not null check(length(btrim(reason)) between 1 and 300),state text not null default 'open' check(state in ('open','accepted','rejected','resolved')),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,invoice_id) references public.mt_repair_invoices(store_id,id)
);
create unique index mt_open_warranty_per_invoice on public.mt_warranty_claims(store_id,invoice_id) where state in ('open','accepted');
create table public.mt_warranty_events(
 store_id uuid not null,request_id uuid not null,claim_id uuid not null,prior_state text not null,next_state text not null,
 note text not null check(length(btrim(note)) between 1 and 300),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,request_id),foreign key(store_id,claim_id) references public.mt_warranty_claims(store_id,id)
);
alter table public.mt_cash_movements drop constraint mt_cash_movements_kind_check;
alter table public.mt_cash_movements add constraint mt_cash_movements_kind_check check(kind in ('sale','funding','expense','exchange','debt_payment','return_refund','supplier_payment','repair_receipt'));
alter table public.mt_cash_movements add column repair_invoice_id uuid;
alter table public.mt_cash_movements add foreign key(store_id,repair_invoice_id) references public.mt_repair_invoices(store_id,id);
alter table public.mt_cash_movements add unique(store_id,repair_invoice_id);
alter table public.mt_cash_movements add check((kind='repair_receipt')=(repair_invoice_id is not null));
create or replace function tenant_private.cash_post() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.saas_stores where id=new.store_id for update;
 if new.kind in ('sale','funding','debt_payment','repair_receipt') then
  insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.currency,new.amount_minor)
  on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;
 else
  update tenant_private.cash_balances set balance_minor=balance_minor-new.amount_minor where store_id=new.store_id and currency=new.currency and balance_minor>=new.amount_minor;
  if not found then raise exception 'Insufficient cash in source currency' using errcode='22023';end if;
  if new.kind='exchange' then
   insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.target_currency,new.target_amount_minor)
   on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;
  end if;
 end if;
 return new;
end $$;
do $$ declare t text; begin
 foreach t in array array['mt_repair_invoices','mt_repair_invoice_lines','mt_warranty_claims','mt_warranty_events'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy mt_owner_read on public.%I for select to authenticated using (tenant_private.member_role(store_id)=''owner'')',t);
 end loop;
end $$;
create function tenant_private.require_repair_invoice() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='delivered' and old.state<>'delivered' and not exists(select 1 from public.mt_repair_invoices where store_id=new.store_id and repair_id=new.id) then raise exception 'Finalize repair invoice before delivery' using errcode='22023';end if;
 return new;
end $$;
create trigger mt_require_repair_invoice before update of state on public.mt_repairs for each row execute function tenant_private.require_repair_invoice();
create function tenant_private.repair_checkout(p_store uuid,p_request uuid,p_repair uuid,p_currency text,p_service bigint,p_lines jsonb,p_warranty integer) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.mt_repairs%rowtype;v public.mt_repair_invoices%rowtype;norm jsonb;x jsonb;pr public.mt_products%rowtype;product uuid;u bigint;price bigint;parts bigint:=0;stock_id uuid;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_repair is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_service is null or p_service not between 0 and 100000000000000 or p_warranty is null or p_warranty not between 0 and 730 or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid repair invoice' using errcode='22023';end if;
 if jsonb_array_length(p_lines)>50 or octet_length(p_lines::text)>25000 then raise exception 'Too many parts' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid part' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid part values' using errcode='22023';end if;
  if (x->>'units')::bigint not between 1 and 10000 or (x->>'expected_price_minor')::bigint not between 1 and 100000000 then raise exception 'Invalid part amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate part' using errcode='22023';end if;
 select coalesce(jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid),'[]'::jsonb) into norm from jsonb_array_elements(p_lines);
 select * into v from public.mt_repair_invoices where store_id=p_store and request_id=p_request;
 if found then
  if v.actor<>auth.uid() or v.repair_id<>p_repair or v.currency<>p_currency or v.service_minor<>p_service or v.warranty_days<>p_warranty or v.lines is distinct from norm then raise exception 'Conflicting repair invoice request' using errcode='22023';end if;
  return v.id;
 end if;
 select * into r from public.mt_repairs where store_id=p_store and id=p_repair for update;
 if not found or r.state<>'ready' or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Ready repair and enabled currency required' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(norm) loop
  product:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=product for update;
  if not found or pr.quantity<u then raise exception 'Insufficient parts' using errcode='22023';end if;
  select price_minor into price from public.mt_product_prices where store_id=p_store and product_id=product and currency=p_currency;
  if not found or price<>(x->>'expected_price_minor')::bigint then raise exception 'Part price changed' using errcode='22023';end if;
  parts:=parts+u*price;
 end loop;
 if parts+p_service>100000000000000 then raise exception 'Invoice too large' using errcode='22023';end if;
 insert into public.mt_repair_invoices(store_id,request_id,repair_id,currency,service_minor,parts_minor,lines,warranty_days,warranty_until,actor) values(p_store,p_request,p_repair,p_currency,p_service,parts,norm,p_warranty,(now() at time zone 'UTC')::date+p_warranty,auth.uid()) returning * into v;
 for x in select value from jsonb_array_elements(norm) loop
  product:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;stock_id:=gen_random_uuid();
  update public.mt_products set quantity=quantity-u where store_id=p_store and id=product returning * into pr;
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(p_store,stock_id,product,-u,pr.quantity,auth.uid());
  insert into public.mt_repair_invoice_lines(store_id,invoice_id,product_id,stock_request,product_name,units,unit_price_minor) values(p_store,v.id,product,stock_id,pr.name,u,(x->>'expected_price_minor')::bigint);
 end loop;
 if v.total_minor>0 then
  insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,repair_invoice_id) values(p_store,gen_random_uuid(),'repair_receipt',p_currency,v.total_minor,'Repair cash receipt',auth.uid(),v.id);
 end if;
 perform tenant_private.repair_transition(p_store,gen_random_uuid(),p_repair,'delivered','Repair invoice completed');
 return v.id;
end $$;
create function tenant_private.warranty_open(p_store uuid,p_request uuid,p_invoice uuid,p_reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare c public.mt_warranty_claims%rowtype;v public.mt_repair_invoices%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_invoice is null or p_reason is null or length(btrim(p_reason)) not between 1 and 300 then raise exception 'Invalid claim' using errcode='22023';end if;
 select * into c from public.mt_warranty_claims where store_id=p_store and request_id=p_request;
 if found then
  if c.actor<>auth.uid() or c.invoice_id<>p_invoice or c.reason<>btrim(p_reason) then raise exception 'Conflicting claim' using errcode='22023';end if;return c.id;
 end if;
 select * into v from public.mt_repair_invoices where store_id=p_store and id=p_invoice;
 if not found or v.warranty_days=0 or v.warranty_until<(now() at time zone 'UTC')::date then raise exception 'Warranty unavailable' using errcode='22023';end if;
 insert into public.mt_warranty_claims(store_id,request_id,invoice_id,reason,actor) values(p_store,p_request,p_invoice,btrim(p_reason),auth.uid()) returning * into c;return c.id;
end $$;
create function tenant_private.warranty_transition(p_store uuid,p_request uuid,p_claim uuid,p_next text,p_note text) returns text
language plpgsql security definer set search_path='' as $$
declare c public.mt_warranty_claims%rowtype;e public.mt_warranty_events%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_claim is null or p_next is null or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid transition' using errcode='22023';end if;
 select * into e from public.mt_warranty_events where store_id=p_store and request_id=p_request;
 if found then
  if e.actor<>auth.uid() or e.claim_id<>p_claim or e.next_state<>p_next or e.note<>btrim(p_note) then raise exception 'Conflicting claim transition' using errcode='22023';end if;return e.next_state;
 end if;
 select * into c from public.mt_warranty_claims where store_id=p_store and id=p_claim for update;
 if not found or not ((c.state='open' and p_next in ('accepted','rejected')) or (c.state='accepted' and p_next='resolved')) then raise exception 'Invalid claim state' using errcode='22023';end if;
 update public.mt_warranty_claims set state=p_next where store_id=p_store and id=p_claim;
 insert into public.mt_warranty_events(store_id,request_id,claim_id,prior_state,next_state,note,actor) values(p_store,p_request,p_claim,c.state,p_next,btrim(p_note),auth.uid());return p_next;
end $$;
create function public.mt_repair_checkout(p_store uuid,p_request uuid,p_repair uuid,p_currency text,p_service bigint,p_lines jsonb,p_warranty integer) returns uuid language sql security invoker set search_path='' as $$select tenant_private.repair_checkout(p_store,p_request,p_repair,p_currency,p_service,p_lines,p_warranty)$$;
create function public.mt_warranty_open(p_store uuid,p_request uuid,p_invoice uuid,p_reason text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.warranty_open(p_store,p_request,p_invoice,p_reason)$$;
create function public.mt_warranty_transition(p_store uuid,p_request uuid,p_claim uuid,p_next text,p_note text) returns text language sql security invoker set search_path='' as $$select tenant_private.warranty_transition(p_store,p_request,p_claim,p_next,p_note)$$;
do $$ declare t text;f text;begin
 foreach t in array array['repair_invoices','warranty_claims'] loop
  f:='mt_list_'||t;
  execute format('create function public.%I(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.%I language plpgsql stable security invoker set search_path='''' as $body$ begin if p_limit is null or p_limit not between 1 and 100 then raise exception ''Invalid page'' using errcode=''22023'';end if;return query select * from public.%I where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $body$',f,'mt_'||t,'mt_'||t);
 end loop;
end $$;
revoke all on function tenant_private.require_repair_invoice(),tenant_private.repair_checkout(uuid,uuid,uuid,text,bigint,jsonb,integer),tenant_private.warranty_open(uuid,uuid,uuid,text),tenant_private.warranty_transition(uuid,uuid,uuid,text,text),public.mt_repair_checkout(uuid,uuid,uuid,text,bigint,jsonb,integer),public.mt_warranty_open(uuid,uuid,uuid,text),public.mt_warranty_transition(uuid,uuid,uuid,text,text),public.mt_list_repair_invoices(uuid,uuid,integer),public.mt_list_warranty_claims(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.repair_checkout(uuid,uuid,uuid,text,bigint,jsonb,integer),tenant_private.warranty_open(uuid,uuid,uuid,text),tenant_private.warranty_transition(uuid,uuid,uuid,text,text),public.mt_repair_checkout(uuid,uuid,uuid,text,bigint,jsonb,integer),public.mt_warranty_open(uuid,uuid,uuid,text),public.mt_warranty_transition(uuid,uuid,uuid,text,text),public.mt_list_repair_invoices(uuid,uuid,integer),public.mt_list_warranty_claims(uuid,uuid,integer) to authenticated;
commit;