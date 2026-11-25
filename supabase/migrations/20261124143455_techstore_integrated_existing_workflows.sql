begin;
alter table public.ts_business_entries add column source_key text unique;
alter table public.ts_business_entries drop constraint ts_business_entries_kind_check;
alter table public.ts_business_entries add constraint ts_business_entries_kind_check check(kind in ('invoice','initial_payment','receipt','expense','cash_in','cost','refund','cost_reverse','debt_cancel','purchase','supplier_payment','branch_sale','branch_cost','branch_transfer','payroll_accrual','payroll_payment'));
alter table public.ts_supplier_bills add column purchase_request_id uuid unique, add column purchase_args jsonb;
alter table public.ts_staff_payroll add column paid_at timestamptz;
create function techstore_private.post_supplier_bill() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day closed';end if;
 insert into public.ts_business_entries(actor,kind,debit,credit,amount,memo,source_key) values(new.actor,'purchase','inventory','supplier_payable',new.amount,'Purchase '||new.purchase_id,'purchase:'||new.purchase_id);
 return new;
end $$;
revoke all on function techstore_private.post_supplier_bill() from public,anon,authenticated;
create trigger ts_post_supplier_bill after insert on public.ts_supplier_bills for each row execute function techstore_private.post_supplier_bill();
create function techstore_private.post_supplier_payment() returns trigger language plpgsql security definer set search_path='' as $$
declare cash_value numeric;
begin
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day closed';end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into cash_value from public.ts_business_entries;
 if new.amount>cash_value then raise exception 'Insufficient recorded cash';end if;
 insert into public.ts_business_entries(actor,kind,debit,credit,amount,memo,source_key) values(new.actor,'supplier_payment','supplier_payable','cash',new.amount,'Supplier payment '||new.purchase_id,'supplier-payment:'||new.id);
 return new;
end $$;
revoke all on function techstore_private.post_supplier_payment() from public,anon,authenticated;
create trigger ts_post_supplier_payment after insert on public.ts_supplier_payments for each row execute function techstore_private.post_supplier_payment();
create function techstore_private.post_branch_pair() returns trigger language plpgsql security definer set search_path='' as $$
declare e public.ts_branch_events%rowtype;
begin
 select * into e from public.ts_branch_events where id=new.event_id;
 insert into public.ts_business_entries(actor,kind,debit,credit,amount,memo,source_key) values(e.actor,case when e.kind='transfer' then 'branch_transfer' when new.credit_account='sales' then 'branch_sale' else 'branch_cost' end,new.debit_account,case when new.credit_account='sales' then 'sales_revenue' else new.credit_account end,new.amount,'Branch '||e.id,'branch-pair:'||new.id);
 return new;
end $$;
revoke all on function techstore_private.post_branch_pair() from public,anon,authenticated;
create trigger ts_post_branch_pair after insert on public.ts_journal_pairs for each row execute function techstore_private.post_branch_pair();
-- No existing source records are backfilled automatically: fail if this release's verified empty baseline changed.
do $$ begin if exists(select 1 from public.ts_supplier_bills) or exists(select 1 from public.ts_supplier_payments) or exists(select 1 from public.ts_journal_pairs) or exists(select 1 from public.ts_staff_payroll) then raise exception 'Historical source records require reconciliation before integration';end if;end $$;
create function techstore_private.post_payroll() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.total>0 then
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day closed';end if;
 insert into public.ts_business_entries(actor,kind,debit,credit,amount,memo,source_key) values(new.actor,'payroll_accrual','payroll_expense','payroll_payable',new.total,'Payroll '||new.id,'payroll:'||new.id);
 end if;return new;
end $$;
revoke all on function techstore_private.post_payroll() from public,anon,authenticated;
create trigger ts_post_payroll after insert on public.ts_staff_payroll for each row execute function techstore_private.post_payroll();
create function techstore_private.pay_staff_statement(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; p public.ts_staff_payroll%rowtype; cash_value numeric;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active and role='admin';if not found then raise exception 'Access denied' using errcode='42501';end if;
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 select * into p from public.ts_staff_payroll where id=p_id for update;if not found then raise exception 'Statement unavailable';end if;
 if p.paid_at is not null then return jsonb_build_object('id',p.id,'paid_at',p.paid_at,'duplicate',true);end if;
 if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day closed';end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into cash_value from public.ts_business_entries;
 if p.total>cash_value then raise exception 'Insufficient recorded cash';end if;
 if p.total>0 then insert into public.ts_business_entries(actor,kind,debit,credit,amount,memo,source_key) values(u.user_id,'payroll_payment','payroll_payable','cash',p.total,'Payroll payment '||p.id,'payroll-payment:'||p.id);end if;
 update public.ts_staff_payroll set paid_at=now() where id=p.id returning * into p;
 insert into public.ts_audit(actor,action) values(u.user_id,'payroll paid '||p.id);return jsonb_build_object('id',p.id,'paid_at',p.paid_at);
end $$;
revoke all on function techstore_private.pay_staff_statement(uuid) from public,anon,authenticated;
grant execute on function techstore_private.pay_staff_statement(uuid) to authenticated;
create function public.ts_pay_staff_statement(p_id uuid) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.pay_staff_statement(p_id) $$;
revoke all on function public.ts_pay_staff_statement(uuid) from public,anon,authenticated;
grant execute on function public.ts_pay_staff_statement(uuid) to authenticated;
create or replace function techstore_private.sync_operation(p_action text,p_args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; prior public.ts_sync_receipts%rowtype;
 req uuid; pid text; k text; q bigint; src uuid; dst uuid; prod jsonb; ix int; central bigint; actual bigint; actual_dst bigint; price_value numeric; cost_value numeric; expected bigint; expected_dst bigint; expected_price numeric; result jsonb; data_value jsonb; records_value jsonb; sale_id uuid; sale jsonb; delta bigint; amount numeric;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found or u.role not in ('admin','cashier','stock') then raise exception 'Access denied' using errcode='42501';end if;
 if p_action not in ('snapshot','apply') or jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>12000 then raise exception 'Invalid request';end if;
 select * into w from public.ts_workspace where id=1 for update;
 if p_action='snapshot' then
 return jsonb_build_object('role',u.role,'revision',w.revision,'captured_at',now(),
 'products',coalesce((select jsonb_agg(jsonb_build_object('id',p->>'id','name',left(p->>'name',200),'sku',left(p->>'sku',100),'qty',p->'qty','price',p->'price')) from jsonb_array_elements(coalesce(w.payload->'data'->'products','[]'::jsonb)) p),'[]'::jsonb),
 'branches',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title)) from public.ts_pro_entries where kind='branches' and not archived),'[]'::jsonb) else '[]'::jsonb end,
 'stock',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('branch_id',branch_id,'product_id',product_id,'qty',qty)) from public.ts_branch_stock),'[]'::jsonb) else '[]'::jsonb end);
 end if;
 req:=(p_args->>'request_id')::uuid;k:=p_args->>'kind';pid:=p_args->>'product';q:=(p_args->>'qty')::bigint;src:=nullif(p_args->>'from','')::uuid;dst:=nullif(p_args->>'to','')::uuid;
 if req is null or pid is null or length(pid)>200 or q is null or q<0 or q>1000000 or k not in ('pos','count','transfer','sale') then raise exception 'Invalid operation';end if;
 if (k='pos' and u.role not in ('admin','cashier')) or (k='count' and u.role not in ('admin','stock')) or (k in ('transfer','sale') and u.role<>'admin') then raise exception 'Access denied' using errcode='42501';end if;
 if k<>'count' and q=0 then raise exception 'Quantity must be positive';end if;
 if k in ('pos','count') and (src is not null or dst is not null) then raise exception 'Central operation only';end if;
 if k='sale' and (src is null or dst is not null) then raise exception 'Invalid branch sale';end if;
 if k='transfer' and src is not distinct from dst then raise exception 'Different locations required';end if;
 select * into prior from public.ts_sync_receipts where request_id=req;
 if found then if prior.actor<>u.user_id or prior.kind<>k or prior.args is distinct from p_args then raise exception 'Request ID conflict';end if;return prior.result||jsonb_build_object('duplicate',true);end if;
 data_value:=w.payload->'data';records_value:=coalesce(w.payload->'records','{}'::jsonb);
 select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(data_value->'products','[]'::jsonb)) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null then return jsonb_build_object('status','conflict','reason','product_missing');end if;
 if src is not null and not exists(select 1 from public.ts_pro_entries where id=src and kind='branches' and not archived) then return jsonb_build_object('status','conflict','reason','source_closed');end if;
 if dst is not null and not exists(select 1 from public.ts_pro_entries where id=dst and kind='branches' and not archived) then return jsonb_build_object('status','conflict','reason','destination_closed');end if;
 central:=(prod->>'qty')::bigint;price_value:=(prod->>'price')::numeric;cost_value:=(prod->>'cost')::numeric;
 actual:=case when src is null then central else coalesce((select qty from public.ts_branch_stock where branch_id=src and product_id=pid),0) end;
 actual_dst:=case when dst is null then central else coalesce((select qty from public.ts_branch_stock where branch_id=dst and product_id=pid),0) end;
 expected:=(p_args->>'expected_qty')::bigint;expected_dst:=(p_args->>'expected_dst_qty')::bigint;expected_price:=(p_args->>'expected_price')::numeric;
 if actual is distinct from expected or (k='transfer' and actual_dst is distinct from expected_dst) or (k in ('pos','sale') and price_value is distinct from expected_price) or (k<>'count' and actual<q) then
 return jsonb_build_object('status','conflict','reason','stock_or_price_changed','actual_qty',actual,'actual_dst_qty',actual_dst,'actual_price',price_value);
 end if;
 if k='pos' then
 result:=techstore_private.invoice_action('sale',jsonb_build_object('request_id',req,'items',jsonb_build_array(jsonb_build_object('product',pid,'qty',q,'expected_price',price_value,'months',0))));
 result:=jsonb_build_object('id',result->>'id','amount',result->'document'->'total');
 elsif k in ('transfer','sale') then
 result:=techstore_private.branch_operation(k,jsonb_build_object('request_id',req,'from',coalesce(src::text,''),'to',coalesce(dst::text,''),'product',pid,'qty',q));
 else
 sale_id:=gen_random_uuid();delta:=case when k='pos' then -q else q-central end;
 data_value:=jsonb_set(data_value,array['products',ix::text,'qty'],to_jsonb(central+delta));
 data_value:=jsonb_set(data_value,'{stockMoves}',coalesce(data_value->'stockMoves','[]'::jsonb)||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',pid,'name',prod->>'name','qty',delta,'reason','offline sync '||k,'date',current_date)),true);
 if k='pos' then
 amount:=round(price_value*q,2);sale:=jsonb_build_object('id',sale_id,'number','POS-'||sale_id::text,'date',current_date,'customer','','payment','cash','paid',true,'items',jsonb_build_array(jsonb_build_object('id',pid,'name',prod->>'name','qty',q,'price',price_value,'cost',cost_value)),'total',amount,'cost',round(cost_value*q,2));
 data_value:=jsonb_set(data_value,'{sales}',coalesce(data_value->'sales','[]'::jsonb)||jsonb_build_array(sale),true);
 else
 amount:=0;records_value:=jsonb_set(records_value,'{inventory}',jsonb_build_array(jsonb_build_object('id',sale_id,'owner',null,'created',now(),'product',pid,'name',prod->>'name','before',central,'qty',q,'delta',delta,'barcode',coalesce(prod->>'sku',pid)))||coalesce(records_value->'inventory','[]'::jsonb),true);
 end if;
 update public.ts_workspace set payload=jsonb_set(jsonb_set(w.payload,'{data}',data_value),'{records}',records_value),revision=revision+1,updated_at=now() where id=1;
 result:=jsonb_build_object('id',sale_id,'amount',amount);
 end if;
 result:=result||jsonb_build_object('status','applied');
 insert into public.ts_sync_receipts(request_id,actor,kind,args,result) values(req,u.user_id,k,p_args,result);
 insert into public.ts_audit(actor,action) values(u.user_id,'offline sync '||k||' '||req::text);
 return result;
end $$;

create or replace function techstore_private.supplier_finance(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; pur jsonb; b public.ts_supplier_bills%rowtype; pay public.ts_supplier_payments%rowtype; pid text; req uuid; a numeric; paid numeric; memo_value text; product_id text; prod jsonb; idx int; q int; unit_cost numeric; d jsonb; rec jsonb; existing public.ts_supplier_bills%rowtype;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or (u.role='admin' or (u.role='stock' and (p_action='purchase' or (p_action='list' and techstore_private.staff_allowed(u.user_id,'supplier_read'))))) is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='list' then
 select * into w from public.ts_workspace where id=1;
 return jsonb_build_object('suppliers',coalesce(w.payload->'records'->'suppliers','[]'),'purchases',coalesce(w.payload->'records'->'purchases','[]'),'bills',coalesce((select jsonb_agg(to_jsonb(x)) from (select sb.purchase_id,sb.supplier_id,sb.amount,sb.due_date,sb.created_at,coalesce((select sum(p.amount) from public.ts_supplier_payments p where p.purchase_id=sb.purchase_id),0) as paid from public.ts_supplier_bills sb order by sb.created_at desc limit 500) x),'[]'),'branch_totals',case when u.role='admin' then coalesce((select jsonb_agg(to_jsonb(x)) from (select e.branch_from as branch_id,sum(e.amount) as revenue,sum(e.cost) as cost,count(*) as sales from public.ts_branch_events e where e.kind='sale' group by e.branch_from) x),'[]') else '[]' end,'branches',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title)) from public.ts_pro_entries where kind='branches'),'[]') else '[]' end);
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


create or replace function techstore_private.business_summary() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 select jsonb_build_object('sales',coalesce(sum(case when credit='sales_revenue' then amount when debit='sales_revenue' then -amount else 0 end),0),'repairs',coalesce(sum(amount) filter(where credit='repair_revenue'),0),'cost',coalesce(sum(case when kind in ('cost','branch_cost') then amount when kind='cost_reverse' then -amount else 0 end),0),'expenses',coalesce(sum(amount) filter(where kind in ('expense','payroll_accrual')),0),'supplier_payable',coalesce(sum(case when credit='supplier_payable' then amount when debit='supplier_payable' then -amount else 0 end),0),'payroll_payable',coalesce(sum(case when credit='payroll_payable' then amount when debit='payroll_payable' then -amount else 0 end),0),'branch_cash',coalesce(sum(case when debit like 'cash:%' then amount when credit like 'cash:%' then -amount else 0 end),0),'receivable',coalesce(sum(case when debit='receivables' then amount when credit='receivables' then -amount else 0 end),0)) into result from public.ts_business_entries;
 return result||jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(a)) from (select p.user_id,p.name,count(distinct i.id) as invoices,coalesce(sum(e.amount) filter(where e.debit='receivables' and e.kind='invoice'),0) -coalesce(sum(e.amount) filter(where e.kind in ('refund','debt_cancel')),0) as billed,coalesce(sum(case when e.kind in ('receipt','initial_payment') and e.credit='receivables' then e.amount when e.kind='refund' then -e.amount else 0 end),0) as paid from public.ts_profiles p join public.ts_invoices i on i.customer_id=p.user_id join public.ts_business_entries e on e.invoice_id=i.id group by p.user_id,p.name order by p.name limit 500) a),'[]'));
end $$;



-- Old clients may not create unlinked purchases or quick POS. Orders and other existing operations remain available.
create or replace function public.ts_commit(p_revision bigint,p_payload jsonb,p_actor uuid,p_action text) returns bigint language plpgsql security invoker set search_path='' as $$
declare v bigint; old_payload jsonb;
begin
 if jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Invalid payload';end if;
 select payload into old_payload from public.ts_workspace where id=1 and revision=p_revision for update;if not found then return null;end if;
 if coalesce(p_payload->'records'->'purchases','[]') is distinct from coalesce(old_payload->'records'->'purchases','[]') then raise exception 'Use integrated purchase workflow; refresh app';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(p_payload->'data'->'sales','[]')) x where x->>'number' like 'POS-%' and not exists(select 1 from jsonb_array_elements(coalesce(old_payload->'data'->'sales','[]')) o where o->>'id'=x->>'id')) then raise exception 'Use integrated invoice workflow; refresh app';end if;
 update public.ts_workspace set payload=p_payload,revision=revision+1,updated_at=now() where id=1 and revision=p_revision returning revision into v;
 insert into public.ts_audit(actor,action,revision) values(p_actor,left(p_action,200),v);return v;
end $$;
commit;