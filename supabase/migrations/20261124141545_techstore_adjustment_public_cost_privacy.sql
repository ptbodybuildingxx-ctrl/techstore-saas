begin;
create or replace function techstore_private.invoice_adjustment(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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
 item_total:=round(price_value*(previously+q),2)-round(price_value*previously,2);
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
end $$;

commit;