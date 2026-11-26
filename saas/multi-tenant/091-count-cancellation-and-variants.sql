-- Count retry cancellation is serialized with count approval; public model variants stay inside one active shop.
begin;
create table tenant_private.stock_count_cancellations(
 store_id uuid not null references public.saas_stores(id), request_id uuid not null, branch_id uuid, actor uuid not null, created_at timestamptz not null default now(), primary key(store_id,request_id),
 foreign key(store_id,branch_id) references tenant_private.branches(store_id,id)
);
alter table tenant_private.stock_count_cancellations enable row level security;
revoke all on tenant_private.stock_count_cancellations from public,anon,authenticated,service_role;
create function tenant_private.count_cancel(s uuid,b uuid,r uuid) returns text language plpgsql security definer set search_path='' as $$
declare prev tenant_private.stock_counts%rowtype; cancelled tenant_private.stock_count_cancellations%rowtype;
begin
 perform tenant_private.count_permission(s,b,true);
 if r is null then raise exception 'Invalid count request';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into prev from tenant_private.stock_counts where store_id=s and request_id=r;
 if found then
  if prev.actor<>auth.uid() or prev.branch_id is distinct from b then raise exception 'Count request not owned' using errcode='42501';end if;
  return 'confirmed';
 end if;
 select * into cancelled from tenant_private.stock_count_cancellations where store_id=s and request_id=r;
 if found then
  if cancelled.actor<>auth.uid() or cancelled.branch_id is distinct from b then raise exception 'Count request not owned' using errcode='42501';end if;
  return 'cancelled';
 end if;
 insert into tenant_private.stock_count_cancellations(store_id,request_id,branch_id,actor) values(s,r,b,auth.uid());
 return 'cancelled';
end $$;
create function public.mt_count_cancel(p_store uuid,p_branch uuid,p_request uuid) returns text language sql security invoker set search_path='' as $$select tenant_private.count_cancel(p_store,p_branch,p_request)$$;
revoke all on function tenant_private.count_cancel(uuid,uuid,uuid),public.mt_count_cancel(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.count_cancel(uuid,uuid,uuid),public.mt_count_cancel(uuid,uuid,uuid) to authenticated;
create or replace function tenant_private.count_commit(s uuid,b uuid,r uuid,reason text,items jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare prev tenant_private.stock_counts%rowtype; item jsonb; pid uuid; eid uuid; exp bigint; act bigint; q bigint; loc bigint; delta bigint; reserved bigint; n integer;
begin
 perform tenant_private.count_permission(s,b,true);
 if r is null or reason is null or length(btrim(reason)) not between 1 and 160 or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or octet_length(items::text)>40000 then raise exception 'Invalid count';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into prev from tenant_private.stock_counts where store_id=s and request_id=r;
 if found then if prev.actor<>auth.uid() or prev.branch_id is distinct from b or prev.reason<>btrim(reason) or prev.lines is distinct from items then raise exception 'Conflicting count request';end if;return jsonb_build_object('request',r,'count',jsonb_array_length(items));end if;
 if exists(select 1 from tenant_private.stock_count_cancellations where store_id=s and request_id=r) then raise exception 'Count request cancelled' using errcode='22023';end if;
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
CREATE OR REPLACE FUNCTION tenant_private.business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t text;v jsonb;out_data jsonb:='{}';n bigint;total_rows bigint:=0;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not tenant_private.shared_licensed(p_store) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner and AAL2 required' using errcode='42501';end if;
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations'] loop
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
create function tenant_private.public_variants(p_slug text,p_currency text,p_product uuid,p_after uuid,p_limit integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s uuid; profile jsonb;
begin
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_product is null or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid variant query' using errcode='22023';end if;
 select t.id,p.catalog into s,profile from public.saas_stores t join public.mt_products p on p.store_id=t.id join tenant_private.storefront_products l on l.store_id=t.id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=t.id and pp.product_id=p.id and pp.currency=p_currency where t.slug=p_slug and tenant_private.storefront_active(t.id) and p.id=p_product;
 if not found or coalesce(btrim(profile->>'model'),'')='' then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from (select p.id,p.name,p.sku,p.catalog->>'variant' as variant,pp.price_minor,tenant_private.main_available(s,p.id)>0 as available from public.mt_products p join tenant_private.storefront_products l on l.store_id=s and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=s and pp.product_id=p.id and pp.currency=p_currency where p.store_id=s and p.id<>p_product and (p_after is null or p.id>p_after) and lower(btrim(p.catalog->>'type'))=lower(btrim(profile->>'type')) and lower(btrim(p.catalog->>'brand'))=lower(btrim(profile->>'brand')) and lower(btrim(p.catalog->>'model'))=lower(btrim(profile->>'model')) order by p.id limit p_limit)x),'[]'::jsonb);
end $$;
create function public.mt_product_variants(p_slug text,p_currency text,p_product uuid,p_after uuid default null,p_limit integer default 50) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.public_variants(p_slug,p_currency,p_product,p_after,p_limit)$$;
revoke all on function tenant_private.public_variants(text,text,uuid,uuid,integer),public.mt_product_variants(text,text,uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.public_variants(text,text,uuid,uuid,integer),public.mt_product_variants(text,text,uuid,uuid,integer) to anon,authenticated;
commit;
