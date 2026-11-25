begin;
create or replace function techstore_private.business_invoice_cost() returns trigger language plpgsql security definer set search_path='' as $$
declare amount_value numeric;
begin
 if new.kind='sale' and new.document->>'source'='web_order' then
 select coalesce(sum(round((x->>'qty')::numeric*(x->>'cost')::numeric,2)),0) into amount_value
 from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'sales','[]')) s cross join lateral jsonb_array_elements(s->'items') x where w.id=1 and s->>'id'=new.id::text;
 elsif new.kind='sale' then
 select coalesce(sum(round((i->>'qty')::numeric*(p->>'cost')::numeric,2)),0) into amount_value
 from jsonb_array_elements(new.document->'items') i join public.ts_workspace w on w.id=1 cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'products','[]')) p where p->>'id'=i->>'product';
 else select coalesce(sum(round(qty*unit_cost,2)),0) into amount_value from public.ts_repair_evidence where repair_id=new.repair_id and kind='part';end if;
 if amount_value>0 then insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(new.id,new.actor,'cost',case when new.kind='sale' then 'cost_of_sales' else 'repair_parts_cost' end,'inventory',amount_value,'INV-'||new.number);end if;
 return new;
end $$;
create or replace function public.ts_commit(p_revision bigint,p_payload jsonb,p_actor uuid,p_action text) returns bigint language plpgsql security invoker set search_path='' as $$
declare v bigint; old_payload jsonb; old_sale jsonb; sale jsonb; old_order jsonb; new_order jsonb; item jsonb; cfg public.ts_invoice_settings%rowtype; cid uuid; sid uuid; doc jsonb; lines jsonb; raw_total numeric; gross numeric; running numeric; allocated numeric; line_value numeric; qty_value bigint; unit_value numeric; original_price numeric; order_count int;
begin
 if jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Invalid payload';end if;
 select payload into old_payload from public.ts_workspace where id=1 and revision=p_revision for update;if not found then return null;end if;
 if coalesce(p_payload->'records'->'purchases','[]') is distinct from coalesce(old_payload->'records'->'purchases','[]') then raise exception 'Use integrated purchase workflow; refresh app';end if;
 -- Existing financial sales are immutable via the legacy snapshot API. Adjustments use their own transactional path.
 for old_sale in select value from jsonb_array_elements(coalesce(old_payload->'data'->'sales','[]')) loop
 if not exists(select 1 from jsonb_array_elements(coalesce(p_payload->'data'->'sales','[]')) x where x=old_sale) then raise exception 'Existing sale cannot be altered by snapshot';end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(coalesce(p_payload->'data'->'sales','[]')) x group by x->>'id' having count(*)>1 or x->>'id' is null) then raise exception 'Duplicate or missing sale identifier';end if;
 -- All new sales entering via this legacy service RPC must be a confirmed order delivery.
 for sale in select x from jsonb_array_elements(coalesce(p_payload->'data'->'sales','[]')) x where not exists(select 1 from jsonb_array_elements(coalesce(old_payload->'data'->'sales','[]')) o where o->>'id'=x->>'id') loop
 if sale->>'number' not like 'WEB-%' or not exists(select 1 from public.ts_profiles where user_id=p_actor and active and role in ('admin','cashier')) then raise exception 'Use integrated invoice workflow; refresh app';end if;
 select x into old_order from jsonb_array_elements(coalesce(old_payload->'records'->'orders','[]')) x where x->>'id'=sale->>'id';
 select x into new_order from jsonb_array_elements(coalesce(p_payload->'records'->'orders','[]')) x where x->>'id'=sale->>'id';
 if old_order->>'status' is distinct from 'confirmed' or new_order->>'status' is distinct from 'delivered' or sale->'items' is distinct from old_order->'items' or sale->'total' is distinct from old_order->'total' or sale->'cost' is distinct from old_order->'cost' or sale->'paid' is distinct from 'true'::jsonb then raise exception 'Invalid order delivery sale';end if;
 end loop;
 update public.ts_workspace set payload=p_payload,revision=revision+1,updated_at=now() where id=1 and revision=p_revision returning revision into v;
 for sale in select x from jsonb_array_elements(coalesce(p_payload->'data'->'sales','[]')) x where not exists(select 1 from jsonb_array_elements(coalesce(old_payload->'data'->'sales','[]')) o where o->>'id'=x->>'id') loop
 sid:=(sale->>'id')::uuid;select x into old_order from jsonb_array_elements(coalesce(old_payload->'records'->'orders','[]')) x where x->>'id'=sale->>'id';
 select * into cfg from public.ts_invoice_settings where id=1;
 cid:=nullif(old_order->>'owner','')::uuid;if cid is not null and not exists(select 1 from public.ts_profiles where user_id=cid and role='customer') then cid:=null;end if;
 if jsonb_typeof(sale->'items') is distinct from 'array' then raise exception 'Invalid order items';end if;
 order_count:=jsonb_array_length(sale->'items');if order_count not between 1 and 30 then raise exception 'Order invoice supports up to 30 items';end if;
 if exists(select 1 from jsonb_array_elements(sale->'items') x group by x->>'id' having count(*)>1 or x->>'id' is null) then raise exception 'Duplicate order item';end if;
 if exists(select 1 from jsonb_array_elements(sale->'items') x where (x->>'qty')::bigint is null or (x->>'qty')::bigint not between 1 and 1000000 or (x->>'price')::numeric is null or (x->>'price')::numeric<0 or (x->>'cost')::numeric is null or (x->>'cost')::numeric<0) then raise exception 'Invalid order amount';end if;
 select coalesce(sum((x->>'qty')::numeric*(x->>'price')::numeric),0) into raw_total from jsonb_array_elements(sale->'items') x;
 gross:=round((sale->>'total')::numeric,2);if gross is null or gross<0 or gross>round(raw_total,2) then raise exception 'Invalid order total';end if;
 lines:='[]';running:=0;allocated:=0;
 for item in select value from jsonb_array_elements(sale->'items') loop
 qty_value:=(item->>'qty')::bigint;original_price:=(item->>'price')::numeric;running:=running+qty_value*original_price;
 line_value:=case when raw_total=0 then 0 else round(gross*running/raw_total,2)-allocated end;
 allocated:=allocated+line_value;unit_value:=round(line_value/qty_value,8);
 lines:=lines||jsonb_build_array(jsonb_build_object('product',item->>'id','name',item->>'name','qty',qty_value,'price',unit_value,'total',line_value,'serial','','warranty_months',0,'warranty_end',null));
 end loop;
 if allocated<>gross then raise exception 'Order discount allocation failed';end if;
 doc:=jsonb_build_object('store_name',cfg.store_name,'store_phone',cfg.phone,'store_address',cfg.address,'title',cfg.sale_title,'footer',cfg.footer,'date',(sale->>'date')::date,'customer',coalesce(old_order->>'customer',''),'phone',coalesce(old_order->>'phone',''),'items',lines,'total',gross,'paid',gross,'currency','USD','warranty_terms','','payment_mode','cash','source','web_order','order_id',sid,'installment_count',0);
 insert into public.ts_invoices(id,request_id,actor,customer_id,kind,document,request_args) values(sid,sid,p_actor,cid,'sale',doc,jsonb_build_object('source','web_order','order_id',sid));
 end loop;
 insert into public.ts_audit(actor,action,revision) values(p_actor,left(p_action,200),v);return v;
end $$;
revoke all on function public.ts_commit(bigint,jsonb,uuid,text) from public,anon,authenticated;
grant execute on function public.ts_commit(bigint,jsonb,uuid,text) to service_role;
commit;