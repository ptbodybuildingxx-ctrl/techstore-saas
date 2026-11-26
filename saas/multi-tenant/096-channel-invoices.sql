-- Attach invoice details to canonical online, guest and exchange sales in the same transaction.
begin;
create function tenant_private.snapshot_channel_invoice(s uuid,sid uuid,channel text,source_id uuid,meta jsonb,known_name text,known_phone text) returns void language plpgsql security definer set search_path='' as $$
declare a public.mt_sales%rowtype;ln jsonb;w jsonb:='[]';doc jsonb;payload jsonb;result jsonb;pid uuid;m integer;serial text;title text;customer text;phone text;terms text;issued date;cnt integer;
begin
 select * into strict a from public.mt_sales where store_id=s and id=sid;
 if a.actor<>auth.uid() or channel not in ('online','guest','tradein') or source_id is null then raise exception 'Invalid invoice source';end if;
 issued:=(a.created_at at time zone 'Asia/Damascus')::date;
 select count(*) into cnt from public.mt_sale_lines where store_id=s and sale_id=sid;
 if cnt not between 1 and 100 then raise exception 'Invalid invoice lines';end if;
 payload:=jsonb_build_object('channel',channel,'source',source_id,'meta',meta);
 if meta is null then
  title:='';customer:='';phone:='';terms:='';
  select jsonb_agg(jsonb_build_object('product_id',product_id,'months',0,'serial','','until',null) order by product_id) into w from public.mt_sale_lines where store_id=s and sale_id=sid;
 else
  if jsonb_typeof(meta) is distinct from 'object' or octet_length(meta::text)>40000 or (select count(*) from jsonb_object_keys(meta))<>5 or not(meta ?& array['title','customer','phone','terms','lines']) or jsonb_typeof(meta->'title') is distinct from 'string' or jsonb_typeof(meta->'customer') is distinct from 'string' or jsonb_typeof(meta->'phone') is distinct from 'string' or jsonb_typeof(meta->'terms') is distinct from 'string' or jsonb_typeof(meta->'lines') is distinct from 'array' or jsonb_array_length(meta->'lines')<>cnt then raise exception 'Invalid invoice metadata';end if;
  title:=btrim(meta->>'title');customer:=btrim(meta->>'customer');phone:=btrim(meta->>'phone');terms:=btrim(meta->>'terms');
  if length(title)>100 or length(customer)>160 or length(phone)>100 or length(terms)>1000 then raise exception 'Invalid invoice details';end if;
  for ln in select value from jsonb_array_elements(meta->'lines') loop
   if jsonb_typeof(ln) is distinct from 'object' or (select count(*) from jsonb_object_keys(ln))<>3 or not(ln ?& array['product_id','months','serial']) or jsonb_typeof(ln->'product_id') is distinct from 'string' or jsonb_typeof(ln->'months') is distinct from 'number' or jsonb_typeof(ln->'serial') is distinct from 'string' or coalesce(ln->>'months','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid warranty line';end if;
   pid:=(ln->>'product_id')::uuid;m:=(ln->>'months')::integer;serial:=btrim(ln->>'serial');
   if pid is null or m not between 0 and 120 or length(serial)>150 or not exists(select 1 from public.mt_sale_lines where store_id=s and sale_id=sid and product_id=pid) or exists(select 1 from jsonb_array_elements(w) x where (x->>'product_id')::uuid=pid) then raise exception 'Invalid warranty line';end if;
   w:=w||jsonb_build_array(jsonb_build_object('product_id',pid,'months',m,'serial',serial,'until',case when m>0 then (issued+make_interval(months=>m))::date else null end));
  end loop;
 end if;
 if known_name is not null then customer:=known_name;end if;
 if known_phone is not null then phone:=known_phone;end if;
 doc:=jsonb_build_object('title',title,'customer',customer,'phone',phone,'terms',terms,'lines',w,'issued',issued,'channel',channel,'source',source_id);
 result:=jsonb_build_object('id',a.id,'number',a.number,'currency',a.currency,'total_minor',a.total_minor,'request_id',a.request_id);
 insert into tenant_private.sale_invoice_details values(s,sid,a.request_id,auth.uid(),payload,doc,result,now());
end $$;
create function tenant_private.channel_invoice_retry(s uuid,sid uuid,channel text,source_id uuid,meta jsonb) returns void language plpgsql stable security definer set search_path='' as $$
begin
 if meta is not null and not exists(select 1 from tenant_private.sale_invoice_details where store_id=s and sale_id=sid and actor=auth.uid() and payload=jsonb_build_object('channel',channel,'source',source_id,'meta',meta)) then raise exception 'Conflicting invoice metadata or historical sale';end if;
end $$;
CREATE OR REPLACE FUNCTION tenant_private.finish_order_with_invoice(p_store uuid, p_order uuid, p_action text,p_meta jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.mt_online_orders%rowtype;r jsonb;is_owner boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_action is null or p_action not in ('cancel','fulfill') then raise exception 'Invalid action' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 is_owner:=coalesce(tenant_private.member_role(p_store)='owner',false);
 select * into o from public.mt_online_orders where store_id=p_store and id=p_order for update;
 if not found or not (is_owner or o.buyer=auth.uid()) then raise exception 'Order access denied' using errcode='42501';end if;
 if p_action='fulfill' then
  if not is_owner then raise exception 'Owner required' using errcode='42501';end if;
  perform tenant_private.owner_write(p_store);
  if o.state='fulfilled' then perform tenant_private.channel_invoice_retry(p_store,o.sale_id,'online',p_order,p_meta);return o.sale_id;end if;
  if o.state<>'pending' then raise exception 'Order not pending' using errcode='22023';end if;
  if o.delivery_method='delivery' and o.delivery_state<>'dispatched' then raise exception 'Dispatch delivery first' using errcode='22023';end if;
  delete from tenant_private.order_reservations where store_id=p_store and order_id=p_order;
  -- Owner confirms actual cash at pickup or delivery; current stock and quoted price checked by core.
  if exists(select 1 from tenant_private.order_discounts where store_id=p_store and order_id=p_order) then r:=tenant_private.record_discounted_order_sale(p_store,p_order);else r:=tenant_private.record_currency_sale(p_store,gen_random_uuid(),o.currency,o.lines);end if;
  perform tenant_private.snapshot_channel_invoice(p_store,(r->>'id')::uuid,'online',p_order,p_meta,null,nullif(o.delivery_phone,''));
  update public.mt_online_orders set state='fulfilled',delivery_state=case when delivery_method='delivery' then 'delivered' else null end,sale_id=(r->>'id')::uuid,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
  return (r->>'id')::uuid;
 end if;
 if p_meta is not null then raise exception 'Cancellation cannot issue invoice';end if;
 if o.state='cancelled' then return null;end if;
 if o.state<>'pending' then raise exception 'Completed order cannot be cancelled' using errcode='22023';end if;
 if o.delivery_state='dispatched' then raise exception 'Owner must confirm physical return before cancellation' using errcode='22023';end if;
 update public.mt_online_orders set state='cancelled',delivery_state=case when delivery_method='delivery' then 'cancelled' else null end,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
 return null;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.guest_finish_with_invoice(p_store uuid, p_id uuid, p_action text, p_confirm boolean,p_meta jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o tenant_private.guest_orders%rowtype;r jsonb;sid uuid;begin
 perform tenant_private.owner_write(p_store);
 if p_action is null or p_action not in ('cancel','fulfill') or p_confirm is distinct from true then raise exception 'Confirm action' using errcode='22023';end if;
 select * into o from tenant_private.guest_orders where store_id=p_store and id=p_id for update;
 if not found then raise exception 'Unknown order' using errcode='22023';end if;
 if p_action='cancel' and p_meta is not null then raise exception 'Cancellation cannot issue invoice';end if;
 if o.state='fulfilled' and p_action='fulfill' then perform tenant_private.channel_invoice_retry(p_store,o.sale_id,'guest',p_id,p_meta);return p_id;end if;
 if o.state='cancelled' and p_action='cancel' then return p_id;end if;
 if o.state<>'pending' then raise exception 'Order already closed' using errcode='22023';end if;
 if p_action='fulfill' then
 if exists(select 1 from public.mt_sales where store_id=p_store and request_id=p_id) then raise exception 'Conflicting sale request' using errcode='22023';end if;
 r:=tenant_private.record_currency_sale(p_store,p_id,o.currency,o.lines);sid:=(r->>'id')::uuid;
 if (r->>'total_minor')::bigint<>o.total_minor then raise exception 'Order total changed' using errcode='22023';end if;
 perform tenant_private.snapshot_channel_invoice(p_store,sid,'guest',p_id,p_meta,o.customer_name,o.phone);
 end if;
 update tenant_private.guest_orders set state=case when p_action='fulfill' then 'fulfilled' else 'cancelled' end,sale_id=sid,finished_at=now() where store_id=p_store and id=p_id;return p_id;
end
$function$;
CREATE OR REPLACE FUNCTION tenant_private.tradein_execute_with_invoice(p_store uuid, p_request uuid, p_id uuid, p_used_product uuid, p_currency text, p_lines jsonb, p_difference bigint, p_confirm boolean,p_meta jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e tenant_private.tradein_estimates%rowtype;prior tenant_private.tradein_settlements%rowtype;c public.mt_customers%rowtype;sup uuid;buy uuid;sale jsonb;sid uuid;debt uuid;dp uuid;sp uuid;total bigint;off bigint;today date:=(now() at time zone 'UTC')::date;
begin
 perform tenant_private.owner_write(p_store);
 perform 1 from public.saas_stores where id=p_store for update;
 if p_request is null or p_id is null or p_used_product is null or p_currency is null or p_difference is null or p_confirm is distinct from true or jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>30000 then raise exception 'Invalid confirmed settlement' using errcode='22023';end if;
 select * into prior from tenant_private.tradein_settlements where store_id=p_store and id=p_id;
 if found then
 if prior.request_id<>p_request or prior.actor<>auth.uid() or prior.used_product_id<>p_used_product or prior.currency<>p_currency or prior.lines is distinct from p_lines or prior.cash_difference_minor<>p_difference then raise exception 'Conflicting settlement' using errcode='22023';end if;
 perform tenant_private.channel_invoice_retry(p_store,prior.sale_id,'tradein',p_id,p_meta);return p_id;
 end if;
 select * into e from tenant_private.tradein_estimates where store_id=p_store and id=p_id for update;
 if not found or e.state<>'accepted' or e.currency<>p_currency or e.amount_minor>100000000 then raise exception 'Accepted matching estimate required' using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_lines) x where x->>'product_id'=p_used_product::text) then raise exception 'Used device cannot be sold in the same exchange' using errcode='22023';end if;
 if not exists(select 1 from public.mt_products where store_id=p_store and id=p_used_product) then raise exception 'Unknown used product' using errcode='22023';end if;
 if exists(select 1 from public.mt_sales where store_id=p_store and request_id=p_request) then raise exception 'Sale request already used' using errcode='22023';end if;
 -- Credit sale engine validates actual prices and available stock before any intake.
 if e.branch_id is null then sale:=tenant_private.record_credit_sale(p_store,p_request,p_currency,p_lines,e.customer_id,0,1,today);
 else sale:=tenant_private.branch_credit_sale(p_store,e.branch_id,p_request,p_currency,p_lines,e.customer_id,0,1,today);end if;
 sid:=(sale->>'id')::uuid;total:=(sale->>'total_minor')::bigint;
 if total-e.amount_minor<>p_difference then raise exception 'Confirmed difference changed' using errcode='22023';end if;
 select id into strict debt from public.mt_debts where store_id=p_store and sale_id=sid;
 select supplier_id into sup from tenant_private.tradein_suppliers where store_id=p_store and customer_id=e.customer_id;
 if not found then
 select * into strict c from public.mt_customers where store_id=p_store and id=e.customer_id;
 sup:=tenant_private.add_supplier(p_store,gen_random_uuid(),left('استبدال: '||c.name,160),c.phone);
 insert into tenant_private.tradein_suppliers values(p_store,e.customer_id,sup);
 end if;
 if e.branch_id is null then buy:=tenant_private.purchase(p_store,gen_random_uuid(),sup,p_used_product,p_currency,1,e.amount_minor,0,'Trade-in '||p_id::text);
 else buy:=tenant_private.branch_purchase(p_store,e.branch_id,gen_random_uuid(),sup,p_used_product,p_currency,1,e.amount_minor,0,'Trade-in '||p_id::text);end if;
 off:=least(total,e.amount_minor);
 insert into public.mt_debt_payments(store_id,debt_id,request_id,amount_minor,actor,settlement_method) values(p_store,debt,gen_random_uuid(),off,auth.uid(),'tradein_offset') returning id into dp;
 update public.mt_installments set paid_minor=paid_minor+off where store_id=p_store and debt_id=debt and number=1;
 insert into public.mt_payment_allocations(store_id,payment_id,debt_id,installment_number,amount_minor) values(p_store,dp,debt,1,off);
 update public.mt_debts set remaining_minor=remaining_minor-off where store_id=p_store and id=debt;
 insert into public.mt_supplier_payments(store_id,request_id,purchase_id,amount_minor,actor,settlement_method) values(p_store,gen_random_uuid(),buy,off,auth.uid(),'tradein_offset') returning id into sp;
 update public.mt_purchases set paid_minor=paid_minor+off where store_id=p_store and id=buy;
 if p_difference>0 then perform tenant_private.pay_debt(p_store,debt,gen_random_uuid(),p_currency,p_difference);
 elsif p_difference<0 then perform tenant_private.pay_supplier(p_store,gen_random_uuid(),buy,p_currency,-p_difference);end if;
 insert into tenant_private.tradein_settlements(store_id,id,request_id,actor,used_product_id,lines,purchase_id,sale_id,debt_payment_id,supplier_payment_id,currency,estimate_minor,sale_minor,offset_minor,cash_difference_minor) values(p_store,p_id,p_request,auth.uid(),p_used_product,p_lines,buy,sid,dp,sp,p_currency,e.amount_minor,total,off,p_difference);
 select * into strict c from public.mt_customers where store_id=p_store and id=e.customer_id;
 perform tenant_private.snapshot_channel_invoice(p_store,sid,'tradein',p_id,p_meta,c.name,c.phone);
 update tenant_private.tradein_estimates set state='settled',purchase_id=buy,sale_id=sid where store_id=p_store and id=p_id;
 return p_id;
end $function$;

create or replace function tenant_private.finish_order(p_store uuid,p_order uuid,p_action text) returns uuid language sql security definer set search_path='' as $$select tenant_private.finish_order_with_invoice(p_store,p_order,p_action,null)$$;
create or replace function tenant_private.guest_finish(p_store uuid,p_id uuid,p_action text,p_confirm boolean) returns uuid language sql security definer set search_path='' as $$select tenant_private.guest_finish_with_invoice(p_store,p_id,p_action,p_confirm,null)$$;
create or replace function tenant_private.tradein_execute(p_store uuid,p_request uuid,p_id uuid,p_used_product uuid,p_currency text,p_lines jsonb,p_difference bigint,p_confirm boolean) returns uuid language sql security definer set search_path='' as $$select tenant_private.tradein_execute_with_invoice(p_store,p_request,p_id,p_used_product,p_currency,p_lines,p_difference,p_confirm,null)$$;
create function public.mt_finish_order_invoice(p_store uuid,p_order uuid,p_action text,p_meta jsonb) returns uuid language sql security invoker set search_path='' as $$select tenant_private.finish_order_with_invoice(p_store,p_order,p_action,p_meta)$$;
create function public.mt_guest_finish_invoice(p_store uuid,p_id uuid,p_action text,p_confirm boolean,p_meta jsonb) returns uuid language sql security invoker set search_path='' as $$select tenant_private.guest_finish_with_invoice(p_store,p_id,p_action,p_confirm,p_meta)$$;
create function public.mt_tradein_execute_invoice(p_store uuid,p_request uuid,p_id uuid,p_used_product uuid,p_currency text,p_lines jsonb,p_difference bigint,p_confirm boolean,p_meta jsonb) returns uuid language sql security invoker set search_path='' as $$select tenant_private.tradein_execute_with_invoice(p_store,p_request,p_id,p_used_product,p_currency,p_lines,p_difference,p_confirm,p_meta)$$;
revoke all on function tenant_private.snapshot_channel_invoice(uuid,uuid,text,uuid,jsonb,text,text),tenant_private.channel_invoice_retry(uuid,uuid,text,uuid,jsonb),tenant_private.finish_order_with_invoice(uuid,uuid,text,jsonb),tenant_private.guest_finish_with_invoice(uuid,uuid,text,boolean,jsonb),tenant_private.tradein_execute_with_invoice(uuid,uuid,uuid,uuid,text,jsonb,bigint,boolean,jsonb),public.mt_finish_order_invoice(uuid,uuid,text,jsonb),public.mt_guest_finish_invoice(uuid,uuid,text,boolean,jsonb),public.mt_tradein_execute_invoice(uuid,uuid,uuid,uuid,text,jsonb,bigint,boolean,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.finish_order_with_invoice(uuid,uuid,text,jsonb),tenant_private.guest_finish_with_invoice(uuid,uuid,text,boolean,jsonb),tenant_private.tradein_execute_with_invoice(uuid,uuid,uuid,uuid,text,jsonb,bigint,boolean,jsonb),public.mt_finish_order_invoice(uuid,uuid,text,jsonb),public.mt_guest_finish_invoice(uuid,uuid,text,boolean,jsonb),public.mt_tradein_execute_invoice(uuid,uuid,uuid,uuid,text,jsonb,bigint,boolean,jsonb) to authenticated;
commit;
