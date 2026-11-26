-- Branch attribution for existing transactional engines; store-wide FIFO remains authoritative.
begin;
create table tenant_private.branch_purchases(store_id uuid not null,purchase_id uuid not null,branch_id uuid not null,primary key(store_id,purchase_id),foreign key(store_id,purchase_id) references public.mt_purchases(store_id,id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
create table tenant_private.branch_batches(store_id uuid not null,batch_id uuid not null,branch_id uuid not null,primary key(store_id,batch_id),foreign key(store_id,batch_id) references public.mt_purchase_batches(store_id,id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
create table tenant_private.branch_repairs(store_id uuid not null,repair_id uuid not null,branch_id uuid not null,primary key(store_id,repair_id),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
do $$declare t text;begin foreach t in array array['branch_purchases','branch_batches','branch_repairs'] loop execute format('alter table tenant_private.%I enable row level security',t);execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create function tenant_private.require_branch(p_store uuid,p_branch uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if p_branch is null or not exists(select 1 from tenant_private.branches where store_id=p_store and id=p_branch) then raise exception 'Unknown branch' using errcode='22023';end if;
end $$;
create function tenant_private.branch_take(p_store uuid,p_branch uuid,p_lines jsonb) returns void language plpgsql security definer set search_path='' as $$
declare x jsonb;u bigint;pid uuid;
begin
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines)>100 then raise exception 'Invalid lines' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
 if coalesce(x->>'units','') !~ '^[0-9]{1,5}$' then raise exception 'Invalid units' using errcode='22023';end if;
 u:=(x->>'units')::bigint;pid:=(x->>'product_id')::uuid;
 if u not between 1 and 10000 then raise exception 'Invalid units' using errcode='22023';end if;
 update tenant_private.branch_stock set units=units-u where store_id=p_store and branch_id=p_branch and product_id=pid and units>=u;
 if not found then raise exception 'Insufficient branch stock' using errcode='22023';end if;
 end loop;
end $$;
create function tenant_private.branch_add(p_store uuid,p_branch uuid,p_product uuid,p_units bigint) returns void language sql security definer set search_path='' as $$
 insert into tenant_private.branch_stock(store_id,branch_id,product_id,units) values(p_store,p_branch,p_product,p_units) on conflict(store_id,branch_id,product_id) do update set units=branch_stock.units+excluded.units
$$;
create function tenant_private.branch_credit_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb,p_customer uuid,p_deposit bigint,p_count integer,p_due date) returns jsonb language plpgsql security definer set search_path='' as $$
declare s uuid;r jsonb;
begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_branch(p_store,p_branch);
 select id into s from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then
 if not exists(select 1 from tenant_private.branch_sales where store_id=p_store and sale_id=s and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;
 return tenant_private.record_credit_sale(p_store,p_request,p_currency,p_lines,p_customer,p_deposit,p_count,p_due);
 end if;
 perform tenant_private.branch_take(p_store,p_branch,p_lines);
 r:=tenant_private.record_credit_sale(p_store,p_request,p_currency,p_lines,p_customer,p_deposit,p_count,p_due);
 insert into tenant_private.branch_sales values(p_store,(r->>'id')::uuid,p_branch);return r;
end
$$;
create function public.mt_branch_credit_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb,p_customer uuid,p_deposit bigint,p_count integer,p_due date) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.branch_credit_sale(p_store,p_branch,p_request,p_currency,p_lines,p_customer,p_deposit,p_count,p_due)$$;
create function tenant_private.branch_mixed_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb,p_tenders jsonb,p_refund_policy text) returns jsonb language plpgsql security definer set search_path='' as $$
declare s uuid;r jsonb;
begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_branch(p_store,p_branch);
 select id into s from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then
 if not exists(select 1 from tenant_private.branch_sales where store_id=p_store and sale_id=s and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;
 return tenant_private.record_mixed_sale(p_store,p_request,p_currency,p_lines,p_tenders,p_refund_policy);
 end if;
 perform tenant_private.branch_take(p_store,p_branch,p_lines);
 r:=tenant_private.record_mixed_sale(p_store,p_request,p_currency,p_lines,p_tenders,p_refund_policy);
 insert into tenant_private.branch_sales values(p_store,(r->>'id')::uuid,p_branch);return r;
end
$$;
create function public.mt_branch_mixed_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb,p_tenders jsonb,p_refund_policy text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.branch_mixed_sale(p_store,p_branch,p_request,p_currency,p_lines,p_tenders,p_refund_policy)$$;
create function tenant_private.branch_purchase(p_store uuid,p_branch uuid,p_request uuid,p_supplier uuid,p_product uuid,p_currency text,p_units bigint,p_cost bigint,p_paid bigint,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare id_now uuid;existing uuid;
begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_branch(p_store,p_branch);
 select id into existing from public.mt_purchases where store_id=p_store and request_id=p_request;
 if found and not exists(select 1 from tenant_private.branch_purchases where store_id=p_store and purchase_id=existing and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;
 id_now:=tenant_private.purchase(p_store,p_request,p_supplier,p_product,p_currency,p_units,p_cost,p_paid,p_note);
 if existing is null then perform tenant_private.branch_add(p_store,p_branch,p_product,p_units);insert into tenant_private.branch_purchases values(p_store,id_now,p_branch);end if;return id_now;
end
$$;
create function public.mt_branch_purchase(p_store uuid,p_branch uuid,p_request uuid,p_supplier uuid,p_product uuid,p_currency text,p_units bigint,p_cost bigint,p_paid bigint,p_note text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_purchase(p_store,p_branch,p_request,p_supplier,p_product,p_currency,p_units,p_cost,p_paid,p_note)$$;
create function tenant_private.branch_purchase_batch(p_store uuid,p_branch uuid,p_request uuid,p_supplier uuid,p_currency text,p_reference text,p_lines jsonb,p_paid bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare id_now uuid;existing uuid;r record;
begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_branch(p_store,p_branch);
 select id into existing from public.mt_purchase_batches where store_id=p_store and request_id=p_request;
 if found and not exists(select 1 from tenant_private.branch_batches where store_id=p_store and batch_id=existing and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;
 id_now:=tenant_private.purchase_batch(p_store,p_request,p_supplier,p_currency,p_reference,p_lines,p_paid);
 if existing is null then insert into tenant_private.branch_batches values(p_store,id_now,p_branch);for r in select id,product_id,units from public.mt_purchases where store_id=p_store and batch_id=id_now loop perform tenant_private.branch_add(p_store,p_branch,r.product_id,r.units);insert into tenant_private.branch_purchases values(p_store,r.id,p_branch);end loop;end if;return id_now;
end
$$;
create function public.mt_branch_purchase_batch(p_store uuid,p_branch uuid,p_request uuid,p_supplier uuid,p_currency text,p_reference text,p_lines jsonb,p_paid bigint) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_purchase_batch(p_store,p_branch,p_request,p_supplier,p_currency,p_reference,p_lines,p_paid)$$;
create function tenant_private.branch_add_repair(p_store uuid,p_branch uuid,p_request uuid,p_customer uuid,p_device text,p_imei text,p_fault text) returns uuid language plpgsql security definer set search_path='' as $$
declare id_now uuid;existing uuid;
begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_branch(p_store,p_branch);
 select id into existing from public.mt_repairs where store_id=p_store and request_id=p_request;
 if found and not exists(select 1 from tenant_private.branch_repairs where store_id=p_store and repair_id=existing and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;
 id_now:=tenant_private.add_repair(p_store,p_request,p_customer,p_device,p_imei,p_fault);
 if existing is null then insert into tenant_private.branch_repairs values(p_store,id_now,p_branch);end if;return id_now;
end
$$;
create function public.mt_branch_add_repair(p_store uuid,p_branch uuid,p_request uuid,p_customer uuid,p_device text,p_imei text,p_fault text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_add_repair(p_store,p_branch,p_request,p_customer,p_device,p_imei,p_fault)$$;
-- Existing checkout and supplier-return engine triggers enforce branch allocation regardless of caller.
create function tenant_private.branch_repair_parts() returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;
begin
 select branch_id into b from tenant_private.branch_repairs where store_id=new.store_id and repair_id=new.repair_id;
 if found then perform tenant_private.branch_take(new.store_id,b,new.lines);end if;return new;
end $$;
create trigger mt_branch_repair_parts before insert on public.mt_repair_invoices for each row execute function tenant_private.branch_repair_parts();
create function tenant_private.branch_supplier_return() returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;pid uuid;
begin
 select bp.branch_id,p.product_id into b,pid from tenant_private.branch_purchases bp join public.mt_purchases p on p.store_id=bp.store_id and p.id=bp.purchase_id where bp.store_id=new.store_id and bp.purchase_id=new.purchase_id;
 if found then update tenant_private.branch_stock set units=units-new.units where store_id=new.store_id and branch_id=b and product_id=pid and units>=new.units;if not found then raise exception 'Return stock to original purchase branch first' using errcode='22023';end if;end if;return new;
end $$;
create trigger mt_branch_supplier_return before insert on public.mt_supplier_returns for each row execute function tenant_private.branch_supplier_return();
revoke all on function tenant_private.require_branch(uuid,uuid),tenant_private.branch_take(uuid,uuid,jsonb),tenant_private.branch_add(uuid,uuid,uuid,bigint),tenant_private.branch_repair_parts(),tenant_private.branch_supplier_return(),tenant_private.branch_credit_sale(uuid,uuid,uuid,text,jsonb,uuid,bigint,integer,date),public.mt_branch_credit_sale(uuid,uuid,uuid,text,jsonb,uuid,bigint,integer,date),tenant_private.branch_mixed_sale(uuid,uuid,uuid,text,jsonb,jsonb,text),public.mt_branch_mixed_sale(uuid,uuid,uuid,text,jsonb,jsonb,text),tenant_private.branch_purchase(uuid,uuid,uuid,uuid,uuid,text,bigint,bigint,bigint,text),public.mt_branch_purchase(uuid,uuid,uuid,uuid,uuid,text,bigint,bigint,bigint,text),tenant_private.branch_purchase_batch(uuid,uuid,uuid,uuid,text,text,jsonb,bigint),public.mt_branch_purchase_batch(uuid,uuid,uuid,uuid,text,text,jsonb,bigint),tenant_private.branch_add_repair(uuid,uuid,uuid,uuid,text,text,text),public.mt_branch_add_repair(uuid,uuid,uuid,uuid,text,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_credit_sale(uuid,uuid,uuid,text,jsonb,uuid,bigint,integer,date),public.mt_branch_credit_sale(uuid,uuid,uuid,text,jsonb,uuid,bigint,integer,date),tenant_private.branch_mixed_sale(uuid,uuid,uuid,text,jsonb,jsonb,text),public.mt_branch_mixed_sale(uuid,uuid,uuid,text,jsonb,jsonb,text),tenant_private.branch_purchase(uuid,uuid,uuid,uuid,uuid,text,bigint,bigint,bigint,text),public.mt_branch_purchase(uuid,uuid,uuid,uuid,uuid,text,bigint,bigint,bigint,text),tenant_private.branch_purchase_batch(uuid,uuid,uuid,uuid,text,text,jsonb,bigint),public.mt_branch_purchase_batch(uuid,uuid,uuid,uuid,text,text,jsonb,bigint),tenant_private.branch_add_repair(uuid,uuid,uuid,uuid,text,text,text),public.mt_branch_add_repair(uuid,uuid,uuid,uuid,text,text,text) to authenticated;
commit;
