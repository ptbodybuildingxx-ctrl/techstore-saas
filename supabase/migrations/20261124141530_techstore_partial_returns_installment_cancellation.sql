begin;
create table public.ts_invoice_adjustments(
 id uuid primary key default gen_random_uuid(), request_id uuid not null unique, invoice_id uuid not null references public.ts_invoices(id),actor uuid not null references public.ts_profiles(user_id),
 kind text not null check(kind in ('partial_return','cancel_installment')),gross numeric(18,2) not null check(gross>0),cash_refund numeric(18,2) not null check(cash_refund>=0),debt_cancel numeric(18,2) not null check(debt_cancel>=0),cost_reversal numeric(18,2) not null check(cost_reversal>=0),reason text not null check(length(reason) between 1 and 500),request_args jsonb not null,created_at timestamptz not null default now(),check(gross=cash_refund+debt_cancel)
);
create index ts_adjustment_invoice_idx on public.ts_invoice_adjustments(invoice_id,created_at);
create table public.ts_invoice_adjustment_lines(
 adjustment_id uuid not null references public.ts_invoice_adjustments(id),line_no int not null check(line_no between 1 and 30),product_id text not null,qty int not null check(qty>0),unit_price numeric(18,4) not null check(unit_price>=0),unit_cost numeric(18,4) not null check(unit_cost>=0),gross numeric(18,2) not null check(gross>=0),primary key(adjustment_id,line_no)
);
alter table public.ts_invoice_adjustments enable row level security;
alter table public.ts_invoice_adjustment_lines enable row level security;
revoke all on public.ts_invoice_adjustments,public.ts_invoice_adjustment_lines from public,anon,authenticated;
alter table public.ts_business_entries drop constraint ts_business_entries_kind_check;
alter table public.ts_business_entries add constraint ts_business_entries_kind_check check(kind in ('invoice','initial_payment','receipt','expense','cash_in','cost','refund','cost_reverse','debt_cancel'));
create function techstore_private.guard_old_full_refund() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.ts_invoice_adjustments where invoice_id=new.invoice_id) then raise exception 'Use the new adjustment workflow for remaining goods';end if;return new;
end $$;
revoke all on function techstore_private.guard_old_full_refund() from public,anon,authenticated;
create trigger ts_old_refund_adjustment_guard before insert on public.ts_invoice_refunds for each row execute function techstore_private.guard_old_full_refund();
create function techstore_private.invoice_adjustment(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; i public.ts_invoices%rowtype; w public.ts_workspace%rowtype; a public.ts_invoice_adjustments%rowtype; req uuid; iid uuid; k text; reason_value text; wanted jsonb; row_value jsonb; original jsonb; original_line jsonb; item jsonb; prod jsonb; line_value int; q int; sold int; previously bigint; seen int[]:='{}'; ix int; oldqty int; price_value numeric; cost_value numeric; gross_value numeric:=0; cost_total numeric:=0; cash_value numeric; paid_value numeric; refunded_value numeric; debt_value numeric; refund_cash numeric; outstanding numeric; d jsonb; out_lines jsonb:='[]'; item_total numeric;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>16000 then raise exception 'Invalid request';end if;
 iid:=(p_args->>'id')::uuid;
 select * into i from public.ts_invoices where id=iid and (u.role in ('admin','cashier') or (u.role='customer' and customer_id=u.user_id));
 if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;
 if p_action='list' then return coalesce((select jsonb_agg(to_jsonb(x)-'request_args'-'request_id'-'actor') from (select a0.*,(select jsonb_agg(to_jsonb(al)-'adjustment_id' order by al.line_no) from public.ts_invoice_adjustment_lines al where al.adjustment_id=a0.id) as lines from public.ts_invoice_adjustments a0 where a0.invoice_id=iid order by a0.created_at,a0.id) x),'[]');end if;
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
revoke all on function techstore_private.invoice_adjustment(text,jsonb) from public,anon,authenticated;
grant execute on function techstore_private.invoice_adjustment(text,jsonb) to authenticated;
create function public.ts_invoice_adjustment(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.invoice_adjustment(p_action,p_args); $$;
revoke all on function public.ts_invoice_adjustment(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_invoice_adjustment(text,jsonb) to authenticated;
create or replace function techstore_private.business_action(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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
 else
 if iid is not null then raise exception 'Invoice not allowed';end if;
 if p_action='expense' then select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into expected_value from public.ts_business_entries;if amount_value>expected_value then raise exception 'Insufficient recorded cash';end if;end if;
 insert into public.ts_business_entries(request_id,actor,kind,debit,credit,amount,memo) values(req,u.user_id,p_action,case when p_action='expense' then 'operating_expense' else 'cash' end,case when p_action='expense' then 'cash' else 'owner_contribution' end,amount_value,note) returning * into e;
 end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'business '||p_action||' '||e.id);
 return to_jsonb(e);
end $$;




create or replace function techstore_private.business_summary() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 select jsonb_build_object('sales',coalesce(sum(case when credit='sales_revenue' then amount when debit='sales_revenue' then -amount else 0 end),0),'repairs',coalesce(sum(amount) filter(where credit='repair_revenue'),0),'cost',coalesce(sum(case when kind='cost' then amount when kind='cost_reverse' then -amount else 0 end),0),'expenses',coalesce(sum(amount) filter(where kind='expense'),0),'receivable',coalesce(sum(case when debit='receivables' then amount when credit='receivables' then -amount else 0 end),0)) into result from public.ts_business_entries;
 return result||jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(a)) from (select p.user_id,p.name,count(distinct i.id) as invoices,coalesce(sum(e.amount) filter(where e.debit='receivables' and e.kind='invoice'),0) -coalesce(sum(e.amount) filter(where e.kind in ('refund','debt_cancel')),0) as billed,coalesce(sum(case when e.kind in ('receipt','initial_payment') and e.credit='receivables' then e.amount when e.kind='refund' then -e.amount else 0 end),0) as paid from public.ts_profiles p join public.ts_invoices i on i.customer_id=p.user_id join public.ts_business_entries e on e.invoice_id=i.id group by p.user_id,p.name order by p.name limit 500) a),'[]'));
end $$;


create or replace function techstore_private.installment_schedule(p_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or u.role not in ('admin','cashier','customer') then raise exception 'Access denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from (
 select s.invoice_id,i.number,i.document->>'customer' as customer,s.sequence,s.due_date,s.amount,exists(select 1 from public.ts_invoice_adjustments a where a.invoice_id=i.id and a.kind='cancel_installment') as cancelled,
 least(s.amount,greatest(0,coalesce((select sum(e.amount) from public.ts_business_entries e where e.invoice_id=i.id and e.kind='receipt'),0)-coalesce((select sum(p.amount) from public.ts_invoice_installments p where p.invoice_id=i.id and p.sequence<s.sequence),0))) as paid
 from public.ts_invoice_installments s join public.ts_invoices i on i.id=s.invoice_id
 where (p_id is null or i.id=p_id) and (u.role in ('admin','cashier') or i.customer_id=u.user_id)
 order by s.due_date,i.number,s.sequence limit 500
 ) x),'[]');
end $$;

create or replace function techstore_private.staff_action(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; target uuid; s public.ts_staff_shifts%rowtype; terms public.ts_staff_terms%rowtype; period_value date; comm numeric; pay public.ts_staff_payroll%rowtype; cap text;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active and role in ('admin','cashier','stock','tech');if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>8000 then raise exception 'Invalid request';end if;
 if p_action='my' then return jsonb_build_object('shifts',coalesce((select jsonb_agg(to_jsonb(x)) from (select * from public.ts_staff_shifts where user_id=u.user_id order by started_at desc limit 100) x),'[]'),'payroll',coalesce((select jsonb_agg(to_jsonb(x)-'actor') from (select * from public.ts_staff_payroll where user_id=u.user_id order by period desc limit 24) x),'[]'),'terms',(select to_jsonb(x) from public.ts_staff_terms x where user_id=u.user_id));end if;
 if p_action in ('clock_in','clock_out') then
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended(u.user_id::text,593227700));
 select * into s from public.ts_staff_shifts where user_id=u.user_id and ended_at is null;
 if p_action='clock_in' then if not found then insert into public.ts_staff_shifts(user_id) values(u.user_id) returning * into s;end if;
 else if not found then raise exception 'No open shift';end if;update public.ts_staff_shifts set ended_at=now() where id=s.id returning * into s;end if;
 return to_jsonb(s);
 end if;
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='list' then return jsonb_build_object('staff',coalesce((select jsonb_agg(jsonb_build_object('id',p.user_id,'name',p.name,'role',p.role,'salary',coalesce(t.monthly_salary,0),'commission',coalesce(t.commission_percent,0))) from public.ts_profiles p left join public.ts_staff_terms t on t.user_id=p.user_id where p.active and p.role in ('cashier','stock','tech')),'[]'),'shifts',coalesce((select jsonb_agg(to_jsonb(x)) from (select s.*,p.name from public.ts_staff_shifts s join public.ts_profiles p on p.user_id=s.user_id order by s.started_at desc limit 200) x),'[]'),'payroll',coalesce((select jsonb_agg(to_jsonb(x)) from (select s.*,p.name from public.ts_staff_payroll s join public.ts_profiles p on p.user_id=s.user_id order by s.period desc limit 200) x),'[]'),'permissions',coalesce((select jsonb_agg(to_jsonb(x)) from public.ts_staff_capabilities x),'[]'));end if;
 target:=(p_args->>'user_id')::uuid;
 if not exists(select 1 from public.ts_profiles where user_id=target and active and role in ('cashier','stock','tech')) then raise exception 'Invalid employee';end if;
 if p_action='terms' then insert into public.ts_staff_terms(user_id,monthly_salary,commission_percent) values(target,(p_args->>'salary')::numeric,(p_args->>'commission')::numeric) on conflict(user_id) do update set monthly_salary=excluded.monthly_salary,commission_percent=excluded.commission_percent,updated_at=now();
 elsif p_action='permission' then cap:=p_args->>'capability';insert into public.ts_staff_capabilities(user_id,capability,allowed) values(target,cap,(p_args->>'allowed')::boolean) on conflict(user_id,capability) do update set allowed=excluded.allowed;
 elsif p_action='payroll' then
 period_value:=(p_args->>'period')::date;if period_value is null or extract(day from period_value)<>1 or period_value>=date_trunc('month',current_date)::date then raise exception 'Use completed month';end if;
 select * into terms from public.ts_staff_terms where user_id=target;if not found then raise exception 'Configure salary first';end if;
 select * into pay from public.ts_staff_payroll where user_id=target and period=period_value;if found then return to_jsonb(pay);end if;
 select round(coalesce(sum(greatest(0,(i.document->>'total')::numeric-coalesce((select sum(a.gross) from public.ts_invoice_adjustments a where a.invoice_id=i.id),0))),0)*terms.commission_percent/100,2) into comm from public.ts_invoices i where i.actor=target and i.kind='sale' and coalesce(i.document->>'payment_mode','cash')='cash' and (i.created_at at time zone 'UTC')::date>=period_value and (i.created_at at time zone 'UTC')::date<(period_value+interval '1 month')::date and not exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=i.id);
 insert into public.ts_staff_payroll(user_id,period,salary,commission,total,actor) values(target,period_value,terms.monthly_salary,comm,terms.monthly_salary+comm,u.user_id) returning * into pay;
 else raise exception 'Unknown action';end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'staff '||p_action||' '||target);return jsonb_build_object('ok',true);
end $$;

commit;