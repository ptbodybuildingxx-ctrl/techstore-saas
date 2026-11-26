-- Opt-in location-specific FIFO. Keep canonical acquisition layers and historical cost postings.
begin;
create table tenant_private.branch_fifo_enabled(store_id uuid primary key references tenant_private.workspaces(store_id),actor uuid not null,activated_at timestamptz not null default now(),opening_reference text not null check(length(btrim(opening_reference)) between 1 and 160));
create table tenant_private.branch_fifo_lots(store_id uuid not null,product_id uuid not null,layer_id bigint not null,branch_id uuid,location_id uuid generated always as(coalesce(branch_id,'00000000-0000-0000-0000-000000000000'::uuid)) stored,units bigint not null check(units>=0),primary key(store_id,product_id,layer_id,location_id),foreign key(store_id,product_id,layer_id) references tenant_private.stock_layers(store_id,product_id,id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),foreign key(store_id) references tenant_private.branch_fifo_enabled(store_id),check(branch_id is null or branch_id<>'00000000-0000-0000-0000-000000000000'::uuid));
create index mt_branch_fifo_lookup on tenant_private.branch_fifo_lots(store_id,product_id,location_id,layer_id) where units>0;
create table tenant_private.fifo_repair_context(store_id uuid not null,transaction_id xid8 not null,branch_id uuid not null,primary key(store_id,transaction_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
create table tenant_private.branch_fifo_moves(store_id uuid not null,request_id uuid not null,product_id uuid not null,layer_id bigint not null,units bigint not null check(units>0),primary key(store_id,request_id,layer_id),foreign key(store_id,request_id) references tenant_private.branch_transfers(store_id,request_id),foreign key(store_id,product_id,layer_id) references tenant_private.stock_layers(store_id,product_id,id));
do $$declare t text;begin foreach t in array array['branch_fifo_enabled','branch_fifo_lots','fifo_repair_context','branch_fifo_moves'] loop execute format('alter table tenant_private.%I enable row level security',t);execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create function tenant_private.fifo_delta(s uuid,p uuid,l bigint,b uuid,d bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 if d>0 then insert into tenant_private.branch_fifo_lots(store_id,product_id,layer_id,branch_id,units) values(s,p,l,b,d) on conflict(store_id,product_id,layer_id,location_id) do update set units=branch_fifo_lots.units+excluded.units;
 elsif d<0 then update tenant_private.branch_fifo_lots set units=units+d where store_id=s and product_id=p and layer_id=l and branch_id is not distinct from b and units>=-d;
 if not found then raise exception 'Insufficient acquisition lot at this location' using errcode='22023';end if;end if;
end $$;
create function tenant_private.fifo_assert_product(s uuid,p uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from tenant_private.branch_fifo_enabled where store_id=s) then return;end if;
 if exists(select 1 from tenant_private.stock_layers l where l.store_id=s and l.product_id=p and l.remaining_units<>(select coalesce(sum(a.units),0) from tenant_private.branch_fifo_lots a where a.store_id=s and a.product_id=p and a.layer_id=l.id)) then raise exception 'FIFO layer reconciliation failed';end if;
 if exists(select 1 from tenant_private.branches b where b.store_id=s and coalesce((select units from tenant_private.branch_stock where store_id=s and product_id=p and branch_id=b.id),0)<>(select coalesce(sum(units),0) from tenant_private.branch_fifo_lots a where a.store_id=s and a.product_id=p and a.branch_id=b.id)) then raise exception 'FIFO branch reconciliation failed';end if;
 if (select quantity-tenant_private.branch_allocated(s,p) from public.mt_products where store_id=s and id=p) is distinct from (select coalesce(sum(units),0)::bigint from tenant_private.branch_fifo_lots where store_id=s and product_id=p and branch_id is null) then raise exception 'FIFO main reconciliation failed';end if;
end $$;
create function tenant_private.fifo_check_trigger() returns trigger language plpgsql security definer set search_path='' as $$begin perform tenant_private.fifo_assert_product(new.store_id,new.product_id);return new;end$$;
create constraint trigger mt_fifo_check_event after insert on public.mt_stock_events deferrable initially deferred for each row execute function tenant_private.fifo_check_trigger();
create constraint trigger mt_fifo_check_transfer after insert on tenant_private.branch_transfers deferrable initially deferred for each row execute function tenant_private.fifo_check_trigger();
create function tenant_private.fifo_event_branch(e public.mt_stock_events) returns uuid language plpgsql stable security definer set search_path='' as $$
declare b uuid;begin
 if e.sale_id is not null then select c.branch_id into b from public.mt_sales s join tenant_private.branch_sale_context c on c.store_id=s.store_id and c.request_id=s.request_id where s.store_id=e.store_id and s.id=e.sale_id;
 elsif e.return_id is not null then select a.branch_id into b from public.mt_returns r join tenant_private.branch_sales a on a.store_id=r.store_id and a.sale_id=r.sale_id where r.store_id=e.store_id and r.id=e.return_id;
 elsif e.supplier_return_id is not null then select a.branch_id into b from public.mt_supplier_returns r join tenant_private.branch_purchases a on a.store_id=r.store_id and a.purchase_id=r.purchase_id where r.store_id=e.store_id and r.id=e.supplier_return_id;
 elsif e.delta<0 then select branch_id into b from tenant_private.fifo_repair_context where store_id=e.store_id and transaction_id=pg_current_xact_id();end if;return b;
end $$;
create function tenant_private.branch_fifo_start(p_store uuid,p_reference text,p_allocations jsonb) returns boolean language plpgsql security definer set search_path='' as $$
declare x jsonb;l tenant_private.stock_layers%rowtype;p uuid;b uuid;u bigint;lid bigint;begin
 perform tenant_private.owner_write(p_store);
 if exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then raise exception 'FIFO already enabled';end if;
 if p_reference is null or length(btrim(p_reference)) not between 1 and 160 or jsonb_typeof(p_allocations) is distinct from 'array' or jsonb_array_length(p_allocations)>10000 or octet_length(p_allocations::text)>2000000 then raise exception 'Invalid opening allocation';end if;
 insert into tenant_private.branch_fifo_enabled values(p_store,auth.uid(),now(),btrim(p_reference));
 insert into tenant_private.branch_fifo_lots(store_id,product_id,layer_id,units) select store_id,product_id,id,remaining_units from tenant_private.stock_layers where store_id=p_store and remaining_units>0;
 for x in select value from jsonb_array_elements(p_allocations) loop
 if jsonb_typeof(x) is distinct from 'object' or coalesce(x->>'layer_id','') !~ '^[0-9]{1,18}$' or coalesce(x->>'units','') !~ '^[0-9]{1,10}$' then raise exception 'Invalid opening lot';end if;
 p:=(x->>'product_id')::uuid;b:=(x->>'branch_id')::uuid;lid:=(x->>'layer_id')::bigint;u:=(x->>'units')::bigint;
 if p is null or b is null or u not between 1 and 1000000000 then raise exception 'Invalid opening quantity';end if;
 perform tenant_private.require_branch(p_store,b);perform tenant_private.fifo_delta(p_store,p,lid,null,-u);perform tenant_private.fifo_delta(p_store,p,lid,b,u);
 end loop;
 for p in select id from public.mt_products where store_id=p_store loop perform tenant_private.fifo_assert_product(p_store,p);end loop;return true;
end $$;
create function tenant_private.fifo_transfer_post() returns trigger language plpgsql security definer set search_path='' as $$
declare l record;remaining bigint:=new.units;used bigint;begin
 if not exists(select 1 from tenant_private.branch_fifo_enabled where store_id=new.store_id) then return new;end if;
 for l in select layer_id,units from tenant_private.branch_fifo_lots where store_id=new.store_id and product_id=new.product_id and branch_id is not distinct from new.source and units>0 order by layer_id for update loop
 exit when remaining=0;used:=least(remaining,l.units);
 perform tenant_private.fifo_delta(new.store_id,new.product_id,l.layer_id,new.source,-used);perform tenant_private.fifo_delta(new.store_id,new.product_id,l.layer_id,new.target,used);
 insert into tenant_private.branch_fifo_moves values(new.store_id,new.request_id,new.product_id,l.layer_id,used);remaining:=remaining-used;
 end loop;if remaining<>0 then raise exception 'Insufficient location FIFO stock';end if;return new;
end $$;
create trigger mt_fifo_transfer_post after insert on tenant_private.branch_transfers for each row execute function tenant_private.fifo_transfer_post();
create function tenant_private.fifo_purchase_post() returns trigger language plpgsql security definer set search_path='' as $$
declare p public.mt_purchases%rowtype;l bigint;begin
 if not exists(select 1 from tenant_private.branch_fifo_enabled where store_id=new.store_id) then return new;end if;
 select * into strict p from public.mt_purchases where store_id=new.store_id and id=new.purchase_id;
 select id into strict l from tenant_private.stock_layers where store_id=p.store_id and product_id=p.product_id and intake_request=p.intake_request;
 perform tenant_private.fifo_delta(p.store_id,p.product_id,l,null,-p.units);perform tenant_private.fifo_delta(p.store_id,p.product_id,l,new.branch_id,p.units);return new;
end $$;
create trigger mt_fifo_purchase_post after insert on tenant_private.branch_purchases for each row execute function tenant_private.fifo_purchase_post();
create or replace function tenant_private.post_stock_cost() returns trigger
language plpgsql security definer set search_path='' as $$
declare intake tenant_private.cost_intakes%rowtype; l tenant_private.stock_layers%rowtype; c tenant_private.stock_consumptions%rowtype; remaining bigint; used bigint; original_event uuid; intake_id uuid; b uuid; active boolean; layer_now bigint; loc uuid; available bigint;
begin
 active:=exists(select 1 from tenant_private.branch_fifo_enabled where store_id=new.store_id);
 if active then b:=tenant_private.fifo_event_branch(new);end if;
 if new.supplier_return_id is not null then
  select p.intake_request into strict intake_id from public.mt_supplier_returns sr join public.mt_purchases p on p.store_id=sr.store_id and p.id=sr.purchase_id where sr.store_id=new.store_id and sr.id=new.supplier_return_id and p.product_id=new.product_id and sr.units=-new.delta;
  select * into l from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and intake_request=intake_id for update;
  if not found or l.remaining_units< -new.delta then raise exception 'Original purchase layer has insufficient stock' using errcode='22023';end if;
  if active then perform tenant_private.fifo_delta(new.store_id,new.product_id,l.id,b,new.delta);end if;
  update tenant_private.stock_layers set remaining_units=remaining_units+new.delta where store_id=l.store_id and product_id=l.product_id and id=l.id;
  insert into tenant_private.stock_consumptions(store_id,product_id,event_id,layer_id,units) values(l.store_id,l.product_id,new.request_id,l.id,-new.delta);
 elsif new.return_id is not null then
  select e.request_id into strict original_event from public.mt_returns r join public.mt_stock_events e on e.store_id=r.store_id and e.sale_id=r.sale_id and e.product_id=r.product_id where r.store_id=new.store_id and r.id=new.return_id and r.product_id=new.product_id;
  remaining:=new.delta;
  for c in select * from tenant_private.stock_consumptions where store_id=new.store_id and product_id=new.product_id and event_id=original_event and restored_units<units order by layer_id for update loop
   exit when remaining=0;
   used:=least(remaining,c.units-c.restored_units);
   update tenant_private.stock_consumptions set restored_units=restored_units+used where store_id=c.store_id and product_id=c.product_id and event_id=c.event_id and layer_id=c.layer_id;
   if active then perform tenant_private.fifo_delta(new.store_id,new.product_id,c.layer_id,b,used);end if;
   update tenant_private.stock_layers set remaining_units=remaining_units+used where store_id=c.store_id and product_id=c.product_id and id=c.layer_id;
   remaining:=remaining-used;
  end loop;
  if remaining<>0 then raise exception 'Return cost allocation mismatch';end if;
 elsif new.delta>0 then
  select * into intake from tenant_private.cost_intakes where store_id=new.store_id and request_id=new.request_id;
  if found and (intake.product_id<>new.product_id or intake.units<>new.delta or intake.actor<>new.actor) then raise exception 'Cost intake mismatch';end if;
  insert into tenant_private.stock_layers(store_id,product_id,intake_request,original_units,remaining_units,currency,unit_cost_minor) values(new.store_id,new.product_id,new.request_id,new.delta,new.delta,intake.currency,intake.unit_cost_minor) returning id into layer_now;
  if active then perform tenant_private.fifo_delta(new.store_id,new.product_id,layer_now,null,new.delta);end if;
 else
  remaining:=-new.delta;
  for l in select * from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and remaining_units>0 and (not active or exists(select 1 from tenant_private.branch_fifo_lots a where a.store_id=new.store_id and a.product_id=new.product_id and a.layer_id=stock_layers.id and a.branch_id is not distinct from b and a.units>0)) order by id for update loop
   exit when remaining=0;
   if active then select units into strict available from tenant_private.branch_fifo_lots where store_id=l.store_id and product_id=l.product_id and layer_id=l.id and branch_id is not distinct from b;else available:=l.remaining_units;end if;
   used:=least(remaining,available);
   if active then perform tenant_private.fifo_delta(new.store_id,new.product_id,l.id,b,-used);end if;
   update tenant_private.stock_layers set remaining_units=remaining_units-used where store_id=l.store_id and product_id=l.product_id and id=l.id;
   insert into tenant_private.stock_consumptions(store_id,product_id,event_id,layer_id,units) values(l.store_id,l.product_id,new.request_id,l.id,used);
   remaining:=remaining-used;
  end loop;
  if remaining<>0 then raise exception 'Insufficient tracked stock layers';end if;
 end if;
 if (select coalesce(sum(remaining_units),0) from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and remaining_units>0)<>new.balance then raise exception 'Stock layer balance mismatch';end if;
 return new;
end $$;
create or replace function tenant_private.branch_credit_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb,p_customer uuid,p_deposit bigint,p_count integer,p_due date) returns jsonb language plpgsql security definer set search_path='' as $$
declare s uuid;r jsonb;
begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_branch(p_store,p_branch);
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
$$;
create or replace function tenant_private.branch_mixed_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb,p_tenders jsonb,p_refund_policy text) returns jsonb language plpgsql security definer set search_path='' as $$
declare s uuid;r jsonb;
begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_branch(p_store,p_branch);
 select id into s from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then
 if not exists(select 1 from tenant_private.branch_sales where store_id=p_store and sale_id=s and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;
 return tenant_private.record_mixed_sale(p_store,p_request,p_currency,p_lines,p_tenders,p_refund_policy);
 end if;
 perform tenant_private.branch_take(p_store,p_branch,p_lines);
 insert into tenant_private.branch_sale_context values(p_store,p_request,p_branch,auth.uid());
 r:=tenant_private.record_mixed_sale(p_store,p_request,p_currency,p_lines,p_tenders,p_refund_policy);
 delete from tenant_private.branch_sale_context where store_id=p_store and request_id=p_request;
 insert into tenant_private.branch_sales values(p_store,(r->>'id')::uuid,p_branch);return r;
end
$$;
create or replace function tenant_private.repair_checkout(p_store uuid,p_request uuid,p_repair uuid,p_currency text,p_service bigint,p_lines jsonb,p_warranty integer) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.mt_repairs%rowtype;v public.mt_repair_invoices%rowtype;norm jsonb;x jsonb;pr public.mt_products%rowtype;product uuid;u bigint;price bigint;parts bigint:=0;stock_id uuid; fifo_branch uuid;
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
 select branch_id into fifo_branch from tenant_private.branch_repairs where store_id=p_store and repair_id=p_repair;
 if fifo_branch is not null and exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then insert into tenant_private.fifo_repair_context values(p_store,pg_current_xact_id(),fifo_branch);end if;
 for x in select value from jsonb_array_elements(norm) loop
  product:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;stock_id:=gen_random_uuid();
  update public.mt_products set quantity=quantity-u where store_id=p_store and id=product returning * into pr;
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(p_store,stock_id,product,-u,pr.quantity,auth.uid());
  insert into public.mt_repair_invoice_lines(store_id,invoice_id,product_id,stock_request,product_name,units,unit_price_minor) values(p_store,v.id,product,stock_id,pr.name,u,(x->>'expected_price_minor')::bigint);
 end loop;
 delete from tenant_private.fifo_repair_context where store_id=p_store and transaction_id=pg_current_xact_id();
 if v.total_minor>0 then
  insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,repair_invoice_id) values(p_store,gen_random_uuid(),'repair_receipt',p_currency,v.total_minor,'Repair cash receipt',auth.uid(),v.id);
 end if;
 perform tenant_private.repair_transition(p_store,gen_random_uuid(),p_repair,'delivered','Repair invoice completed');
 return v.id;
end $$;
create or replace function tenant_private.warranty_part(p_store uuid,p_request uuid,p_claim uuid,p_product uuid,p_units bigint,p_reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare c public.mt_warranty_claims%rowtype;v public.mt_repair_invoices%rowtype;r public.mt_warranty_parts%rowtype;q bigint;event_id uuid:=gen_random_uuid(); fifo_branch uuid;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_claim is null or p_product is null or p_units is null or p_units not between 1 and 10000 or p_reason is null or length(btrim(p_reason)) not between 1 and 300 then raise exception 'Invalid warranty part' using errcode='22023';end if;
 select * into r from public.mt_warranty_parts where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.claim_id<>p_claim or r.product_id<>p_product or r.units<>p_units or r.reason<>btrim(p_reason) then raise exception 'Conflicting request' using errcode='22023';end if;return r.id;
 end if;
 select * into c from public.mt_warranty_claims where store_id=p_store and id=p_claim for update;
 if not found or c.state<>'accepted' then raise exception 'Accepted claim required' using errcode='22023';end if;
 select * into strict v from public.mt_repair_invoices where store_id=p_store and id=c.invoice_id;
 select branch_id into fifo_branch from tenant_private.branch_repairs where store_id=p_store and repair_id=v.repair_id;
 if fifo_branch is not null and exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then
 update tenant_private.branch_stock set units=units-p_units where store_id=p_store and branch_id=fifo_branch and product_id=p_product and units>=p_units;
 if not found then raise exception 'Insufficient warranty stock at repair branch';end if;
 insert into tenant_private.fifo_repair_context values(p_store,pg_current_xact_id(),fifo_branch);end if;
 update public.mt_products set quantity=quantity-p_units where store_id=p_store and id=p_product and quantity>=p_units returning quantity into q;
 if not found then raise exception 'Insufficient warranty stock' using errcode='22023';end if;
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(p_store,event_id,p_product,-p_units,q,auth.uid());
 insert into public.mt_warranty_parts(store_id,request_id,claim_id,product_id,units,stock_request,reason,actor) values(p_store,p_request,p_claim,p_product,p_units,event_id,btrim(p_reason),auth.uid()) returning * into r;
 delete from tenant_private.fifo_repair_context where store_id=p_store and transaction_id=pg_current_xact_id();
 perform tenant_private.snapshot_cost(p_store,p_product,event_id,null,v.id,v.currency,r.created_at);
 return r.id;
end $$;
create function tenant_private.branch_fifo_report(p_store uuid,p_product uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare enabled boolean;begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 enabled:=exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store);
 return jsonb_build_object('enabled',enabled,'lots',coalesce((select jsonb_agg(to_jsonb(x) order by layer_id,branch_id) from (select l.id::text layer_id,l.product_id,a.branch_id,case when enabled then a.units else l.remaining_units end units,l.currency,l.unit_cost_minor from tenant_private.stock_layers l left join tenant_private.branch_fifo_lots a on a.store_id=l.store_id and a.product_id=l.product_id and a.layer_id=l.id where l.store_id=p_store and l.product_id=p_product and (case when enabled then a.units else l.remaining_units end)>0 order by l.id,a.branch_id limit 500)x),'[]'),'valuation',case when enabled then (select coalesce(jsonb_agg(to_jsonb(x) order by x.branch_id,x.currency),'[]') from (select a.branch_id,l.currency,sum(a.units)::text units,sum(a.units::numeric*l.unit_cost_minor)::text cost_minor from tenant_private.branch_fifo_lots a join tenant_private.stock_layers l on l.store_id=a.store_id and l.product_id=a.product_id and l.id=a.layer_id where a.store_id=p_store and a.units>0 group by a.branch_id,l.currency)x) else null end);
end $$;
create function public.mt_branch_fifo_start(p_store uuid,p_reference text,p_allocations jsonb) returns boolean language sql security invoker set search_path='' as $$select tenant_private.branch_fifo_start(p_store,p_reference,p_allocations)$$;
create function public.mt_branch_fifo_report(p_store uuid,p_product uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_fifo_report(p_store,p_product)$$;
revoke all on function tenant_private.fifo_delta(uuid,uuid,bigint,uuid,bigint),tenant_private.fifo_assert_product(uuid,uuid),tenant_private.fifo_check_trigger(),tenant_private.fifo_event_branch(public.mt_stock_events),tenant_private.fifo_transfer_post(),tenant_private.fifo_purchase_post(),tenant_private.branch_fifo_start(uuid,text,jsonb),tenant_private.branch_fifo_report(uuid,uuid),public.mt_branch_fifo_start(uuid,text,jsonb),public.mt_branch_fifo_report(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_fifo_start(uuid,text,jsonb),tenant_private.branch_fifo_report(uuid,uuid),public.mt_branch_fifo_start(uuid,text,jsonb),public.mt_branch_fifo_report(uuid,uuid) to authenticated;
commit;
