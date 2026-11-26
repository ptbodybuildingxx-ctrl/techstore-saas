-- 120: refund-aware repair warranty coverage, Damascus warranty dates, branch-safe parts.
begin;
create function tenant_private.repair_fully_refunded(s uuid,i uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.mt_repair_invoices v where v.store_id=s and v.id=i and v.total_minor>0 and (select coalesce(sum(amount_minor),0) from public.mt_repair_refunds where store_id=s and invoice_id=i)>=v.total_minor)
$$;
revoke all on function tenant_private.repair_fully_refunded(uuid,uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION tenant_private.repair_checkout(p_store uuid, p_request uuid, p_repair uuid, p_currency text, p_service bigint, p_lines jsonb, p_warranty integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 select branch_id into fifo_branch from tenant_private.branch_repairs where store_id=p_store and repair_id=p_repair;
 if fifo_branch is not null and jsonb_array_length(norm)>0 and not exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then raise exception 'Activate branch FIFO before consuming repair parts' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(norm) loop
  product:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=product for update;
  if not found or pr.quantity<u or (fifo_branch is null and coalesce(tenant_private.main_available(p_store,product),0)<u) then raise exception 'Insufficient parts at repair location' using errcode='22023';end if;
  select price_minor into price from public.mt_product_prices where store_id=p_store and product_id=product and currency=p_currency;
  if not found or price<>(x->>'expected_price_minor')::bigint then raise exception 'Part price changed' using errcode='22023';end if;
  parts:=parts+u*price;
 end loop;
 if parts+p_service>100000000000000 then raise exception 'Invoice too large' using errcode='22023';end if;
 insert into public.mt_repair_invoices(store_id,request_id,repair_id,currency,service_minor,parts_minor,lines,warranty_days,warranty_until,actor) values(p_store,p_request,p_repair,p_currency,p_service,parts,norm,p_warranty,(now() at time zone 'Asia/Damascus')::date+p_warranty,auth.uid()) returning * into v;
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
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.warranty_open(p_store uuid, p_request uuid, p_invoice uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.mt_warranty_claims%rowtype;v public.mt_repair_invoices%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_invoice is null or p_reason is null or length(btrim(p_reason)) not between 1 and 300 then raise exception 'Invalid claim' using errcode='22023';end if;
 select * into c from public.mt_warranty_claims where store_id=p_store and request_id=p_request;
 if found then
  if c.actor<>auth.uid() or c.invoice_id<>p_invoice or c.reason<>btrim(p_reason) then raise exception 'Conflicting claim' using errcode='22023';end if;return c.id;
 end if;
 select * into v from public.mt_repair_invoices where store_id=p_store and id=p_invoice;
 if not found or v.warranty_days=0 or v.warranty_until<(now() at time zone 'Asia/Damascus')::date or tenant_private.repair_fully_refunded(p_store,p_invoice) then raise exception 'Warranty unavailable' using errcode='22023';end if;
 if exists(select 1 from public.mt_warranty_claims where store_id=p_store and invoice_id=p_invoice and state in ('open','accepted')) then raise exception 'An active warranty claim already exists' using errcode='22023';end if;
 insert into public.mt_warranty_claims(store_id,request_id,invoice_id,reason,actor) values(p_store,p_request,p_invoice,btrim(p_reason),auth.uid()) returning * into c;return c.id;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.warranty_part(p_store uuid, p_request uuid, p_claim uuid, p_product uuid, p_units bigint, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 if tenant_private.repair_fully_refunded(p_store,v.id) then raise exception 'Fully refunded repair has no active warranty' using errcode='22023';end if;
 select branch_id into fifo_branch from tenant_private.branch_repairs where store_id=p_store and repair_id=v.repair_id;
 if fifo_branch is not null and not exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then raise exception 'Activate branch FIFO before consuming warranty parts' using errcode='22023';end if;
 if fifo_branch is null and coalesce(tenant_private.main_available(p_store,p_product),0)<p_units then raise exception 'Insufficient warranty stock at central location' using errcode='22023';end if;
 if fifo_branch is not null then
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
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.warranty_transition(p_store uuid, p_request uuid, p_claim uuid, p_next text, p_note text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 if p_next='accepted' and tenant_private.repair_fully_refunded(p_store,c.invoice_id) then raise exception 'Fully refunded repair has no active warranty' using errcode='22023';end if;
 update public.mt_warranty_claims set state=p_next where store_id=p_store and id=p_claim;
 insert into public.mt_warranty_events(store_id,request_id,claim_id,prior_state,next_state,note,actor) values(p_store,p_request,p_claim,c.state,p_next,btrim(p_note),auth.uid());return p_next;
end $function$
;

create function tenant_private.repair_warranty_register(s uuid,q text,filter_state text,off integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if q is null or length(q)>120 or filter_state is null or filter_state not in ('all','active','expired','refunded','none') or off is null or off not between 0 and 100000 then raise exception 'Invalid warranty search' using errcode='22023';end if;
 with data as (
  select i.id,i.repair_id,i.currency,i.total_minor,i.warranty_days,i.warranty_until,i.created_at,r.device,r.imei,c.name customer_name,b.branch_id,coalesce(br.name,'') branch_name,
  f.refunded_minor,cl.claim_count,cl.active_claims,
  case when i.warranty_days=0 then 'none' when i.total_minor>0 and f.refunded_minor>=i.total_minor then 'refunded' when i.warranty_until<(now() at time zone 'Asia/Damascus')::date then 'expired' else 'active' end coverage
  from public.mt_repair_invoices i
  join public.mt_repairs r on r.store_id=i.store_id and r.id=i.repair_id
  join public.mt_customers c on c.store_id=r.store_id and c.id=r.customer_id
  left join tenant_private.branch_repairs b on b.store_id=r.store_id and b.repair_id=r.id
  left join tenant_private.branches br on br.store_id=b.store_id and br.id=b.branch_id
  cross join lateral (select coalesce(sum(amount_minor),0)::bigint refunded_minor from public.mt_repair_refunds where store_id=i.store_id and invoice_id=i.id) f
  cross join lateral (select count(*) claim_count,count(*) filter(where state in ('open','accepted')) active_claims from public.mt_warranty_claims where store_id=i.store_id and invoice_id=i.id) cl
  where i.store_id=s and (btrim(q)='' or strpos(lower(i.id::text),lower(btrim(q)))>0 or strpos(lower(r.id::text),lower(btrim(q)))>0 or strpos(lower(r.device),lower(btrim(q)))>0 or strpos(coalesce(r.imei,''),btrim(q))>0 or strpos(lower(c.name),lower(btrim(q)))>0)
 ),page as (select * from data where filter_state='all' or coverage=filter_state order by created_at desc,id offset off limit 51)
 select coalesce(jsonb_agg(to_jsonb(page) order by created_at desc,id),'[]'::jsonb) into rows from page;
 return jsonb_build_object('rows',case when jsonb_array_length(rows)>50 then rows-50 else rows end,'more',jsonb_array_length(rows)>50);
end $$;
create function public.mt_repair_warranty_register(s uuid,q text,filter_state text,off integer)
returns jsonb language sql stable set search_path='' as $$select tenant_private.repair_warranty_register(s,q,filter_state,off)$$;
revoke all on function tenant_private.repair_warranty_register(uuid,text,text,integer),public.mt_repair_warranty_register(uuid,text,text,integer) from public,anon,authenticated;
grant execute on function tenant_private.repair_warranty_register(uuid,text,text,integer),public.mt_repair_warranty_register(uuid,text,text,integer) to authenticated;
commit;
