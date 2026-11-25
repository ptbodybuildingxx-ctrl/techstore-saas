begin;
create function techstore_private.operation_status(p_scope text,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
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
 when 'ops-branch:sale' then select id::text into ref from public.ts_branch_events where request_id=p_request and actor=u and kind='sale';
 when 'ops-repair:add' then select id::text into ref from public.ts_repair_evidence where request_id=p_request and actor=u;
 when 'ops-checkout:order' then select order_id into ref from public.ts_member_checkout_keys where request_id=p_request and user_id=u;
 else raise exception 'Unknown operation';
 end case;
 return jsonb_build_object('applied',ref is not null,'reference',ref);
end $$;
revoke all on function techstore_private.operation_status(text,uuid) from public,anon,authenticated;
grant execute on function techstore_private.operation_status(text,uuid) to authenticated;
create function public.ts_operation_status(p_scope text,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.operation_status(p_scope,p_request) $$;
revoke all on function public.ts_operation_status(text,uuid) from public,anon,authenticated;
grant execute on function public.ts_operation_status(text,uuid) to authenticated;
create function techstore_private.guard_invoiced_repair_parts() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.kind='part' then
 perform 1 from public.ts_workspace where id=1 for update;
 if exists(select 1 from public.ts_invoices where repair_id=new.repair_id) then raise exception 'Repair already invoiced; cannot consume additional parts';end if;
 end if;
 return new;
end $$;
revoke all on function techstore_private.guard_invoiced_repair_parts() from public,anon,authenticated;
create trigger ts_guard_invoiced_repair_parts before insert on public.ts_repair_evidence for each row execute function techstore_private.guard_invoiced_repair_parts();
commit;