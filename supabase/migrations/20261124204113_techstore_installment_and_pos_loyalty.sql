
create or replace function techstore_private.pos_loyalty_quote(p_customer uuid,p_subtotal numeric,p_points bigint)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; cfg public.ts_loyalty_config%rowtype; balance bigint; used bigint; discount numeric;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or u.role not in ('admin','cashier') or (u.role='cashier' and (not techstore_private.staff_allowed(u.user_id,'invoice_sale') or not techstore_private.staff_allowed(u.user_id,'customers_read') or not techstore_private.staff_allowed(u.user_id,'loyalty_read'))) then raise exception 'Access denied' using errcode='42501';end if;
 if p_customer is null or not exists(select 1 from public.ts_profiles where user_id=p_customer and role='customer' and active) then raise exception 'Active linked customer required';end if;
 if p_subtotal is null or p_subtotal<=0 or p_subtotal>1000000000000 or p_subtotal<>round(p_subtotal,2) or p_points is null or p_points<0 then raise exception 'Invalid points request';end if;
 select * into cfg from public.ts_loyalty_config where id=1;
 select greatest(0,coalesce(sum((x->>'points')::bigint),0)) into balance from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'records'->'loyalty','[]')) x where w.id=1 and x->>'owner'=p_customer::text;
 used:=least(p_points,balance,floor(p_subtotal*cfg.max_redeem_percent/100*cfg.points_per_usd)::bigint,floor(greatest(0,p_subtotal-0.01)*cfg.points_per_usd)::bigint);
 discount:=floor(used::numeric*100/cfg.points_per_usd)/100;
 used:=ceil(discount*cfg.points_per_usd)::bigint;
 return jsonb_build_object('points_balance',balance,'points_used',used,'points_discount',discount,'total',p_subtotal-discount,'subtotal',p_subtotal,'max_redeem_percent',cfg.max_redeem_percent);
end $$;
revoke all on function techstore_private.pos_loyalty_quote(uuid,numeric,bigint) from public,anon,authenticated;
grant execute on function techstore_private.pos_loyalty_quote(uuid,numeric,bigint) to authenticated;
create or replace function public.ts_pos_loyalty_quote(p_customer uuid,p_subtotal numeric,p_points bigint) returns jsonb language sql stable set search_path='' as $$ select techstore_private.pos_loyalty_quote(p_customer,p_subtotal,p_points) $$;
revoke all on function public.ts_pos_loyalty_quote(uuid,numeric,bigint) from public,anon,authenticated;
grant execute on function public.ts_pos_loyalty_quote(uuid,numeric,bigint) to authenticated;
CREATE OR REPLACE FUNCTION techstore_private.capture_sale_loyalty()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare gross numeric; points bigint;
begin
 if tg_table_name='ts_invoices' then
 if new.kind<>'sale' or new.customer_id is null or new.document->>'source'='web_order' or coalesce(new.document->>'payment_mode','cash') not in ('cash','installment') then return new;end if;
 gross:=(new.document->>'total')::numeric;
 else
 if new.kind<>'sale' or new.customer_id is null then return new;end if;
 gross:=new.amount;
 end if;
 if gross<=0 then return new;end if;
 points:=floor(case when tg_table_name='ts_invoices' and coalesce(new.document->>'payment_mode','cash')='installment' then (new.document->>'paid')::numeric else gross end)::bigint;
 insert into techstore_private.loyalty_sale_links(source_kind,source_id,customer_id,total,earned,target) values(case when tg_table_name='ts_invoices' then 'invoice' else 'branch' end,new.id,new.customer_id,gross,points,points);
 return new;
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
 if p_action='warranties' then return coalesce((select jsonb_agg(to_jsonb(x)) from (select w.*,i.number,i.kind,i.document->>'customer' as customer,i.document->>'warranty_terms' as terms,(exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=i.id) or coalesce((select sum(al.qty) from public.ts_invoice_adjustment_lines al join public.ts_invoice_adjustments a on a.id=al.adjustment_id where a.invoice_id=i.id and al.line_no=w.line_no),0)>=w.qty) as refunded,case when exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=i.id) then w.qty else coalesce((select sum(al.qty) from public.ts_invoice_adjustment_lines al join public.ts_invoice_adjustments a on a.id=al.adjustment_id where a.invoice_id=i.id and al.line_no=w.line_no),0) end as returned_qty from public.ts_invoice_warranties w join public.ts_invoices i on i.id=w.invoice_id where u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id) order by w.ends desc limit 300) x),'[]');end if;
 if p_action='balance' then
 select * into inv from public.ts_invoices i where i.id=(p_args->>'id')::uuid and (u.role in ('admin','cashier') or (u.role='customer' and i.customer_id=u.user_id) or (u.role='tech' and i.kind='repair'));
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
 if p_action='list' then return coalesce((select jsonb_agg(to_jsonb(x) order by x.number desc) from (select i.id,i.number,i.kind,i.repair_id,i.created_at,i.document from public.ts_invoices i where (u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id)) order by i.number desc limit 100 offset greatest(0,least(100000,coalesce((p_args->>'offset')::int,0)))) x),'[]'::jsonb);end if;
 if p_action='get' then select * into inv from public.ts_invoices i where i.id=(p_args->>'id')::uuid and (u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id));if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;return to_jsonb(inv)-'request_args'-'request_id'-'actor'-'customer_id';end if;
 if u.role not in ('admin','cashier') or p_action not in ('sale','repair') then raise exception 'Access denied' using errcode='42501';end if;
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

CREATE OR REPLACE FUNCTION techstore_private.reconcile_return_loyalty()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare i record; l jsonb; o jsonb; earned bigint; redeemed bigint; target_earned bigint; target_redeemed bigint; actual_earned bigint; actual_redeemed bigint; ratio numeric; total_return numeric; delta bigint;
begin
 l:=coalesce(new.payload->'records'->'loyalty','[]');
 for i in select v.id,v.customer_id,v.document from public.ts_invoices v where v.kind='sale' and v.customer_id is not null and v.document->>'source'='web_order' and (exists(select 1 from public.ts_invoice_adjustments a where a.invoice_id=v.id) or exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=v.id)) loop
 select x into o from jsonb_array_elements(coalesce(new.payload->'records'->'orders','[]')) x where x->>'id'=i.id::text;
 if o is null or o->>'status' is distinct from 'delivered' then continue;end if;
 select coalesce(sum(gross),0) into total_return from public.ts_invoice_adjustments where invoice_id=i.id;
 if exists(select 1 from public.ts_invoice_refunds where invoice_id=i.id) then total_return:=(i.document->>'total')::numeric;end if;
 if coalesce((i.document->>'total')::numeric,0)<=0 then continue;end if;
 ratio:=least(1,greatest(0,total_return/(i.document->>'total')::numeric));
 select coalesce(sum((x->>'points')::bigint),0) into earned from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and coalesce(x->>'kind','earn')='earn' and (x->>'points')::bigint>0;
 select coalesce(-sum((x->>'points')::bigint),0) into redeemed from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and x->>'kind'='redemption';
 target_earned:=-floor(earned*ratio)::bigint;target_redeemed:=floor(redeemed*ratio)::bigint;
 select coalesce(sum((x->>'points')::bigint),0) into actual_earned from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and x->>'kind'='return_earn_reverse';
 select coalesce(sum((x->>'points')::bigint),0) into actual_redeemed from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and x->>'kind'='return_redemption_restore';
 delta:=target_earned-actual_earned;
 if delta<>0 then l:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',i.customer_id,'created',now(),'points',delta,'order',i.id,'kind','return_earn_reverse'))||l;end if;
 delta:=target_redeemed-actual_redeemed;
 if delta<>0 then l:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',i.customer_id,'created',now(),'points',delta,'order',i.id,'kind','return_redemption_restore'))||l;end if;
 end loop;
 
 for i in select v.id,v.customer_id,v.document from public.ts_invoices v where v.kind='sale' and v.customer_id is not null and v.document->>'source' is distinct from 'web_order' and coalesce((v.document->>'points_used')::bigint,0)>0 and (exists(select 1 from public.ts_invoice_adjustments a where a.invoice_id=v.id) or exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=v.id)) loop
  select coalesce(sum(gross),0) into total_return from public.ts_invoice_adjustments where invoice_id=i.id;
  if exists(select 1 from public.ts_invoice_refunds where invoice_id=i.id) then total_return:=(i.document->>'total')::numeric;end if;
  if coalesce((i.document->>'total')::numeric,0)<=0 then continue;end if;
  ratio:=least(1,greatest(0,total_return/(i.document->>'total')::numeric));
  redeemed:=(i.document->>'points_used')::bigint;target_redeemed:=floor(redeemed*ratio)::bigint;
  select coalesce(sum((x->>'points')::bigint),0) into actual_redeemed from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and x->>'kind'='return_redemption_restore' and x->>'source'='invoice';
  delta:=target_redeemed-actual_redeemed;
  if delta<>0 then l:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',i.customer_id,'created',now(),'points',delta,'order',i.id,'kind','return_redemption_restore','source','invoice'))||l;end if;
 end loop;
 if l is distinct from coalesce(new.payload->'records'->'loyalty','[]') then new.payload:=jsonb_set(new.payload,'{records,loyalty}',l,true);end if;
 return new;
end $function$
;
