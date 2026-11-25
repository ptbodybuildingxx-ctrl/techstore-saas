begin;
alter table public.ts_staff_capabilities drop constraint ts_staff_capabilities_capability_check;
alter table public.ts_staff_capabilities add constraint ts_staff_capabilities_capability_check check(capability in ('invoice_sale','invoice_repair','receipt','repair_intake','supplier_read','inventory_write','purchase_write','supplier_write','orders_write','repair_write','warranty_write','debt_write','installment_write','used_write'));
create function techstore_private.guard_legacy_write(p_actor uuid,p_old jsonb,p_new jsonb) returns void language plpgsql security definer set search_path='' as $$
declare r text; k text; cap text; allowed text[]; before_rows jsonb; after_rows jsonb;
begin
 select role into r from public.ts_profiles where user_id=p_actor and active;
 if r is null then raise exception 'Inactive account' using errcode='42501';end if;
 if r='admin' then return;end if;
 allowed:=case r when 'cashier' then array['orders','repairs','warranty','debts','installments','payments','notifications','loyalty','returns'] when 'stock' then array['suppliers','inventory','used'] when 'tech' then array['repairs','warranty','notifications'] when 'customer' then array['orders','notifications'] else array[]::text[] end;
 for k in select key from jsonb_object_keys(coalesce(p_old->'records','{}')||coalesce(p_new->'records','{}')) key loop
 before_rows:=coalesce(p_old->'records'->k,'[]');after_rows:=coalesce(p_new->'records'->k,'[]');
 if before_rows is not distinct from after_rows then continue;end if;
 if not(k=any(allowed)) then raise exception 'Record permission denied: %',k using errcode='42501';end if;
 cap:=case k when 'orders' then 'orders_write' when 'repairs' then 'repair_write' when 'warranty' then 'warranty_write' when 'inventory' then 'inventory_write' when 'suppliers' then 'supplier_write' when 'used' then 'used_write' when 'debts' then 'debt_write' when 'installments' then 'installment_write' else null end;
 if cap is not null and r<>'customer' and not techstore_private.staff_allowed(p_actor,cap) then raise exception 'Operation permission denied: %',cap using errcode='42501';end if;
 if k='returns' then raise exception 'Use integrated return workflow';end if;
 if k='orders' and r='customer' then raise exception 'Use integrated customer checkout';end if;
 end loop;
 if (coalesce(p_old->'data','{}')-'products'-'stockMoves'-'sales') is distinct from (coalesce(p_new->'data','{}')-'products'-'stockMoves'-'sales') then raise exception 'Workspace edit denied' using errcode='42501';end if;
 if coalesce(p_old->'data'->'products','[]') is distinct from coalesce(p_new->'data'->'products','[]') then
 if r='stock' and not techstore_private.staff_allowed(p_actor,'inventory_write') or r='cashier' and not techstore_private.staff_allowed(p_actor,'orders_write') or r not in ('stock','cashier') then raise exception 'Stock permission denied' using errcode='42501';end if;
 end if;
end $$;
revoke all on function techstore_private.guard_legacy_write(uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function techstore_private.guard_legacy_write(uuid,jsonb,jsonb) to service_role;
create function techstore_private.guard_supplier_purchase() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.ts_profiles where user_id=new.actor and role='stock') and not techstore_private.staff_allowed(new.actor,'purchase_write') then raise exception 'Purchase permission denied' using errcode='42501';end if;return new;
end $$;
revoke all on function techstore_private.guard_supplier_purchase() from public,anon,authenticated;
create trigger ts_guard_supplier_purchase before insert on public.ts_supplier_bills for each row execute function techstore_private.guard_supplier_purchase();
create or replace function public.ts_commit(p_revision bigint,p_payload jsonb,p_actor uuid,p_action text) returns bigint language plpgsql security invoker set search_path='' as $$
declare v bigint; old_payload jsonb; old_sale jsonb; sale jsonb; old_order jsonb; new_order jsonb; item jsonb; cfg public.ts_invoice_settings%rowtype; cid uuid; sid uuid; doc jsonb; lines jsonb; raw_total numeric; gross numeric; running numeric; allocated numeric; line_value numeric; qty_value bigint; unit_value numeric; original_price numeric; order_count int;
begin
 if jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Invalid payload';end if;
 select payload into old_payload from public.ts_workspace where id=1 and revision=p_revision for update;if not found then return null;end if;
 perform techstore_private.guard_legacy_write(p_actor,old_payload,p_payload);
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

create or replace function techstore_private.sync_operation(p_action text,p_args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; prior public.ts_sync_receipts%rowtype;
 req uuid; pid text; k text; q bigint; src uuid; dst uuid; prod jsonb; ix int; central bigint; actual bigint; actual_dst bigint; price_value numeric; cost_value numeric; expected bigint; expected_dst bigint; expected_price numeric; result jsonb; data_value jsonb; records_value jsonb; sale_id uuid; sale jsonb; delta bigint; amount numeric;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found or u.role not in ('admin','cashier','stock') then raise exception 'Access denied' using errcode='42501';end if;
 if p_action not in ('snapshot','apply') or jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>12000 then raise exception 'Invalid request';end if;
 select * into w from public.ts_workspace where id=1 for update;
 if p_action='snapshot' then
 return jsonb_build_object('role',u.role,'revision',w.revision,'captured_at',now(),
 'products',coalesce((select jsonb_agg(jsonb_build_object('id',p->>'id','name',left(p->>'name',200),'sku',left(p->>'sku',100),'qty',p->'qty','price',p->'price')) from jsonb_array_elements(coalesce(w.payload->'data'->'products','[]'::jsonb)) p),'[]'::jsonb),
 'branches',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title)) from public.ts_pro_entries where kind='branches' and not archived),'[]'::jsonb) else '[]'::jsonb end,
 'stock',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('branch_id',branch_id,'product_id',product_id,'qty',qty)) from public.ts_branch_stock),'[]'::jsonb) else '[]'::jsonb end);
 end if;
 req:=(p_args->>'request_id')::uuid;k:=p_args->>'kind';pid:=p_args->>'product';q:=(p_args->>'qty')::bigint;src:=nullif(p_args->>'from','')::uuid;dst:=nullif(p_args->>'to','')::uuid;
 if req is null or pid is null or length(pid)>200 or q is null or q<0 or q>1000000 or k not in ('pos','count','transfer','sale') then raise exception 'Invalid operation';end if;
 if k='count' and u.role='stock' and not techstore_private.staff_allowed(u.user_id,'inventory_write') then raise exception 'Access denied' using errcode='42501';end if;
 if (k='pos' and u.role not in ('admin','cashier')) or (k='count' and u.role not in ('admin','stock')) or (k in ('transfer','sale') and u.role<>'admin') then raise exception 'Access denied' using errcode='42501';end if;
 if k<>'count' and q=0 then raise exception 'Quantity must be positive';end if;
 if k in ('pos','count') and (src is not null or dst is not null) then raise exception 'Central operation only';end if;
 if k='sale' and (src is null or dst is not null) then raise exception 'Invalid branch sale';end if;
 if k='transfer' and src is not distinct from dst then raise exception 'Different locations required';end if;
 select * into prior from public.ts_sync_receipts where request_id=req;
 if found then if prior.actor<>u.user_id or prior.kind<>k or prior.args is distinct from p_args then raise exception 'Request ID conflict';end if;return prior.result||jsonb_build_object('duplicate',true);end if;
 data_value:=w.payload->'data';records_value:=coalesce(w.payload->'records','{}'::jsonb);
 select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(data_value->'products','[]'::jsonb)) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null then return jsonb_build_object('status','conflict','reason','product_missing');end if;
 if src is not null and not exists(select 1 from public.ts_pro_entries where id=src and kind='branches' and not archived) then return jsonb_build_object('status','conflict','reason','source_closed');end if;
 if dst is not null and not exists(select 1 from public.ts_pro_entries where id=dst and kind='branches' and not archived) then return jsonb_build_object('status','conflict','reason','destination_closed');end if;
 central:=(prod->>'qty')::bigint;price_value:=(prod->>'price')::numeric;cost_value:=(prod->>'cost')::numeric;
 actual:=case when src is null then central else coalesce((select qty from public.ts_branch_stock where branch_id=src and product_id=pid),0) end;
 actual_dst:=case when dst is null then central else coalesce((select qty from public.ts_branch_stock where branch_id=dst and product_id=pid),0) end;
 expected:=(p_args->>'expected_qty')::bigint;expected_dst:=(p_args->>'expected_dst_qty')::bigint;expected_price:=(p_args->>'expected_price')::numeric;
 if actual is distinct from expected or (k='transfer' and actual_dst is distinct from expected_dst) or (k in ('pos','sale') and price_value is distinct from expected_price) or (k<>'count' and actual<q) then
 return jsonb_build_object('status','conflict','reason','stock_or_price_changed','actual_qty',actual,'actual_dst_qty',actual_dst,'actual_price',price_value);
 end if;
 if k='pos' then
 result:=techstore_private.invoice_action('sale',jsonb_build_object('request_id',req,'items',jsonb_build_array(jsonb_build_object('product',pid,'qty',q,'expected_price',price_value,'months',0))));
 result:=jsonb_build_object('id',result->>'id','amount',result->'document'->'total');
 elsif k in ('transfer','sale') then
 result:=techstore_private.branch_operation(k,jsonb_build_object('request_id',req,'from',coalesce(src::text,''),'to',coalesce(dst::text,''),'product',pid,'qty',q));
 else
 sale_id:=gen_random_uuid();delta:=case when k='pos' then -q else q-central end;
 data_value:=jsonb_set(data_value,array['products',ix::text,'qty'],to_jsonb(central+delta));
 data_value:=jsonb_set(data_value,'{stockMoves}',coalesce(data_value->'stockMoves','[]'::jsonb)||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',pid,'name',prod->>'name','qty',delta,'reason','offline sync '||k,'date',current_date)),true);
 if k='pos' then
 amount:=round(price_value*q,2);sale:=jsonb_build_object('id',sale_id,'number','POS-'||sale_id::text,'date',current_date,'customer','','payment','cash','paid',true,'items',jsonb_build_array(jsonb_build_object('id',pid,'name',prod->>'name','qty',q,'price',price_value,'cost',cost_value)),'total',amount,'cost',round(cost_value*q,2));
 data_value:=jsonb_set(data_value,'{sales}',coalesce(data_value->'sales','[]'::jsonb)||jsonb_build_array(sale),true);
 else
 amount:=0;records_value:=jsonb_set(records_value,'{inventory}',jsonb_build_array(jsonb_build_object('id',sale_id,'owner',null,'created',now(),'product',pid,'name',prod->>'name','before',central,'qty',q,'delta',delta,'barcode',coalesce(prod->>'sku',pid)))||coalesce(records_value->'inventory','[]'::jsonb),true);
 end if;
 update public.ts_workspace set payload=jsonb_set(jsonb_set(w.payload,'{data}',data_value),'{records}',records_value),revision=revision+1,updated_at=now() where id=1;
 result:=jsonb_build_object('id',sale_id,'amount',amount);
 end if;
 result:=result||jsonb_build_object('status','applied');
 insert into public.ts_sync_receipts(request_id,actor,kind,args,result) values(req,u.user_id,k,p_args,result);
 insert into public.ts_audit(actor,action) values(u.user_id,'offline sync '||k||' '||req::text);
 return result;
end $$;


create or replace function techstore_private.repair_evidence(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; ticket jsonb; rid text; k text; image_value text; note_value text; prod jsonb; pid text; ix int; q int; cost numeric; data jsonb; item public.ts_repair_evidence%rowtype; is_staff boolean; request_value uuid;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found then raise exception 'Access denied' using errcode='42501';end if;
 is_staff:=u.role in ('admin','tech','cashier');
 select * into w from public.ts_workspace where id=1 for update;
 rid:=p_args->>'repair_id';
 if p_action='tickets' then return coalesce((select jsonb_agg(jsonb_build_object('id',r->>'id','device',r->>'device','status',r->>'status','estimate',r->>'estimate')) from jsonb_array_elements(coalesce(w.payload->'records'->'repairs','[]'::jsonb)) r where is_staff or r->>'customerId'=u.user_id::text),'[]'::jsonb);end if;
 select r into ticket from jsonb_array_elements(coalesce(w.payload->'records'->'repairs','[]'::jsonb)) r where r->>'id'=rid;
 if ticket is null or (not is_staff and ticket->>'customerId' is distinct from u.user_id::text) then raise exception 'Ticket unavailable' using errcode='42501';end if;
 if p_action='list' then return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'kind',e.kind,'image',e.image,'notes',e.notes,'product_id',e.product_id,'qty',e.qty,'created_at',e.created_at)||case when u.role='admin' then jsonb_build_object('unit_cost',e.unit_cost) else '{}'::jsonb end order by e.created_at) from public.ts_repair_evidence e where e.repair_id=rid and (is_staff or e.kind in ('before','after','approval'))),'[]'::jsonb);end if;
 k:=p_args->>'kind';note_value:=left(coalesce(p_args->>'notes',''),500);image_value:=coalesce(p_args->>'image','');
 if u.role='tech' and not techstore_private.staff_allowed(u.user_id,'repair_write') then raise exception 'Access denied' using errcode='42501';end if;
 if p_action<>'add' then raise exception 'Invalid action';end if;
 request_value:=(p_args->>'request_id')::uuid;if request_value is null then raise exception 'Request ID required';end if;
 select * into item from public.ts_repair_evidence where request_id=request_value;
 if found then if item.actor<>u.user_id or item.repair_id<>rid or item.kind is distinct from k then raise exception 'Request ID conflict';end if;return jsonb_build_object('id',item.id,'kind',item.kind,'duplicate',true);end if;
 if k='approval' then
 if u.role<>'customer' or ticket->>'customerId' is distinct from u.user_id::text or ticket->>'status' is distinct from 'approval' then raise exception 'Approval unavailable' using errcode='42501';end if;
 if (p_args->>'expected_estimate')::numeric is distinct from coalesce((ticket->>'estimate')::numeric,0) then raise exception 'Estimate changed; reload the ticket';end if;
 note_value:='Customer approved estimate USD '||coalesce(ticket->>'estimate','0');image_value:='';
 elsif k in ('before','after') then
 if u.role not in ('admin','tech') or image_value='' then raise exception 'Photo not allowed' using errcode='42501';end if;
 if (select count(*) from public.ts_repair_evidence where repair_id=rid and kind in ('before','after'))>=12 then raise exception 'Maximum 12 photos';end if;
 elsif k='part' then
 if u.role not in ('admin','tech') then raise exception 'Access denied' using errcode='42501';end if;
 pid:=p_args->>'product_id';q:=(p_args->>'qty')::int;
 data:=w.payload->'data';select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(data->'products','[]'::jsonb)) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null or q is null or q<1 or q>1000000 or (prod->>'qty')::int<q then raise exception 'Insufficient stock';end if;
 if ticket->>'status' in ('delivered','cancelled') then raise exception 'Closed ticket';end if;
 cost:=(prod->>'cost')::numeric;note_value:=left(coalesce(prod->>'name','')||' — '||note_value,500);image_value:='';
 data:=jsonb_set(data,array['products',ix::text,'qty'],to_jsonb((prod->>'qty')::int-q));
 update public.ts_workspace set payload=jsonb_set(w.payload,'{data}',data),revision=revision+1,updated_at=now() where id=1;
 else raise exception 'Invalid evidence type';end if;
 insert into public.ts_repair_evidence(repair_id,actor,kind,image,notes,product_id,qty,unit_cost,request_id) values(rid,u.user_id,k,image_value,note_value,pid,q,cost,request_value) returning * into item;
 insert into public.ts_audit(actor,action) values(u.user_id,'repair evidence '||k||' '||rid);
 return jsonb_build_object('id',item.id,'kind',item.kind);
end $$;


create or replace function techstore_private.operation_status(p_scope text,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); ref text;
begin
 if techstore_private.live_session() is distinct from true or not exists(select 1 from public.ts_profiles where user_id=u and active) then raise exception 'Access denied' using errcode='42501';end if;
 if p_request is null then raise exception 'Request required';end if;
 case p_scope
 when 'invoice:sale' then select id::text into ref from public.ts_invoices where request_id=p_request and actor=u and kind='sale';
 when 'invoice:repair' then select id::text into ref from public.ts_invoices where request_id=p_request and actor=u and kind='repair';
 when 'business:receipt' then select id::text into ref from public.ts_business_entries where request_id=p_request and actor=u and kind='receipt';
 when 'business:cash_in' then select id::text into ref from public.ts_business_entries where request_id=p_request and actor=u and kind='cash_in';
 when 'business:expense' then select id::text into ref from public.ts_business_entries where request_id=p_request and actor=u and kind='expense';
 when 'adjustment:apply' then select id::text into ref from public.ts_invoice_adjustments where request_id=p_request and actor=u;
 when 'refund:refund' then select id::text into ref from public.ts_invoice_refunds where request_id=p_request and actor=u;
 when 'supplier-finance:purchase' then select purchase_id into ref from public.ts_supplier_bills where purchase_request_id=p_request and actor=u;
 when 'supplier-finance:payment' then select id::text into ref from public.ts_supplier_payments where request_id=p_request and actor=u;
 when 'ops-branch:transfer' then select id::text into ref from public.ts_branch_events where request_id=p_request and actor=u and kind='transfer';
 when 'ops-branch:return' then select id::text into ref from public.ts_branch_events where request_id=p_request and actor=u and kind='return';
 when 'ops-branch:sale' then select id::text into ref from public.ts_branch_events where request_id=p_request and actor=u and kind='sale';
 when 'ops-repair:add' then select id::text into ref from public.ts_repair_evidence where request_id=p_request and actor=u;
 when 'ops-checkout:order' then select order_id into ref from public.ts_member_checkout_keys where request_id=p_request and user_id=u;
 else raise exception 'Unknown operation';
 end case;
 return jsonb_build_object('applied',ref is not null,'reference',ref);
end $$;

commit;