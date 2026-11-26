-- Owner-only searchable customer directory and audited profile changes.
-- Preserve creation request identity and historical invoice snapshots.
create table tenant_private.customer_profile_edits(
 store_id uuid not null,id uuid not null,customer_id uuid not null,revision bigint not null check(revision>0),
 old_name text not null,old_phone text not null,new_name text not null,new_phone text not null,
 actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,customer_id,revision),
 foreign key(store_id,customer_id) references public.mt_customers(store_id,id));
alter table tenant_private.customer_profile_edits enable row level security;
revoke all on tenant_private.customer_profile_edits from public,anon,authenticated,service_role;

create function tenant_private.edit_customer(p_store uuid,p_request uuid,p_customer uuid,p_old_name text,p_old_phone text,p_name text,p_phone text)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.mt_customers%rowtype;e tenant_private.customer_profile_edits%rowtype;v_revision bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_customer is null or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_phone is null or length(btrim(p_phone))>60 or p_old_name is null or p_old_phone is null then raise exception 'Invalid customer profile' using errcode='22023';end if;
 select * into e from tenant_private.customer_profile_edits where store_id=p_store and id=p_request;
 if found then
  if e.actor<>auth.uid() or e.customer_id<>p_customer or e.old_name<>p_old_name or e.old_phone<>p_old_phone or e.new_name<>btrim(p_name) or e.new_phone<>btrim(p_phone) then raise exception 'Conflicting request' using errcode='22023';end if;
  return e.customer_id;
 end if;
 select * into strict c from public.mt_customers where store_id=p_store and id=p_customer for update;
 if c.name<>p_old_name or c.phone<>p_old_phone then raise exception 'Customer profile has changed; reload first' using errcode='22023';end if;
 select coalesce(max(revision),0)+1 into v_revision from tenant_private.customer_profile_edits where store_id=p_store and customer_id=p_customer;
 insert into tenant_private.customer_profile_edits(store_id,id,customer_id,revision,old_name,old_phone,new_name,new_phone,actor) values(p_store,p_request,p_customer,v_revision,c.name,c.phone,btrim(p_name),btrim(p_phone),auth.uid());
 update public.mt_customers set name=btrim(p_name),phone=btrim(p_phone) where store_id=p_store and id=p_customer;
 return p_customer;
end $$;
create function public.mt_edit_customer(p_store uuid,p_request uuid,p_customer uuid,p_old_name text,p_old_phone text,p_name text,p_phone text)
returns uuid language sql set search_path='' as $$select tenant_private.edit_customer(p_store,p_request,p_customer,p_old_name,p_old_phone,p_name,p_phone)$$;
create function public.mt_search_customers(p_store uuid,p_query text,p_after uuid,p_limit integer)
returns setof public.mt_customers language plpgsql stable set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_query is null or length(p_query)>160 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid filters' using errcode='22023';end if;
 return query select c.* from public.mt_customers c where c.store_id=p_store and (p_after is null or c.id>p_after) and (p_query='' or strpos(lower(c.name),lower(p_query))>0 or strpos(c.phone,p_query)>0) order by c.id limit p_limit;
end $$;
revoke all on function tenant_private.edit_customer(uuid,uuid,uuid,text,text,text,text),public.mt_edit_customer(uuid,uuid,uuid,text,text,text,text),public.mt_search_customers(uuid,text,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.edit_customer(uuid,uuid,uuid,text,text,text,text),public.mt_edit_customer(uuid,uuid,uuid,text,text,text,text),public.mt_search_customers(uuid,text,uuid,integer) to authenticated;
CREATE OR REPLACE FUNCTION tenant_private.add_customer(p_store uuid, p_request uuid, p_name text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.mt_customers%rowtype;original_name text;original_phone text;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_phone is null or length(btrim(p_phone))>60 then raise exception 'Invalid customer' using errcode='22023';end if;
 select * into c from public.mt_customers where store_id=p_store and request_id=p_request;
 if found then
  select old_name,old_phone into original_name,original_phone from tenant_private.customer_profile_edits where store_id=p_store and customer_id=c.id order by revision limit 1;
  if c.actor<>auth.uid() or coalesce(original_name,c.name)<>btrim(p_name) or coalesce(original_phone,c.phone)<>btrim(p_phone) then raise exception 'Conflicting customer request' using errcode='22023';end if;
  return c.id;
 end if;
 insert into public.mt_customers(store_id,request_id,name,phone,actor) values(p_store,p_request,btrim(p_name),btrim(p_phone),auth.uid()) returning * into c;
 return c.id;
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
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits'] loop
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
