-- 139: historical single-location cost FX and atomic documented supplier returns.
begin;
create or replace function tenant_private.sy_tax_credit_review(s uuid,purchase uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare p public.mt_purchases%rowtype;l tenant_private.stock_layers%rowtype;i tenant_private.sy_tax_input_events%rowtype; a tenant_private.sy_tax_credit_events%rowtype;
 branch uuid; journal jsonb; liability numeric:=0; store_liability numeric:=0; consumed numeric:=0; valid boolean:=false; reason text; history jsonb; result jsonb;
 sold_by_branch jsonb:='[]'::jsonb; allocation jsonb:='[]'::jsonb; transfer_exists boolean:=false; cross_branch boolean:=false; legal_cap numeric:=0; maximum numeric:=0; inventory_mode boolean:=false; inventory_posted numeric:=0; inventory_outstanding numeric:=0; net_tax numeric:=0; net_units bigint; bad_returns bigint; fx_history boolean:=false; historical_mode boolean:=false; historical_rows jsonb:='[]'::jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into p from public.mt_purchases x where x.store_id=s and x.id=purchase;
 if not found then raise exception 'Purchase not found' using errcode='22023';end if;
 select * into i from tenant_private.sy_tax_input_current(s) x where x.kind='purchase' and x.source_id=purchase;
 select * into a from tenant_private.sy_tax_credit_active(s,purchase);
 select * into l from tenant_private.stock_layers x where x.store_id=s and x.intake_request=p.intake_request and x.product_id=p.product_id;
 select x.branch_id into branch from tenant_private.branch_purchases x where x.store_id=s and x.purchase_id=purchase;
 net_units:=p.units-p.returned_units;
 select coalesce(i.tax_minor,0)-coalesce(sum(x.tax_minor),0),count(*) filter(where x.request_id is null or x.treatment is distinct from 'potential_credit') into net_tax,bad_returns from public.mt_supplier_returns r left join tenant_private.sy_tax_input_current(s) x on x.kind='supplier_return' and x.source_id=r.id where r.store_id=s and r.purchase_id=purchase;
 if a.request_id is not null then
  reason:='already_posted';
  select coalesce(jsonb_agg(jsonb_build_object('branch_id',z.cost_branch_id,'name',b.name,'amount_minor',z.amount_minor::text) order by z.cost_branch_id nulls first),'[]'::jsonb) into allocation
  from tenant_private.sy_tax_credit_allocations z left join tenant_private.branches b on b.store_id=z.store_id and b.id=z.cost_branch_id where z.store_id=s and z.credit_id=a.request_id;
 elsif i.request_id is null or i.treatment<>'potential_credit' or i.tax_minor<=0 then reason:='review_required';
 elsif l.id is null or l.currency is distinct from p.currency or l.unit_cost_minor is null or l.original_units<>p.units or l.unit_cost_minor::numeric*p.units<>p.total_minor or net_units<=0 or bad_returns<>0 or net_tax<=0 or net_tax>net_units::numeric*p.unit_cost_minor then reason:='inventory_cost_mismatch';
 else
  select coalesce(sum(c.units),0),coalesce(bool_and(c.restored_units=0 and coalesce(cp.sale_id is not null and cp.repair_invoice_id is null and cp.units=c.units and cp.source_currency=p.currency and cp.source_cost_minor=c.units::numeric*l.unit_cost_minor and cp.invoice_cost_minor is not null and ((cp.invoice_currency=p.currency and cp.invoice_cost_minor=cp.source_cost_minor) or exists(select 1 from public.mt_fx_rates fx where fx.store_id=cp.store_id and fx.id=cp.fx_rate_id and fx.from_currency=cp.source_currency and fx.to_currency=cp.invoice_currency and round(cp.source_cost_minor*fx.numerator/fx.denominator)=cp.invoice_cost_minor)),false)),false)
  into consumed,valid from tenant_private.stock_consumptions c
  left join tenant_private.cost_postings cp on cp.store_id=c.store_id and cp.product_id=c.product_id and cp.event_id=c.event_id and cp.layer_id=c.layer_id
  where c.store_id=s and c.product_id=l.product_id and c.layer_id=l.id and not exists(select 1 from public.mt_stock_events e where e.store_id=c.store_id and e.request_id=c.event_id and e.supplier_return_id is not null);
  if (consumed>0 and not valid) or consumed<>net_units-l.remaining_units then reason:='cost_attribution_incomplete';
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
    historical_mode:=not transfer_exists and not cross_branch and exists(select 1 from tenant_private.branch_fifo_enabled f where f.store_id=s and f.activated_at<=p.created_at) and (select coalesce(sum(z.units),0) from tenant_private.branch_fifo_lots z where z.store_id=s and z.product_id=l.product_id and z.layer_id=l.id and z.branch_id is not distinct from branch)=l.remaining_units and not exists(select 1 from tenant_private.branch_fifo_lots z where z.store_id=s and z.product_id=l.product_id and z.layer_id=l.id and z.branch_id is distinct from branch and z.units>0);
    inventory_mode:=historical_mode and l.remaining_units>0;
    select coalesce(bool_or(cp.invoice_currency<>p.currency),false),coalesce(jsonb_agg(jsonb_build_array(cp.event_id,cp.layer_id,cp.units,cp.source_cost_minor,cp.invoice_cost_minor,cp.invoice_currency,cp.fx_rate_id) order by cp.created_at,cp.event_id),'[]'::jsonb) into fx_history,historical_rows from tenant_private.cost_postings cp where cp.store_id=s and cp.product_id=l.product_id and cp.layer_id=l.id;
    legal_cap:=case when historical_mode then net_tax when fx_history then 0 else floor(net_tax*consumed/net_units) end;
    journal:=tenant_private.branch_journal_projection(s,(now() at time zone 'Asia/Damascus')::date,(now() at time zone 'Asia/Damascus')::date);
    select coalesce(-sum((x->>'closing')::numeric) filter(where (x->>'branch_id')::uuid is not distinct from branch),0),coalesce(-sum((x->>'closing')::numeric),0) into liability,store_liability from jsonb_array_elements(journal->'rows') x where x->>'account'='indirect_tax_payable' and x->>'currency'=p.currency;
    if liability<=0 or store_liability<=0 then reason:='no_recorded_liability';
    elsif fx_history and not historical_mode then reason:='historical_fx_requires_location';
    elsif legal_cap<=0 then reason:='no_sold_credit';
    else reason:='eligible';maximum:=least(legal_cap,liability,store_liability,p.total_minor);end if;
   end if;
  end if;
 end if;
 if a.request_id is not null then
  select z.amount_minor, coalesce((select sum(k.amount) from tenant_private.sy_tax_inventory_locations(s,z.credit_id) k),0) into inventory_posted,inventory_outstanding from tenant_private.sy_tax_inventory_parts z where z.store_id=s and z.credit_id=a.request_id;
 end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id desc),'[]'::jsonb) into history from (
  select request_id,reversal_of,amount_minor::text amount_minor,reference,legal_reference,created_at,pending_lot from tenant_private.sy_tax_credit_events e where e.store_id=s and e.purchase_id=purchase order by created_at desc,request_id desc limit 50
 ) x;
 result:=jsonb_build_object('purchase_id',purchase,'branch_id',branch,'currency',p.currency,'input_revision',i.request_id,'documented_tax',coalesce(i.tax_minor,0)::text,'active_credit',a.request_id,'active_amount',coalesce(a.amount_minor,0)::text,'reason',reason,'maximum',maximum::text,'history',history,
 'original_units',net_units::text,'historical_mode',historical_mode,'historical_rows',historical_rows,'net_documented_tax',greatest(net_tax,0)::text,'returned_units',p.returned_units::text,'remaining_units',case when l.id is null then null else l.remaining_units::text end,'sold_units',consumed::text,'sold_by_branch',sold_by_branch,'active_allocation',allocation,'pending_lot',coalesce(a.pending_lot,false),'sold_credit_cap',legal_cap::text,'inventory_mode',inventory_mode,'inventory_credit',coalesce(inventory_posted,0)::text,'inventory_outstanding',coalesce(inventory_outstanding,0)::text);
 return result||jsonb_build_object('digest',tenant_private.finance_review_digest(result));
end $$;

CREATE OR REPLACE FUNCTION tenant_private.sy_tax_credit_record(s uuid, req uuid, purchase uuid, previous uuid, digest text, amount bigint, proof text, legal text, confirmed boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q jsonb;old tenant_private.sy_tax_credit_events%rowtype; a tenant_private.sy_tax_credit_events%rowtype; allocated numeric; inventory_share bigint:=0; sold_share bigint; historical boolean:=false; row_cost record; seen numeric:=0; previous_share numeric:=0; share bigint; converted numeric; quote public.mt_fx_rates%rowtype; layer tenant_private.stock_layers%rowtype;
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
  historical:=coalesce((q->>'historical_mode')::boolean,false);
  if historical then inventory_share:=amount;elsif coalesce((q->>'inventory_mode')::boolean,false) then inventory_share:=amount-floor(amount::numeric*(q->>'sold_units')::numeric/(q->>'original_units')::numeric)::bigint;end if;
  sold_share:=amount-inventory_share;
  insert into tenant_private.sy_tax_credit_events(store_id,purchase_id,request_id,input_revision,branch_id,currency,amount_minor,reference,legal_reference,actor,pending_lot)
  values(s,purchase,req,(q->>'input_revision')::uuid,(q->>'branch_id')::uuid,q->>'currency',amount,btrim(proof),btrim(legal),auth.uid(),(q->>'remaining_units')::numeric>0 and inventory_share=0);
  if inventory_share>0 then insert into tenant_private.sy_tax_inventory_parts(store_id,credit_id,amount_minor,base_units) values(s,req,inventory_share,case when historical then (q->>'original_units')::bigint else (q->>'remaining_units')::bigint end);end if;
  if historical then
   select l.* into strict layer from tenant_private.stock_layers l join public.mt_purchases p on p.store_id=l.store_id and p.intake_request=l.intake_request where p.store_id=s and p.id=purchase;
   for row_cost in select cp.* from tenant_private.cost_postings cp where cp.store_id=s and cp.product_id=layer.product_id and cp.layer_id=layer.id order by cp.created_at,cp.event_id loop
    seen:=seen+row_cost.units;share:=(floor(amount::numeric*seen/(q->>'original_units')::numeric)-previous_share)::bigint;previous_share:=previous_share+share;
    if row_cost.invoice_currency=row_cost.source_currency then converted:=share;else
     select * into strict quote from public.mt_fx_rates x where x.store_id=s and x.id=row_cost.fx_rate_id and x.from_currency=row_cost.source_currency and x.to_currency=row_cost.invoice_currency;
     converted:=row_cost.invoice_cost_minor-round((row_cost.source_cost_minor-share)*quote.numerator/quote.denominator);
    end if;
    if share<0 or share>row_cost.source_cost_minor or converted<0 or converted>row_cost.invoice_cost_minor then raise exception 'Historical cost credit exceeds recorded cost';end if;
    insert into tenant_private.sy_tax_inventory_releases(store_id,credit_id,product_id,event_id,layer_id,units,currency,invoice_currency,amount_minor,invoice_amount,fx_rate_id,created_at,branch_id,location_recorded) values(s,req,row_cost.product_id,row_cost.event_id,row_cost.layer_id,row_cost.units,row_cost.source_currency,row_cost.invoice_currency,share,converted,row_cost.fx_rate_id,now(),(q->>'branch_id')::uuid,true);
   end loop;
   if seen<>(q->>'sold_units')::numeric then raise exception 'Historical credit unit mismatch';end if;
  end if;
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
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.sy_tax_input_record(s uuid, req uuid, k text, source uuid, expected_previous uuid, amount bigint, treatment text, proof text, legal text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d record;old tenant_private.sy_tax_input_events%rowtype;current_row tenant_private.sy_tax_input_events%rowtype;original tenant_private.sy_tax_input_events%rowtype;other_returns numeric;
begin
 perform tenant_private.owner_write(s);
 if req is null or source is null or k is null or k not in ('purchase','supplier_return') or amount is null or amount not between 0 and 100000000000000 or treatment is null or treatment not in ('not_applicable','nonrecoverable_in_cost','pending_review','potential_credit') or (treatment='not_applicable' and amount<>0) or (treatment in ('nonrecoverable_in_cost','potential_credit') and amount=0 and not (k='supplier_return' and treatment='potential_credit')) or proof is null or length(btrim(proof)) not between 1 and 160 or legal is null or length(btrim(legal)) not between 1 and 200 then raise exception 'Invalid input tax documentation' using errcode='22023';end if;
 select * into old from tenant_private.sy_tax_input_events where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.kind<>k or old.source_id<>source or old.previous is distinct from expected_previous or old.tax_minor<>amount or old.treatment<>treatment or old.document_ref<>btrim(proof) or old.legal_reference<>btrim(legal) then raise exception 'Conflicting input tax request' using errcode='22023';end if;return req;
 end if;
 select * into d from tenant_private.sy_tax_documents(s) x where x.kind=k and x.source_id=source;
 if not found or amount>d.gross_minor then raise exception 'Input amount exceeds recorded document' using errcode='22023';end if;
 select * into current_row from tenant_private.sy_tax_input_current(s) x where x.kind=k and x.source_id=source;
 if current_row.request_id is distinct from expected_previous then raise exception 'Input review changed; reload' using errcode='22023';end if;
 select coalesce(sum(x.tax_minor),0) into other_returns from tenant_private.sy_tax_input_current(s) x where x.kind='supplier_return' and x.invoice_id=d.invoice_id and (k='purchase' or x.source_id<>source);
 if k='purchase' then
  if amount<other_returns then raise exception 'Input reversal exceeds revised purchase tax' using errcode='22023';end if;
 else
  select * into original from tenant_private.sy_tax_input_current(s) x where x.kind='purchase' and x.source_id=d.invoice_id;
  if not found or amount+other_returns>original.tax_minor then raise exception 'Document original purchase first; reversal cannot exceed purchase tax' using errcode='22023';end if;
  if original.treatment in ('pending_review','potential_credit') and treatment not in ('pending_review','potential_credit') then raise exception 'Resolve purchase tax treatment first' using errcode='22023';end if;
 end if;
 insert into tenant_private.sy_tax_input_events(store_id,request_id,kind,source_id,invoice_id,currency,tax_minor,treatment,document_ref,legal_reference,previous,actor) values(s,req,k,source,d.invoice_id,d.currency,amount,treatment,btrim(proof),btrim(legal),expected_previous,auth.uid());
 return req;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.sy_tax_period_review(s uuid, d1 date, d2 date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with docs as (
 select d.*,e.id entry_id,e.tax_minor,e.created_at posted,o.profile_id,o.document_ref output_ref,i.request_id input_id,i.treatment,i.tax_minor input_tax,
 parent.request_id parent_revision,parent.treatment parent_treatment,m.parts mixed_parts,cr.request_id credit_id,cr.amount_minor credit_minor,cr.pending_lot credit_pending_lot,
 case when d.kind in ('purchase','supplier_return') then
   i.request_id is null or i.treatment='pending_review' or (i.treatment='potential_credit' and ((d.kind='purchase' and (cr.request_id is null or cr.pending_lot) and not (i.tax_minor=(select coalesce(sum(z.tax_minor),0) from tenant_private.sy_tax_input_current(s) z where z.kind='supplier_return' and z.invoice_id=d.invoice_id and z.treatment='potential_credit') and not exists(select 1 from public.mt_supplier_returns r left join tenant_private.sy_tax_input_current(s) z on z.kind='supplier_return' and z.source_id=r.id where r.store_id=s and r.purchase_id=d.invoice_id and z.treatment is distinct from 'potential_credit'))) or (d.kind='supplier_return' and parent.treatment is distinct from 'potential_credit'))) or
   (d.kind='supplier_return' and (parent.request_id is null or parent.treatment='pending_review' or
     (i.tax_minor>0 and i.treatment is distinct from parent.treatment)))
 else o.profile_id is null and m.parts is null end unresolved
 from tenant_private.sy_tax_documents(s) d
 left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id
 left join lateral (select jsonb_agg(jsonb_build_array(z.profile_id,z.gross_minor,z.tax_minor) order by z.profile_id) parts from tenant_private.sy_tax_mixed_parts z where z.store_id=s and z.entry_id=e.id) m on true
 left join tenant_private.sy_tax_input_current(s) i on i.kind=d.kind and i.source_id=d.source_id
 left join lateral (select e0.request_id,e0.amount_minor,e0.pending_lot from tenant_private.sy_tax_credit_events e0 where e0.store_id=s and d.kind='purchase' and e0.purchase_id=d.source_id and e0.input_revision=i.request_id and e0.reversal_of is null and not exists(select 1 from tenant_private.sy_tax_credit_events z where z.store_id=s and z.reversal_of=e0.request_id)) cr on true
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
 'evidence_digest',encode(sha256(convert_to(coalesce(jsonb_agg(jsonb_build_array(kind,source_id,invoice_id,branch_id,currency,gross_minor,occurred_at,entry_id,tax_minor,posted,profile_id,output_ref,input_id,input_tax,treatment,parent_revision,parent_treatment,mixed_parts,credit_id,credit_minor,credit_pending_lot,unresolved) order by kind,source_id),'[]'::jsonb)::text,'UTF8')),'hex'),
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
 cr.request_id credit_id,cr.amount_minor credit_minor,cr.pending_lot credit_pending_lot,inp.request_id input_revision,inp.tax_minor input_tax,inp.treatment,inp.document_ref input_document_ref,inp.legal_reference input_legal_reference,
 case when d.kind in ('purchase','supplier_return') then inp.request_id is null or inp.treatment='pending_review' or (inp.treatment='potential_credit' and ((d.kind='purchase' and (cr.request_id is null or cr.pending_lot) and not (inp.tax_minor=(select coalesce(sum(z.tax_minor),0) from tenant_private.sy_tax_input_current(s) z where z.kind='supplier_return' and z.invoice_id=d.invoice_id and z.treatment='potential_credit') and not exists(select 1 from public.mt_supplier_returns r left join tenant_private.sy_tax_input_current(s) z on z.kind='supplier_return' and z.source_id=r.id where r.store_id=s and r.purchase_id=d.invoice_id and z.treatment is distinct from 'potential_credit'))) or (d.kind='supplier_return' and not exists(select 1 from tenant_private.sy_tax_input_current(s) z where z.kind='purchase' and z.source_id=d.invoice_id and z.treatment='potential_credit')))) else o.profile_id is null and m.parts is null end unresolved
 from tenant_private.sy_tax_documents(s) d left join tenant_private.branches b on b.store_id=s and b.id=d.branch_id
 left join public.mt_indirect_tax_entries e on e.store_id=s and e.kind=d.kind and e.source_id=d.source_id
 left join tenant_private.sy_tax_output o on o.store_id=s and o.entry_id=e.id left join tenant_private.sy_tax_profiles p on p.store_id=s and p.id=o.profile_id
 left join lateral (select jsonb_agg(jsonb_build_object('profile_id',z.profile_id,'gross_minor',z.gross_minor,'tax_minor',z.tax_minor,'label',p0.label,'rate_bps',p0.rate_bps) order by z.profile_id) parts from tenant_private.sy_tax_mixed_parts z join tenant_private.sy_tax_profiles p0 on p0.store_id=z.store_id and p0.id=z.profile_id where z.store_id=s and z.entry_id=e.id) m on true
 left join public.mt_indirect_tax_entries orig on orig.store_id=s and orig.source_id=d.invoice_id and orig.kind=case d.kind when 'sale_return' then 'sale' when 'repair_refund' then 'repair' end
 left join tenant_private.sy_tax_input_current(s) inp on inp.kind=d.kind and inp.source_id=d.source_id
 left join lateral (select e0.request_id,e0.amount_minor,e0.pending_lot from tenant_private.sy_tax_credit_events e0 where e0.store_id=s and d.kind='purchase' and e0.purchase_id=d.source_id and e0.input_revision=inp.request_id and e0.reversal_of is null and not exists(select 1 from tenant_private.sy_tax_credit_events z where z.store_id=s and z.reversal_of=e0.request_id)) cr on true
 where d.occurred_at>=d1::timestamp at time zone 'Asia/Damascus' and d.occurred_at<(d2+1)::timestamp at time zone 'Asia/Damascus' and (filter_kind='all' or d.kind=filter_kind)
 ),page as (select * from docs where not missing_only or unresolved order by occurred_at desc,kind,source_id offset off limit 51)
 select coalesce(jsonb_agg(to_jsonb(page) order by occurred_at desc,kind,source_id),'[]'::jsonb) into data from page;
 return jsonb_build_object('rows',case when jsonb_array_length(data)>50 then data-50 else data end,'more',jsonb_array_length(data)>50);
end $function$;

create table tenant_private.sy_tax_supplier_return_actions(
 store_id uuid not null,request_id uuid not null,purchase_id uuid not null,return_id uuid not null,reversal_id uuid not null,input_id uuid not null,
 original_credit uuid not null,units bigint not null,tax_minor bigint not null,reason text not null,proof text not null,legal text not null,
 confirmed_refund boolean not null,actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,request_id),
 foreign key(store_id,purchase_id) references public.mt_purchases(store_id,id),
 foreign key(store_id,return_id) references public.mt_supplier_returns(store_id,id),
 foreign key(store_id,reversal_id) references tenant_private.sy_tax_credit_events(store_id,request_id),
 foreign key(store_id,original_credit) references tenant_private.sy_tax_credit_events(store_id,request_id),
 foreign key(store_id,input_id) references tenant_private.sy_tax_input_events(store_id,request_id)
);
alter table tenant_private.sy_tax_supplier_return_actions enable row level security;
revoke all on tenant_private.sy_tax_supplier_return_actions from public,anon,authenticated,service_role;
create function tenant_private.sy_tax_supplier_return(s uuid,req uuid,purchase uuid,previous uuid,digest text,units bigint,tax_minor bigint,reason text,proof text,legal text,confirmed_refund boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare e tenant_private.sy_tax_supplier_return_actions%rowtype; a tenant_private.sy_tax_credit_events%rowtype; p public.mt_purchases%rowtype; r uuid; rev uuid; inp uuid;
begin
 perform tenant_private.owner_write(s);
 if req is null or purchase is null or previous is null or digest is null or units is null or units not between 1 and 1000000 or tax_minor is null or tax_minor<0 or reason is null or length(btrim(reason)) not between 1 and 300 or proof is null or length(btrim(proof)) not between 1 and 160 or legal is null or length(btrim(legal)) not between 1 and 200 or confirmed_refund is null then raise exception 'Confirm documented supplier return';end if;
 select * into e from tenant_private.sy_tax_supplier_return_actions x where x.store_id=s and x.request_id=req;
 if found then
  if e.actor<>auth.uid() or e.purchase_id<>purchase or e.original_credit<>previous or e.units<>units or e.tax_minor<>tax_minor or e.reason<>btrim(reason) or e.proof<>btrim(proof) or e.legal<>btrim(legal) or e.confirmed_refund<>confirmed_refund then raise exception 'Conflicting supplier return request';end if;return e.return_id;
 end if;
 select * into strict p from public.mt_purchases x where x.store_id=s and x.id=purchase for update;
 select * into strict a from tenant_private.sy_tax_credit_active(s,purchase);
 if a.request_id<>previous or tax_minor>units::numeric*p.unit_cost_minor then raise exception 'Supplier return evidence changed';end if;
 rev:=tenant_private.sy_tax_credit_record(s,gen_random_uuid(),purchase,previous,digest,a.amount_minor,proof,legal,true);
 r:=tenant_private.supplier_return(s,req,purchase,units,reason,confirmed_refund);
 inp:=tenant_private.sy_tax_input_record(s,gen_random_uuid(),'supplier_return',r,null,tax_minor,'potential_credit',proof,legal);
 insert into tenant_private.sy_tax_supplier_return_actions(store_id,request_id,purchase_id,return_id,reversal_id,input_id,original_credit,units,tax_minor,reason,proof,legal,confirmed_refund,actor) values(s,req,purchase,r,rev,inp,previous,units,tax_minor,btrim(reason),btrim(proof),btrim(legal),confirmed_refund,auth.uid());
 return r;
end $$;
create function public.mt_sy_tax_supplier_return(s uuid,req uuid,purchase uuid,previous uuid,digest text,units bigint,tax_minor bigint,reason text,proof text,legal text,confirmed_refund boolean) returns uuid language sql set search_path='' as $$select tenant_private.sy_tax_supplier_return(s,req,purchase,previous,digest,units,tax_minor,reason,proof,legal,confirmed_refund)$$;
revoke all on function tenant_private.sy_tax_supplier_return(uuid,uuid,uuid,uuid,text,bigint,bigint,text,text,text,boolean),public.mt_sy_tax_supplier_return(uuid,uuid,uuid,uuid,text,bigint,bigint,text,text,text,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.sy_tax_supplier_return(uuid,uuid,uuid,uuid,text,bigint,bigint,text,text,text,boolean),public.mt_sy_tax_supplier_return(uuid,uuid,uuid,uuid,text,bigint,bigint,text,text,text,boolean) to authenticated;
commit;
