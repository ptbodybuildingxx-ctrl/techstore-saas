-- Atomic financed redemption with existing sale, debt and tender engines.
CREATE FUNCTION tenant_private.pos_financed_mode(s uuid, b uuid, r uuid, t uuid, c text, items jsonb, meta jsonb, terms jsonb, expected bigint, prices jsonb, expected_spend jsonb)
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
 if expected_spend is not null then payload:=payload||jsonb_build_object('spend',expected_spend);end if;
 select * into old from tenant_private.pos_loyalty_sales where store_id=s and request_id=r;
 if found then
 if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting membership sale';end if;
 return old.result;
 end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale request';end if;
 select * into strict a from tenant_private.pos_authorizations where store_id=s and token=t;
 if a.points<>0 or (not a.use_membership and a.spend_requested is null) then raise exception 'Membership or spend-value code required';end if;
 q:=tenant_private.pos_quote(s,b,t,c,items);
 if (q->>'total_minor')::bigint<>expected or q->'prices' is distinct from prices then raise exception 'Financed price quote changed';end if;
 if a.spend_requested is not null then
 if expected_spend is distinct from jsonb_build_object('requested',q->'spend_requested','used',q->'spend_points_used','points_discount_minor',q->'points_discount_minor','currency_per_usd_minor',q->'currency_per_usd_minor','points_per_usd',q->'points_per_usd','max_redeem_bps',q->'max_redeem_bps','base_total_minor',q->'base_total_minor') then raise exception 'Spend-value quote changed';end if;
 elsif expected_spend is not null or q->>'price_tier' is null then raise exception 'Invalid membership quote';end if;
 select jsonb_agg(jsonb_build_object('product_id',(x->>'product_id')::uuid,'units',(x->>'units')::bigint,'expected_price_minor',(prices->>(x->>'product_id'))::bigint) order by (x->>'product_id')::uuid) into net_items from jsonb_array_elements(items) x;
 insert into tenant_private.membership_sale_context values(s,r,auth.uid(),c,prices);
 result:=tenant_private.issue_sale_invoice(s,b,r,c,net_items,meta,terms);
 delete from tenant_private.membership_sale_context where store_id=s and request_id=r;
 sid:=(result->>'id')::uuid;
 if (result->>'total_minor')::bigint<>expected then raise exception 'Priced invoice mismatch';end if;
 result:=result||q;
 insert into tenant_private.pos_loyalty_sales(store_id,sale_id,token,buyer,points,basis_points,gross_minor,discount_minor,actor,request_id,branch_id,payload,result,price_tier)
 values(s,sid,t,a.buyer,0,(q->>'basis_points')::int,a.gross_minor,(q->>'discount_minor')::bigint,auth.uid(),r,b,payload,result,q->>'price_tier');
 if a.spend_requested is not null then
 insert into tenant_private.spend_pos_redemptions(store_id,sale_id,buyer,token,requested_points,points_used,quote) values(s,sid,a.buyer,t,a.spend_requested,(q->>'spend_points_used')::bigint,q);
 end if;
 update tenant_private.sale_invoice_details set document=document||jsonb_build_object('loyalty',jsonb_build_object('gross_minor',a.gross_minor,'discount_minor',(q->>'discount_minor')::bigint,'points',0,'price_tier',q->>'price_tier','spend_points_used',q->'spend_points_used','points_discount_minor',q->'points_discount_minor')) where store_id=s and sale_id=sid;
 return result;
end $function$;
create or replace function tenant_private.pos_membership_financed(s uuid,b uuid,r uuid,t uuid,c text,items jsonb,meta jsonb,terms jsonb,expected bigint,prices jsonb) returns jsonb language sql security definer set search_path='' as $$select tenant_private.pos_financed_mode(s,b,r,t,c,items,meta,terms,expected,prices,null)$$;
create function public.mt_pos_spend_financed(p_store uuid,p_branch uuid,p_request uuid,p_token uuid,p_currency text,p_lines jsonb,p_metadata jsonb,p_terms jsonb,p_expected bigint,p_prices jsonb,p_spend jsonb) returns jsonb language sql set search_path='' as $$select tenant_private.pos_financed_mode(p_store,p_branch,p_request,p_token,p_currency,p_lines,p_metadata,p_terms,p_expected,p_prices,p_spend)$$;
revoke all on function tenant_private.pos_financed_mode(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,bigint,jsonb,jsonb),public.mt_pos_spend_financed(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,bigint,jsonb,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.pos_financed_mode(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,bigint,jsonb,jsonb),public.mt_pos_spend_financed(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,bigint,jsonb,jsonb) to authenticated;

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
   same:=exists(select 1 from tenant_private.pos_loyalty_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'token',(x->'membership'->>'token')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'membership'->>'expected')::bigint,'prices',x->'membership'->'prices')||case when x->'membership' ? 'spend' then jsonb_build_object('spend',x->'membership'->'spend') else '{}'::jsonb end);
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
    same:=exists(select 1 from tenant_private.pos_loyalty_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'token',(x->'membership'->>'token')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'membership'->>'expected')::bigint,'prices',x->'membership'->'prices')||case when x->'membership' ? 'spend' then jsonb_build_object('spend',x->'membership'->'spend') else '{}'::jsonb end);
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
