-- 135: externally confirmed input credit against existing indirect tax liability.
-- Deliberately limited to fully expensed single-location same-currency FIFO purchase lots.
begin;
create table tenant_private.sy_tax_credit_events(
 store_id uuid not null,purchase_id uuid not null,request_id uuid not null,input_revision uuid not null,
 branch_id uuid,currency text not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),
 reversal_of uuid,reference text not null check(length(btrim(reference)) between 1 and 160),
 legal_reference text not null check(length(btrim(legal_reference)) between 1 and 200),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,request_id),
 foreign key(store_id,purchase_id) references public.mt_purchases(store_id,id),
 foreign key(store_id,input_revision) references tenant_private.sy_tax_input_events(store_id,request_id),
 foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 foreign key(store_id,reversal_of) references tenant_private.sy_tax_credit_events(store_id,request_id),
 unique(store_id,reversal_of),check(reversal_of is null or reversal_of<>request_id)
);
create index sy_tax_credit_purchase on tenant_private.sy_tax_credit_events(store_id,purchase_id,created_at desc);
alter table tenant_private.sy_tax_credit_events enable row level security;
revoke all on tenant_private.sy_tax_credit_events from public,anon,authenticated,service_role;
create trigger mt_guard_closed_period before insert on tenant_private.sy_tax_credit_events for each row execute function tenant_private.guard_closed_period();

create function tenant_private.sy_tax_credit_active(s uuid,purchase uuid)
returns setof tenant_private.sy_tax_credit_events language sql stable set search_path='' as $$
 select e.* from tenant_private.sy_tax_credit_events e where e.store_id=s and e.purchase_id=purchase and e.reversal_of is null and not exists(select 1 from tenant_private.sy_tax_credit_events z where z.store_id=s and z.reversal_of=e.request_id)
$$;
revoke all on function tenant_private.sy_tax_credit_active(uuid,uuid) from public,anon,authenticated,service_role;

create function tenant_private.sy_tax_credit_review(s uuid,purchase uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare p public.mt_purchases%rowtype;l tenant_private.stock_layers%rowtype;i tenant_private.sy_tax_input_events%rowtype; a tenant_private.sy_tax_credit_events%rowtype;
 branch uuid; journal jsonb; liability numeric:=0; store_liability numeric:=0; consumed numeric:=0; valid boolean:=false; reason text; history jsonb; result jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into p from public.mt_purchases x where x.store_id=s and x.id=purchase;
 if not found then raise exception 'Purchase not found' using errcode='22023';end if;
 select * into i from tenant_private.sy_tax_input_current(s) x where x.kind='purchase' and x.source_id=purchase;
 select * into a from tenant_private.sy_tax_credit_active(s,purchase);
 select * into l from tenant_private.stock_layers x where x.store_id=s and x.intake_request=p.intake_request and x.product_id=p.product_id;
 select x.branch_id into branch from tenant_private.branch_purchases x where x.store_id=s and x.purchase_id=purchase;
 if a.request_id is not null then reason:='already_posted';
 elsif i.request_id is null or i.treatment<>'potential_credit' or i.tax_minor<=0 then reason:='review_required';
 elsif l.id is null or l.currency is distinct from p.currency or l.unit_cost_minor is null or l.original_units<>p.units or l.unit_cost_minor::numeric*p.units<>p.total_minor or p.returned_units<>0 or l.remaining_units<>0 then reason:='inventory_not_fully_expensed';
 elsif exists(select 1 from tenant_private.branch_fifo_moves x where x.store_id=s and x.product_id=l.product_id and x.layer_id=l.id) then reason:='transferred_inventory';
 else
  select coalesce(sum(c.units),0),coalesce(bool_and(c.restored_units=0 and coalesce(cp.sale_id is not null and cp.repair_invoice_id is null and cp.units=c.units and cp.source_currency=p.currency and cp.invoice_currency=p.currency and cp.source_cost_minor=c.units::numeric*l.unit_cost_minor and cp.invoice_cost_minor=cp.source_cost_minor and bs.branch_id is not distinct from branch,false)),false)
  into consumed,valid from tenant_private.stock_consumptions c
  left join tenant_private.cost_postings cp on cp.store_id=c.store_id and cp.product_id=c.product_id and cp.event_id=c.event_id and cp.layer_id=c.layer_id
  left join tenant_private.branch_sales bs on bs.store_id=cp.store_id and bs.sale_id=cp.sale_id
  where c.store_id=s and c.product_id=l.product_id and c.layer_id=l.id;
  if not valid or consumed<>p.units then reason:='cost_attribution_incomplete';
  else
   journal:=tenant_private.branch_journal_projection(s,(now() at time zone 'Asia/Damascus')::date,(now() at time zone 'Asia/Damascus')::date);
   select coalesce(-sum((x->>'closing')::numeric) filter(where (x->>'branch_id')::uuid is not distinct from branch),0),coalesce(-sum((x->>'closing')::numeric),0) into liability,store_liability from jsonb_array_elements(journal->'rows') x where x->>'account'='indirect_tax_payable' and x->>'currency'=p.currency;
   if liability<=0 or store_liability<=0 then reason:='no_recorded_liability';else reason:='eligible';end if;
  end if;
 end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id desc),'[]'::jsonb) into history from (
  select request_id,reversal_of,amount_minor::text amount_minor,reference,legal_reference,created_at from tenant_private.sy_tax_credit_events e where e.store_id=s and e.purchase_id=purchase order by created_at desc,request_id desc limit 50
 ) x;
 result:=jsonb_build_object('purchase_id',purchase,'branch_id',branch,'currency',p.currency,'input_revision',i.request_id,'documented_tax',coalesce(i.tax_minor,0)::text,'active_credit',a.request_id,'active_amount',coalesce(a.amount_minor,0)::text,'reason',reason,'maximum',case when reason='eligible' then least(i.tax_minor,liability,store_liability,p.total_minor)::text else '0' end,'history',history);
 return result||jsonb_build_object('digest',tenant_private.finance_review_digest(result));
end $$;

create function tenant_private.sy_tax_credit_record(s uuid,req uuid,purchase uuid,previous uuid,digest text,amount bigint,proof text,legal text,confirmed boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare q jsonb;old tenant_private.sy_tax_credit_events%rowtype; a tenant_private.sy_tax_credit_events%rowtype;
begin
 perform tenant_private.owner_write(s);
 if req is null or purchase is null or digest is null or digest !~ '^[0-9a-f]{64}$' or amount is null or amount not between 1 and 100000000000000 or proof is null or length(btrim(proof)) not between 1 and 160 or legal is null or length(btrim(legal)) not between 1 and 200 or confirmed is distinct from true then raise exception 'Confirm documented credit' using errcode='22023';end if;
 select * into old from tenant_private.sy_tax_credit_events where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.purchase_id<>purchase or old.reversal_of is distinct from previous or old.amount_minor<>amount or old.reference<>btrim(proof) or old.legal_reference<>btrim(legal) then raise exception 'Conflicting credit request' using errcode='22023';end if;return req;
 end if;
 q:=tenant_private.sy_tax_credit_review(s,purchase);
 if q->>'digest' is distinct from digest then raise exception 'Credit review changed; reload' using errcode='22023';end if;
 if previous is null then
  if q->>'reason' is distinct from 'eligible' or amount>(q->>'maximum')::numeric then raise exception 'Credit exceeds eligible documented amount' using errcode='22023';end if;
  insert into tenant_private.sy_tax_credit_events(store_id,purchase_id,request_id,input_revision,branch_id,currency,amount_minor,reference,legal_reference,actor)
  values(s,purchase,req,(q->>'input_revision')::uuid,(q->>'branch_id')::uuid,q->>'currency',amount,btrim(proof),btrim(legal),auth.uid());
 else
  select * into a from tenant_private.sy_tax_credit_active(s,purchase);
  if a.request_id is distinct from previous or a.amount_minor<>amount then raise exception 'Reverse the exact active credit' using errcode='22023';end if;
  insert into tenant_private.sy_tax_credit_events(store_id,purchase_id,request_id,input_revision,branch_id,currency,amount_minor,reversal_of,reference,legal_reference,actor)
  values(s,purchase,req,a.input_revision,a.branch_id,a.currency,a.amount_minor,previous,btrim(proof),btrim(legal),auth.uid());
 end if;return req;
end $$;

-- Prevent gross inventory restoration or contradictory input evidence while a cost credit remains active.
create function tenant_private.sy_tax_credit_guard_restore() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.remaining_units>old.remaining_units and exists(select 1 from public.mt_purchases p cross join lateral tenant_private.sy_tax_credit_active(new.store_id,p.id) a where p.store_id=new.store_id and p.intake_request=new.intake_request) then raise exception 'Reverse the documented input credit before restoring this inventory' using errcode='22023';end if;return new;
end $$;
create trigger sy_tax_credit_guard_restore before update of remaining_units on tenant_private.stock_layers for each row execute function tenant_private.sy_tax_credit_guard_restore();
create function tenant_private.sy_tax_credit_guard_input() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from tenant_private.sy_tax_credit_active(new.store_id,new.invoice_id)) then raise exception 'Reverse the documented input credit before revising purchase tax evidence' using errcode='22023';end if;return new;
end $$;
create trigger sy_tax_credit_guard_input before insert on tenant_private.sy_tax_input_events for each row execute function tenant_private.sy_tax_credit_guard_input();
revoke all on function tenant_private.sy_tax_credit_guard_restore(),tenant_private.sy_tax_credit_guard_input() from public,anon,authenticated,service_role;
create function public.mt_sy_tax_credit_review(s uuid,purchase uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.sy_tax_credit_review(s,purchase)$$;
create function public.mt_sy_tax_credit_record(s uuid,req uuid,purchase uuid,previous uuid,digest text,amount bigint,proof text,legal text,confirmed boolean) returns uuid language sql set search_path='' as $$select tenant_private.sy_tax_credit_record(s,req,purchase,previous,digest,amount,proof,legal,confirmed)$$;
revoke all on function tenant_private.sy_tax_credit_review(uuid,uuid),public.mt_sy_tax_credit_review(uuid,uuid),tenant_private.sy_tax_credit_record(uuid,uuid,uuid,uuid,text,bigint,text,text,boolean),public.mt_sy_tax_credit_record(uuid,uuid,uuid,uuid,text,bigint,text,text,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.sy_tax_credit_review(uuid,uuid),public.mt_sy_tax_credit_review(uuid,uuid),tenant_private.sy_tax_credit_record(uuid,uuid,uuid,uuid,text,bigint,text,text,boolean),public.mt_sy_tax_credit_record(uuid,uuid,uuid,uuid,text,bigint,text,text,boolean) to authenticated;
CREATE OR REPLACE FUNCTION tenant_private.journal_pairs(p_store uuid, p_until timestamp with time zone)
 RETURNS TABLE(posted_at timestamp with time zone, source_type text, source_id uuid, currency text, debit_account text, credit_account text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with cash as (
 select * from public.mt_cash_movements where store_id=p_store and created_at<p_until
),costs as (
 select * from tenant_private.cost_postings where store_id=p_store and created_at<p_until
),return_costs as (
 select r.*,l.currency as source_currency,r.units::numeric*l.unit_cost_minor as source_cost
 from tenant_private.return_cost_postings r join tenant_private.stock_layers l on l.store_id=r.store_id and l.product_id=r.product_id and l.id=r.layer_id
 where r.store_id=p_store and r.created_at<p_until
),pairs(posted_at,source_type,source_id,currency,debit_account,credit_account,amount) as (
 select c.created_at,'cash',c.id,c.currency,
 case when sd.direction='payable' then 'accounts_payable' when sd.direction='receivable' then 'cash' when b.direction='deposit' then 'bank' else case c.kind when 'expense' then 'expense_unclassified' when 'supplier_payment' then 'accounts_payable' when 'exchange' then 'fx_clearing' else 'cash' end end,
 case when rev.kind='advance' then 'employee_advances' when rev.kind in ('partial','final') then 'payroll_payable' when sd.direction='receivable' then 'accounts_receivable' when sd.direction='payable' then 'cash' when b.direction='withdrawal' then 'bank' else case c.kind when 'sale' then 'sales_revenue' when 'funding' then 'funding_unclassified' when 'debt_payment' then 'accounts_receivable' when 'repair_receipt' then 'repair_revenue' when 'mixed_receipt' then 'fx_clearing' when 'supplier_refund' then 'accounts_payable' else 'cash' end end,c.amount_minor::numeric
 from cash c left join tenant_private.staff_payroll_reversals rev on rev.store_id=c.store_id and rev.cash_request=c.request_id left join tenant_private.bank_transfers b on b.store_id=c.store_id and b.cash_id=c.id left join tenant_private.standalone_debt_payments sdp on sdp.store_id=c.store_id and sdp.cash_id=c.id left join tenant_private.standalone_debts sd on sd.store_id=sdp.store_id and sd.id=sdp.debt_id where c.kind in ('sale','funding','expense','exchange','debt_payment','supplier_payment','repair_receipt','mixed_receipt','supplier_refund')
 union all select created_at,'standalone_debt_opening',id,currency,case when direction='receivable' then 'accounts_receivable' else 'funding_unclassified' end,case when direction='receivable' then 'funding_unclassified' else 'accounts_payable' end,principal_minor from tenant_private.standalone_debts where store_id=p_store and created_at<p_until
 union all select created_at,'exchange_target',id,target_currency,'cash','fx_clearing',target_amount_minor from cash where kind='exchange'
 union all select created_at,'credit_sale',id,currency,'accounts_receivable','sales_revenue',total_minor from public.mt_sales where store_id=p_store and payment_mode='credit' and created_at<p_until
 union all select created_at,'mixed_sale',id,currency,'fx_clearing','sales_revenue',total_minor from public.mt_sales where store_id=p_store and payment_mode='mixed' and created_at<p_until
 union all select created_at,'sale_return_debt',id,currency,'sales_returns','accounts_receivable',debt_reduction_minor from public.mt_returns where store_id=p_store and created_at<p_until
 union all select created_at,'sale_return_cash',id,currency,'sales_returns','cash',refund_minor from public.mt_returns where store_id=p_store and created_at<p_until
 union all select created_at,'repair_refund',id,currency,'sales_returns','cash',amount_minor from public.mt_repair_refunds where store_id=p_store and created_at<p_until
 union all select created_at,'purchase',id,currency,'inventory','accounts_payable',total_minor from public.mt_purchases where store_id=p_store and created_at<p_until
 union all select created_at,'supplier_return',id,currency,'accounts_payable','inventory',units::numeric*unit_cost_minor from public.mt_supplier_returns where store_id=p_store and created_at<p_until
 union all select e.created_at,'standalone_intake',e.request_id,i.currency,'inventory','stock_intake_unclassified',i.units::numeric*i.unit_cost_minor
 from tenant_private.cost_intakes i join public.mt_stock_events e on e.store_id=i.store_id and e.request_id=i.request_id
 where i.store_id=p_store and e.created_at<p_until and not exists(select 1 from public.mt_purchases p where p.store_id=i.store_id and p.intake_request=i.request_id)
 union all select e.created_at,'stock_adjustment',e.request_id,l.currency,'stock_adjustment_expense','inventory',a.units::numeric*l.unit_cost_minor
 from public.mt_stock_events e join tenant_private.stock_consumptions a on a.store_id=e.store_id and a.product_id=e.product_id and a.event_id=e.request_id
 join tenant_private.stock_layers l on l.store_id=a.store_id and l.product_id=a.product_id and l.id=a.layer_id
 where e.store_id=p_store and e.created_at<p_until and e.delta<0 and e.sale_id is null and e.supplier_return_id is null and not exists(select 1 from tenant_private.cost_postings r where r.store_id=e.store_id and r.event_id=e.request_id)
 union all select created_at,'cost_source',event_id,source_currency,
 case when source_currency<>invoice_currency and invoice_cost_minor is not null then 'fx_clearing' else 'cost_of_goods_services' end,'inventory',source_cost_minor from costs
 union all select created_at,'cost_conversion',event_id,invoice_currency,'cost_of_goods_services','fx_clearing',invoice_cost_minor from costs where source_currency<>invoice_currency and invoice_cost_minor is not null
 union all select created_at,'return_cost_source',return_id,source_currency,'inventory',
 case when source_currency<>invoice_currency and invoice_cost_minor is not null then 'fx_clearing' else 'cost_of_goods_services' end,source_cost from return_costs
 union all select created_at,'return_cost_conversion',return_id,invoice_currency,'fx_clearing','cost_of_goods_services',invoice_cost_minor from return_costs where source_currency<>invoice_currency and invoice_cost_minor is not null
 union all select created_at,'tradein_offset',id,currency,'accounts_payable','accounts_receivable',offset_minor from tenant_private.tradein_settlements where store_id=p_store and created_at<p_until
 union all select a.created_at,'accounting_adjustment',a.id,a.currency,case when adv.id is not null then 'employee_advances' when p.id is not null or dis.id is not null then 'payroll_payable' else a.debit_account end,a.credit_account,a.amount_minor from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join tenant_private.staff_payroll_finalizations p on p.store_id=v.store_id and p.id=v.request_id left join tenant_private.staff_payroll_disbursements dis on dis.store_id=v.store_id and dis.id=v.request_id left join tenant_private.staff_advances adv on adv.store_id=v.store_id and adv.id=v.request_id where a.store_id=p_store and a.created_at<p_until
 union all select a.created_at,'payroll_adjustment',a.id,p.currency,case when a.kind='bonus' then 'payroll_expense' else 'payroll_payable' end,case when a.kind='bonus' then 'payroll_payable' else 'payroll_expense' end,a.amount_minor from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and a.created_at<p_until
 union all select o.created_at,'payroll_advance_offset',o.id,p.currency,'payroll_payable','employee_advances',o.amount_minor from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id where o.store_id=p_store and o.created_at<p_until
 union all select r.created_at,'payroll_offset_reversal',r.id,p.currency,'employee_advances','payroll_payable',r.amount_minor from tenant_private.staff_payroll_reversals r join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id where r.store_id=p_store and r.kind='offset' and r.created_at<p_until
 union all select created_at,'payroll_accrual',id,currency,'payroll_expense','payroll_payable',total_minor from tenant_private.staff_payroll where store_id=p_store and created_at<p_until
 union all select created_at,'indirect_tax',id,currency,case kind when 'sale' then 'sales_revenue' when 'repair' then 'repair_revenue' else 'indirect_tax_payable' end,case when kind in ('sale','repair') then 'indirect_tax_payable' else 'sales_returns' end,tax_minor from public.mt_indirect_tax_entries where store_id=p_store and created_at<p_until 
 union all select created_at,'sy_tax_credit',request_id,currency,case when reversal_of is null then 'indirect_tax_payable' else 'cost_of_goods_services' end,case when reversal_of is null then 'cost_of_goods_services' else 'indirect_tax_payable' end,amount_minor::numeric from tenant_private.sy_tax_credit_events where store_id=p_store and created_at<p_until
 union all select created_at,'opening_debt_equity',request_id,currency,case when direction='receivable' then 'funding_unclassified' else 'capital' end,case when direction='receivable' then 'capital' else 'funding_unclassified' end,amount_minor from tenant_private.opening_debt_equity where store_id=p_store and created_at<p_until
)
select * from pairs where pairs.amount>0;
$function$;

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
  select m.id,m.request_id,case when a.posted then a.branch_id else coalesce(s.branch_id,ds.branch_id,ret.branch_id,p.branch_id,sr.branch_id,i.branch_id,rr.branch_id,bk.branch_id,v.branch_id,sd.branch_id) end branch_id
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
  left join tenant_private.standalone_debt_payments sdp on sdp.store_id=m.store_id and sdp.cash_id=m.id left join tenant_private.standalone_debts sd on sd.store_id=sdp.store_id and sd.id=sdp.debt_id
  where m.store_id=p_store
 ), cost_loc as (
  select c.event_id id,coalesce(s.branch_id,i.branch_id) branch_id
  from tenant_private.cost_postings c left join sale_loc s on s.id=c.sale_id left join repair_loc i on i.id=c.repair_invoice_id where c.store_id=p_store
 ), sources(kind,id,branch_id) as (
  select 'stock_adjustment',e.request_id,c.branch_id from public.mt_stock_events e left join tenant_private.stock_count_lines c on c.store_id=e.store_id and c.event_id=e.request_id where e.store_id=p_store
  union all select 'standalone_intake',i.request_id,c.branch_id from tenant_private.cost_intakes i left join tenant_private.stock_count_lines c on c.store_id=i.store_id and c.event_id=i.request_id where i.store_id=p_store
  union all select 'sy_tax_credit',request_id,branch_id from tenant_private.sy_tax_credit_events where store_id=p_store
  union all select 'opening_debt_equity',request_id,branch_id from tenant_private.opening_debt_equity where store_id=p_store
  union all
  select k,c.id,c.branch_id from cash_loc c cross join unnest(array['cash','exchange_target']) k
  union all select k,s.id,s.branch_id from sale_loc s cross join unnest(array['credit_sale','mixed_sale']) k
  union all select k,r.id,r.branch_id from return_loc r cross join unnest(array['sale_return_debt','sale_return_cash','return_cost_source','return_cost_conversion']) k
  union all select 'repair_refund',id,branch_id from repair_refund_loc
  union all select 'purchase',id,branch_id from purchase_loc
  union all select 'supplier_return',id,branch_id from supplier_return_loc
  union all select k,c.id,c.branch_id from cost_loc c cross join unnest(array['cost_source','cost_conversion']) k
  union all select 'accounting_adjustment',a.id,coalesce(v.branch_id,c.branch_id,sc.branch_id) from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join cash_loc c on c.request_id=a.source_request left join tenant_private.stock_count_lines sc on sc.store_id=a.store_id and sc.event_id=a.source_request where a.store_id=p_store
  union all select 'standalone_debt_opening',id,branch_id from tenant_private.standalone_debts where store_id=p_store
  union all select 'payroll_accrual',id,branch_id from tenant_private.staff_payroll where store_id=p_store
  union all select 'payroll_adjustment',a.id,p.branch_id from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store
  union all select 'payroll_advance_offset',o.id,case when p.branch_id is not distinct from a.branch_id then p.branch_id end from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'payroll_offset_reversal',r.id,case when a.branch_id is not distinct from p.branch_id then a.branch_id end from tenant_private.staff_payroll_reversals r join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id join tenant_private.staff_advances a on a.store_id=r.store_id and a.id=r.advance_id where r.store_id=p_store and r.kind='offset'
  union all select 'tradein_offset',t.id,case when s.branch_id is not distinct from p.branch_id then s.branch_id end from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
  union all select 'indirect_tax',t.id,coalesce(s.branch_id,i.branch_id) from public.mt_indirect_tax_entries t left join sale_loc s on t.kind in ('sale','sale_return') and s.id=t.invoice_id left join repair_loc i on t.kind in ('repair','repair_refund') and i.id=t.invoice_id where t.store_id=p_store
 ), unique_sources as (
  select kind,id,case when count(distinct coalesce(branch_id::text,''))=1 then min(branch_id::text)::uuid end branch_id,count(distinct coalesce(branch_id::text,''))=1 mapped from sources group by kind,id
 ), offset_locations as (
  select 'payroll_advance_offset'::text kind,o.id,p.branch_id debit_branch,a.branch_id credit_branch
  from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'payroll_offset_reversal',r.id,a.branch_id,p.branch_id from tenant_private.staff_payroll_reversals r join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id join tenant_private.staff_advances a on a.store_id=r.store_id and a.id=r.advance_id where r.store_id=p_store and r.kind='offset'
  union all select 'tradein_offset',t.id,p.branch_id,s.branch_id from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
 ), journal as (
  select j.*,s.branch_id,coalesce(s.mapped,false) mapped,o.id is not null and o.debit_branch is distinct from o.credit_branch as split,o.debit_branch,o.credit_branch
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
  'unmapped_pair_count',(select count(*) from journal where not split and not mapped),
  'unknown_transfer_units',coalesce((select sum(m.units) from tenant_private.branch_fifo_moves m join tenant_private.branch_transfers t on t.store_id=m.store_id and t.request_id=m.request_id join tenant_private.stock_layers l on l.store_id=m.store_id and l.product_id=m.product_id and l.id=m.layer_id where m.store_id=p_store and t.created_at<hi and (l.currency is null or l.unit_cost_minor is null)),0)::text,
  'opening_verified',false,
  'rows',coalesce((select jsonb_agg(to_jsonb(r) order by r.name,r.currency,r.account) from rows r),'[]'::jsonb)) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.financial_reconciliation(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;stock_mismatches bigint;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 with j as (
 select currency,account,sum(amount) balance from (
 select currency,debit_account account,amount from tenant_private.journal_pairs(p_store,'infinity'::timestamptz)
 union all select currency,credit_account,-amount from tenant_private.journal_pairs(p_store,'infinity'::timestamptz)) q group by currency,account
 ), source as (
 select currency,'cash' account,balance_minor::numeric amount from tenant_private.cash_balances where store_id=p_store
 union all select currency,'bank',balance_minor::numeric from tenant_private.bank_accounts where store_id=p_store
 union all select currency,'payroll_payable',-tenant_private.payroll_due(store_id,id)::numeric from tenant_private.staff_payroll where store_id=p_store and paid_at is null
 union all select currency,'employee_advances',tenant_private.advance_remaining(store_id,id)::numeric from tenant_private.staff_advances where store_id=p_store
 union all select currency,'inventory',remaining_units::numeric*unit_cost_minor from tenant_private.stock_layers where store_id=p_store
 union all select currency,'accounts_receivable',remaining_minor::numeric from public.mt_debts where store_id=p_store
 union all select currency,case when direction='receivable' then 'accounts_receivable' else 'accounts_payable' end,case when direction='receivable' then remaining_minor::numeric else -remaining_minor::numeric end from tenant_private.standalone_debts where store_id=p_store
 union all select currency,'accounts_payable',-(total_minor::numeric-returned_units::numeric*unit_cost_minor-paid_minor+refunded_minor) from public.mt_purchases where store_id=p_store
 union all select currency,'income_tax_payable',case when kind='income_tax_accrual' then -amount_minor::numeric else amount_minor::numeric end from public.mt_accounting_adjustments where store_id=p_store and kind in ('income_tax_accrual','income_tax_reverse','expense_tax_payment')
 union all select currency,'indirect_tax_payable',case when kind in ('sale','repair') then -tax_minor::numeric else tax_minor::numeric end from public.mt_indirect_tax_entries where store_id=p_store
 union all select currency,'indirect_tax_payable',amount_minor::numeric from public.mt_accounting_adjustments where store_id=p_store and kind='expense_indirect_tax_payment'
 union all select currency,'indirect_tax_payable',case when reversal_of is null then amount_minor::numeric else -amount_minor::numeric end from tenant_private.sy_tax_credit_events where store_id=p_store
 ), s as (select currency,account,sum(amount) balance from source group by currency,account),
 vals as (select c.currency,a.account,coalesce(j.balance,0) journal,coalesce(s.balance,0) recorded from tenant_private.sale_currencies c cross join unnest(array['cash','employee_advances','bank','inventory','accounts_receivable','accounts_payable','payroll_payable','income_tax_payable','indirect_tax_payable']) a(account) left join j on j.currency=c.currency and j.account=a.account left join s on s.currency=c.currency and s.account=a.account where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'account',account,'journal',journal::text,'recorded',recorded::text,'difference',(recorded-journal)::text,'balanced',recorded=journal) order by currency,account),'[]'::jsonb) into rows from vals;
 select count(*) into stock_mismatches from public.mt_products p where p.store_id=p_store and p.quantity<>(select coalesce(sum(l.remaining_units),0) from tenant_private.stock_layers l where l.store_id=p.store_id and l.product_id=p.id);
 return jsonb_build_object('mode','current_subledger_reconciliation','rows',rows,'stock_quantity_mismatches',stock_mismatches,'balanced',stock_mismatches=0 and not exists(select 1 from jsonb_array_elements(rows) x where x->>'balanced'='false'));
end; $function$;

CREATE OR REPLACE FUNCTION tenant_private.accounting_adjust(p_store uuid, p_request uuid, p_kind text, p_source uuid, p_currency text, p_amount bigint, p_reference text, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.mt_accounting_adjustments%rowtype;d text;c text;source_amount bigint;source_currency text;available numeric;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_amount is null or p_amount not between 1 and 100000000000000 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_note is null or length(btrim(p_note)) not between 1 and 300 or p_kind is null or p_kind not in ('funding_equity','funding_loan','stock_equity','expense_rent','expense_payroll','expense_utilities','expense_other','expense_tax_payment','expense_indirect_tax_payment','expense_loan_payment','expense_capital_withdrawal','income_tax_accrual','income_tax_reverse') or ((p_kind in ('income_tax_accrual','income_tax_reverse'))<>(p_source is null)) then raise exception 'Invalid accounting entry' using errcode='22023';end if;
 select * into r from public.mt_accounting_adjustments where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.kind<>p_kind or r.source_request is distinct from p_source or r.currency<>p_currency or r.amount_minor<>p_amount or r.reference<>btrim(p_reference) or r.note<>btrim(p_note) then raise exception 'Conflicting accounting request' using errcode='22023';end if;return r.id;
 end if;
 if p_source is not null then
  if p_kind='stock_equity' then
   select i.units*i.unit_cost_minor,i.currency into source_amount,source_currency from tenant_private.cost_intakes i where i.store_id=p_store and i.request_id=p_source and not exists(select 1 from public.mt_purchases p where p.store_id=i.store_id and p.intake_request=i.request_id);
  else
   select amount_minor,currency into source_amount,source_currency from public.mt_cash_movements where store_id=p_store and request_id=p_source and kind=case when p_kind in ('funding_equity','funding_loan') then 'funding' else 'expense' end;
  end if;
  if not found or source_currency<>p_currency or p_amount>source_amount-(select coalesce(sum(amount_minor),0) from public.mt_accounting_adjustments where store_id=p_store and source_request=p_source) then raise exception 'Source unavailable or already classified' using errcode='22023';end if;
 end if;
 case p_kind
 when 'funding_equity' then d:='funding_unclassified';c:='capital';
 when 'funding_loan' then d:='funding_unclassified';c:='loan_payable';
 when 'stock_equity' then d:='stock_intake_unclassified';c:='capital';
 when 'expense_rent' then d:='rent_expense';c:='expense_unclassified';
 when 'expense_payroll' then d:='payroll_expense';c:='expense_unclassified';
 when 'expense_utilities' then d:='utilities_expense';c:='expense_unclassified';
 when 'expense_other' then d:='other_operating_expense';c:='expense_unclassified';
 when 'expense_tax_payment' then d:='income_tax_payable';c:='expense_unclassified';
 when 'expense_indirect_tax_payment' then d:='indirect_tax_payable';c:='expense_unclassified';
 when 'expense_loan_payment' then d:='loan_payable';c:='expense_unclassified';
 when 'expense_capital_withdrawal' then d:='capital';c:='expense_unclassified';
 when 'income_tax_accrual' then d:='income_tax_expense';c:='income_tax_payable';
 when 'income_tax_reverse' then d:='income_tax_payable';c:='income_tax_expense';
 end case;
 if d in ('capital','loan_payable','income_tax_payable','indirect_tax_payable') then
 select coalesce(sum(case when credit_account=d then amount_minor else 0 end-case when debit_account=d then amount_minor else 0 end),0) into available from public.mt_accounting_adjustments where store_id=p_store and currency=p_currency and (debit_account=d or credit_account=d);
 if d='indirect_tax_payable' then
  available:=available+(select coalesce(sum(case when kind in ('sale','repair') then tax_minor else -tax_minor end),0) from public.mt_indirect_tax_entries where store_id=p_store and currency=p_currency)-(select coalesce(sum(case when reversal_of is null then amount_minor else -amount_minor end),0) from tenant_private.sy_tax_credit_events where store_id=p_store and currency=p_currency);
 end if;
 if p_amount>available then raise exception 'Adjustment exceeds recorded liability or equity' using errcode='22023';end if;
 end if;
 insert into public.mt_accounting_adjustments(store_id,request_id,kind,source_request,currency,amount_minor,debit_account,credit_account,reference,note,actor) values(p_store,p_request,p_kind,p_source,p_currency,p_amount,d,c,btrim(p_reference),btrim(p_note),auth.uid()) returning * into r;return r.id;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.indirect_tax_summary(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 with amounts as (select currency,coalesce(sum(tax_minor) filter(where kind in ('sale','repair')),0) assessed,coalesce(sum(tax_minor) filter(where kind in ('sale_return','repair_refund')),0) reversed from public.mt_indirect_tax_entries where store_id=p_store group by currency),
 credits as (select currency,sum(case when reversal_of is null then amount_minor else -amount_minor end) credited from tenant_private.sy_tax_credit_events where store_id=p_store group by currency),
 payments as (select currency,sum(amount_minor) paid from public.mt_accounting_adjustments where store_id=p_store and kind='expense_indirect_tax_payment' group by currency),
 missing as (select currency,count(*) missing from (
 select s.currency from public.mt_sales s where s.store_id=p_store and not exists(select 1 from public.mt_indirect_tax_entries e where e.store_id=p_store and e.kind='sale' and e.source_id=s.id)
 union all select s.currency from public.mt_repair_invoices s where s.store_id=p_store and not exists(select 1 from public.mt_indirect_tax_entries e where e.store_id=p_store and e.kind='repair' and e.source_id=s.id)
 union all select s.currency from public.mt_returns s where s.store_id=p_store and not exists(select 1 from public.mt_indirect_tax_entries e where e.store_id=p_store and e.kind='sale_return' and e.source_id=s.id)
 union all select s.currency from public.mt_repair_refunds s where s.store_id=p_store and not exists(select 1 from public.mt_indirect_tax_entries e where e.store_id=p_store and e.kind='repair_refund' and e.source_id=s.id)
 ) q group by currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency,'assessed',coalesce(a.assessed,0)::text,'reversed',coalesce(a.reversed,0)::text,'paid',coalesce(p.paid,0)::text,'credits',coalesce(k.credited,0)::text,'balance',(coalesce(a.assessed,0)-coalesce(a.reversed,0)-coalesce(p.paid,0)-coalesce(k.credited,0))::text,'unclassified_documents',coalesce(m.missing,0)) order by c.currency),'[]'::jsonb) into rows from tenant_private.sale_currencies c left join amounts a on a.currency=c.currency left join payments p on p.currency=c.currency left join credits k on k.currency=c.currency left join missing m on m.currency=c.currency where c.store_id=p_store;
 return rows;
end; $function$;

CREATE OR REPLACE FUNCTION tenant_private.sy_tax_period_review(s uuid, d1 date, d2 date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with docs as (
 select d.*,e.id entry_id,e.tax_minor,e.created_at posted,o.profile_id,o.document_ref output_ref,i.request_id input_id,i.treatment,i.tax_minor input_tax,
 parent.request_id parent_revision,parent.treatment parent_treatment,m.parts mixed_parts,cr.request_id credit_id,cr.amount_minor credit_minor,
 case when d.kind in ('purchase','supplier_return') then
   i.request_id is null or i.treatment='pending_review' or (i.treatment='potential_credit' and cr.request_id is null) or
   (d.kind='supplier_return' and (parent.request_id is null or parent.treatment in ('pending_review','potential_credit') or
     (i.tax_minor>0 and i.treatment is distinct from parent.treatment)))
 else o.profile_id is null and m.parts is null end unresolved
 from tenant_private.sy_tax_documents(s) d
 left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id
 left join lateral (select jsonb_agg(jsonb_build_array(z.profile_id,z.gross_minor,z.tax_minor) order by z.profile_id) parts from tenant_private.sy_tax_mixed_parts z where z.store_id=s and z.entry_id=e.id) m on true
 left join tenant_private.sy_tax_input_current(s) i on i.kind=d.kind and i.source_id=d.source_id
 left join lateral (select e0.request_id,e0.amount_minor from tenant_private.sy_tax_credit_events e0 where e0.store_id=s and d.kind='purchase' and e0.purchase_id=d.source_id and e0.input_revision=i.request_id and e0.reversal_of is null and not exists(select 1 from tenant_private.sy_tax_credit_events z where z.store_id=s and z.reversal_of=e0.request_id)) cr on true
 left join tenant_private.sy_tax_input_current(s) parent on d.kind='supplier_return' and parent.kind='purchase' and parent.source_id=d.invoice_id
 where d.occurred_at>=d1::timestamp at time zone 'Asia/Damascus' and d.occurred_at<(d2+1)::timestamp at time zone 'Asia/Damascus'
 ), totals as (
 select branch_id,currency,
 coalesce(sum(tax_minor::numeric) filter(where kind in ('sale','repair')),0)-coalesce(sum(tax_minor::numeric) filter(where kind in ('sale_return','repair_refund')),0) output_net,
 coalesce(sum(input_tax::numeric) filter(where kind='purchase'),0)-coalesce(sum(input_tax::numeric) filter(where kind='supplier_return'),0) input_documented_net,
 count(*) filter(where unresolved) unresolved_count
 from docs group by branch_id,currency
 )
 select jsonb_build_object('output_unclassified',count(*) filter(where kind not in ('purchase','supplier_return') and unresolved),
 'input_unclassified',count(*) filter(where kind in ('purchase','supplier_return') and unresolved),
 'late_output_postings',count(*) filter(where tax_minor>0 and (posted<d1::timestamp at time zone 'Asia/Damascus' or posted>=(d2+1)::timestamp at time zone 'Asia/Damascus'))+
 (select count(*) from public.mt_indirect_tax_entries e join tenant_private.sy_tax_documents(s) d on d.kind=e.kind and d.source_id=e.source_id where e.store_id=s and e.tax_minor>0 and e.created_at>=d1::timestamp at time zone 'Asia/Damascus' and e.created_at<(d2+1)::timestamp at time zone 'Asia/Damascus' and (d.occurred_at<d1::timestamp at time zone 'Asia/Damascus' or d.occurred_at>=(d2+1)::timestamp at time zone 'Asia/Damascus')),
 'input_credit_posting_enabled',true,'credit_postings',coalesce((select jsonb_agg(jsonb_build_object('branch_id',z.branch_id,'currency',z.currency,'net_credit',z.net_credit::text) order by z.branch_id nulls first,z.currency) from (select branch_id,currency,sum(case when reversal_of is null then amount_minor else -amount_minor end) net_credit from tenant_private.sy_tax_credit_events where store_id=s and created_at>=d1::timestamp at time zone 'Asia/Damascus' and created_at<(d2+1)::timestamp at time zone 'Asia/Damascus' group by branch_id,currency) z),'[]'::jsonb),
 'evidence_digest',encode(sha256(convert_to(coalesce(jsonb_agg(jsonb_build_array(kind,source_id,invoice_id,branch_id,currency,gross_minor,occurred_at,entry_id,tax_minor,posted,profile_id,output_ref,input_id,input_tax,treatment,parent_revision,parent_treatment,mixed_parts,credit_id,credit_minor,unresolved) order by kind,source_id),'[]'::jsonb)::text,'UTF8')),'hex'),
 'totals',coalesce((select jsonb_agg(jsonb_build_object('branch_id',t.branch_id,'currency',t.currency,'output_net',t.output_net::text,'input_documented_net',t.input_documented_net::text,'unresolved_count',t.unresolved_count) order by t.branch_id nulls first,t.currency) from totals t),'[]'::jsonb)) from docs
$function$;

CREATE OR REPLACE FUNCTION tenant_private.sy_tax_queue(s uuid, d1 date, d2 date, filter_kind text, missing_only boolean, off integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare data jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if d1 is null or d2 is null or d2<d1 or d2-d1>365 or d2>(now() at time zone 'Asia/Damascus')::date or filter_kind is null or filter_kind not in ('all','sale','repair','sale_return','repair_refund','purchase','supplier_return') or missing_only is null or off is null or off not between 0 and 100000 then raise exception 'Invalid tax period' using errcode='22023';end if;
 with docs as (
 select d.*,coalesce(b.name,'') branch_name,e.id entry_id,o.profile_id,p.label profile_label,e.tax_minor output_tax,e.created_at tax_posted_at,
 m.parts mixed_parts, (orig.id is not null and orig.rate_bps is null) original_mixed,
 cr.request_id credit_id,cr.amount_minor credit_minor,inp.request_id input_revision,inp.tax_minor input_tax,inp.treatment,inp.document_ref input_document_ref,inp.legal_reference input_legal_reference,
 case when d.kind in ('purchase','supplier_return') then inp.request_id is null or inp.treatment='pending_review' or (inp.treatment='potential_credit' and cr.request_id is null) else o.profile_id is null and m.parts is null end unresolved
 from tenant_private.sy_tax_documents(s) d left join tenant_private.branches b on b.store_id=s and b.id=d.branch_id
 left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id left join tenant_private.sy_tax_profiles p on p.store_id=s and p.id=o.profile_id
 left join lateral (select jsonb_agg(jsonb_build_object('profile_id',z.profile_id,'gross_minor',z.gross_minor,'tax_minor',z.tax_minor,'label',p0.label,'rate_bps',p0.rate_bps) order by z.profile_id) parts from tenant_private.sy_tax_mixed_parts z join tenant_private.sy_tax_profiles p0 on p0.store_id=z.store_id and p0.id=z.profile_id where z.store_id=s and z.entry_id=e.id) m on true
 left join public.mt_indirect_tax_entries orig on orig.store_id=s and orig.source_id=d.invoice_id and orig.kind=case d.kind when 'sale_return' then 'sale' when 'repair_refund' then 'repair' end
 left join tenant_private.sy_tax_input_current(s) inp on inp.kind=d.kind and inp.source_id=d.source_id
 left join lateral (select e0.request_id,e0.amount_minor from tenant_private.sy_tax_credit_events e0 where e0.store_id=s and d.kind='purchase' and e0.purchase_id=d.source_id and e0.input_revision=inp.request_id and e0.reversal_of is null and not exists(select 1 from tenant_private.sy_tax_credit_events z where z.store_id=s and z.reversal_of=e0.request_id)) cr on true
 where d.occurred_at>=d1::timestamp at time zone 'Asia/Damascus' and d.occurred_at<(d2+1)::timestamp at time zone 'Asia/Damascus' and (filter_kind='all' or d.kind=filter_kind)
 ),page as (select * from docs where not missing_only or unresolved order by occurred_at desc,kind,source_id offset off limit 51)
 select coalesce(jsonb_agg(to_jsonb(page) order by occurred_at desc,kind,source_id),'[]'::jsonb) into data from page;
 return jsonb_build_object('rows',case when jsonb_array_length(data)>50 then data-50 else data end,'more',jsonb_array_length(data)>50);
end $function$;

commit;
