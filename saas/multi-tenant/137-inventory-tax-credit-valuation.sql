-- 137: documented input-credit inventory valuation and automatic cost release with actual recorded FX.
-- Only stationary, verified branch FIFO lots qualify for the inventory component. Transfers/returns require reversal.
begin;
create table tenant_private.sy_tax_inventory_parts(
 store_id uuid not null,credit_id uuid not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),
 base_units bigint not null check(base_units>0),primary key(store_id,credit_id),
 foreign key(store_id,credit_id) references tenant_private.sy_tax_credit_events(store_id,request_id)
);
create table tenant_private.sy_tax_inventory_releases(
 store_id uuid not null,id uuid not null default gen_random_uuid(),credit_id uuid not null,
 product_id uuid not null,event_id uuid not null,layer_id bigint not null,units bigint not null check(units>0),
 currency text not null,invoice_currency text not null,amount_minor bigint not null check(amount_minor>=0),
 invoice_amount numeric not null check(invoice_amount>=0),fx_rate_id uuid,created_at timestamptz not null,
 primary key(store_id,id),unique(store_id,credit_id,product_id,event_id,layer_id),
 foreign key(store_id,credit_id) references tenant_private.sy_tax_inventory_parts(store_id,credit_id),
 foreign key(store_id,product_id,event_id,layer_id) references tenant_private.cost_postings(store_id,product_id,event_id,layer_id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 foreign key(store_id,invoice_currency) references tenant_private.sale_currencies(store_id,currency)
);
alter table tenant_private.sy_tax_inventory_parts enable row level security;
alter table tenant_private.sy_tax_inventory_releases enable row level security;
revoke all on tenant_private.sy_tax_inventory_parts,tenant_private.sy_tax_inventory_releases from public,anon,authenticated,service_role;
create trigger mt_guard_closed_period before insert on tenant_private.sy_tax_inventory_releases for each row execute function tenant_private.guard_closed_period();

create function tenant_private.sy_tax_inventory_outstanding(s uuid)
returns table(branch_id uuid,currency text,outstanding numeric)
language sql stable set search_path='' as $$
 select e.branch_id,e.currency,z.amount_minor-coalesce((select sum(r.amount_minor) from tenant_private.sy_tax_inventory_releases r where r.store_id=s and r.credit_id=z.credit_id),0)
 from tenant_private.sy_tax_inventory_parts z join tenant_private.sy_tax_credit_events e on e.store_id=z.store_id and e.request_id=z.credit_id
 where z.store_id=s and e.reversal_of is null and not exists(select 1 from tenant_private.sy_tax_credit_events rev where rev.store_id=s and rev.reversal_of=e.request_id)
$$;
revoke all on function tenant_private.sy_tax_inventory_outstanding(uuid) from public,anon,authenticated,service_role;

create function tenant_private.sy_tax_inventory_guard_consumption() returns trigger
language plpgsql security definer set search_path='' as $$
declare c tenant_private.sy_tax_credit_events%rowtype;e public.mt_stock_events%rowtype;
begin
 select a.* into c from tenant_private.stock_layers l join public.mt_purchases p on p.store_id=l.store_id and p.intake_request=l.intake_request cross join lateral tenant_private.sy_tax_credit_active(new.store_id,p.id) a join tenant_private.sy_tax_inventory_parts z on z.store_id=a.store_id and z.credit_id=a.request_id where l.store_id=new.store_id and l.product_id=new.product_id and l.id=new.layer_id;
 if not found then return new;end if;
 select * into strict e from public.mt_stock_events x where x.store_id=new.store_id and x.request_id=new.event_id;
 if e.sale_id is null or e.delta>=0 or tenant_private.fifo_event_branch(e) is distinct from c.branch_id then raise exception 'Reverse inventory tax credit before non-sale or cross-location stock use' using errcode='22023';end if;
 return new;
end $$;
create trigger sy_tax_inventory_guard_consumption before insert on tenant_private.stock_consumptions for each row execute function tenant_private.sy_tax_inventory_guard_consumption();

create function tenant_private.sy_tax_inventory_guard_transfer() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from tenant_private.stock_layers l where l.store_id=new.store_id and l.product_id=new.product_id and l.id=new.layer_id for update;
 if exists(select 1 from tenant_private.stock_layers l join public.mt_purchases p on p.store_id=l.store_id and p.intake_request=l.intake_request cross join lateral tenant_private.sy_tax_credit_active(new.store_id,p.id) a join tenant_private.sy_tax_inventory_parts z on z.store_id=a.store_id and z.credit_id=a.request_id where l.store_id=new.store_id and l.product_id=new.product_id and l.id=new.layer_id) then raise exception 'Reverse inventory tax credit before branch transfer' using errcode='22023';end if;return new;
end $$;
create trigger sy_tax_inventory_guard_transfer before insert on tenant_private.branch_fifo_moves for each row execute function tenant_private.sy_tax_inventory_guard_transfer();

create function tenant_private.sy_tax_inventory_release_cost() returns trigger
language plpgsql security definer set search_path='' as $$
declare c tenant_private.sy_tax_credit_events%rowtype;z tenant_private.sy_tax_inventory_parts%rowtype; old_units numeric; old_amount numeric; source_share bigint; converted numeric;rate public.mt_fx_rates%rowtype;
begin
 select a.* into c from tenant_private.stock_layers l join public.mt_purchases p on p.store_id=l.store_id and p.intake_request=l.intake_request cross join lateral tenant_private.sy_tax_credit_active(new.store_id,p.id) a join tenant_private.sy_tax_inventory_parts k on k.store_id=a.store_id and k.credit_id=a.request_id where l.store_id=new.store_id and l.product_id=new.product_id and l.id=new.layer_id;
 if not found then return new;end if;
 select * into strict z from tenant_private.sy_tax_inventory_parts k where k.store_id=c.store_id and k.credit_id=c.request_id;
 if new.sale_id is null or new.source_currency is distinct from c.currency or new.invoice_cost_minor is null or new.source_cost_minor is null or new.created_at<c.created_at then raise exception 'Inventory tax credit requires a valid current sale cost and currency rate' using errcode='22023';end if;
 select coalesce(sum(r.units),0),coalesce(sum(r.amount_minor),0) into old_units,old_amount from tenant_private.sy_tax_inventory_releases r where r.store_id=c.store_id and r.credit_id=c.request_id;
 if old_units+new.units>z.base_units then raise exception 'Tax credit release units exceed original credited stock';end if;
 source_share:=(floor(z.amount_minor::numeric*(old_units+new.units)/z.base_units)-old_amount)::bigint;
 if source_share<0 or source_share>new.source_cost_minor then raise exception 'Invalid inventory tax credit release';end if;
 if new.source_currency=new.invoice_currency then converted:=source_share;
 else
  select * into rate from public.mt_fx_rates x where x.store_id=new.store_id and x.id=new.fx_rate_id and x.from_currency=new.source_currency and x.to_currency=new.invoice_currency;
  if not found or round(new.source_cost_minor*rate.numerator/rate.denominator)<>new.invoice_cost_minor then raise exception 'Recorded FX quote required for credited stock';end if;
  converted:=new.invoice_cost_minor-round((new.source_cost_minor-source_share)*rate.numerator/rate.denominator);
 end if;
 if converted<0 or converted>new.invoice_cost_minor then raise exception 'Invalid converted credit cost';end if;
 insert into tenant_private.sy_tax_inventory_releases(store_id,credit_id,product_id,event_id,layer_id,units,currency,invoice_currency,amount_minor,invoice_amount,fx_rate_id,created_at)
 values(new.store_id,c.request_id,new.product_id,new.event_id,new.layer_id,new.units,new.source_currency,new.invoice_currency,source_share,converted,new.fx_rate_id,new.created_at);
 return new;
end $$;
create trigger sy_tax_inventory_release_cost after insert on tenant_private.cost_postings for each row execute function tenant_private.sy_tax_inventory_release_cost();
revoke all on function tenant_private.sy_tax_inventory_guard_consumption(),tenant_private.sy_tax_inventory_guard_transfer(),tenant_private.sy_tax_inventory_release_cost() from public,anon,authenticated,service_role;

create or replace function tenant_private.sy_tax_credit_review(s uuid,purchase uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare p public.mt_purchases%rowtype;l tenant_private.stock_layers%rowtype;i tenant_private.sy_tax_input_events%rowtype; a tenant_private.sy_tax_credit_events%rowtype;
 branch uuid; journal jsonb; liability numeric:=0; store_liability numeric:=0; consumed numeric:=0; valid boolean:=false; reason text; history jsonb; result jsonb;
 sold_by_branch jsonb:='[]'::jsonb; allocation jsonb:='[]'::jsonb; transfer_exists boolean:=false; cross_branch boolean:=false; legal_cap numeric:=0; maximum numeric:=0; inventory_mode boolean:=false; inventory_posted numeric:=0; inventory_outstanding numeric:=0;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into p from public.mt_purchases x where x.store_id=s and x.id=purchase;
 if not found then raise exception 'Purchase not found' using errcode='22023';end if;
 select * into i from tenant_private.sy_tax_input_current(s) x where x.kind='purchase' and x.source_id=purchase;
 select * into a from tenant_private.sy_tax_credit_active(s,purchase);
 select * into l from tenant_private.stock_layers x where x.store_id=s and x.intake_request=p.intake_request and x.product_id=p.product_id;
 select x.branch_id into branch from tenant_private.branch_purchases x where x.store_id=s and x.purchase_id=purchase;
 if a.request_id is not null then
  reason:='already_posted';
  select coalesce(jsonb_agg(jsonb_build_object('branch_id',z.cost_branch_id,'name',b.name,'amount_minor',z.amount_minor::text) order by z.cost_branch_id nulls first),'[]'::jsonb) into allocation
  from tenant_private.sy_tax_credit_allocations z left join tenant_private.branches b on b.store_id=z.store_id and b.id=z.cost_branch_id where z.store_id=s and z.credit_id=a.request_id;
 elsif i.request_id is null or i.treatment<>'potential_credit' or i.tax_minor<=0 then reason:='review_required';
 elsif l.id is null or l.currency is distinct from p.currency or l.unit_cost_minor is null or l.original_units<>p.units or l.unit_cost_minor::numeric*p.units<>p.total_minor or p.returned_units<>0 then reason:='inventory_cost_mismatch';
 else
  select coalesce(sum(c.units),0),coalesce(bool_and(c.restored_units=0 and coalesce(cp.sale_id is not null and cp.repair_invoice_id is null and cp.units=c.units and cp.source_currency=p.currency and cp.invoice_currency=p.currency and cp.source_cost_minor=c.units::numeric*l.unit_cost_minor and cp.invoice_cost_minor=cp.source_cost_minor,false)),false)
  into consumed,valid from tenant_private.stock_consumptions c
  left join tenant_private.cost_postings cp on cp.store_id=c.store_id and cp.product_id=c.product_id and cp.event_id=c.event_id and cp.layer_id=c.layer_id
  where c.store_id=s and c.product_id=l.product_id and c.layer_id=l.id;
  if (consumed>0 and not valid) or consumed<>p.units-l.remaining_units then reason:='cost_attribution_incomplete';
  else
   with grouped as (
    select bs.branch_id,sum(c.units)::numeric units
    from tenant_private.stock_consumptions c join tenant_private.cost_postings cp on cp.store_id=c.store_id and cp.product_id=c.product_id and cp.event_id=c.event_id and cp.layer_id=c.layer_id
    left join tenant_private.branch_sales bs on bs.store_id=cp.store_id and bs.sale_id=cp.sale_id
    where c.store_id=s and c.product_id=l.product_id and c.layer_id=l.id group by bs.branch_id
   )
   select coalesce(jsonb_agg(jsonb_build_object('branch_id',g.branch_id,'name',b.name,'units',g.units::text) order by g.branch_id nulls first),'[]'::jsonb),coalesce(bool_or(g.branch_id is distinct from branch),false) into sold_by_branch,cross_branch
   from grouped g left join tenant_private.branches b on b.store_id=s and b.id=g.branch_id;
   select exists(select 1 from tenant_private.branch_fifo_moves x where x.store_id=s and x.product_id=l.product_id and x.layer_id=l.id) into transfer_exists;
   if (cross_branch or transfer_exists) and (not transfer_exists or not exists(select 1 from tenant_private.branch_fifo_enabled f where f.store_id=s and f.activated_at<=p.created_at) or (select coalesce(sum(z.units),0) from tenant_private.branch_fifo_lots z where z.store_id=s and z.product_id=l.product_id and z.layer_id=l.id)<>l.remaining_units) then reason:='transfer_history_incomplete';
   else
    inventory_mode:=l.remaining_units>0 and not transfer_exists and not cross_branch and exists(select 1 from tenant_private.branch_fifo_enabled f where f.store_id=s and f.activated_at<=p.created_at) and (select coalesce(sum(z.units),0) from tenant_private.branch_fifo_lots z where z.store_id=s and z.product_id=l.product_id and z.layer_id=l.id and z.branch_id is not distinct from branch)=l.remaining_units and not exists(select 1 from tenant_private.branch_fifo_lots z where z.store_id=s and z.product_id=l.product_id and z.layer_id=l.id and z.branch_id is distinct from branch and z.units>0);
    legal_cap:=case when inventory_mode then i.tax_minor::numeric else floor(i.tax_minor::numeric*consumed/p.units) end;
    journal:=tenant_private.branch_journal_projection(s,(now() at time zone 'Asia/Damascus')::date,(now() at time zone 'Asia/Damascus')::date);
    select coalesce(-sum((x->>'closing')::numeric) filter(where (x->>'branch_id')::uuid is not distinct from branch),0),coalesce(-sum((x->>'closing')::numeric),0) into liability,store_liability from jsonb_array_elements(journal->'rows') x where x->>'account'='indirect_tax_payable' and x->>'currency'=p.currency;
    if liability<=0 or store_liability<=0 then reason:='no_recorded_liability';
    elsif legal_cap<=0 then reason:='no_sold_credit';
    else reason:='eligible';maximum:=least(legal_cap,liability,store_liability,p.total_minor);end if;
   end if;
  end if;
 end if;
 if a.request_id is not null then
  select z.amount_minor, z.amount_minor-coalesce((select sum(r.amount_minor) from tenant_private.sy_tax_inventory_releases r where r.store_id=s and r.credit_id=z.credit_id),0) into inventory_posted,inventory_outstanding from tenant_private.sy_tax_inventory_parts z where z.store_id=s and z.credit_id=a.request_id;
 end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id desc),'[]'::jsonb) into history from (
  select request_id,reversal_of,amount_minor::text amount_minor,reference,legal_reference,created_at,pending_lot from tenant_private.sy_tax_credit_events e where e.store_id=s and e.purchase_id=purchase order by created_at desc,request_id desc limit 50
 ) x;
 result:=jsonb_build_object('purchase_id',purchase,'branch_id',branch,'currency',p.currency,'input_revision',i.request_id,'documented_tax',coalesce(i.tax_minor,0)::text,'active_credit',a.request_id,'active_amount',coalesce(a.amount_minor,0)::text,'reason',reason,'maximum',maximum::text,'history',history,
 'original_units',p.units::text,'remaining_units',case when l.id is null then null else l.remaining_units::text end,'sold_units',consumed::text,'sold_by_branch',sold_by_branch,'active_allocation',allocation,'pending_lot',coalesce(a.pending_lot,false),'sold_credit_cap',legal_cap::text,'inventory_mode',inventory_mode,'inventory_credit',coalesce(inventory_posted,0)::text,'inventory_outstanding',coalesce(inventory_outstanding,0)::text);
 return result||jsonb_build_object('digest',tenant_private.finance_review_digest(result));
end $$;

create or replace function tenant_private.sy_tax_credit_record(s uuid,req uuid,purchase uuid,previous uuid,digest text,amount bigint,proof text,legal text,confirmed boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare q jsonb;old tenant_private.sy_tax_credit_events%rowtype; a tenant_private.sy_tax_credit_events%rowtype; allocated numeric; inventory_share bigint:=0; sold_share bigint;
begin
 perform tenant_private.owner_write(s);
 if req is null or purchase is null or digest is null or digest !~ '^[0-9a-f]{64}$' or amount is null or amount not between 1 and 100000000000000 or proof is null or length(btrim(proof)) not between 1 and 160 or legal is null or length(btrim(legal)) not between 1 and 200 or confirmed is distinct from true then raise exception 'Confirm documented credit' using errcode='22023';end if;
 select * into old from tenant_private.sy_tax_credit_events where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.purchase_id<>purchase or old.reversal_of is distinct from previous or old.amount_minor<>amount or old.reference<>btrim(proof) or old.legal_reference<>btrim(legal) then raise exception 'Conflicting credit request' using errcode='22023';end if;return req;
 end if;
 -- Serialize against stock sales and transfers before computing the final quote.
 perform 1 from tenant_private.stock_layers l join public.mt_purchases p on p.store_id=l.store_id and p.intake_request=l.intake_request where p.store_id=s and p.id=purchase for update of l;
 q:=tenant_private.sy_tax_credit_review(s,purchase);
 if q->>'digest' is distinct from digest then raise exception 'Credit review changed; reload' using errcode='22023';end if;
 if previous is null then
  if q->>'reason' is distinct from 'eligible' or amount>(q->>'maximum')::numeric then raise exception 'Credit exceeds eligible documented amount' using errcode='22023';end if;
  if coalesce((q->>'inventory_mode')::boolean,false) then inventory_share:=amount-floor(amount::numeric*(q->>'sold_units')::numeric/(q->>'original_units')::numeric)::bigint;end if;
  sold_share:=amount-inventory_share;
  insert into tenant_private.sy_tax_credit_events(store_id,purchase_id,request_id,input_revision,branch_id,currency,amount_minor,reference,legal_reference,actor,pending_lot)
  values(s,purchase,req,(q->>'input_revision')::uuid,(q->>'branch_id')::uuid,q->>'currency',amount,btrim(proof),btrim(legal),auth.uid(),(q->>'remaining_units')::numeric>0 and inventory_share=0);
  if inventory_share>0 then insert into tenant_private.sy_tax_inventory_parts(store_id,credit_id,amount_minor,base_units) values(s,req,inventory_share,(q->>'remaining_units')::bigint);end if;
  with groups as (
   select (x->>'branch_id')::uuid branch_id,(x->>'units')::numeric units from jsonb_array_elements(q->'sold_by_branch') x
  ), running as (
   select branch_id,units,sum(units) over(order by branch_id nulls first rows unbounded preceding) cumulative from groups
  ), allocations as (
   select branch_id,floor(sold_share::numeric*cumulative/nullif((q->>'sold_units')::numeric,0))-floor(sold_share::numeric*(cumulative-units)/nullif((q->>'sold_units')::numeric,0)) share from running
  )
  insert into tenant_private.sy_tax_credit_allocations(store_id,credit_id,cost_branch_id,amount_minor)
  select s,req,branch_id,share::bigint from allocations where share>0;
  select coalesce(sum(z.amount_minor),0) into allocated from tenant_private.sy_tax_credit_allocations z where z.store_id=s and z.credit_id=req;
  if allocated+inventory_share<>amount then raise exception 'Credit allocation does not balance';end if;
 else
  select * into a from tenant_private.sy_tax_credit_active(s,purchase);
  if a.request_id is distinct from previous or a.amount_minor<>amount then raise exception 'Reverse the exact active credit' using errcode='22023';end if;
  insert into tenant_private.sy_tax_credit_events(store_id,purchase_id,request_id,input_revision,branch_id,currency,amount_minor,reversal_of,reference,legal_reference,actor,pending_lot)
  values(s,purchase,req,a.input_revision,a.branch_id,a.currency,a.amount_minor,previous,btrim(proof),btrim(legal),auth.uid(),a.pending_lot);
  insert into tenant_private.sy_tax_credit_allocations(store_id,credit_id,cost_branch_id,amount_minor)
  select s,req,z.cost_branch_id,z.amount_minor from tenant_private.sy_tax_credit_allocations z where z.store_id=s and z.credit_id=previous;
  select coalesce(sum(z.amount_minor),0) into allocated from tenant_private.sy_tax_credit_allocations z where z.store_id=s and z.credit_id=req;
  insert into tenant_private.sy_tax_inventory_parts(store_id,credit_id,amount_minor,base_units) select s,req,z.amount_minor,z.base_units from tenant_private.sy_tax_inventory_parts z where z.store_id=s and z.credit_id=previous;
  select coalesce(sum(z.amount_minor),0) into inventory_share from tenant_private.sy_tax_inventory_parts z where z.store_id=s and z.credit_id=req;
  if allocated+inventory_share<>0 and allocated+inventory_share<>amount then raise exception 'Credit reversal allocation does not balance';end if;
 end if;return req;
end $$;

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
 union all select e.created_at,'sy_tax_credit',e.request_id,e.currency,case when e.reversal_of is null then 'indirect_tax_payable' else 'cost_of_goods_services' end,case when e.reversal_of is null then 'cost_of_goods_services' else 'indirect_tax_payable' end,e.amount_minor::numeric from tenant_private.sy_tax_credit_events e where e.store_id=p_store and e.created_at<p_until and not exists(select 1 from tenant_private.sy_tax_credit_allocations a where a.store_id=e.store_id and a.credit_id=e.request_id) and not exists(select 1 from tenant_private.sy_tax_inventory_parts z where z.store_id=e.store_id and z.credit_id=e.request_id)
 union all select e.created_at,'sy_tax_credit_part',a.id,e.currency,case when e.reversal_of is null then 'indirect_tax_payable' else 'cost_of_goods_services' end,case when e.reversal_of is null then 'cost_of_goods_services' else 'indirect_tax_payable' end,a.amount_minor::numeric from tenant_private.sy_tax_credit_allocations a join tenant_private.sy_tax_credit_events e on e.store_id=a.store_id and e.request_id=a.credit_id where a.store_id=p_store and e.created_at<p_until
 union all select e.created_at,'sy_tax_inventory_part',z.credit_id,e.currency,case when e.reversal_of is null then 'indirect_tax_payable' else 'inventory' end,case when e.reversal_of is null then 'inventory' else 'indirect_tax_payable' end,z.amount_minor::numeric from tenant_private.sy_tax_inventory_parts z join tenant_private.sy_tax_credit_events e on e.store_id=z.store_id and e.request_id=z.credit_id where z.store_id=p_store and e.created_at<p_until
 union all select r.created_at,'sy_tax_inventory_release',r.id,r.currency,'inventory',case when r.currency=r.invoice_currency then 'cost_of_goods_services' else 'fx_clearing' end,r.amount_minor::numeric from tenant_private.sy_tax_inventory_releases r where r.store_id=p_store and r.created_at<p_until
 union all select r.created_at,'sy_tax_inventory_release',r.id,r.invoice_currency,'fx_clearing','cost_of_goods_services',r.invoice_amount from tenant_private.sy_tax_inventory_releases r where r.store_id=p_store and r.created_at<p_until and r.currency<>r.invoice_currency
 union all select e.created_at,'sy_tax_inventory_release',r.id,r.currency,case when r.currency=r.invoice_currency then 'cost_of_goods_services' else 'fx_clearing' end,'inventory',r.amount_minor::numeric from tenant_private.sy_tax_inventory_releases r join tenant_private.sy_tax_credit_events e on e.store_id=r.store_id and e.reversal_of=r.credit_id where r.store_id=p_store and e.created_at<p_until
 union all select e.created_at,'sy_tax_inventory_release',r.id,r.invoice_currency,'cost_of_goods_services','fx_clearing',r.invoice_amount from tenant_private.sy_tax_inventory_releases r join tenant_private.sy_tax_credit_events e on e.store_id=r.store_id and e.reversal_of=r.credit_id where r.store_id=p_store and e.created_at<p_until and r.currency<>r.invoice_currency
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
  union all select 'sy_tax_credit_part',a.id,e.branch_id from tenant_private.sy_tax_credit_allocations a join tenant_private.sy_tax_credit_events e on e.store_id=a.store_id and e.request_id=a.credit_id where a.store_id=p_store
  union all select 'sy_tax_inventory_part',z.credit_id,e.branch_id from tenant_private.sy_tax_inventory_parts z join tenant_private.sy_tax_credit_events e on e.store_id=z.store_id and e.request_id=z.credit_id where z.store_id=p_store
  union all select 'sy_tax_inventory_release',r.id,e.branch_id from tenant_private.sy_tax_inventory_releases r join tenant_private.sy_tax_credit_events e on e.store_id=r.store_id and e.request_id=r.credit_id where r.store_id=p_store
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
  select 'sy_tax_credit_part'::text kind,a.id,case when e.reversal_of is null then e.branch_id else a.cost_branch_id end debit_branch,case when e.reversal_of is null then a.cost_branch_id else e.branch_id end credit_branch from tenant_private.sy_tax_credit_allocations a join tenant_private.sy_tax_credit_events e on e.store_id=a.store_id and e.request_id=a.credit_id where a.store_id=p_store
  union all
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
 union all select currency,'inventory',-outstanding from tenant_private.sy_tax_inventory_outstanding(p_store)
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

CREATE OR REPLACE FUNCTION tenant_private.branch_account_balances(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return (with locations as (
 select null::uuid branch_id,'المستودع الرئيسي'::text name union all select id,name from tenant_private.branches where store_id=p_store
 ), entries as (
 select b.branch_id,d.currency,'receivable'::text account,d.remaining_minor::numeric amount from public.mt_debts d left join tenant_private.branch_sales b on b.store_id=d.store_id and b.sale_id=d.sale_id where d.store_id=p_store
 union all select branch_id,currency,direction,remaining_minor::numeric from tenant_private.standalone_debts where store_id=p_store
 union all select b.branch_id,p.currency,'payable',p.total_minor::numeric-p.returned_units::numeric*p.unit_cost_minor-p.paid_minor+p.refunded_minor from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=p_store
 union all select branch_id,currency,'payroll',tenant_private.payroll_due(store_id,id)::numeric from tenant_private.staff_payroll where store_id=p_store and paid_at is null
 union all select branch_id,currency,'advance',tenant_private.advance_remaining(store_id,id)::numeric from tenant_private.staff_advances where store_id=p_store
 ), totals as (select branch_id,currency,sum(amount) filter(where account='receivable') receivable,sum(amount) filter(where account='payable') payable,sum(amount) filter(where account='payroll') payroll,sum(amount) filter(where account='advance') advances from entries group by branch_id,currency),
 units as (select branch_id,sum(units)::numeric units from tenant_private.branch_stock where store_id=p_store group by branch_id union all select null::uuid,coalesce(sum(p.quantity-tenant_private.branch_allocated(p.store_id,p.id)),0)::numeric from public.mt_products p where store_id=p_store),
 bank as (select branch_id,currency,sum(balance_minor)::numeric amount from tenant_private.bank_accounts where store_id=p_store group by branch_id,currency),
 gross_valuation as (select a.branch_id,k.currency,a.units::numeric*k.unit_cost_minor amount from tenant_private.branch_fifo_lots a join tenant_private.stock_layers k on k.store_id=a.store_id and k.product_id=a.product_id and k.id=a.layer_id where a.store_id=p_store and a.units>0 and k.currency is not null union all select branch_id,currency,-outstanding from tenant_private.sy_tax_inventory_outstanding(p_store)),
 valuation as (select branch_id,currency,sum(amount) amount from gross_valuation group by branch_id,currency),
 unknown as (select a.branch_id,sum(a.units)::numeric units from tenant_private.branch_fifo_lots a join tenant_private.stock_layers k on k.store_id=a.store_id and k.product_id=a.product_id and k.id=a.layer_id where a.store_id=p_store and a.units>0 and k.currency is null group by a.branch_id),
 rows as (select l.branch_id,l.name,c.currency,case when exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then coalesce(a.balance_minor,0)::text else null end cash,coalesce(bk.amount,0)::text bank,case when exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then coalesce(v.amount,0)::text else null end known_stock_cost,case when exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then coalesce(un.units,0)::text else null end unknown_cost_units,coalesce(t.receivable,0)::text receivable,coalesce(t.payable,0)::text payable,coalesce(t.payroll,0)::text payroll,coalesce(t.advances,0)::text advances,coalesce(u.units,0)::text stock_units from locations l cross join tenant_private.sale_currencies c left join totals t on t.branch_id is not distinct from l.branch_id and t.currency=c.currency left join tenant_private.branch_cash_accounts a on a.store_id=p_store and a.branch_id is not distinct from l.branch_id and a.currency=c.currency left join units u on u.branch_id is not distinct from l.branch_id left join bank bk on bk.branch_id is not distinct from l.branch_id and bk.currency=c.currency left join valuation v on v.branch_id is not distinct from l.branch_id and v.currency=c.currency left join unknown un on un.branch_id is not distinct from l.branch_id where c.store_id=p_store)
 select jsonb_build_object('mode','attributed_subledgers','stock_valuation_available',exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store),'rows',coalesce(jsonb_agg(to_jsonb(r) order by r.name,r.currency),'[]'::jsonb)) from rows r);
end $function$;

commit;
