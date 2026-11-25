CREATE OR REPLACE FUNCTION techstore_private.invoice_action(p_action text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; cfg public.ts_invoice_settings%rowtype; inv public.ts_invoices%rowtype; cust uuid; req uuid; rid text; ticket jsonb; d jsonb; rec jsonb; doc jsonb; lines jsonb:='[]'; sale_lines jsonb:='[]'; line jsonb; prod jsonb; pid text; ix int; q int; months int; serial_value text; seen text[]:='{}'; total_value numeric:=0; cost_value numeric:=0; price_value numeric; labor numeric; parts numeric; customer_name text; phone_value text; issue_date date; sale_id uuid; title_value text; warranty_terms text; paid_value numeric; mode_value text:='cash'; installments_value int:=0; due_value date; pos_quote jsonb; requested_points bigint:=0; used_points bigint:=0; discount_value numeric:=0; subtotal_value numeric; running numeric:=0; allocated numeric:=0; net_line numeric; idx int; original_line jsonb;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>48000 then raise exception 'Invalid request';end if;
 select * into cfg from public.ts_invoice_settings where id=1;
 if p_action='settings' and u.role in ('admin','cashier','tech') then return to_jsonb(cfg);end if;
 if p_action='configure' then
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 update public.ts_invoice_settings set store_name=btrim(p_args->>'store_name'),phone=coalesce(p_args->>'phone',''),address=coalesce(p_args->>'address',''),sale_title=btrim(p_args->>'sale_title'),repair_title=btrim(p_args->>'repair_title'),footer=coalesce(p_args->>'footer','') where id=1 returning * into cfg;
 insert into public.ts_audit(actor,action) values(u.user_id,'invoice settings updated');return to_jsonb(cfg);
 end if;
 if p_action='list' then return coalesce((select jsonb_agg(to_jsonb(x) order by x.number desc) from (select i.id,i.number,i.kind,i.repair_id,i.created_at,i.document from public.ts_invoices i where (u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id)) and (u.role not in ('cashier','tech') or techstore_private.staff_allowed(u.user_id,case when i.kind='sale' then 'orders_read' else 'repairs_read' end)) order by i.number desc limit 100 offset greatest(0,least(100000,coalesce((p_args->>'offset')::int,0)))) x),'[]'::jsonb);end if;
 if p_action='get' then select * into inv from public.ts_invoices i where i.id=(p_args->>'id')::uuid and (u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id)) and (u.role not in ('cashier','tech') or techstore_private.staff_allowed(u.user_id,case when i.kind='sale' then 'orders_read' else 'repairs_read' end));if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;return to_jsonb(inv)-'request_args'-'request_id'-'actor'-'customer_id';end if;
 if u.role not in ('admin','cashier') or p_action not in ('sale','repair') then raise exception 'Access denied' using errcode='42501';end if;
 if u.role='cashier' and (not techstore_private.staff_allowed(u.user_id,case when p_action='sale' then 'orders_read' else 'repairs_read' end) or (p_action='sale' and not techstore_private.staff_allowed(u.user_id,'stock_read')) or (p_action='sale' and nullif(p_args->>'customer_id','') is not null and not techstore_private.staff_allowed(u.user_id,'customers_read'))) then raise exception 'Invoice read dependency denied' using errcode='42501';end if;
 req:=(p_args->>'request_id')::uuid;if req is null then raise exception 'Request ID required';end if;
 select * into w from public.ts_workspace where id=1 for update;
 select * into inv from public.ts_invoices where request_id=req;
 if found then if inv.actor<>u.user_id or inv.kind<>p_action or inv.request_args is distinct from p_args then raise exception 'Request ID conflict';end if;return to_jsonb(inv)-'request_args'-'request_id'-'actor'-'customer_id';end if;
 d:=w.payload->'data';rec:=coalesce(w.payload->'records','{}');issue_date:=(now() at time zone 'UTC')::date;
 title_value:=btrim(coalesce(p_args->>'title',case when p_action='sale' then cfg.sale_title else cfg.repair_title end));if length(title_value) not between 1 and 100 then raise exception 'Invalid title';end if;
 warranty_terms:=left(coalesce(p_args->>'warranty_terms',''),1000);
 customer_name:=left(btrim(coalesce(p_args->>'customer','')),150);phone_value:=left(coalesce(p_args->>'phone',''),100);
 if p_action='sale' then
 cust:=nullif(p_args->>'customer_id','')::uuid;
 if cust is not null then select name into customer_name from public.ts_profiles where user_id=cust and role='customer' and active;if not found then raise exception 'Invalid customer';end if;end if;
 if jsonb_typeof(p_args->'items') is distinct from 'array' then raise exception 'Invalid items';end if;
 if jsonb_array_length(p_args->'items') not between 1 and 30 then raise exception 'Invalid items';end if;
 for line in select value from jsonb_array_elements(p_args->'items') loop
 pid:=line->>'product';q:=(line->>'qty')::int;months:=coalesce((line->>'months')::int,0);serial_value:=left(coalesce(line->>'serial',''),150);
 if pid is null or pid=any(seen) or q is null or q not between 1 and 1000000 or months not between 0 and 120 then raise exception 'Invalid item';end if;seen:=array_append(seen,pid);
 select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(d->'products','[]')) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null or (prod->>'qty')::int<q then raise exception 'Insufficient stock';end if;
 price_value:=(prod->>'price')::numeric;if price_value<0 or price_value is null or price_value is distinct from (line->>'expected_price')::numeric then raise exception 'Price changed; reload';end if;
 total_value:=total_value+round(price_value*q,2);cost_value:=cost_value+round((prod->>'cost')::numeric*q,2);
 line:=jsonb_build_object('product',pid,'name',prod->>'name','qty',q,'price',price_value,'total',round(price_value*q,2),'serial',serial_value,'warranty_months',months,'warranty_end',case when months>0 then (issue_date+make_interval(months=>months))::date else null end);
 lines:=lines||jsonb_build_array(line);sale_lines:=sale_lines||jsonb_build_array(line||jsonb_build_object('id',pid,'cost',(prod->>'cost')::numeric));
 d:=jsonb_set(d,array['products',ix::text,'qty'],to_jsonb((prod->>'qty')::int-q));
 d:=jsonb_set(d,'{stockMoves}',coalesce(d->'stockMoves','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',pid,'name',prod->>'name','qty',-q,'reason','invoice sale','date',issue_date)),true);
 end loop;
 mode_value:=coalesce(p_args->>'payment_mode','cash');
 requested_points:=coalesce((p_args->>'points_requested')::bigint,0);
 if requested_points<0 then raise exception 'Invalid points';end if;
 if requested_points>0 then
  if mode_value<>'cash' then raise exception 'Points redemption is available for cash POS sales only';end if;
  subtotal_value:=total_value;
  pos_quote:=techstore_private.pos_loyalty_quote(cust,subtotal_value,requested_points);
  used_points:=(pos_quote->>'points_used')::bigint;discount_value:=(pos_quote->>'points_discount')::numeric;
  if used_points<=0 or used_points is distinct from (p_args->>'expected_points_used')::bigint or discount_value is distinct from (p_args->>'expected_points_discount')::numeric then raise exception 'Points quote changed; refresh';end if;
  total_value:=(pos_quote->>'total')::numeric;
  for idx in 0..jsonb_array_length(lines)-1 loop
   original_line:=lines->idx;
   running:=running+(original_line->>'total')::numeric;
   net_line:=round(total_value*running/subtotal_value,2)-allocated;allocated:=allocated+net_line;
   lines:=jsonb_set(lines,array[idx::text],original_line||jsonb_build_object('original_price',original_line->'price','price',round(net_line/(original_line->>'qty')::numeric,8),'total',net_line));
   sale_lines:=jsonb_set(sale_lines,array[idx::text],(sale_lines->idx)||jsonb_build_object('original_price',original_line->'price','price',round(net_line/(original_line->>'qty')::numeric,8),'total',net_line));
  end loop;
  if allocated<>total_value then raise exception 'Discount allocation failed';end if;
 end if;
 if mode_value='cash' then paid_value:=total_value;
 elsif mode_value='installment' then
 if u.role<>'admin' or cust is null then raise exception 'Owner and linked customer required for installment sale' using errcode='42501';end if;
 paid_value:=round((p_args->>'down_payment')::numeric,2);installments_value:=(p_args->>'installment_count')::int;due_value:=(p_args->>'first_due')::date;
 if paid_value is null or paid_value<0 or paid_value>=total_value or installments_value is null or installments_value not between 1 and 36 or due_value is null or due_value<issue_date or due_value>issue_date+365 or total_value-paid_value<installments_value*0.01 then raise exception 'Invalid installment terms';end if;
 else raise exception 'Invalid payment mode';end if;
 else
 rid:=p_args->>'repair_id';select x into ticket from jsonb_array_elements(coalesce(rec->'repairs','[]')) x where x->>'id'=rid;
 if ticket is null or ticket->>'status' not in ('ready','delivered') then raise exception 'Repair must be ready or delivered';end if;
 if exists(select 1 from public.ts_invoices where repair_id=rid) then raise exception 'Repair invoice already issued';end if;
 cust:=nullif(ticket->>'customerId','')::uuid;customer_name:=coalesce(ticket->>'customer','');phone_value:=coalesce(ticket->>'phone','');
 labor:=(p_args->>'labor')::numeric;parts:=(p_args->>'parts')::numeric;months:=coalesce((p_args->>'months')::int,0);paid_value:=coalesce((p_args->>'paid')::numeric,0);
 if labor is null or parts is null or labor<0 or parts<0 or labor>100000000 or parts>100000000 or months not between 0 and 120 then raise exception 'Invalid repair amounts';end if;
 total_value:=round(labor+parts,2);if paid_value<0 or paid_value>total_value then raise exception 'Invalid paid amount';end if;
 lines:=jsonb_build_array(jsonb_build_object('name',coalesce(ticket->>'device','Repair'),'qty',1,'price',total_value,'total',total_value,'serial',coalesce(ticket->>'serial',''),'warranty_months',months,'warranty_end',case when months>0 then (issue_date+make_interval(months=>months))::date else null end,'fault',coalesce(ticket->>'fault',''),'labor',labor,'parts',parts,'work',left(coalesce(p_args->>'work',''),1000)));
 end if;
 doc:=jsonb_build_object('store_name',cfg.store_name,'store_phone',cfg.phone,'store_address',cfg.address,'title',title_value,'footer',cfg.footer,'date',issue_date,'customer',customer_name,'phone',phone_value,'items',lines,'total',total_value,'paid',round(paid_value,2),'currency','USD','warranty_terms',warranty_terms,'payment_mode',mode_value,'installment_count',installments_value,'first_due',due_value);
 if used_points>0 then doc:=doc||jsonb_build_object('subtotal',subtotal_value,'points_used',used_points,'points_discount',discount_value);end if;
 insert into public.ts_invoices(request_id,actor,customer_id,kind,repair_id,document,request_args) values(req,u.user_id,cust,p_action,rid,doc,p_args) returning * into inv;
 if p_action='sale' then
 d:=jsonb_set(d,'{sales}',coalesce(d->'sales','[]')||jsonb_build_array(jsonb_build_object('id',inv.id,'number','INV-'||inv.number,'date',issue_date,'customer',customer_name,'payment',mode_value,'paid',paid_value=total_value,'items',sale_lines,'total',total_value,'cost',cost_value)),true);
 if used_points>0 then rec:=jsonb_set(rec,'{loyalty}',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',cust,'created',now(),'points',-used_points,'order',inv.id,'kind','redemption','source','invoice'))||coalesce(rec->'loyalty','[]'),true);end if;
 update public.ts_workspace set payload=jsonb_set(jsonb_set(w.payload,'{data}',d),'{records}',rec,true),revision=revision+1,updated_at=now() where id=1;
 end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'invoice '||p_action||' '||inv.id);
 return to_jsonb(inv)-'request_args'-'request_id'-'actor'-'customer_id';
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.business_action(p_action text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u public.ts_profiles%rowtype; inv public.ts_invoices%rowtype; e public.ts_business_entries%rowtype; req uuid; iid uuid; amount_value numeric; paid numeric; refunded numeric; debt_cancelled numeric; bal numeric; day_value date:=(now() at time zone 'UTC')::date; expected_value numeric; counted_value numeric; note text; k text; c public.ts_invoice_settings%rowtype;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>200000 then raise exception 'Invalid request';end if;
 if p_action='warranties' and u.role in ('cashier','tech') and not techstore_private.staff_allowed(u.user_id,'warranty_read') then raise exception 'Warranty read denied' using errcode='42501';end if;
 if p_action='warranties' then return coalesce((select jsonb_agg(to_jsonb(x)) from (select w.*,i.number,i.kind,i.document->>'customer' as customer,i.document->>'warranty_terms' as terms,(exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=i.id) or coalesce((select sum(al.qty) from public.ts_invoice_adjustment_lines al join public.ts_invoice_adjustments a on a.id=al.adjustment_id where a.invoice_id=i.id and al.line_no=w.line_no),0)>=w.qty) as refunded,case when exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=i.id) then w.qty else coalesce((select sum(al.qty) from public.ts_invoice_adjustment_lines al join public.ts_invoice_adjustments a on a.id=al.adjustment_id where a.invoice_id=i.id and al.line_no=w.line_no),0) end as returned_qty from public.ts_invoice_warranties w join public.ts_invoices i on i.id=w.invoice_id where (u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id)) and (u.role not in ('cashier','tech') or techstore_private.staff_allowed(u.user_id,case when i.kind='sale' then 'orders_read' else 'repairs_read' end)) order by w.ends desc limit 300) x),'[]');end if;
 if p_action='balance' then
 select * into inv from public.ts_invoices i where i.id=(p_args->>'id')::uuid and (u.role in ('admin','cashier') or (u.role='customer' and i.customer_id=u.user_id) or (u.role='tech' and i.kind='repair')) and (u.role not in ('cashier','tech') or techstore_private.staff_allowed(u.user_id,case when i.kind='sale' then 'orders_read' else 'repairs_read' end));
 if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;
 select coalesce(sum(amount),0) into paid from public.ts_business_entries where invoice_id=inv.id and kind in ('initial_payment','receipt');
 -- Legacy invoice fallback; new invoice initial payment is recorded by the trigger.
 if not exists(select 1 from public.ts_business_entries where invoice_id=inv.id and kind='invoice') then paid:=coalesce((inv.document->>'paid')::numeric,0)+coalesce((select sum(amount) from public.ts_business_entries where invoice_id=inv.id and kind='receipt'),0);end if;
 select coalesce(sum(amount),0) into refunded from public.ts_business_entries where invoice_id=inv.id and kind='refund';
 select coalesce(sum(amount),0) into debt_cancelled from public.ts_business_entries where invoice_id=inv.id and kind='debt_cancel';
 return jsonb_build_object('total',(inv.document->>'total')::numeric-refunded-debt_cancelled,'original_total',(inv.document->>'total')::numeric,'refunded',refunded,'debt_cancelled',debt_cancelled,'cancelled',((inv.document->>'total')::numeric>0 and (inv.document->>'total')::numeric=refunded+debt_cancelled),'paid',paid-refunded,'balance',greatest(0,(inv.document->>'total')::numeric-paid-debt_cancelled),'receipts',coalesce((select jsonb_agg(jsonb_build_object('id',id,'amount',amount,'created_at',created_at,'memo',memo)) from public.ts_business_entries where invoice_id=inv.id and kind='receipt'),'[]'));
 end if;
 if u.role not in ('admin','cashier') then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='branding' then select * into c from public.ts_invoice_settings where id=1;return jsonb_build_object('syp_rate',c.syp_rate,'logo',c.logo);end if;
 if p_action='configure' then if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;update public.ts_invoice_settings set syp_rate=(p_args->>'syp_rate')::numeric,logo=coalesce(p_args->>'logo','') where id=1 returning * into c;insert into public.ts_audit(actor,action) values(u.user_id,'business branding updated');return jsonb_build_object('ok',true);end if;
 if p_action='list' then
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into expected_value from public.ts_business_entries;
 return jsonb_build_object('day',day_value,'cash_expected',expected_value,'closed',exists(select 1 from public.ts_business_closings where day=day_value),'entries',coalesce((select jsonb_agg(to_jsonb(x)) from (select id,invoice_id,kind,debit,credit,amount,memo,created_at from public.ts_business_entries order by created_at desc,id limit 200) x),'[]'),'closings',coalesce((select jsonb_agg(to_jsonb(x)) from (select day,expected,counted,created_at from public.ts_business_closings order by day desc limit 30) x),'[]'));
 end if;
 if p_action='receipt' then perform 1 from public.ts_workspace where id=1 for update;end if;
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 if p_action='close' then
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 counted_value:=round((p_args->>'counted')::numeric,2);
 if counted_value is null or counted_value<0 or counted_value>1000000000 then raise exception 'Invalid counted amount';end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into expected_value from public.ts_business_entries;
 insert into public.ts_business_closings(day,expected,counted,actor) values(day_value,expected_value,counted_value,u.user_id);
 insert into public.ts_audit(actor,action) values(u.user_id,'cash day closed '||day_value);
 return jsonb_build_object('expected',expected_value,'counted',counted_value,'difference',counted_value-expected_value);
 end if;
 if p_action not in ('receipt','expense','cash_in') then raise exception 'Invalid action';end if;
 if p_action<>'receipt' and u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 req:=(p_args->>'request_id')::uuid;amount_value:=round((p_args->>'amount')::numeric,2);note:=left(btrim(coalesce(p_args->>'memo','')),500);iid:=nullif(p_args->>'invoice_id','')::uuid;
 if req is null or amount_value is null or amount_value<=0 or amount_value>1000000000 or note='' then raise exception 'Invalid amount or reference';end if;
 select * into e from public.ts_business_entries where request_id=req;
 if found then if e.actor<>u.user_id or e.kind<>p_action or e.invoice_id is distinct from iid or e.amount<>amount_value or e.memo<>note then raise exception 'Request ID conflict';end if;return to_jsonb(e);end if;
 if exists(select 1 from public.ts_business_closings where day=day_value) then raise exception 'Cash day is closed';end if;
 if p_action='receipt' then
 select * into inv from public.ts_invoices where id=iid for update;if not found then raise exception 'Invoice unavailable';end if;
 bal:=(techstore_private.business_action('balance',jsonb_build_object('id',iid))->>'balance')::numeric;
 if amount_value>bal then raise exception 'Payment exceeds balance';end if;
 insert into public.ts_business_entries(request_id,invoice_id,actor,kind,debit,credit,amount,memo) values(req,iid,u.user_id,'receipt','cash','receivables',amount_value,note) returning * into e;
 if inv.kind='sale' and inv.customer_id is not null and inv.document->>'payment_mode'='installment' then
  select coalesce(sum(amount),0) into paid from public.ts_business_entries where invoice_id=iid and kind in ('initial_payment','receipt');
  insert into techstore_private.loyalty_sale_links(source_kind,source_id,customer_id,total,earned,target)
  values('invoice',iid,inv.customer_id,(inv.document->>'total')::numeric,floor(paid)::bigint,floor(paid)::bigint)
  on conflict(source_kind,source_id) do update set earned=excluded.earned,target=excluded.target;
  update public.ts_workspace set payload=payload,revision=revision+1,updated_at=now() where id=1;
 end if;
 else
 if iid is not null then raise exception 'Invoice not allowed';end if;
 if p_action='expense' then select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into expected_value from public.ts_business_entries;if amount_value>expected_value then raise exception 'Insufficient recorded cash';end if;end if;
 insert into public.ts_business_entries(request_id,actor,kind,debit,credit,amount,memo) values(req,u.user_id,p_action,case when p_action='expense' then 'operating_expense' else 'cash' end,case when p_action='expense' then 'cash' else 'owner_contribution' end,amount_value,note) returning * into e;
 end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'business '||p_action||' '||e.id);
 return to_jsonb(e);
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.invoice_adjustment(p_action text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u public.ts_profiles%rowtype; i public.ts_invoices%rowtype; w public.ts_workspace%rowtype; a public.ts_invoice_adjustments%rowtype; req uuid; iid uuid; k text; reason_value text; wanted jsonb; row_value jsonb; original jsonb; original_line jsonb; item jsonb; prod jsonb; line_value int; q int; sold int; previously bigint; seen int[]:='{}'; ix int; oldqty int; price_value numeric; cost_value numeric; gross_value numeric:=0; cost_total numeric:=0; cash_value numeric; paid_value numeric; refunded_value numeric; debt_value numeric; refund_cash numeric; outstanding numeric; d jsonb; out_lines jsonb:='[]'; item_total numeric;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>16000 then raise exception 'Invalid request';end if;
 iid:=(p_args->>'id')::uuid;
 select * into i from public.ts_invoices where id=iid and (u.role in ('admin','cashier') or (u.role='customer' and customer_id=u.user_id));
 if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;
 if u.role='cashier' and (not techstore_private.staff_allowed(u.user_id,'returns_read') or not techstore_private.staff_allowed(u.user_id,'orders_read')) then raise exception 'Return read denied' using errcode='42501';end if;
 if p_action='list' then return coalesce((select jsonb_agg(to_jsonb(x)-'request_args'-'request_id'-'actor'-'cost_reversal') from (select a0.*,(select jsonb_agg(to_jsonb(al)-'adjustment_id'-'unit_cost' order by al.line_no) from public.ts_invoice_adjustment_lines al where al.adjustment_id=a0.id) as lines from public.ts_invoice_adjustments a0 where a0.invoice_id=iid order by a0.created_at,a0.id) x),'[]');end if;
 if p_action is distinct from 'apply' or u.role<>'admin' or i.kind<>'sale' then raise exception 'Access denied' using errcode='42501';end if;
 req:=(p_args->>'request_id')::uuid;k:=p_args->>'kind';reason_value:=btrim(coalesce(p_args->>'reason',''));
 if req is null or k is null or k not in ('partial_return','cancel_installment') or length(reason_value) not between 1 and 500 or p_args->'inspected' is distinct from 'true'::jsonb then raise exception 'Inspection and reason required';end if;
 select * into w from public.ts_workspace where id=1 for update;
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 select * into a from public.ts_invoice_adjustments where request_id=req;
 if found then if a.actor<>u.user_id or a.invoice_id<>iid or a.request_args is distinct from p_args then raise exception 'Request ID conflict';end if;return to_jsonb(a)-'request_args'-'request_id'-'actor';end if;
 if exists(select 1 from public.ts_invoice_refunds where invoice_id=iid) or exists(select 1 from public.ts_invoice_adjustments where invoice_id=iid and kind='cancel_installment') then raise exception 'Invoice already fully cancelled';end if;
 if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day closed';end if;
 if not exists(select 1 from public.ts_business_entries where invoice_id=iid and kind='invoice') then raise exception 'Invoice not in new ledger';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(w.payload->'records'->'returns','[]')) x where x->>'sale'=iid::text) then raise exception 'Legacy return exists';end if;
 select coalesce(sum(amount),0) into paid_value from public.ts_business_entries where invoice_id=iid and kind in ('initial_payment','receipt');
 select coalesce(sum(amount),0) into refunded_value from public.ts_business_entries where invoice_id=iid and kind='refund';
 if k='partial_return' then
 if coalesce(i.document->>'payment_mode','cash')<>'cash' or paid_value<>(i.document->>'total')::numeric then raise exception 'Partial returns require a fully paid cash invoice';end if;
 wanted:=p_args->'lines';
 elsif k='cancel_installment' then
 if i.document->>'payment_mode' is distinct from 'installment' or exists(select 1 from public.ts_invoice_adjustments where invoice_id=iid) then raise exception 'Only untouched installment invoices can be cancelled';end if;
 select jsonb_agg(jsonb_build_object('line_no',ord,'qty',(x->>'qty')::int)) into wanted from jsonb_array_elements(i.document->'items') with ordinality a1(x,ord);
 end if;
 if jsonb_typeof(wanted) is distinct from 'array' then raise exception 'Invalid lines';end if;
 if jsonb_array_length(wanted) not between 1 and 30 then raise exception 'Invalid lines';end if;
 d:=w.payload->'data';select x into original from jsonb_array_elements(coalesce(d->'sales','[]')) x where x->>'id'=iid::text;
 if original is null then raise exception 'Original sale unavailable';end if;
 for row_value in select value from jsonb_array_elements(wanted) loop
 line_value:=(row_value->>'line_no')::int;q:=(row_value->>'qty')::int;
 if line_value is null or line_value not between 1 and jsonb_array_length(i.document->'items') or line_value=any(seen) or q is null or q<=0 then raise exception 'Invalid return quantity';end if;
 seen:=array_append(seen,line_value);item:=i.document->'items'->(line_value-1);sold:=(item->>'qty')::int;
 select coalesce(sum(al.qty),0) into previously from public.ts_invoice_adjustment_lines al join public.ts_invoice_adjustments a2 on a2.id=al.adjustment_id where a2.invoice_id=iid and al.line_no=line_value;
 if q>sold-previously then raise exception 'Return exceeds sold quantity';end if;
 if coalesce(item->>'serial','')<>'' and sold>1 and q<>sold-previously then raise exception 'Serialized multi-unit line must be returned together';end if;
 select x into original_line from jsonb_array_elements(original->'items') x where x->>'id'=item->>'product';
 cost_value:=(original_line->>'cost')::numeric;price_value:=(item->>'price')::numeric;
 if cost_value is null or price_value is null or cost_value<0 or price_value<0 then raise exception 'Original price or cost unavailable';end if;
 select x,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(d->'products','[]')) with ordinality z(x,ord) where x->>'id'=item->>'product';
 if prod is null then raise exception 'Product unavailable for restock';end if;
 oldqty:=(prod->>'qty')::int;
 if oldqty is null or oldqty<0 or oldqty::bigint+q>2147483647 or (prod->>'cost')::numeric is null then raise exception 'Invalid stock';end if;
 -- Cumulative cent rounding ensures multiple partial returns cannot exceed original line total/cost.
 item_total:=round((item->>'total')::numeric*(previously+q)/sold,2)-round((item->>'total')::numeric*previously/sold,2);
 gross_value:=gross_value+item_total;
 cost_total:=cost_total+round(cost_value*(previously+q),2)-round(cost_value*previously,2);
 d:=jsonb_set(jsonb_set(d,array['products',ix::text,'qty'],to_jsonb(oldqty+q)),array['products',ix::text,'cost'],to_jsonb(round((oldqty*(prod->>'cost')::numeric+q*cost_value)/(oldqty+q),4)));
 d:=jsonb_set(d,'{stockMoves}',coalesce(d->'stockMoves','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',item->>'product','name',item->>'name','qty',q,'reason','invoice adjustment','date',current_date)),true);
 out_lines:=out_lines||jsonb_build_array(jsonb_build_object('line_no',line_value,'product_id',item->>'product','qty',q,'unit_price',price_value,'unit_cost',cost_value,'gross',item_total));
 end loop;
 if gross_value<=0 or gross_value>(i.document->>'total')::numeric-refunded_value then raise exception 'Invalid return total';end if;
 if k='cancel_installment' then
 if gross_value<>(i.document->>'total')::numeric or refunded_value<>0 or paid_value<0 or paid_value>gross_value then raise exception 'Invalid cancellation total';end if;
 refund_cash:=paid_value;debt_value:=gross_value-paid_value;
 else refund_cash:=gross_value;debt_value:=0;end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into cash_value from public.ts_business_entries;
 if refund_cash>cash_value then raise exception 'Insufficient recorded cash';end if;
 insert into public.ts_invoice_adjustments(request_id,invoice_id,actor,kind,gross,cash_refund,debt_cancel,cost_reversal,reason,request_args) values(req,iid,u.user_id,k,gross_value,refund_cash,debt_value,cost_total,reason_value,p_args) returning * into a;
 for row_value in select value from jsonb_array_elements(out_lines) loop
 insert into public.ts_invoice_adjustment_lines(adjustment_id,line_no,product_id,qty,unit_price,unit_cost,gross) values(a.id,(row_value->>'line_no')::int,row_value->>'product_id',(row_value->>'qty')::int,(row_value->>'unit_price')::numeric,(row_value->>'unit_cost')::numeric,(row_value->>'gross')::numeric);
 end loop;
 if refund_cash>0 then insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(iid,u.user_id,'refund','sales_revenue','cash',refund_cash,'Return INV-'||i.number);end if;
 if debt_value>0 then insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(iid,u.user_id,'debt_cancel','sales_revenue','receivables',debt_value,'Cancellation INV-'||i.number);end if;
 if cost_total>0 then insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(iid,u.user_id,'cost_reverse','inventory','cost_of_sales',cost_total,'Return INV-'||i.number);end if;
 d:=jsonb_set(d,'{expenses}',coalesce(d->'expenses','[]')||jsonb_build_array(jsonb_build_object('id',a.id,'date',current_date,'desc','Invoice adjustment INV-'||i.number,'amount',gross_value-cost_total)),true);
 update public.ts_workspace set payload=jsonb_set(w.payload,'{data}',d),revision=revision+1,updated_at=now() where id=1;
 insert into public.ts_audit(actor,action) values(u.user_id,'invoice adjustment '||a.id);
 return to_jsonb(a)-'request_args'-'request_id'-'actor';
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.invoice_refund(p_action text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u public.ts_profiles%rowtype; i public.ts_invoices%rowtype; w public.ts_workspace%rowtype; r public.ts_invoice_refunds%rowtype; d jsonb; line jsonb; p jsonb; original jsonb; ix int; qty int; oldqty int; unit_cost numeric; c numeric; cash_value numeric; req uuid; reason_value text; iid uuid; refund_value numeric;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>4000 then raise exception 'Invalid request';end if;
 iid:=(p_args->>'id')::uuid;
 select * into i from public.ts_invoices where id=iid and (u.role in ('admin','cashier') or (u.role='customer' and customer_id=u.user_id));
 if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;
 if u.role='cashier' and (not techstore_private.staff_allowed(u.user_id,'returns_read') or not techstore_private.staff_allowed(u.user_id,'orders_read')) then raise exception 'Refund read denied' using errcode='42501';end if;
 if p_action='get' then return coalesce((select to_jsonb(x)-'actor'-'request_id' from public.ts_invoice_refunds x where invoice_id=iid),'null');end if;
 if p_action<>'refund' or u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 req:=(p_args->>'request_id')::uuid;reason_value:=btrim(coalesce(p_args->>'reason',''));
 if req is null or length(reason_value) not between 1 and 500 or p_args->'inspected' is distinct from 'true'::jsonb then raise exception 'Confirm all goods inspected and resalable';end if;
 select * into w from public.ts_workspace where id=1 for update;
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 select * into r from public.ts_invoice_refunds where request_id=req;
 if found then if r.actor<>u.user_id or r.invoice_id<>iid or r.reason<>reason_value then raise exception 'Request ID conflict';end if;return to_jsonb(r)-'actor'-'request_id';end if;
 if exists(select 1 from public.ts_invoice_refunds where invoice_id=iid) then raise exception 'Already refunded';end if;
 if i.kind<>'sale' or coalesce(i.document->>'payment_mode','cash')<>'cash' then raise exception 'Only paid cash sale invoices can be fully refunded';end if;
 if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day closed';end if;
 refund_value:=(i.document->>'total')::numeric;
 if refund_value<=0 or not exists(select 1 from public.ts_business_entries where invoice_id=iid and kind='invoice') or (select coalesce(sum(amount),0) from public.ts_business_entries where invoice_id=iid and kind in ('initial_payment','receipt'))<>refund_value then raise exception 'Invoice not fully paid in new ledger';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(w.payload->'records'->'returns','[]')) x where x->>'sale'=iid::text) then raise exception 'Legacy return exists';end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into cash_value from public.ts_business_entries;
 if cash_value<refund_value then raise exception 'Insufficient recorded cash';end if;
 d:=w.payload->'data';
 select x into original from jsonb_array_elements(coalesce(d->'sales','[]')) x where x->>'id'=iid::text;
 if original is null then raise exception 'Original stock cost unavailable';end if;
 for line in select value from jsonb_array_elements(i.document->'items') loop
 qty:=(line->>'qty')::int;
 select x,ord::int-1 into p,ix from jsonb_array_elements(coalesce(d->'products','[]')) with ordinality a(x,ord) where x->>'id'=line->>'product';
 select (x->>'cost')::numeric into unit_cost from jsonb_array_elements(original->'items') x where x->>'id'=line->>'product';
 if p is null or unit_cost is null or unit_cost<0 or qty<=0 then raise exception 'Product or original cost unavailable';end if;
 oldqty:=(p->>'qty')::int;
 d:=jsonb_set(jsonb_set(d,array['products',ix::text,'qty'],to_jsonb(oldqty+qty)),array['products',ix::text,'cost'],to_jsonb(round((oldqty*(p->>'cost')::numeric+qty*unit_cost)/(oldqty+qty),4)));
 d:=jsonb_set(d,'{stockMoves}',coalesce(d->'stockMoves','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',line->>'product','name',line->>'name','qty',qty,'reason','invoice full refund','date',current_date)),true);
 end loop;
 select coalesce(sum(amount),0) into c from public.ts_business_entries where invoice_id=iid and kind='cost';
 insert into public.ts_invoice_refunds(invoice_id,request_id,actor,reason,amount) values(iid,req,u.user_id,reason_value,refund_value) returning * into r;
 insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(iid,u.user_id,'refund','sales_revenue','cash',refund_value,'Refund INV-'||i.number);
 if c>0 then insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(iid,u.user_id,'cost_reverse','inventory','cost_of_sales',c,'Refund INV-'||i.number);end if;
 -- Keep legacy profit calculation consistent without deleting the original sale.
 d:=jsonb_set(d,'{expenses}',coalesce(d->'expenses','[]')||jsonb_build_array(jsonb_build_object('id',r.id,'date',current_date,'desc','Full invoice refund INV-'||i.number,'amount',refund_value-c)),true);
 update public.ts_workspace set payload=jsonb_set(w.payload,'{data}',d),revision=revision+1,updated_at=now() where id=1;
 insert into public.ts_audit(actor,action) values(u.user_id,'full invoice refund '||iid);
 return to_jsonb(r)-'actor'-'request_id';
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.installment_schedule(p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u public.ts_profiles%rowtype;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or u.role not in ('admin','cashier','customer') or (u.role='cashier' and (not techstore_private.staff_allowed(u.user_id,'installment_read') or not techstore_private.staff_allowed(u.user_id,'orders_read'))) then raise exception 'Access denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from (
 select s.invoice_id,i.number,i.document->>'customer' as customer,s.sequence,s.due_date,s.amount,exists(select 1 from public.ts_invoice_adjustments a where a.invoice_id=i.id and a.kind='cancel_installment') as cancelled,
 least(s.amount,greatest(0,coalesce((select sum(e.amount) from public.ts_business_entries e where e.invoice_id=i.id and e.kind='receipt'),0)-coalesce((select sum(p.amount) from public.ts_invoice_installments p where p.invoice_id=i.id and p.sequence<s.sequence),0))) as paid
 from public.ts_invoice_installments s join public.ts_invoices i on i.id=s.invoice_id
 where (p_id is null or i.id=p_id) and (u.role in ('admin','cashier') or i.customer_id=u.user_id)
 order by s.due_date,i.number,s.sequence limit 500
 ) x),'[]');
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.repair_workflow(p_action text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; r jsonb; rid text; tech uuid; result jsonb;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>10000 then raise exception 'Invalid request';end if;
 if u.role in ('cashier','tech') and not techstore_private.staff_allowed(u.user_id,'repairs_read') then raise exception 'Repair read denied' using errcode='42501';end if;
 if u.role='cashier' and p_action='save' and not techstore_private.staff_allowed(u.user_id,'repair_intake') then raise exception 'Repair intake denied' using errcode='42501';end if;
 if p_action='staff' then if u.role not in ('admin','cashier') then raise exception 'Access denied' using errcode='42501';end if;return coalesce((select jsonb_agg(jsonb_build_object('id',user_id,'name',name)) from public.ts_profiles where role='tech' and active),'[]');end if;
 if p_action='report' then
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from (select p.name,count(*) as assigned,count(*) filter(where r->>'status' in ('ready','delivered')) as completed,count(*) filter(where r->>'status' not in ('ready','delivered','cancelled')) as open from public.ts_repair_intake a join public.ts_profiles p on p.user_id=a.technician join public.ts_workspace w on w.id=1 cross join lateral jsonb_array_elements(coalesce(w.payload->'records'->'repairs','[]')) r where r->>'id'=a.repair_id group by p.user_id,p.name) x),'[]');
 end if;
 rid:=p_args->>'repair_id';select * into w from public.ts_workspace where id=1 for update;
 select x into r from jsonb_array_elements(coalesce(w.payload->'records'->'repairs','[]')) x where x->>'id'=rid;
 if r is null or (u.role in ('admin','cashier','tech') or (u.role='customer' and r->>'customerId'=u.user_id::text)) is distinct from true then raise exception 'Ticket unavailable' using errcode='42501';end if;
 if p_action='get' then
 return jsonb_build_object('intake',(select jsonb_build_object('condition',a.condition,'accessories',a.accessories,'technician',a.technician,'technician_name',p.name,'updated_at',a.updated_at) from public.ts_repair_intake a left join public.ts_profiles p on p.user_id=a.technician where a.repair_id=rid),'history',coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from (select id,status,recorded_at from public.ts_repair_history where repair_id=rid order by id desc limit 100) x),'[]'));
 end if;
 if p_action<>'save' or u.role not in ('admin','cashier') then raise exception 'Access denied' using errcode='42501';end if;
 if r->>'status' in ('delivered','cancelled') then raise exception 'Closed ticket';end if;
 tech:=nullif(p_args->>'technician','')::uuid;
 if tech is not null and not exists(select 1 from public.ts_profiles where user_id=tech and role='tech' and active) then raise exception 'Invalid technician';end if;
 insert into public.ts_repair_intake(repair_id,condition,accessories,technician,actor) values(rid,coalesce(p_args->>'condition',''),coalesce(p_args->>'accessories',''),tech,u.user_id)
 on conflict(repair_id) do update set condition=excluded.condition,accessories=excluded.accessories,technician=excluded.technician,actor=excluded.actor,updated_at=now();
 insert into public.ts_audit(actor,action) values(u.user_id,'repair intake updated '||rid);return jsonb_build_object('ok',true);
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.repair_evidence(p_action text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; ticket jsonb; rid text; k text; image_value text; note_value text; prod jsonb; pid text; ix int; q int; cost numeric; data jsonb; item public.ts_repair_evidence%rowtype; is_staff boolean; request_value uuid;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found then raise exception 'Access denied' using errcode='42501';end if;
 is_staff:=u.role in ('admin','tech','cashier');
 if u.role in ('cashier','tech') and not techstore_private.staff_allowed(u.user_id,'repairs_read') then raise exception 'Repair read denied' using errcode='42501';end if;
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
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.guest_request(p_action text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w public.ts_workspace%rowtype; g public.ts_guest_requests%rowtype; token_value uuid; hash_value text; customer_value text; phone_value text; normalized text; address_value text; pid text; q int; line jsonb; prod jsonb; items_value jsonb:='[]'; order_items jsonb:='[]'; total_value numeric:=0; cost_value numeric:=0; data_value jsonb; record_value jsonb; order_value jsonb; order_ref uuid; ix int; seen text[]:='{}';
begin
 if p_args is null or jsonb_typeof(p_args)<>'object' or octet_length(p_args::text)>24000 then raise exception 'Invalid request';end if;
 if p_action='list' or p_action='review' then
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role in ('admin','cashier')) then raise exception 'Access denied' using errcode='42501';end if;
 if exists(select 1 from public.ts_profiles where user_id=auth.uid() and role='cashier') and not techstore_private.staff_allowed(auth.uid(),'orders_read') then raise exception 'Order read denied' using errcode='42501';end if;
 if p_action='review' and exists(select 1 from public.ts_profiles where user_id=auth.uid() and role='cashier') and not techstore_private.staff_allowed(auth.uid(),'orders_write') then raise exception 'Order review permission denied' using errcode='42501';end if;
 if p_action='list' then return coalesce((select jsonb_agg(to_jsonb(r)-'tracking_hash') from (select * from public.ts_guest_requests order by created_at desc limit 200) r),'[]'::jsonb);end if;
 select * into w from public.ts_workspace where id=1 for update;
 select * into g from public.ts_guest_requests where id=(p_args->>'id')::uuid for update;
 if not found or g.status<>'awaiting_review' then raise exception 'Request already reviewed or missing';end if;
 if p_args->>'decision'='reject' then update public.ts_guest_requests set status='cancelled',reviewed_at=now() where id=g.id;insert into public.ts_audit(actor,action) values(auth.uid(),'guest request rejected '||g.id);return jsonb_build_object('id',g.id,'status','cancelled');end if;
 if p_args->>'decision' is distinct from 'accept' or p_args->'contact_confirmed' is distinct from 'true'::jsonb then raise exception 'Confirm customer contact first';end if;
 data_value:=w.payload->'data';
 if data_value->'owner'->>'maintenance'='true' then raise exception 'Store closed';end if;
 for line in select value from jsonb_array_elements(g.items) loop
 pid:=line->>'id';q:=(line->>'qty')::int;
 select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(data_value->'products','[]'::jsonb)) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null or prod->>'hidden'='true' or (coalesce(data_value->'owner'->'hiddenCategories','[]'::jsonb) ? coalesce(prod->>'type','')) or (prod->>'qty')::int<q or (prod->>'price')::numeric is distinct from (line->>'price')::numeric then raise exception 'Stock or price changed; contact customer';end if;
 cost_value:=cost_value+q*(prod->>'cost')::numeric;
 order_items:=order_items||jsonb_build_array(line||jsonb_build_object('cost',(prod->>'cost')::numeric));
 data_value:=jsonb_set(data_value,array['products',ix::text,'qty'],to_jsonb((prod->>'qty')::int-q));
 end loop;
 order_ref:=gen_random_uuid(); order_value:=jsonb_build_object('id',order_ref,'owner',null,'created',now(),'customer',g.customer,'phone',g.phone,'address',g.address,'items',order_items,'total',g.total,'cost',cost_value,'discount',0,'status','confirmed','payment','cod');
 record_value:=coalesce(w.payload->'records','{}'::jsonb);record_value:=jsonb_set(record_value,'{orders}',jsonb_build_array(order_value)||coalesce(record_value->'orders','[]'::jsonb));
 update public.ts_workspace set payload=jsonb_set(jsonb_set(w.payload,'{data}',data_value),'{records}',record_value),revision=revision+1,updated_at=now() where id=1;
 update public.ts_guest_requests set status='accepted',order_id=order_ref::text,reviewed_at=now() where id=g.id;
 insert into public.ts_audit(actor,action) values(auth.uid(),'guest request accepted '||g.id);
 return jsonb_build_object('id',g.id,'status','accepted','order_id',order_ref);
 end if;
 if p_action not in ('submit','status') then raise exception 'Invalid action';end if;
 token_value:=(p_args->>'token')::uuid;if token_value is null then raise exception 'Invalid tracking code';end if;
 hash_value:=encode(extensions.digest(token_value::text,'sha256'),'hex');
 select * into g from public.ts_guest_requests where tracking_hash=hash_value;
 if found then
  if g.order_id is not null then select r into order_value from public.ts_workspace w0 cross join lateral jsonb_array_elements(coalesce(w0.payload->'records'->'orders','[]'::jsonb)) r where w0.id=1 and r->>'id'=g.order_id;end if;
  return jsonb_build_object('id',g.id,'status',coalesce(order_value->>'status',g.status),'total',g.total);
 end if;
 if p_action='status' then raise exception 'Request not found';end if;
 customer_value:=btrim(coalesce(p_args->>'customer',''));phone_value:=btrim(coalesce(p_args->>'phone',''));normalized:=regexp_replace(phone_value,'[^0-9]','','g');address_value:=btrim(coalesce(p_args->>'address',''));
 if length(customer_value) not between 1 and 150 or length(phone_value) not between 7 and 40 or length(normalized) not between 7 and 18 or length(address_value) not between 1 and 500 or p_args->'consent' is distinct from 'true'::jsonb then raise exception 'Valid name, phone, address and consent required';end if;
 if jsonb_typeof(p_args->'items') is distinct from 'array' then raise exception 'Invalid cart';end if;
 if jsonb_array_length(p_args->'items') not between 1 and 30 then raise exception 'Invalid cart';end if;
 select * into w from public.ts_workspace where id=1;data_value:=w.payload->'data';
 if data_value->'owner'->>'maintenance'='true' then raise exception 'Store closed';end if;
 for line in select value from jsonb_array_elements(p_args->'items') loop
 pid:=line->>'id';q:=(line->>'qty')::int;if pid is null or length(pid)>200 or q is null or q not between 1 and 20 or pid=any(seen) then raise exception 'Invalid cart item';end if;seen:=array_append(seen,pid);
 select p into prod from jsonb_array_elements(coalesce(data_value->'products','[]'::jsonb)) p where p->>'id'=pid;
 if prod is null or prod->>'hidden'='true' or (coalesce(data_value->'owner'->'hiddenCategories','[]'::jsonb) ? coalesce(prod->>'type','')) or (prod->>'qty')::int<q then raise exception 'Product unavailable';end if;
 items_value:=items_value||jsonb_build_array(jsonb_build_object('id',pid,'name',left(prod->>'name',200),'qty',q,'price',(prod->>'price')::numeric));
 total_value:=total_value+q*(prod->>'price')::numeric;
 end loop;
 if not public.ts_guest_reserve(encode(extensions.digest('guest:'||normalized,'sha256'),'hex')) then raise exception 'Too many requests';end if;
 insert into public.ts_guest_requests(tracking_hash,customer,phone,address,items,total) values(hash_value,customer_value,phone_value,address_value,items_value,round(total_value,2)) on conflict(tracking_hash) do nothing returning * into g;
 if not found then select * into g from public.ts_guest_requests where tracking_hash=hash_value;end if;
 return jsonb_build_object('id',g.id,'status',g.status,'total',g.total);
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.supplier_finance(p_action text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; pur jsonb; b public.ts_supplier_bills%rowtype; pay public.ts_supplier_payments%rowtype; pid text; req uuid; a numeric; paid numeric; memo_value text; product_id text; prod jsonb; idx int; q int; unit_cost numeric; d jsonb; rec jsonb; existing public.ts_supplier_bills%rowtype;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or (u.role='admin' or (u.role='stock' and (p_action='purchase' or (p_action='list' and techstore_private.staff_allowed(u.user_id,'supplier_read'))))) is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 if u.role='stock' and (not techstore_private.staff_allowed(u.user_id,'supplier_read') or not techstore_private.staff_allowed(u.user_id,'purchase_read')) then raise exception 'Supplier or purchase read denied' using errcode='42501';end if;
 if p_action='list' then
 select * into w from public.ts_workspace where id=1;
 return jsonb_build_object('suppliers',coalesce(w.payload->'records'->'suppliers','[]'),'purchases',coalesce(w.payload->'records'->'purchases','[]'),'bills',coalesce((select jsonb_agg(to_jsonb(x)) from (select sb.purchase_id,sb.supplier_id,sb.amount,sb.due_date,sb.created_at,coalesce((select sum(p.amount) from public.ts_supplier_payments p where p.purchase_id=sb.purchase_id),0) as paid from public.ts_supplier_bills sb order by sb.created_at desc limit 500) x),'[]'),'branch_totals',case when u.role='admin' then coalesce((select jsonb_agg(to_jsonb(x)) from (select e.branch_from as branch_id,sum(case when e.kind='return' then -e.amount else e.amount end) as revenue,sum(case when e.kind='return' then -e.cost else e.cost end) as cost,count(*) filter(where e.kind='sale') as sales from public.ts_branch_events e where e.kind in ('sale','return') group by e.branch_from) x),'[]') else '[]' end,'branches',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title)) from public.ts_pro_entries where kind='branches'),'[]') else '[]' end);
 end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>8000 then raise exception 'Invalid request';end if;
 pid:=p_args->>'purchase_id';
 select * into w from public.ts_workspace where id=1 for update;
 if p_action='purchase' then
 req:=(p_args->>'request_id')::uuid;product_id:=p_args->>'product';q:=(p_args->>'qty')::int;unit_cost:=round((p_args->>'cost')::numeric,4);
 if req is null or product_id is null or q is null or q not between 1 and 1000000 or unit_cost is null or unit_cost<=0 or unit_cost>100000000 or round(unit_cost*q,2)<=0 or unit_cost*q>1000000000 then raise exception 'Invalid purchase';end if;
 select * into existing from public.ts_supplier_bills where purchase_request_id=req;
 if found then if existing.actor<>u.user_id or existing.purchase_args is distinct from p_args then raise exception 'Request ID conflict';end if;return jsonb_build_object('id',existing.purchase_id,'duplicate',true);end if;
 rec:=coalesce(w.payload->'records','{}');d:=w.payload->'data';
 if not exists(select 1 from jsonb_array_elements(coalesce(rec->'suppliers','[]')) x where x->>'id'=p_args->>'supplier') then raise exception 'Supplier unavailable';end if;
 select x,ord::int-1 into prod,idx from jsonb_array_elements(coalesce(d->'products','[]')) with ordinality a(x,ord) where x->>'id'=product_id;
 if prod is null or (prod->>'qty')::bigint<0 or (prod->>'qty')::bigint+q>2147483647 or (prod->>'cost')::numeric<0 then raise exception 'Invalid product stock';end if;
 pid:=gen_random_uuid()::text;a:=round(unit_cost*q,2);
 d:=jsonb_set(jsonb_set(d,array['products',idx::text,'qty'],to_jsonb((prod->>'qty')::bigint+q)),array['products',idx::text,'cost'],to_jsonb(round(((prod->>'qty')::numeric*(prod->>'cost')::numeric+q*unit_cost)/((prod->>'qty')::numeric+q),4)));
 d:=jsonb_set(d,'{stockMoves}',coalesce(d->'stockMoves','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',product_id,'name',prod->>'name','qty',q,'reason','supplier purchase','date',current_date)),true);
 rec:=jsonb_set(rec,'{purchases}',jsonb_build_array(jsonb_build_object('id',pid,'owner',null,'created',now(),'product',product_id,'name',prod->>'name','qty',q,'cost',unit_cost,'total',a,'supplier',p_args->>'supplier'))||coalesce(rec->'purchases','[]'),true);
 insert into public.ts_supplier_bills(purchase_id,supplier_id,amount,due_date,actor,purchase_request_id,purchase_args) values(pid,p_args->>'supplier',a,nullif(p_args->>'due_date','')::date,u.user_id,req,p_args);
 update public.ts_workspace set payload=jsonb_set(jsonb_set(w.payload,'{data}',d),'{records}',rec),revision=revision+1,updated_at=now() where id=1;
 elsif p_action='register' then
 select x into pur from jsonb_array_elements(coalesce(w.payload->'records'->'purchases','[]')) x where x->>'id'=pid;
 if pur is null or (pur->>'total')::numeric<=0 or pur->>'supplier' is null then raise exception 'Purchase unavailable';end if;
 insert into public.ts_supplier_bills(purchase_id,supplier_id,amount,due_date,actor) values(pid,pur->>'supplier',round((pur->>'total')::numeric,2),nullif(p_args->>'due_date','')::date,u.user_id) on conflict(purchase_id) do nothing;
 elsif p_action='payment' then
 req:=(p_args->>'request_id')::uuid;a:=round((p_args->>'amount')::numeric,2);memo_value:=btrim(coalesce(p_args->>'memo',''));
 if req is null or a is null or a<=0 or a>1000000000 or length(memo_value) not between 1 and 500 then raise exception 'Invalid payment';end if;
 select * into pay from public.ts_supplier_payments where request_id=req;
 if found then if pay.actor<>u.user_id or pay.purchase_id<>pid or pay.amount<>a or pay.memo<>memo_value then raise exception 'Request conflict';end if;return to_jsonb(pay);end if;
 select * into b from public.ts_supplier_bills where purchase_id=pid for update;if not found then raise exception 'Register purchase first';end if;
 select coalesce(sum(amount),0) into paid from public.ts_supplier_payments where purchase_id=pid;
 if a>b.amount-paid then raise exception 'Payment exceeds supplier balance';end if;
 insert into public.ts_supplier_payments(request_id,purchase_id,amount,actor,memo) values(req,pid,a,u.user_id,memo_value) returning * into pay;
 else raise exception 'Unknown action';end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'supplier '||p_action||' '||pid);return jsonb_build_object('ok',true);
end $function$
;

CREATE OR REPLACE FUNCTION techstore_private.guard_legacy_write(p_actor uuid, p_old jsonb, p_new jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r text; k text; cap text; read_cap text; allowed text[]; before_rows jsonb; after_rows jsonb;
begin
 select role into r from public.ts_profiles where user_id=p_actor and active;
 if r is null then raise exception 'Inactive account' using errcode='42501';end if;
 if coalesce(p_old->'records'->'returns','[]') is distinct from coalesce(p_new->'records'->'returns','[]') then raise exception 'Use integrated return workflow';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(p_old->'records'->'loyalty','[]')) old_row where not exists(select 1 from jsonb_array_elements(coalesce(p_new->'records'->'loyalty','[]')) new_row where new_row=old_row)) then raise exception 'Existing loyalty entries cannot be changed';end if;
 if r='admin' then return;end if;
 allowed:=case r when 'cashier' then array['orders','repairs','warranty','debts','installments','payments','notifications','loyalty','returns'] when 'stock' then array['suppliers','inventory','used'] when 'tech' then array['repairs','warranty','notifications'] when 'customer' then array['orders','notifications'] else array[]::text[] end;
 for k in select key from jsonb_object_keys(coalesce(p_old->'records','{}')||coalesce(p_new->'records','{}')) key loop
 before_rows:=coalesce(p_old->'records'->k,'[]');after_rows:=coalesce(p_new->'records'->k,'[]');
 if before_rows is not distinct from after_rows then continue;end if;
 if not(k=any(allowed)) then raise exception 'Record permission denied: %',k using errcode='42501';end if;
 cap:=case k when 'orders' then 'orders_write' when 'repairs' then 'repair_write' when 'warranty' then 'warranty_write' when 'inventory' then 'inventory_write' when 'suppliers' then 'supplier_write' when 'used' then 'used_write' when 'debts' then 'debt_write' when 'installments' then 'installment_write' else null end;
 read_cap:=case k when 'orders' then 'orders_read' when 'repairs' then 'repairs_read' when 'warranty' then 'warranty_read' when 'inventory' then 'inventory_read' when 'suppliers' then 'supplier_read' when 'used' then 'used_read' when 'debts' then 'debt_read' when 'installments' then 'installment_read' else null end;
 if read_cap is not null and r<>'customer' and not techstore_private.staff_allowed(p_actor,read_cap) then raise exception 'Record read permission denied: %',read_cap using errcode='42501';end if;
 if cap is not null and r<>'customer' and not techstore_private.staff_allowed(p_actor,cap) then raise exception 'Operation permission denied: %',cap using errcode='42501';end if;
 if k='returns' then raise exception 'Use integrated return workflow';end if;
 if k='orders' and r='customer' then raise exception 'Use integrated customer checkout';end if;
 end loop;
 if (coalesce(p_old->'data','{}')-'products'-'stockMoves'-'sales') is distinct from (coalesce(p_new->'data','{}')-'products'-'stockMoves'-'sales') then raise exception 'Workspace edit denied' using errcode='42501';end if;
 if coalesce(p_old->'data'->'products','[]') is distinct from coalesce(p_new->'data'->'products','[]') then
 if r='stock' and not techstore_private.staff_allowed(p_actor,'inventory_write') or r='cashier' and not techstore_private.staff_allowed(p_actor,'orders_write') or r not in ('stock','cashier') then raise exception 'Stock permission denied' using errcode='42501';end if;
 end if;
end $function$
;
