begin;
alter table public.ts_branch_events drop constraint ts_branch_events_kind_check;
alter table public.ts_branch_events add constraint ts_branch_events_kind_check check(kind in ('transfer','sale','return'));
alter table public.ts_branch_events add column original_sale_id uuid references public.ts_branch_events(id),add column return_reason text,add column request_args jsonb;
create index ts_branch_return_sale_idx on public.ts_branch_events(original_sale_id) where kind='return';
alter table public.ts_business_entries drop constraint ts_business_entries_kind_check;
alter table public.ts_business_entries add constraint ts_business_entries_kind_check check(kind in ('invoice','initial_payment','receipt','expense','cash_in','cost','refund','cost_reverse','debt_cancel','purchase','supplier_payment','branch_sale','branch_cost','branch_transfer','payroll_accrual','payroll_payment','branch_refund','branch_cost_reverse'));
create or replace function techstore_private.post_branch_pair() returns trigger language plpgsql security definer set search_path='' as $$
declare e public.ts_branch_events%rowtype;
begin
 select * into e from public.ts_branch_events where id=new.event_id;
 insert into public.ts_business_entries(actor,kind,debit,credit,amount,memo,source_key) values(e.actor,case when e.kind='transfer' then 'branch_transfer' when e.kind='return' and new.debit_account='sales' then 'branch_refund' when e.kind='return' then 'branch_cost_reverse' when new.credit_account='sales' then 'branch_sale' else 'branch_cost' end,case when new.debit_account='sales' then 'sales_revenue' else new.debit_account end,case when new.credit_account='sales' then 'sales_revenue' else new.credit_account end,new.amount,'Branch '||e.id,'branch-pair:'||new.id);
 return new;
end $$;
create function techstore_private.branch_return(p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.ts_workspace%rowtype; original public.ts_branch_events%rowtype; e public.ts_branch_events%rowtype; req uuid; sid uuid; q bigint; previous bigint; gross numeric; c numeric; cash_value numeric; reason text; unit_value numeric;
begin
 if techstore_private.live_session() is distinct from true or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>5000 then raise exception 'Invalid request';end if;
 req:=(p_args->>'request_id')::uuid;sid:=(p_args->>'sale_id')::uuid;q:=(p_args->>'qty')::bigint;reason:=btrim(coalesce(p_args->>'reason',''));
 if req is null or sid is null or q is null or q not between 1 and 1000000 or length(reason) not between 1 and 500 or p_args->'inspected' is distinct from 'true'::jsonb then raise exception 'Inspection and valid return required';end if;
 select * into w from public.ts_workspace where id=1 for update;
 select * into e from public.ts_branch_events where request_id=req;
 if found then if e.actor<>auth.uid() or e.kind<>'return' or e.request_args is distinct from p_args then raise exception 'Request ID conflict';end if;return jsonb_build_object('id',e.id,'amount',e.amount,'duplicate',true);end if;
 select * into original from public.ts_branch_events where id=sid and kind='sale';
 if not found then raise exception 'Original branch sale unavailable';end if;
 if not exists(select 1 from public.ts_pro_entries where id=original.branch_from and kind='branches' and not archived) then raise exception 'Reopen branch first';end if;
 if not exists(select 1 from jsonb_array_elements(coalesce(w.payload->'data'->'products','[]')) x where x->>'id'=original.product_id) then raise exception 'Product unavailable';end if;
 select coalesce(sum(qty),0) into previous from public.ts_branch_events where original_sale_id=sid and kind='return';
 if q>original.qty-previous then raise exception 'Return exceeds sold quantity';end if;
 gross:=round(original.amount*(previous+q)/original.qty,2)-round(original.amount*previous/original.qty,2);
 c:=round(original.cost*(previous+q)/original.qty,2)-round(original.cost*previous/original.qty,2);
 select coalesce(sum(case when debit='cash:'||original.branch_from::text then amount when credit='cash:'||original.branch_from::text then -amount else 0 end),0) into cash_value from public.ts_business_entries;
 if gross>cash_value then raise exception 'Insufficient recorded branch cash';end if;
 unit_value:=round(original.cost/original.qty,4);
 insert into public.ts_branch_stock(branch_id,product_id,qty,unit_cost) values(original.branch_from,original.product_id,q,unit_value) on conflict(branch_id,product_id) do update set unit_cost=round((public.ts_branch_stock.qty*public.ts_branch_stock.unit_cost+excluded.qty*excluded.unit_cost)/(public.ts_branch_stock.qty+excluded.qty),4),qty=public.ts_branch_stock.qty+excluded.qty;
 insert into public.ts_branch_events(request_id,actor,kind,branch_from,product_id,qty,amount,cost,original_sale_id,return_reason,request_args) values(req,auth.uid(),'return',original.branch_from,original.product_id,q,gross,c,sid,reason,p_args) returning * into e;
 if gross>0 then insert into public.ts_journal_pairs(event_id,debit_account,credit_account,amount) values(e.id,'sales','cash:'||original.branch_from::text,gross);end if;
 if c>0 then insert into public.ts_journal_pairs(event_id,debit_account,credit_account,amount) values(e.id,'inventory:'||original.branch_from::text,'cost_of_sales',c);end if;
 update public.ts_workspace set revision=revision+1,updated_at=now() where id=1;
 insert into public.ts_audit(actor,action) values(auth.uid(),'branch return '||e.id);return jsonb_build_object('id',e.id,'amount',gross,'duplicate',false);
end $$;
revoke all on function techstore_private.branch_return(jsonb) from public,anon,authenticated;
grant execute on function techstore_private.branch_return(jsonb) to authenticated;
create or replace function public.ts_branch_operation(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select case when p_action='return' then techstore_private.branch_return(p_args) else techstore_private.branch_operation(p_action,p_args) end $$;
create or replace function techstore_private.business_summary() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 select jsonb_build_object('sales',coalesce(sum(case when credit='sales_revenue' then amount when debit='sales_revenue' then -amount else 0 end),0),'repairs',coalesce(sum(amount) filter(where credit='repair_revenue'),0),'cost',coalesce(sum(case when kind in ('cost','branch_cost') then amount when kind in ('cost_reverse','branch_cost_reverse') then -amount else 0 end),0),'expenses',coalesce(sum(amount) filter(where kind in ('expense','payroll_accrual')),0),'supplier_payable',coalesce(sum(case when credit='supplier_payable' then amount when debit='supplier_payable' then -amount else 0 end),0),'payroll_payable',coalesce(sum(case when credit='payroll_payable' then amount when debit='payroll_payable' then -amount else 0 end),0),'branch_cash',coalesce(sum(case when debit like 'cash:%' then amount when credit like 'cash:%' then -amount else 0 end),0),'receivable',coalesce(sum(case when debit='receivables' then amount when credit='receivables' then -amount else 0 end),0)) into result from public.ts_business_entries;
 return result||jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(a)) from (select p.user_id,p.name,count(distinct i.id) as invoices,coalesce(sum(e.amount) filter(where e.debit='receivables' and e.kind='invoice'),0) -coalesce(sum(e.amount) filter(where e.kind in ('refund','debt_cancel')),0) as billed,coalesce(sum(case when e.kind in ('receipt','initial_payment') and e.credit='receivables' then e.amount when e.kind='refund' then -e.amount else 0 end),0) as paid from public.ts_profiles p join public.ts_invoices i on i.customer_id=p.user_id join public.ts_business_entries e on e.invoice_id=i.id group by p.user_id,p.name order by p.name limit 500) a),'[]'));
end $$;




create or replace function techstore_private.supplier_finance(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; pur jsonb; b public.ts_supplier_bills%rowtype; pay public.ts_supplier_payments%rowtype; pid text; req uuid; a numeric; paid numeric; memo_value text; product_id text; prod jsonb; idx int; q int; unit_cost numeric; d jsonb; rec jsonb; existing public.ts_supplier_bills%rowtype;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or (u.role='admin' or (u.role='stock' and (p_action='purchase' or (p_action='list' and techstore_private.staff_allowed(u.user_id,'supplier_read'))))) is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
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
end $$;



commit;