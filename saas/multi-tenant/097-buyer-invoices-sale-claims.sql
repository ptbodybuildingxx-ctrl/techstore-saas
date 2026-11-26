-- Product warranty claims and authenticated buyer invoice access.
begin;
create table tenant_private.sale_warranty_claims (
 store_id uuid not null,sale_id uuid not null,product_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,actor uuid not null,buyer uuid,units bigint not null check(units between 1 and 10000),reason text not null check(length(reason) between 1 and 300),state text not null default 'open' check(state in ('open','accepted','rejected','resolved')),created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),foreign key(store_id,sale_id) references public.mt_sales(store_id,id)
);
create table tenant_private.sale_warranty_events (
 store_id uuid not null,claim_id uuid not null,request_id uuid not null,actor uuid not null,prior_state text not null,next_state text not null,note text not null check(length(note) between 1 and 300),created_at timestamptz not null default now(),primary key(store_id,request_id),foreign key(store_id,claim_id) references tenant_private.sale_warranty_claims(store_id,id)
);
alter table tenant_private.sale_warranty_claims enable row level security;
alter table tenant_private.sale_warranty_events enable row level security;
revoke all on tenant_private.sale_warranty_claims,tenant_private.sale_warranty_events from public,anon,authenticated,service_role;
create index sale_warranty_claim_line on tenant_private.sale_warranty_claims(store_id,sale_id,product_id,state);
create index sale_warranty_claim_buyer on tenant_private.sale_warranty_claims(store_id,buyer,created_at desc,id);
create function tenant_private.buyer_invoice(s uuid,o uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.mt_sales%rowtype;doc jsonb;settings jsonb;lines jsonb;sid uuid;
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 select sale_id into sid from public.mt_online_orders where store_id=s and id=o and buyer=auth.uid() and state='fulfilled';
 if not found or sid is null then raise exception 'Invoice unavailable' using errcode='42501';end if;
 select * into strict a from public.mt_sales where store_id=s and id=sid;
 select d.document into doc from tenant_private.sale_invoice_details d where store_id=s and sale_id=sid;
 select r.settings into settings from tenant_private.receipt_snapshots r where store_id=s and kind='sale' and document_id=sid;
 select coalesce(jsonb_agg(jsonb_build_object('product_id',l.product_id,'product_name',l.product_name,'sku',l.sku,'units',l.units,'unit_price_minor',l.unit_price_minor,'line_total_minor',l.line_total_minor) order by l.product_id),'[]') into lines from public.mt_sale_lines l where l.store_id=s and l.sale_id=sid;
 if doc is not null then doc:=doc||jsonb_build_object('returned',coalesce((select jsonb_agg(jsonb_build_object('product_id',x.product_id,'units',x.units)) from (select product_id,sum(units)::bigint units from public.mt_returns where store_id=s and sale_id=sid group by product_id)x),'[]'::jsonb));end if;
 return jsonb_build_object('sale',jsonb_build_object('id',a.id,'number',a.number,'currency',a.currency,'total_minor',a.total_minor,'payment_mode',a.payment_mode,'created_at',a.created_at,'request_id',a.request_id),'identity',settings,'invoice',doc,'lines',lines);
end $$;
create function tenant_private.sale_claim_open(s uuid,r uuid,sid uuid,pid uuid,u bigint,why text,from_buyer boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare old tenant_private.sale_warranty_claims%rowtype;b uuid;w jsonb;available bigint;out_id uuid;
begin
 if from_buyer is null or r is null or sid is null or pid is null or u is null or u not between 1 and 10000 or why is null or length(btrim(why)) not between 1 and 300 then raise exception 'Invalid claim';end if;
 if from_buyer then
  if auth.uid() is null or not coalesce(saas_private.live_session(),false) or not exists(select 1 from public.mt_online_orders where store_id=s and sale_id=sid and state='fulfilled' and buyer=auth.uid()) then raise exception 'Claim access denied' using errcode='42501';end if;
  b:=auth.uid();
 else
  perform tenant_private.owner_write(s);
  select buyer into b from public.mt_online_orders where store_id=s and sale_id=sid and state='fulfilled';
 end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into old from tenant_private.sale_warranty_claims where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.sale_id<>sid or old.product_id<>pid or old.units<>u or old.reason<>btrim(why) or old.buyer is distinct from b then raise exception 'Conflicting claim request';end if;return old.id;end if;
 select x into w from tenant_private.sale_invoice_details d cross join lateral jsonb_array_elements(d.document->'lines')x where d.store_id=s and d.sale_id=sid and (x->>'product_id')::uuid=pid;
 if not found or (w->>'months')::integer<=0 or (w->>'until')::date<(now() at time zone 'Asia/Damascus')::date then raise exception 'Warranty unavailable';end if;
 select l.units-coalesce((select sum(t.units) from public.mt_returns t where t.store_id=s and t.sale_id=sid and t.product_id=pid),0)-coalesce((select sum(c.units) from tenant_private.sale_warranty_claims c where c.store_id=s and c.sale_id=sid and c.product_id=pid and c.state in ('open','accepted')),0) into available from public.mt_sale_lines l where l.store_id=s and l.sale_id=sid and l.product_id=pid;
 if not found or available<u then raise exception 'Claim exceeds available coverage';end if;
 insert into tenant_private.sale_warranty_claims(store_id,sale_id,product_id,request_id,actor,buyer,units,reason) values(s,sid,pid,r,auth.uid(),b,u,btrim(why)) returning id into out_id;return out_id;
end $$;
create function tenant_private.sale_claim_transition(s uuid,r uuid,cid uuid,next_state text,why text) returns text language plpgsql security definer set search_path='' as $$
declare e tenant_private.sale_warranty_events%rowtype;c tenant_private.sale_warranty_claims%rowtype;coverage bigint;
begin
 perform tenant_private.owner_write(s);
 if r is null or cid is null or next_state is null or why is null or length(btrim(why)) not between 1 and 300 then raise exception 'Invalid transition';end if;
 select * into e from tenant_private.sale_warranty_events where store_id=s and request_id=r;
 if found then if e.actor<>auth.uid() or e.claim_id<>cid or e.next_state<>next_state or e.note<>btrim(why) then raise exception 'Conflicting transition';end if;return e.next_state;end if;
 select * into c from tenant_private.sale_warranty_claims where store_id=s and id=cid for update;
 if not found or not ((c.state='open' and next_state in ('accepted','rejected')) or (c.state='accepted' and next_state='resolved')) then raise exception 'Invalid claim state';end if;
 if next_state='accepted' then
 select l.units-coalesce((select sum(t.units) from public.mt_returns t where t.store_id=s and t.sale_id=c.sale_id and t.product_id=c.product_id),0)-coalesce((select sum(z.units) from tenant_private.sale_warranty_claims z where z.store_id=s and z.sale_id=c.sale_id and z.product_id=c.product_id and z.state='accepted'),0) into coverage from public.mt_sale_lines l where l.store_id=s and l.sale_id=c.sale_id and l.product_id=c.product_id;
 if not found or coverage<c.units then raise exception 'Coverage changed; review return';end if;
 end if;
 update tenant_private.sale_warranty_claims set state=next_state where store_id=s and id=cid;
 insert into tenant_private.sale_warranty_events(store_id,claim_id,request_id,actor,prior_state,next_state,note) values(s,cid,r,auth.uid(),c.state,next_state,btrim(why));return next_state;
end $$;
create function tenant_private.sale_claim_list(s uuid,from_buyer boolean,off integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if from_buyer is null or off is null or off not between 0 and 100000 then raise exception 'Invalid page';end if;
 if from_buyer then
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 elsif tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from (
 select c.id,c.sale_id,c.product_id,c.units,c.reason,c.state,c.created_at,a.number,l.product_name,l.sku,
 coalesce((select jsonb_agg(jsonb_build_object('prior',e.prior_state,'next',e.next_state,'note',e.note,'at',e.created_at) order by e.created_at,e.request_id) from tenant_private.sale_warranty_events e where e.store_id=s and e.claim_id=c.id),'[]'::jsonb) events
 from tenant_private.sale_warranty_claims c join public.mt_sales a on a.store_id=c.store_id and a.id=c.sale_id join public.mt_sale_lines l on l.store_id=c.store_id and l.sale_id=c.sale_id and l.product_id=c.product_id
 where c.store_id=s and (not from_buyer or (c.buyer=auth.uid() and exists(select 1 from public.mt_online_orders o where o.store_id=s and o.sale_id=c.sale_id and o.buyer=auth.uid() and o.state='fulfilled'))) order by c.created_at desc,c.id desc offset off limit 50)x),'[]');
end $$;
create function public.mt_buyer_invoice(p_slug text,p_order uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.buyer_invoice(tenant_private.buyer_store(p_slug),p_order)$$;
create function public.mt_buyer_sale_claim(p_slug text,p_request uuid,p_sale uuid,p_product uuid,p_units bigint,p_reason text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.sale_claim_open(tenant_private.buyer_store(p_slug),p_request,p_sale,p_product,p_units,p_reason,true)$$;
create function public.mt_buyer_sale_claims(p_slug text,p_offset integer) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.sale_claim_list(tenant_private.buyer_store(p_slug),true,p_offset)$$;
create function public.mt_sale_claim_open(p_store uuid,p_request uuid,p_sale uuid,p_product uuid,p_units bigint,p_reason text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.sale_claim_open(p_store,p_request,p_sale,p_product,p_units,p_reason,false)$$;
create function public.mt_sale_claim_transition(p_store uuid,p_request uuid,p_claim uuid,p_next text,p_note text) returns text language sql security invoker set search_path='' as $$select tenant_private.sale_claim_transition(p_store,p_request,p_claim,p_next,p_note)$$;
create function public.mt_sale_claims(p_store uuid,p_offset integer) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.sale_claim_list(p_store,false,p_offset)$$;
revoke all on function tenant_private.buyer_invoice(uuid,uuid),tenant_private.sale_claim_open(uuid,uuid,uuid,uuid,bigint,text,boolean),tenant_private.sale_claim_transition(uuid,uuid,uuid,text,text),tenant_private.sale_claim_list(uuid,boolean,integer),public.mt_buyer_invoice(text,uuid),public.mt_buyer_sale_claim(text,uuid,uuid,uuid,bigint,text),public.mt_buyer_sale_claims(text,integer),public.mt_sale_claim_open(uuid,uuid,uuid,uuid,bigint,text),public.mt_sale_claim_transition(uuid,uuid,uuid,text,text),public.mt_sale_claims(uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.buyer_invoice(uuid,uuid),tenant_private.sale_claim_open(uuid,uuid,uuid,uuid,bigint,text,boolean),tenant_private.sale_claim_transition(uuid,uuid,uuid,text,text),tenant_private.sale_claim_list(uuid,boolean,integer),public.mt_buyer_invoice(text,uuid),public.mt_buyer_sale_claim(text,uuid,uuid,uuid,bigint,text),public.mt_buyer_sale_claims(text,integer),public.mt_sale_claim_open(uuid,uuid,uuid,uuid,bigint,text),public.mt_sale_claim_transition(uuid,uuid,uuid,text,text),public.mt_sale_claims(uuid,integer) to authenticated;
CREATE OR REPLACE FUNCTION tenant_private.business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t text;v jsonb;out_data jsonb:='{}';n bigint;total_rows bigint:=0;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not tenant_private.shared_licensed(p_store) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner and AAL2 required' using errcode='42501';end if;
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events'] loop
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
commit;
