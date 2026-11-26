-- Owner-scoped, bounded FX snapshot for mixed-tender drafts.
-- No offline financial posting; existing current-rate checks are still authoritative.
create function tenant_private.offline_mixed_rates(s uuid,c text) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is distinct from 'owner' or not coalesce(tenant_private.can_sell(s),false) then raise exception 'Owner sale permission required' using errcode='42501';end if;
 if c is null or not exists(select 1 from tenant_private.sale_currencies where store_id=s and currency=c) then raise exception 'Invoice currency unavailable';end if;
 return jsonb_build_object('version',1,'store',s,'actor',auth.uid(),'currency',c,'capturedAt',now(),'rates',(
 select coalesce(jsonb_agg(jsonb_build_object('currency',sc.currency,'rate_id',q.id,'numerator',case when sc.currency=c then 1 else q.numerator end,'denominator',case when sc.currency=c then 1 else q.denominator end,'expires_at',case when sc.currency=c then null else q.created_at+interval '24 hours' end) order by sc.currency),'[]'::jsonb)
 from tenant_private.sale_currencies sc left join lateral(select r.id,r.numerator,r.denominator,r.created_at from public.mt_fx_rates r where r.store_id=s and r.from_currency=sc.currency and r.to_currency=c and r.created_at between now()-interval '24 hours' and now() order by r.created_at desc,r.id desc limit 1)q on sc.currency<>c
 where sc.store_id=s and (sc.currency=c or q.id is not null)));
end $$;
create function public.mt_offline_mixed_rates(p_store uuid,p_currency text) returns jsonb language sql stable set search_path='' as $$select tenant_private.offline_mixed_rates(p_store,p_currency)$$;
revoke all on function tenant_private.offline_mixed_rates(uuid,text),public.mt_offline_mixed_rates(uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_mixed_rates(uuid,text),public.mt_offline_mixed_rates(uuid,text) to authenticated;

CREATE OR REPLACE FUNCTION tenant_private.pos_membership_financed(s uuid, b uuid, r uuid, t uuid, c text, items jsonb, meta jsonb, terms jsonb, expected bigint, prices jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a tenant_private.pos_authorizations%rowtype;old tenant_private.pos_loyalty_sales%rowtype;q jsonb;net_items jsonb;payload jsonb;result jsonb;sid uuid;credit boolean;
begin
 if r is null or t is null or expected is null or expected<1 or jsonb_typeof(prices) is distinct from 'object' or jsonb_typeof(terms) is distinct from 'object' then raise exception 'Invalid priced sale';end if;
 credit:=terms ? 'customer';
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.member_role(s)='cashier' and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if credit then
 if not tenant_private.receivable_allowed(s,'credit_sale') or not tenant_private.receivable_branch_allowed(s,b) or not(terms ?& array['customer','deposit','count','due']) or (select count(*) from jsonb_object_keys(terms))<>4 then raise exception 'Credit denied';end if;
 else
 if tenant_private.member_role(s) is distinct from 'owner' or not(terms ?& array['tenders','refund_policy']) or (select count(*) from jsonb_object_keys(terms))<>2 then raise exception 'Mixed sale denied';end if;
 end if;
 perform 1 from public.saas_stores where id=s for update;
 perform tenant_private.assert_receivable_live(s,r,case when credit then 'credit' else 'mixed' end);
 payload:=jsonb_build_object('branch',b,'token',t,'currency',c,'lines',items,'meta',meta,'terms',terms,'expected',expected,'prices',prices);
 select * into old from tenant_private.pos_loyalty_sales where store_id=s and request_id=r;
 if found then
 if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting membership sale';end if;
 return old.result;
 end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale request';end if;
 select * into strict a from tenant_private.pos_authorizations where store_id=s and token=t;
 if not a.use_membership or a.points<>0 or a.spend_requested is not null then raise exception 'Membership-only code required';end if;
 q:=tenant_private.pos_quote(s,b,t,c,items);
 if q->>'price_tier' is null or (q->>'total_minor')::bigint<>expected or q->'prices' is distinct from prices then raise exception 'Membership quote changed';end if;
 select jsonb_agg(jsonb_build_object('product_id',(x->>'product_id')::uuid,'units',(x->>'units')::bigint,'expected_price_minor',(prices->>(x->>'product_id'))::bigint) order by (x->>'product_id')::uuid) into net_items from jsonb_array_elements(items) x;
 insert into tenant_private.membership_sale_context values(s,r,auth.uid(),c,prices);
 result:=tenant_private.issue_sale_invoice(s,b,r,c,net_items,meta,terms);
 delete from tenant_private.membership_sale_context where store_id=s and request_id=r;
 sid:=(result->>'id')::uuid;
 if (result->>'total_minor')::bigint<>expected then raise exception 'Priced invoice mismatch';end if;
 result:=result||q;
 insert into tenant_private.pos_loyalty_sales(store_id,sale_id,token,buyer,points,basis_points,gross_minor,discount_minor,actor,request_id,branch_id,payload,result,price_tier)
 values(s,sid,t,a.buyer,0,(q->>'basis_points')::int,a.gross_minor,(q->>'discount_minor')::bigint,auth.uid(),r,b,payload,result,q->>'price_tier');
 update tenant_private.sale_invoice_details set document=document||jsonb_build_object('loyalty',jsonb_build_object('gross_minor',a.gross_minor,'discount_minor',(q->>'discount_minor')::bigint,'points',0,'price_tier',q->>'price_tier')) where store_id=s and sale_id=sid;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.record_mixed_sale(p_store uuid, p_request uuid, p_currency text, p_lines jsonb, p_tenders jsonb, p_refund_policy text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare x jsonb; v_product uuid; v_units bigint; v_expected bigint; v_price bigint; v_sum bigint:=0; v_norm jsonb; v_previous jsonb; v_settings tenant_private.sales_settings%rowtype; v_sale public.mt_sales%rowtype; pr public.mt_products%rowtype; tn jsonb; previous_tenders jsonb;
begin
 perform tenant_private.owner_write(p_store);
 perform 1 from public.saas_stores where id=p_store for update;
 perform tenant_private.assert_receivable_live(p_store,p_request,'mixed');
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Sale not permitted' using errcode='42501';end if;
 if p_refund_policy is distinct from 'invoice_currency' then raise exception 'Explicit invoice currency refund policy required' using errcode='22023';end if;
 tn:=tenant_private.normalize_tenders(p_tenders);
 if p_currency is null or p_currency not in ('SYP','USD','EUR') or p_request is null or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid sale' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>50000 then raise exception 'Invalid sale size' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid line' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line values' using errcode='22023';end if;
  v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  if v_units not between 1 and 10000 or v_expected not between 1 and 100000000 then raise exception 'Invalid line amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into v_norm from jsonb_array_elements(p_lines);
 select * into v_sale from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then
  select jsonb_agg(jsonb_build_object('product_id',l.product_id,'units',l.units,'expected_price_minor',l.unit_price_minor) order by l.product_id) into v_previous from public.mt_sale_lines l where l.store_id=p_store and l.sale_id=v_sale.id;
  select tenders into previous_tenders from public.mt_mixed_sales where store_id=p_store and sale_id=v_sale.id;
  if v_sale.payment_mode<>'mixed' or previous_tenders is distinct from tn then raise exception 'Conflicting tender request' using errcode='22023';end if;
  if v_sale.actor<>auth.uid() or v_sale.currency<>p_currency or v_previous is distinct from v_norm then raise exception 'Conflicting sale request' using errcode='22023';end if;
  return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
 end if;
 select * into v_settings from tenant_private.sales_settings where store_id=p_store for update;
 if not found or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Enable sale currency first' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=v_product for update;
  if not found or pr.quantity<v_units then raise exception 'Insufficient stock or unknown product' using errcode='22023';end if;
  select price_minor into v_price from public.mt_product_prices where store_id=p_store and product_id=v_product and currency=p_currency;
  if not found then raise exception 'Unavailable product';end if;
  v_price:=tenant_private.authorized_sale_unit_price(p_store,p_request,p_currency,v_product,v_price);
  if v_price is distinct from v_expected then raise exception 'Unavailable product, price changed or insufficient stock' using errcode='22023';end if;
  v_sum:=v_sum+v_units*v_price;
 end loop;
 perform tenant_private.verify_tenders(p_store,p_currency,tn,v_sum);
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(p_store,v_settings.next_number,p_request,auth.uid(),p_currency,v_sum,'mixed') returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;
  update public.mt_products set quantity=quantity-v_units where store_id=p_store and id=v_product returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,v_sale.id,pr.id,pr.sku,pr.name,v_units,(x->>'expected_price_minor')::bigint);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pr.id,-v_units,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 perform tenant_private.post_tenders(p_store,v_sale.id,p_currency,tn);
 return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.resolve_receivable(s uuid, op jsonb, mode text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r uuid;k text;u uuid:=auth.uid();x jsonb;v jsonb;old_n text;old_p text;found_record boolean:=false;same boolean:=false;prior text;sid uuid;b uuid;items jsonb;meta jsonb;terms jsonb;invoice_payload jsonb;
begin
 if u is null or tenant_private.member_role(s) is null then raise exception 'Active membership required' using errcode='42501';end if;
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>100000 or (op->>'store')::uuid is distinct from s or mode is null or mode not in ('inspect','cancel','acknowledge') then raise exception 'Invalid resolution request' using errcode='22023';end if;
 r:=(op->>'requestId')::uuid;k:=op->>'kind';
 if r is null or k is null or k not in ('customer','customerEdit','pay','credit','standaloneOpen','standalonePay','cashSale','mixed') or (k='cashSale' and jsonb_typeof(op->'localPricing') is distinct from 'object') or (k='mixed' and jsonb_typeof(op->'invoice') is distinct from 'object') then raise exception 'Invalid resolution reference' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=s for update;
 if tenant_private.member_role(s) is null then raise exception 'Membership ended' using errcode='42501';end if;
 select outcome into prior from tenant_private.receivable_resolutions where store_id=s and actor=u and request_id=r and kind=k;
 if prior is not null then return prior;end if;
 x:=op->'payload';
 case k
 when 'customer' then
  select to_jsonb(c) into v from public.mt_customers c where c.store_id=s and c.request_id=r and c.actor=u;
  found_record:=found;
  if found_record then
   select e.old_name,e.old_phone into old_n,old_p from tenant_private.customer_profile_edits e where e.store_id=s and e.customer_id=(v->>'id')::uuid order by e.revision limit 1;
   same:=coalesce(old_n,v->>'name')=btrim(op->>'name') and coalesce(old_p,v->>'phone')=btrim(op->>'phone');
  end if;
 when 'customerEdit' then
  select to_jsonb(e) into v from tenant_private.customer_profile_edits e where e.store_id=s and e.id=r and e.actor=u;
  found_record:=found;
  if found_record then same:=(v->>'customer_id')::uuid=(op->>'customer')::uuid and v->>'old_name'=op->>'oldName' and v->>'old_phone'=op->>'oldPhone' and v->>'new_name'=btrim(op->>'name') and v->>'new_phone'=btrim(op->>'phone');end if;
 when 'pay' then
  select to_jsonb(p)||jsonb_build_object('currency',d.currency) into v from public.mt_debt_payments p join public.mt_debts d on d.store_id=p.store_id and d.id=p.debt_id where p.store_id=s and p.request_id=r and p.actor=u;
  found_record:=found;
  if found_record then same:=not (v->>'is_deposit')::boolean and v->>'settlement_method'='cash' and (v->>'debt_id')::uuid=(op->>'debt')::uuid and (v->>'amount_minor')::bigint=(op->>'amount')::bigint and v->>'currency'=op->>'currency';end if;
 when 'standaloneOpen' then
  select to_jsonb(d) into v from tenant_private.standalone_debts d where d.store_id=s and d.id=r and d.actor=u;
  found_record:=found;
  if found_record then same:=(v->>'customer_id')::uuid is not distinct from (x->>'customer')::uuid and (v->>'branch_id')::uuid is not distinct from (x->>'branch')::uuid and v->>'direction'=x->>'direction' and v->>'party'=btrim(x->>'party') and v->>'phone'=btrim(x->>'phone') and v->>'currency'=x->>'currency' and (v->>'principal_minor')::bigint=(x->>'amount')::bigint and (v->>'installment_count')::integer=(x->>'count')::integer and (v->>'first_due')::date=(x->>'due')::date and v->>'notes'=btrim(x->>'notes');end if;
 when 'standalonePay' then
  select to_jsonb(p) into v from tenant_private.standalone_debt_payments p where p.store_id=s and p.id=r and p.actor=u;
  found_record:=found;
  if found_record then same:=(v->>'debt_id')::uuid=(x->>'debt')::uuid and (v->>'amount_minor')::bigint=(x->>'amount')::bigint and v->>'memo'=btrim(x->>'memo');end if;
 when 'cashSale','mixed' then
  x:=op;terms:=case when k='mixed' then jsonb_build_object('tenders',op->'tenders','refund_policy',op->>'refundPolicy') else null end;
  select a.id,to_jsonb(a) into sid,v from public.mt_sales a where a.store_id=s and a.request_id=r and a.actor=u;
  found_record:=found;
  if found_record and v->>'payment_mode'=(case when k='mixed' then 'mixed' else 'cash' end) then
   if x ? 'localPricing' then
   same:=exists(select 1 from tenant_private.local_membership_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'customer',(x->'localPricing'->>'customer')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'localPricing'->>'expected')::bigint,'prices',x->'localPricing'->'prices'));
   elsif k='mixed' and x ? 'membership' then
   same:=exists(select 1 from tenant_private.pos_loyalty_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'token',(x->'membership'->>'token')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'membership'->>'expected')::bigint,'prices',x->'membership'->'prices'));
   elsif k='mixed' then
   select payload into invoice_payload from tenant_private.sale_invoice_details where store_id=s and sale_id=sid;
   same:=invoice_payload=jsonb_build_object('branch',(x->>'branch')::uuid,'currency',x->>'currency','items',x->'lines','meta',x->'invoice','terms',terms);
   end if;
  end if;
 when 'credit' then
  x:=op->'sale';terms:=op->'terms';
  select a.id,to_jsonb(a) into sid,v from public.mt_sales a where a.store_id=s and a.request_id=r and a.actor=u;
  found_record:=found;
  if found_record and v->>'payment_mode'='credit' then
   select branch_id into b from tenant_private.branch_sales where store_id=s and sale_id=sid;
   select jsonb_agg(jsonb_build_object('product_id',l.product_id,'units',l.units,'expected_price_minor',l.unit_price_minor) order by l.product_id) into items from public.mt_sale_lines l where l.store_id=s and l.sale_id=sid;
   select payload into invoice_payload from tenant_private.sale_invoice_details where store_id=s and sale_id=sid;
   same:=((x->>'store')::uuid=s and (x->>'requestId')::uuid=r and b is not distinct from (x->>'branch')::uuid and v->>'currency'=x->>'currency' and items=x->'lines' and exists(select 1 from public.mt_debts d where d.store_id=s and d.sale_id=sid and d.customer_id=(terms->>'customer')::uuid and d.deposit_minor=(terms->>'deposit')::bigint and d.installment_count=(terms->>'count')::integer and d.first_due=(terms->>'due')::date));
   if x ? 'localPricing' then
    same:=exists(select 1 from tenant_private.local_membership_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'customer',(x->'localPricing'->>'customer')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'localPricing'->>'expected')::bigint,'prices',x->'localPricing'->'prices'));
   elsif x ? 'membership' then
    same:=exists(select 1 from tenant_private.pos_loyalty_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'token',(x->'membership'->>'token')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'membership'->>'expected')::bigint,'prices',x->'membership'->'prices'));
   elsif x ? 'invoice' then same:=same and invoice_payload=jsonb_build_object('branch',(x->>'branch')::uuid,'currency',x->>'currency','items',x->'lines','meta',x->'invoice','terms',terms);else same:=same and invoice_payload is null;end if;
  end if;
 end case;
 if found_record and coalesce(same,false) then return 'confirmed';end if;
 if found_record then
  if mode<>'acknowledge' then return 'conflict';end if;
  insert into tenant_private.receivable_resolutions values(s,u,r,k,'conflict_acknowledged',now());return 'conflict_acknowledged';
 end if;
 if mode<>'cancel' then return 'not_recorded';end if;
 insert into tenant_private.receivable_resolutions values(s,u,r,k,'cancelled',now());return 'cancelled';
end $function$;
