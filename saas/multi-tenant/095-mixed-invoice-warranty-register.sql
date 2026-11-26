-- Complete mixed POS invoice issue and provide read-only warranty register and immutable claim history.
begin;
CREATE OR REPLACE FUNCTION tenant_private.issue_sale_invoice(s uuid, b uuid, r uuid, c text, items jsonb, meta jsonb, terms jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prev tenant_private.sale_invoice_details%rowtype;payload jsonb;doc jsonb;result jsonb;ln jsonb;p uuid;months integer;serial text;customer uuid;customer_name text;customer_phone text;title text;note text;issued date;sid uuid;warranties jsonb:='[]';
begin
 perform 1 from public.saas_stores where id=s for update;
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.current_branch_scope(s) is not null and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 if r is null or c is null or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or jsonb_typeof(meta) is distinct from 'object' or octet_length(meta::text)>40000 or (select count(*) from jsonb_object_keys(meta))<>5 or not(meta ?& array['title','customer','phone','terms','lines']) then raise exception 'Invalid invoice metadata';end if;
 if jsonb_typeof(meta->'title') is distinct from 'string' or jsonb_typeof(meta->'customer') is distinct from 'string' or jsonb_typeof(meta->'phone') is distinct from 'string' or jsonb_typeof(meta->'terms') is distinct from 'string' or jsonb_typeof(meta->'lines') is distinct from 'array' then raise exception 'Invalid invoice metadata';end if;
 title:=btrim(meta->>'title');customer_name:=btrim(meta->>'customer');customer_phone:=btrim(meta->>'phone');note:=btrim(meta->>'terms');
 if length(title)>100 or length(customer_name)>160 or length(customer_phone)>100 or length(note)>1000 or jsonb_array_length(meta->'lines')<>jsonb_array_length(items) then raise exception 'Invalid invoice metadata';end if;
 if terms is not null and (jsonb_typeof(terms) is distinct from 'object' or not (((select count(*) from jsonb_object_keys(terms))=4 and terms ?& array['customer','deposit','count','due']) or ((select count(*) from jsonb_object_keys(terms))=2 and terms ?& array['tenders','refund_policy']))) then raise exception 'Invalid credit terms';end if;
 if terms is not null and tenant_private.member_role(s)<>'owner' then raise exception 'Owner required for credit' using errcode='42501';end if;
 payload:=jsonb_build_object('branch',b,'currency',c,'items',items,'meta',meta,'terms',terms);
 select * into prev from tenant_private.sale_invoice_details where store_id=s and request_id=r;
 if found then if prev.actor<>auth.uid() or prev.payload is distinct from payload then raise exception 'Conflicting invoice request';end if;return prev.result;end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale cannot receive new invoice details';end if;
 issued:=(now() at time zone 'Asia/Damascus')::date;
 for ln in select value from jsonb_array_elements(meta->'lines') loop
  if jsonb_typeof(ln) is distinct from 'object' or (select count(*) from jsonb_object_keys(ln))<>3 or not (ln ?& array['product_id','months','serial']) or jsonb_typeof(ln->'product_id') is distinct from 'string' or jsonb_typeof(ln->'months') is distinct from 'number' or jsonb_typeof(ln->'serial') is distinct from 'string' or coalesce(ln->>'months','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid warranty line';end if;
  p:=(ln->>'product_id')::uuid;months:=(ln->>'months')::integer;serial:=btrim(ln->>'serial');
  if p is null or months not between 0 and 120 or length(serial)>150 or not exists(select 1 from jsonb_array_elements(items) i where (i->>'product_id')::uuid=p) or exists(select 1 from jsonb_array_elements(warranties) i where (i->>'product_id')::uuid=p) then raise exception 'Invalid warranty line';end if;
  warranties:=warranties||jsonb_build_array(jsonb_build_object('product_id',p,'months',months,'serial',serial,'until',case when months>0 then (issued+make_interval(months=>months))::date else null end));
 end loop;
 if terms is not null and terms ? 'tenders' then
  if b is null then result:=tenant_private.record_mixed_sale(s,r,c,items,terms->'tenders',terms->>'refund_policy');
  else result:=tenant_private.branch_mixed_sale(s,b,r,c,items,terms->'tenders',terms->>'refund_policy');end if;
 elsif terms is not null then
  customer:=(terms->>'customer')::uuid;
  select name,phone into customer_name,customer_phone from public.mt_customers where store_id=s and id=customer;
  if not found then raise exception 'Unknown customer';end if;
  if b is null then result:=tenant_private.record_credit_sale(s,r,c,items,customer,(terms->>'deposit')::bigint,(terms->>'count')::integer,(terms->>'due')::date);
  else result:=tenant_private.branch_credit_sale(s,b,r,c,items,customer,(terms->>'deposit')::bigint,(terms->>'count')::integer,(terms->>'due')::date);end if;
 else
  if b is null then result:=tenant_private.record_currency_sale(s,r,c,items);
  else result:=tenant_private.branch_cash_sale(s,b,r,c,items);end if;
 end if;
 sid:=(result->>'id')::uuid;
 doc:=jsonb_build_object('title',title,'customer',customer_name,'phone',customer_phone,'terms',note,'lines',warranties,'issued',issued);
 insert into tenant_private.sale_invoice_details values(s,sid,r,auth.uid(),payload,doc,result,now());return result;
end $function$;

create function tenant_private.sale_warranty_register(s uuid,q text,filter_state text,off integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(s);sc uuid:=tenant_private.current_branch_scope(s);today date:=(now() at time zone 'Asia/Damascus')::date;
begin
 if role_now is null or role_now not in ('owner','cashier') or not coalesce(tenant_private.staff_action_allowed(s,'sales_read'),false) then raise exception 'Warranty access denied' using errcode='42501';end if;
 if q is null or length(q)>160 or filter_state is null or filter_state not in ('all','active','expired','returned') or off is null or off not between 0 and 100000 then raise exception 'Invalid warranty page';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.number desc,x.product_id) from (
 select a.id sale_id,a.number,a.currency,a.total_minor,a.payment_mode,a.created_at,a.request_id,l.product_id,l.product_name,l.sku,l.units,coalesce(ret.units,0) returned_units,l.units-coalesce(ret.units,0) covered_units,d.document->>'customer' customer,w->>'serial' serial,(w->>'months')::integer months,(w->>'until')::date until_date,b.branch_id,
 case when l.units<=coalesce(ret.units,0) then 'returned' when (w->>'until')::date<today then 'expired' else 'active' end state
 from tenant_private.sale_invoice_details d join public.mt_sales a on a.store_id=d.store_id and a.id=d.sale_id
 join public.mt_sale_lines l on l.store_id=a.store_id and l.sale_id=a.id
 cross join lateral jsonb_array_elements(d.document->'lines') w
 left join tenant_private.branch_sales b on b.store_id=a.store_id and b.sale_id=a.id
 left join lateral (select sum(r.units)::bigint units from public.mt_returns r where r.store_id=a.store_id and r.sale_id=a.id and r.product_id=l.product_id) ret on true
 where d.store_id=s and (role_now='owner' or a.actor=auth.uid()) and (sc is null or sc=b.branch_id) and (w->>'product_id')::uuid=l.product_id and (w->>'months')::integer>0
 and (btrim(q)='' or strpos(lower(concat_ws(' ',a.number::text,l.product_name,l.sku,d.document->>'customer',w->>'serial')),lower(btrim(q)))>0)
 and (filter_state='all' or filter_state=case when l.units<=coalesce(ret.units,0) then 'returned' when (w->>'until')::date<today then 'expired' else 'active' end)
 order by a.number desc,l.product_id offset off limit 50)x),'[]'::jsonb);
end $$;
create function public.mt_sale_warranty_register(p_store uuid,p_query text,p_state text,p_offset integer default 0) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.sale_warranty_register(p_store,p_query,p_state,p_offset)$$;
revoke all on function tenant_private.sale_warranty_register(uuid,text,text,integer),public.mt_sale_warranty_register(uuid,text,text,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.sale_warranty_register(uuid,text,text,integer),public.mt_sale_warranty_register(uuid,text,text,integer) to authenticated;
CREATE OR REPLACE FUNCTION tenant_private.business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t text;v jsonb;out_data jsonb:='{}';n bigint;total_rows bigint:=0;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not tenant_private.shared_licensed(p_store) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner and AAL2 required' using errcode='42501';end if;
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details'] loop
 -- Fixed relation allowlist; no user-supplied table or SQL text.
 execute format('select count(*) from (select 1 from %I.%I where store_id=$1 limit 5001)x',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>5000 or total_rows+n>20000 then raise exception 'Export exceeds browser snapshot limit; use controlled server backup' using errcode='22023';end if;
 -- Limit before building the aggregate, including large image-containing product rows.
 execute format('select coalesce(sum(octet_length(to_jsonb(r)::text)),0) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>4000000 or octet_length(out_data::text)+n>8000000 then raise exception 'Export exceeds browser byte limit' using errcode='22023';end if;
 execute format('select coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into v using p_store;
 total_rows:=total_rows+jsonb_array_length(v);out_data:=out_data||jsonb_build_object(t,v);
 end loop;
 return jsonb_build_object('version',1,'scope','business_export_only','store',p_store,'captured_at',now(),'rows',total_rows,'tables',out_data);
end $function$;
commit;
