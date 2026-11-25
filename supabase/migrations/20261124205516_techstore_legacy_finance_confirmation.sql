CREATE OR REPLACE FUNCTION techstore_private.operation_status(p_scope text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 when 'records:debts' then select id::text into ref from public.ts_business_entries where request_id=p_request and actor=u and kind='legacy_opening' and source_key='legacy-opening:debts:'||p_request;
 when 'records:installments' then select id::text into ref from public.ts_business_entries where request_id=p_request and actor=u and kind='legacy_opening' and source_key='legacy-opening:installments:'||p_request;
 when 'operation:debts' then select e.id::text into ref from public.ts_business_entries e where e.request_id=p_request and e.actor=u and e.kind='legacy_payment' and exists(select 1 from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'records'->'payments','[]')) x where w.id=1 and x->>'id'=p_request::text and x->>'kind'='debts');
 when 'operation:installments' then select e.id::text into ref from public.ts_business_entries e where e.request_id=p_request and e.actor=u and e.kind='legacy_payment' and exists(select 1 from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'records'->'payments','[]')) x where w.id=1 and x->>'id'=p_request::text and x->>'kind'='installments');
 else raise exception 'Unknown operation';
 end case;
 return jsonb_build_object('applied',ref is not null,'reference',ref);
end $function$
;
