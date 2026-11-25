
alter table public.ts_business_entries drop constraint ts_business_entries_kind_check;
alter table public.ts_business_entries add constraint ts_business_entries_kind_check check(kind in ('invoice','initial_payment','receipt','expense','cash_in','cost','refund','cost_reverse','debt_cancel','purchase','supplier_payment','branch_sale','branch_cost','branch_transfer','payroll_accrual','payroll_payment','branch_refund','branch_cost_reverse','legacy_opening','legacy_payment'));
create or replace function techstore_private.legacy_finance(p_action text,p_kind text,p_args jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; req uuid; target uuid; val numeric; paid numeric; rec jsonb; rows jsonb; payments jsonb; row_value jsonb; entry jsonb; clean jsonb; old_payment jsonb; prior public.ts_business_entries%rowtype; direction text; due text; n integer; cash_expected numeric; cap text;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501'; end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or u.role not in ('admin','cashier') or p_kind is null or p_kind not in ('debts','installments') or p_action is null or p_action not in ('create','pay') then raise exception 'Access denied' using errcode='42501';end if;
 cap:=case p_kind when 'debts' then 'debt' else 'installment' end;
 if u.role<>'admin' and (not techstore_private.staff_allowed(u.user_id,cap||'_write') or not techstore_private.staff_allowed(u.user_id,cap||'_read')) then raise exception 'Operation permission denied' using errcode='42501';end if;
 req:=(p_args->>'request_id')::uuid;val:=(p_args->>'amount')::numeric;
 if req is null or val is null or val<=0 or val>1000000000000 or val<>round(val,2) then raise exception 'Invalid request or USD amount';end if;
 select * into w from public.ts_workspace where id=1 for update;if not found then raise exception 'Workspace unavailable';end if;
 rec:=coalesce(w.payload->'records','{}');rows:=coalesce(rec->p_kind,'[]');payments:=coalesce(rec->'payments','[]');
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 select * into prior from public.ts_business_entries where request_id=req;
 if p_action='create' then
  direction:=case when p_kind='installments' then 'receivable' else p_args->>'direction' end;
  if direction is null or direction not in ('receivable','payable') or length(btrim(coalesce(p_args->>'name',''))) not between 1 and 1000 then raise exception 'Invalid party or debt direction';end if;
  due:=coalesce(p_args->>'due','');if due<>'' then if due !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Invalid due date';end if;perform due::date;end if;
  clean:=jsonb_build_object('name',btrim(p_args->>'name'),'amount',val,'due',due,'notes',left(btrim(coalesce(p_args->>'notes','')),1000));
  if p_kind='debts' then clean:=clean||jsonb_build_object('direction',direction);else n:=(p_args->>'count')::integer;if n is null or n not between 1 and 120 then raise exception 'Invalid installment count';end if;clean:=clean||jsonb_build_object('count',n);end if;
  select x into row_value from jsonb_array_elements(rows) x where x->>'id'=req::text;
  if prior.id is not null or row_value is not null then
   if prior.actor is distinct from u.user_id or prior.source_key is distinct from 'legacy-opening:'||p_kind||':'||req or row_value is null or (row_value-'id'-'owner'-'created'-'paid'-'actor') is distinct from clean then raise exception 'Request ID conflict';end if;
   return row_value;
  end if;
  if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day is closed';end if;
  row_value:=clean||jsonb_build_object('id',req,'owner',null,'actor',u.user_id,'created',now(),'paid',0);
  rec:=jsonb_set(rec,array[p_kind],jsonb_build_array(row_value)||rows,true);
  insert into public.ts_business_entries(request_id,actor,kind,debit,credit,amount,memo,source_key) values(req,u.user_id,'legacy_opening',case when direction='receivable' then 'receivables' else 'legacy_opening_balance' end,case when direction='receivable' then 'legacy_opening_balance' else 'legacy_payable' end,val,left('Standalone '||p_kind||' '||req,500),'legacy-opening:'||p_kind||':'||req);
 else
  target:=(p_args->>'id')::uuid;if target is null then raise exception 'Reference required';end if;
  select x into row_value from jsonb_array_elements(rows) x where x->>'id'=target::text;if not found then raise exception 'Record not found';end if;
  select x into old_payment from jsonb_array_elements(payments) x where x->>'id'=req::text;
  if prior.id is not null or old_payment is not null then
   if prior.actor is distinct from u.user_id or prior.source_key is distinct from 'legacy-payment:'||req or old_payment is null or old_payment->>'kind' is distinct from p_kind or old_payment->>'reference' is distinct from target::text or (old_payment->>'amount')::numeric is distinct from val then raise exception 'Request ID conflict';end if;
   return row_value;
  end if;
  if not exists(select 1 from public.ts_business_entries where source_key='legacy-opening:'||p_kind||':'||target and amount=(row_value->>'amount')::numeric) then raise exception 'Unreconciled historical balance; owner review required';end if;
  paid:=coalesce((row_value->>'paid')::numeric,0);
  if paid<0 or paid+val>(row_value->>'amount')::numeric then raise exception 'Exceeds balance';end if;
  if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day is closed';end if;
  direction:=case when p_kind='installments' then 'receivable' else row_value->>'direction' end;
  if direction not in ('receivable','payable') or direction is null then raise exception 'Invalid direction';end if;
  if direction='payable' then select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into cash_expected from public.ts_business_entries;if val>cash_expected then raise exception 'Insufficient recorded cash';end if;end if;
  row_value:=jsonb_set(row_value,'{paid}',to_jsonb(paid+val),true);
  select jsonb_agg(case when x->>'id'=target::text then row_value else x end order by ord) into rows from jsonb_array_elements(rows) with ordinality as a(x,ord);
  rec:=jsonb_set(rec,array[p_kind],rows,true);
  entry:=jsonb_build_object('id',req,'owner',null,'actor',u.user_id,'created',now(),'kind',p_kind,'reference',target,'amount',val);
  rec:=jsonb_set(rec,'{payments}',jsonb_build_array(entry)||payments,true);
  insert into public.ts_business_entries(request_id,actor,kind,debit,credit,amount,memo,source_key) values(req,u.user_id,'legacy_payment',case when direction='receivable' then 'cash' else 'legacy_payable' end,case when direction='receivable' then 'receivables' else 'cash' end,val,left('Standalone payment '||target,500),'legacy-payment:'||req);
 end if;
 update public.ts_workspace set payload=jsonb_set(w.payload,'{records}',rec,true),revision=revision+1,updated_at=now() where id=1;
 insert into public.ts_audit(actor,action) values(u.user_id,'integrated legacy finance '||p_action||' '||req);
 return row_value;
end $$;
revoke all on function techstore_private.legacy_finance(text,text,jsonb) from public,anon,authenticated;
grant execute on function techstore_private.legacy_finance(text,text,jsonb) to authenticated;
create or replace function public.ts_legacy_finance(p_action text,p_kind text,p_args jsonb) returns jsonb language sql set search_path='' as $$ select techstore_private.legacy_finance(p_action,p_kind,p_args) $$;
revoke all on function public.ts_legacy_finance(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_legacy_finance(text,text,jsonb) to authenticated;

CREATE OR REPLACE FUNCTION public.ts_commit(p_revision bigint, p_payload jsonb, p_actor uuid, p_action text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v bigint; old_payload jsonb; old_sale jsonb; sale jsonb; old_order jsonb; new_order jsonb; item jsonb; cfg public.ts_invoice_settings%rowtype; cid uuid; sid uuid; doc jsonb; lines jsonb; raw_total numeric; gross numeric; running numeric; allocated numeric; line_value numeric; qty_value bigint; unit_value numeric; original_price numeric; order_count int;
begin
 if jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Invalid payload';end if;
 select payload into old_payload from public.ts_workspace where id=1 and revision=p_revision for update;if not found then return null;end if;
 perform techstore_private.guard_legacy_write(p_actor,old_payload,p_payload);
 if exists(select 1 from unnest(array['debts','installments','payments']) k where coalesce(old_payload->'records'->k,'[]') is distinct from coalesce(p_payload->'records'->k,'[]')) then raise exception 'Use integrated legacy finance';end if;
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
end $function$
;
