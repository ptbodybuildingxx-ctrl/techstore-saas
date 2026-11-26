-- Physical count documents, exact-location stock movements and larger bounded catalog import.
begin;
create table tenant_private.stock_counts (
 store_id uuid not null references public.saas_stores(id), request_id uuid not null, branch_id uuid, actor uuid not null, reason text not null, lines jsonb not null, created_at timestamptz not null default now(), primary key(store_id,request_id),
 foreign key(store_id,branch_id) references tenant_private.branches(store_id,id)
);
create table tenant_private.stock_count_lines (
 store_id uuid not null, request_id uuid not null, event_id uuid not null, product_id uuid not null, expected bigint not null check(expected between 0 and 1000000000), actual bigint not null check(actual between 0 and 1000000000), branch_id uuid,
 primary key(store_id,event_id), unique(store_id,request_id,product_id),
 foreign key(store_id,request_id) references tenant_private.stock_counts(store_id,request_id),
 foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,branch_id) references tenant_private.branches(store_id,id)
);
alter table tenant_private.stock_counts enable row level security;
alter table tenant_private.stock_count_lines enable row level security;
revoke all on tenant_private.stock_counts,tenant_private.stock_count_lines from public,anon,authenticated,service_role;
create index stock_counts_recent on tenant_private.stock_counts(store_id,created_at desc,request_id desc);
create function tenant_private.count_permission(s uuid,b uuid,writing boolean) returns void language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(s); scope uuid:=tenant_private.current_branch_scope(s);
begin
 if role_now is null or role_now not in ('owner','stock') or not coalesce(tenant_private.staff_action_allowed(s,'catalog_read'),false) or (scope is not null and scope is distinct from b) then raise exception 'Stock count access denied' using errcode='42501';end if;
 if b is not null and not exists(select 1 from tenant_private.branches where store_id=s and id=b) then raise exception 'Unknown branch' using errcode='22023';end if;
 if writing and (not coalesce(tenant_private.shared_licensed(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'stock_adjust'),false)) then raise exception 'Stock count write denied' using errcode='42501';end if;
end $$;
create function tenant_private.count_snapshot(s uuid,b uuid,ids uuid[]) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 perform tenant_private.count_permission(s,b,false);
 if ids is null or cardinality(ids) not between 1 and 100 or (select count(distinct x) from unnest(ids)x)<>cardinality(ids) then raise exception 'Invalid product list';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'sku',p.sku,'name',p.name,'expected',case when b is null then p.quantity-tenant_private.branch_allocated(s,p.id) else coalesce(bs.units,0) end) order by p.name,p.id),'[]'::jsonb) into result from public.mt_products p left join tenant_private.branch_stock bs on bs.store_id=p.store_id and bs.product_id=p.id and bs.branch_id=b where p.store_id=s and p.id=any(ids);
 if jsonb_array_length(result)<>cardinality(ids) then raise exception 'Unknown product';end if;return result;
end $$;
create function tenant_private.count_commit(s uuid,b uuid,r uuid,reason text,items jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare prev tenant_private.stock_counts%rowtype; item jsonb; pid uuid; eid uuid; exp bigint; act bigint; q bigint; loc bigint; delta bigint; reserved bigint; n integer;
begin
 perform tenant_private.count_permission(s,b,true);
 if r is null or reason is null or length(btrim(reason)) not between 1 and 160 or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or octet_length(items::text)>40000 then raise exception 'Invalid count';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into prev from tenant_private.stock_counts where store_id=s and request_id=r;
 if found then if prev.actor<>auth.uid() or prev.branch_id is distinct from b or prev.reason<>btrim(reason) or prev.lines is distinct from items then raise exception 'Conflicting count request';end if;return jsonb_build_object('request',r,'count',jsonb_array_length(items));end if;
 if b is not null and not exists(select 1 from tenant_private.branch_fifo_enabled where store_id=s) then raise exception 'Activate branch FIFO before count';end if;
 insert into tenant_private.stock_counts(store_id,request_id,branch_id,actor,reason,lines) values(s,r,b,auth.uid(),btrim(reason),items);
 for item in select value from jsonb_array_elements(items) loop
  if jsonb_typeof(item) is distinct from 'object' or coalesce(item->>'expected','') !~ '^[0-9]{1,10}$' or coalesce(item->>'actual','') !~ '^[0-9]{1,10}$' then raise exception 'Invalid count line';end if;
  pid:=(item->>'id')::uuid;eid:=(item->>'event')::uuid;exp:=(item->>'expected')::bigint;act:=(item->>'actual')::bigint;
  if pid is null or eid is null or exp not between 0 and 1000000000 or act not between 0 and 1000000000 then raise exception 'Invalid count line';end if;
  select quantity into q from public.mt_products where store_id=s and id=pid for update;
  if not found then raise exception 'Unknown product';end if;
  if b is null then
   loc:=q-tenant_private.branch_allocated(s,pid);
   if not exists(select 1 from tenant_private.branch_fifo_enabled where store_id=s) and loc<>q then raise exception 'Activate branch FIFO before adjusting allocated stock';end if;
   select coalesce(sum(units),0) into reserved from tenant_private.order_reservations where store_id=s and product_id=pid;
   if act<reserved then raise exception 'Count conflicts with reserved stock';end if;
  else
   select coalesce((select units from tenant_private.branch_stock where store_id=s and product_id=pid and branch_id=b),0) into loc;
  end if;
  if exp<>loc then raise exception 'Stock changed; recount before approval';end if;
  delta:=act-exp;
  if q+delta not between 0 and 1000000000 then raise exception 'Invalid total stock';end if;
  insert into tenant_private.stock_count_lines values(s,r,eid,pid,exp,act,b);
  if delta<>0 then
   if b is not null then insert into tenant_private.branch_stock(store_id,branch_id,product_id,units) values(s,b,pid,act) on conflict(store_id,branch_id,product_id) do update set units=excluded.units;end if;
   update public.mt_products set quantity=q+delta where store_id=s and id=pid;
   insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(s,eid,pid,delta,q+delta,auth.uid());
  end if;
 end loop;
 return jsonb_build_object('request',r,'count',jsonb_array_length(items));
end $$;
create function tenant_private.count_history(s uuid,b uuid,off integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform tenant_private.count_permission(s,b,false);
 if not coalesce(tenant_private.staff_action_allowed(s,'stock_history_read'),false) then raise exception 'History denied' using errcode='42501';end if;
 if off is null or off not between 0 and 100000 then raise exception 'Invalid page';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id desc) from (select request_id,branch_id,reason,lines,created_at from tenant_private.stock_counts where store_id=s and branch_id is not distinct from b order by created_at desc,request_id desc offset off limit 50)x),'[]'::jsonb);
end $$;
create function public.mt_count_snapshot(p_store uuid,p_branch uuid,p_ids uuid[]) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.count_snapshot(p_store,p_branch,p_ids)$$;
create function public.mt_count_commit(p_store uuid,p_branch uuid,p_request uuid,p_reason text,p_items jsonb) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.count_commit(p_store,p_branch,p_request,p_reason,p_items)$$;
create function public.mt_count_history(p_store uuid,p_branch uuid,p_offset integer) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.count_history(p_store,p_branch,p_offset)$$;
revoke all on function tenant_private.count_permission(uuid,uuid,boolean),tenant_private.count_snapshot(uuid,uuid,uuid[]),tenant_private.count_commit(uuid,uuid,uuid,text,jsonb),tenant_private.count_history(uuid,uuid,integer),public.mt_count_snapshot(uuid,uuid,uuid[]),public.mt_count_commit(uuid,uuid,uuid,text,jsonb),public.mt_count_history(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.count_snapshot(uuid,uuid,uuid[]),tenant_private.count_commit(uuid,uuid,uuid,text,jsonb),tenant_private.count_history(uuid,uuid,integer),public.mt_count_snapshot(uuid,uuid,uuid[]),public.mt_count_commit(uuid,uuid,uuid,text,jsonb),public.mt_count_history(uuid,uuid,integer) to authenticated;
CREATE OR REPLACE FUNCTION tenant_private.fifo_event_branch(e mt_stock_events)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid;begin
 select branch_id into b from tenant_private.stock_count_lines where store_id=e.store_id and event_id=e.request_id;
 if found then return b;end if;
 if e.sale_id is not null then select c.branch_id into b from public.mt_sales s join tenant_private.branch_sale_context c on c.store_id=s.store_id and c.request_id=s.request_id where s.store_id=e.store_id and s.id=e.sale_id;
 elsif e.return_id is not null then select a.branch_id into b from public.mt_returns r join tenant_private.branch_sales a on a.store_id=r.store_id and a.sale_id=r.sale_id where r.store_id=e.store_id and r.id=e.return_id;
 elsif e.supplier_return_id is not null then select a.branch_id into b from public.mt_supplier_returns r join tenant_private.branch_purchases a on a.store_id=r.store_id and a.purchase_id=r.purchase_id where r.store_id=e.store_id and r.id=e.supplier_return_id;
 elsif e.delta<0 then select branch_id into b from tenant_private.fifo_repair_context where store_id=e.store_id and transaction_id=pg_current_xact_id();end if;return b;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.post_stock_cost()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare intake tenant_private.cost_intakes%rowtype; l tenant_private.stock_layers%rowtype; c tenant_private.stock_consumptions%rowtype; remaining bigint; used bigint; original_event uuid; intake_id uuid; b uuid; active boolean; layer_now bigint; loc uuid; available bigint;
begin
 active:=exists(select 1 from tenant_private.branch_fifo_enabled where store_id=new.store_id);
 if active then b:=tenant_private.fifo_event_branch(new);end if;
 if new.supplier_return_id is not null then
  select p.intake_request into strict intake_id from public.mt_supplier_returns sr join public.mt_purchases p on p.store_id=sr.store_id and p.id=sr.purchase_id where sr.store_id=new.store_id and sr.id=new.supplier_return_id and p.product_id=new.product_id and sr.units=-new.delta;
  select * into l from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and intake_request=intake_id for update;
  if not found or l.remaining_units< -new.delta then raise exception 'Original purchase layer has insufficient stock' using errcode='22023';end if;
  if active then perform tenant_private.fifo_delta(new.store_id,new.product_id,l.id,b,new.delta);end if;
  update tenant_private.stock_layers set remaining_units=remaining_units+new.delta where store_id=l.store_id and product_id=l.product_id and id=l.id;
  insert into tenant_private.stock_consumptions(store_id,product_id,event_id,layer_id,units) values(l.store_id,l.product_id,new.request_id,l.id,-new.delta);
 elsif new.return_id is not null then
  select e.request_id into strict original_event from public.mt_returns r join public.mt_stock_events e on e.store_id=r.store_id and e.sale_id=r.sale_id and e.product_id=r.product_id where r.store_id=new.store_id and r.id=new.return_id and r.product_id=new.product_id;
  remaining:=new.delta;
  for c in select * from tenant_private.stock_consumptions where store_id=new.store_id and product_id=new.product_id and event_id=original_event and restored_units<units order by layer_id for update loop
   exit when remaining=0;
   used:=least(remaining,c.units-c.restored_units);
   update tenant_private.stock_consumptions set restored_units=restored_units+used where store_id=c.store_id and product_id=c.product_id and event_id=c.event_id and layer_id=c.layer_id;
   if active then perform tenant_private.fifo_delta(new.store_id,new.product_id,c.layer_id,b,used);end if;
   update tenant_private.stock_layers set remaining_units=remaining_units+used where store_id=c.store_id and product_id=c.product_id and id=c.layer_id;
   remaining:=remaining-used;
  end loop;
  if remaining<>0 then raise exception 'Return cost allocation mismatch';end if;
 elsif new.delta>0 then
  select * into intake from tenant_private.cost_intakes where store_id=new.store_id and request_id=new.request_id;
  if found and (intake.product_id<>new.product_id or intake.units<>new.delta or intake.actor<>new.actor) then raise exception 'Cost intake mismatch';end if;
  insert into tenant_private.stock_layers(store_id,product_id,intake_request,original_units,remaining_units,currency,unit_cost_minor) values(new.store_id,new.product_id,new.request_id,new.delta,new.delta,intake.currency,intake.unit_cost_minor) returning id into layer_now;
  if active then perform tenant_private.fifo_delta(new.store_id,new.product_id,layer_now,b,new.delta);end if;
 else
  remaining:=-new.delta;
  for l in select * from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and remaining_units>0 and (not active or exists(select 1 from tenant_private.branch_fifo_lots a where a.store_id=new.store_id and a.product_id=new.product_id and a.layer_id=stock_layers.id and a.branch_id is not distinct from b and a.units>0)) order by id for update loop
   exit when remaining=0;
   if active then select units into strict available from tenant_private.branch_fifo_lots where store_id=l.store_id and product_id=l.product_id and layer_id=l.id and branch_id is not distinct from b;else available:=l.remaining_units;end if;
   used:=least(remaining,available);
   if active then perform tenant_private.fifo_delta(new.store_id,new.product_id,l.id,b,-used);end if;
   update tenant_private.stock_layers set remaining_units=remaining_units-used where store_id=l.store_id and product_id=l.product_id and id=l.id;
   insert into tenant_private.stock_consumptions(store_id,product_id,event_id,layer_id,units) values(l.store_id,l.product_id,new.request_id,l.id,used);
   remaining:=remaining-used;
  end loop;
  if remaining<>0 then raise exception 'Insufficient tracked stock layers';end if;
 end if;
 if (select coalesce(sum(remaining_units),0) from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and remaining_units>0)<>new.balance then raise exception 'Stock layer balance mismatch';end if;
 return new;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.branch_journal_projection(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare lo timestamptz;hi timestamptz;result jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 or p_to>(now() at time zone 'Asia/Damascus')::date then raise exception 'Invalid period' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'Asia/Damascus';hi:=(p_to+1)::timestamp at time zone 'Asia/Damascus';
 with sale_loc as (
  select s.id,b.branch_id from public.mt_sales s left join tenant_private.branch_sales b on b.store_id=s.store_id and b.sale_id=s.id where s.store_id=p_store
 ), purchase_loc as (
  select p.id,p.intake_request,b.branch_id from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=p_store
 ), repair_loc as (
  select i.id,b.branch_id from public.mt_repair_invoices i left join tenant_private.branch_repairs b on b.store_id=i.store_id and b.repair_id=i.repair_id where i.store_id=p_store
 ), return_loc as (
  select r.id,s.branch_id from public.mt_returns r join sale_loc s on s.id=r.sale_id where r.store_id=p_store
 ), supplier_return_loc as (
  select r.id,p.branch_id from public.mt_supplier_returns r join purchase_loc p on p.id=r.purchase_id where r.store_id=p_store
 ), repair_refund_loc as (
  select r.id,i.branch_id from public.mt_repair_refunds r join repair_loc i on i.id=r.invoice_id where r.store_id=p_store
 ), cash_loc as (
  select m.id,m.request_id,case when a.posted then a.branch_id else coalesce(s.branch_id,ds.branch_id,ret.branch_id,p.branch_id,sr.branch_id,i.branch_id,rr.branch_id,bk.branch_id,v.branch_id) end branch_id
  from public.mt_cash_movements m
  left join tenant_private.branch_cash_attribution a on a.store_id=m.store_id and a.cash_id=m.id
  left join sale_loc s on s.id=coalesce(m.sale_id,m.mixed_sale_id)
  left join public.mt_debt_payments dp on dp.store_id=m.store_id and dp.id=m.debt_payment_id
  left join public.mt_debts d on d.store_id=dp.store_id and d.id=dp.debt_id
  left join sale_loc ds on ds.id=d.sale_id
  left join return_loc ret on ret.id=m.return_id
  left join public.mt_supplier_payments sp on sp.store_id=m.store_id and sp.id=m.supplier_payment_id
  left join purchase_loc p on p.id=sp.purchase_id
  left join supplier_return_loc sr on sr.id=m.supplier_return_id
  left join repair_loc i on i.id=m.repair_invoice_id
  left join repair_refund_loc rr on rr.id=m.repair_refund_id
  left join tenant_private.bank_transfers bt on bt.store_id=m.store_id and bt.cash_id=m.id
  left join tenant_private.bank_accounts bk on bk.store_id=bt.store_id and bk.id=bt.account_id
  left join tenant_private.branch_vouchers v on v.store_id=m.store_id and v.cash_id=m.id
  where m.store_id=p_store
 ), cost_loc as (
  select c.event_id id,coalesce(s.branch_id,i.branch_id) branch_id
  from tenant_private.cost_postings c left join sale_loc s on s.id=c.sale_id left join repair_loc i on i.id=c.repair_invoice_id where c.store_id=p_store
 ), sources(kind,id,branch_id) as (
  select 'stock_adjustment',event_id,branch_id from tenant_private.stock_count_lines where store_id=p_store
  union all
  select k,c.id,c.branch_id from cash_loc c cross join unnest(array['cash','exchange_target']) k
  union all select k,s.id,s.branch_id from sale_loc s cross join unnest(array['credit_sale','mixed_sale']) k
  union all select k,r.id,r.branch_id from return_loc r cross join unnest(array['sale_return_debt','sale_return_cash','return_cost_source','return_cost_conversion']) k
  union all select 'repair_refund',id,branch_id from repair_refund_loc
  union all select 'purchase',id,branch_id from purchase_loc
  union all select 'supplier_return',id,branch_id from supplier_return_loc
  union all select k,c.id,c.branch_id from cost_loc c cross join unnest(array['cost_source','cost_conversion']) k
  union all select 'accounting_adjustment',a.id,coalesce(v.branch_id,c.branch_id) from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join cash_loc c on c.request_id=a.source_request where a.store_id=p_store
  union all select 'payroll_accrual',id,branch_id from tenant_private.staff_payroll where store_id=p_store
  union all select 'payroll_adjustment',a.id,p.branch_id from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store
  union all select 'payroll_advance_offset',o.id,case when p.branch_id is not distinct from a.branch_id then p.branch_id end from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'tradein_offset',t.id,case when s.branch_id is not distinct from p.branch_id then s.branch_id end from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
  union all select 'indirect_tax',t.id,coalesce(s.branch_id,i.branch_id) from public.mt_indirect_tax_entries t left join sale_loc s on t.kind in ('sale','sale_return') and s.id=t.invoice_id left join repair_loc i on t.kind in ('repair','repair_refund') and i.id=t.invoice_id where t.store_id=p_store
 ), unique_sources as (
  select kind,id,case when count(distinct coalesce(branch_id::text,''))=1 then min(branch_id::text)::uuid end branch_id from sources group by kind,id
 ), offset_locations as (
  select 'payroll_advance_offset'::text kind,o.id,p.branch_id debit_branch,a.branch_id credit_branch
  from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'tradein_offset',t.id,p.branch_id,s.branch_id from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
 ), journal as (
  select j.*,s.branch_id,o.id is not null and o.debit_branch is distinct from o.credit_branch as split,o.debit_branch,o.credit_branch
  from tenant_private.journal_pairs(p_store,hi) j left join unique_sources s on s.kind=j.source_type and s.id=j.source_id
  left join offset_locations o on o.kind=j.source_type and o.id=j.source_id
 ), canonical as (
  select posted_at,currency,debit_account,credit_account,amount,branch_id from journal where not split
 ), offset_pairs as (
  -- Split cross-location noncash offsets across the exact original debit/credit locations.
  select posted_at,currency,debit_account,'interbranch_clearing'::text credit_account,amount,debit_branch branch_id from journal where split
  union all select posted_at,currency,'interbranch_clearing',credit_account,amount,credit_branch from journal where split
 ), internal_moves as (
  select t.created_at posted_at,t.currency,t.amount_minor::numeric amount,t.source,t.target,'cash'::text account
  from tenant_private.branch_cash_transfers t where t.store_id=p_store and t.created_at<hi
  union all
  select t.created_at,l.currency,m.units::numeric*l.unit_cost_minor,t.source,t.target,'inventory'
  from tenant_private.branch_fifo_moves m join tenant_private.branch_transfers t on t.store_id=m.store_id and t.request_id=m.request_id
  join tenant_private.stock_layers l on l.store_id=m.store_id and l.product_id=m.product_id and l.id=m.layer_id
  where m.store_id=p_store and t.created_at<hi and l.currency is not null and l.unit_cost_minor is not null
 ), pairs as (
  select * from canonical
  union all select * from offset_pairs
  union all select posted_at,currency,'interbranch_clearing',account,amount,source from internal_moves where amount>0
  union all select posted_at,currency,account,'interbranch_clearing',amount,target from internal_moves where amount>0
  -- Management allocations affect branch results, never consolidated cash, tax or statutory accounts.
  union all select a.created_at,a.currency,case when a.reverses is null then 'interbranch_clearing' else a.account end,
    case when a.reverses is null then a.account else 'interbranch_clearing' end,a.amount_minor::numeric,null::uuid
    from tenant_private.branch_expense_allocations a where a.store_id=p_store and a.created_at<hi
  union all select a.created_at,a.currency,case when a.reverses is null then a.account else 'interbranch_clearing' end,
    case when a.reverses is null then 'interbranch_clearing' else a.account end,a.amount_minor::numeric,a.branch_id
    from tenant_private.branch_expense_allocations a where a.store_id=p_store and a.created_at<hi
 ), legs as (
  select branch_id,currency,debit_account account,posted_at,amount debit,0::numeric credit from pairs
  union all select branch_id,currency,credit_account,posted_at,0::numeric,amount from pairs
 ), grouped as (
  select branch_id,currency,account,coalesce(sum(debit-credit) filter(where posted_at<lo),0) opening,
    coalesce(sum(debit) filter(where posted_at>=lo),0) debit,coalesce(sum(credit) filter(where posted_at>=lo),0) credit,
    sum(debit-credit) closing
  from legs group by branch_id,currency,account
 ), rows as (
  select g.branch_id,coalesce(b.name,'المركزي / غير الموزع') name,g.currency,g.account,g.opening::text,g.debit::text,g.credit::text,g.closing::text
  from grouped g left join tenant_private.branches b on b.store_id=p_store and b.id=g.branch_id
 )
 select jsonb_build_object('mode','branch_journal_projection','from',p_from,'to',p_to,
  'unallocated_pair_count',(select count(*) from canonical where branch_id is null),
  'unknown_transfer_units',coalesce((select sum(m.units) from tenant_private.branch_fifo_moves m join tenant_private.branch_transfers t on t.store_id=m.store_id and t.request_id=m.request_id join tenant_private.stock_layers l on l.store_id=m.store_id and l.product_id=m.product_id and l.id=m.layer_id where m.store_id=p_store and t.created_at<hi and (l.currency is null or l.unit_cost_minor is null)),0)::text,
  'opening_verified',false,
  'rows',coalesce((select jsonb_agg(to_jsonb(r) order by r.name,r.currency,r.account) from rows r),'[]'::jsonb)) into result;
 return result;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t text;v jsonb;out_data jsonb:='{}';n bigint;total_rows bigint:=0;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not tenant_private.shared_licensed(p_store) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner and AAL2 required' using errcode='42501';end if;
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines'] loop
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
CREATE OR REPLACE FUNCTION tenant_private.catalog_import(p_store uuid, p_request uuid, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old tenant_private.catalog_requests%rowtype;x jsonb;r jsonb;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'Invalid import' using errcode='22023';end if;
 if jsonb_array_length(p_rows) not between 1 and 500 or octet_length(p_rows::text)>2000000 then raise exception 'Invalid import size' using errcode='22023';end if;
 select * into old from tenant_private.catalog_requests where store_id=p_store and request_id=p_request;
 if found then if old.actor<>auth.uid() or old.payload is distinct from p_rows then raise exception 'Conflicting request' using errcode='22023';end if;return old.result;end if;
 if (select count(distinct lower(btrim(value->>'sku'))) from jsonb_array_elements(p_rows))<>jsonb_array_length(p_rows) then raise exception 'Duplicate SKU';end if;
 for x in select value from jsonb_array_elements(p_rows) loop
 if jsonb_typeof(x) is distinct from 'object' or jsonb_typeof(x->'sku') is distinct from 'string' or jsonb_typeof(x->'name') is distinct from 'string' or length(btrim(x->>'sku')) not between 1 and 80 or length(btrim(x->>'name')) not between 1 and 160 or not tenant_private.valid_catalog_profile(x->'profile') then raise exception 'Invalid import row' using errcode='22023';end if;
 insert into public.mt_products(store_id,sku,name,catalog) values(p_store,btrim(x->>'sku'),btrim(x->>'name'),x->'profile');
 end loop;
 r:=jsonb_build_object('count',jsonb_array_length(p_rows));insert into tenant_private.catalog_requests values(p_store,p_request,auth.uid(),p_rows,r,now());return r;
end $function$;
commit;
