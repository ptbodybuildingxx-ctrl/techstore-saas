begin;
-- One immutable supplier invoice grouping existing FIFO receipts and payables.
create table public.mt_purchase_batches(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,supplier_id uuid not null,currency text not null,
 reference text not null check(length(btrim(reference)) between 1 and 160),lines jsonb not null check(jsonb_typeof(lines)='array' and jsonb_array_length(lines) between 1 and 100),
 total_minor bigint not null check(total_minor between 1 and 100000000000000),initial_paid_minor bigint not null check(initial_paid_minor between 0 and total_minor),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,supplier_id) references public.mt_suppliers(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
alter table public.mt_purchases add column batch_id uuid,add foreign key(store_id,batch_id) references public.mt_purchase_batches(store_id,id);
create index mt_purchase_batch_idx on public.mt_purchases(store_id,batch_id);
alter table public.mt_purchase_batches enable row level security;
revoke all on public.mt_purchase_batches from public,anon,authenticated,service_role;
grant select on public.mt_purchase_batches to authenticated;
create policy owner_read on public.mt_purchase_batches for select to authenticated using (tenant_private.member_role(store_id)='owner');
create function tenant_private.purchase_batch(p_store uuid,p_request uuid,p_supplier uuid,p_currency text,p_reference text,p_lines jsonb,p_paid bigint) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.mt_purchase_batches%rowtype;x jsonb;norm jsonb;total numeric:=0;left_paid bigint;alloc bigint;line_total bigint;purchase_id uuid;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_supplier is null or p_currency is null or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_paid is null or p_paid<0 or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid purchase invoice' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>30000 then raise exception 'Invalid lines' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
 if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid line' using errcode='22023';end if;
 if (select count(*) from jsonb_object_keys(x))<>3 or not(x ?& array['product_id','units','unit_cost_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'unit_cost_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,7}$' or coalesce(x->>'unit_cost_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line values' using errcode='22023';end if;
 if (x->>'units')::bigint not between 1 and 1000000 or (x->>'unit_cost_minor')::bigint not between 1 and 100000000 then raise exception 'Line amount out of range' using errcode='22023';end if;
 total:=total+(x->>'units')::numeric*(x->>'unit_cost_minor')::numeric;
 end loop;
 if total not between 1 and 100000000000000 or p_paid>total or (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Invalid invoice total or duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'unit_cost_minor',(value->>'unit_cost_minor')::bigint) order by (value->>'product_id')::uuid) into norm from jsonb_array_elements(p_lines);
 select * into r from public.mt_purchase_batches where store_id=p_store and request_id=p_request;
 if found then
 if r.actor<>auth.uid() or r.supplier_id<>p_supplier or r.currency<>p_currency or r.reference<>btrim(p_reference) or r.lines is distinct from norm or r.initial_paid_minor<>p_paid then raise exception 'Conflicting purchase invoice' using errcode='22023';end if;return r.id;
 end if;
 insert into public.mt_purchase_batches(store_id,request_id,supplier_id,currency,reference,lines,total_minor,initial_paid_minor,actor) values(p_store,p_request,p_supplier,p_currency,btrim(p_reference),norm,total::bigint,p_paid,auth.uid()) returning * into r;
 left_paid:=p_paid;
 for x in select value from jsonb_array_elements(norm) loop
 line_total:=(x->>'units')::bigint*(x->>'unit_cost_minor')::bigint;alloc:=least(left_paid,line_total);
 purchase_id:=tenant_private.purchase(p_store,gen_random_uuid(),p_supplier,(x->>'product_id')::uuid,p_currency,(x->>'units')::bigint,(x->>'unit_cost_minor')::bigint,alloc,btrim(p_reference));
 update public.mt_purchases set batch_id=r.id where store_id=p_store and id=purchase_id;
 left_paid:=left_paid-alloc;
 end loop;
 if left_paid<>0 then raise exception 'Purchase allocation mismatch';end if;return r.id;
end $$;
create function public.mt_purchase_batch(p_store uuid,p_request uuid,p_supplier uuid,p_currency text,p_reference text,p_lines jsonb,p_paid bigint) returns uuid language sql security invoker set search_path='' as $$select tenant_private.purchase_batch(p_store,p_request,p_supplier,p_currency,p_reference,p_lines,p_paid)$$;
create function public.mt_list_purchase_batches(p_store uuid,p_after uuid default null,p_limit integer default 50) returns table(store_id uuid,id uuid,supplier_id uuid,currency text,reference text,total_minor bigint,paid_minor bigint,created_at timestamptz)
language plpgsql stable security invoker set search_path='' as $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select b.store_id,b.id,b.supplier_id,b.currency,b.reference,b.total_minor,(select coalesce(sum(p.paid_minor),0)::bigint from public.mt_purchases p where p.store_id=b.store_id and p.batch_id=b.id),b.created_at from public.mt_purchase_batches b where b.store_id=p_store and (p_after is null or b.id>p_after) order by b.id limit p_limit;
end $$;
revoke all on function tenant_private.purchase_batch(uuid,uuid,uuid,text,text,jsonb,bigint),public.mt_purchase_batch(uuid,uuid,uuid,text,text,jsonb,bigint),public.mt_list_purchase_batches(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.purchase_batch(uuid,uuid,uuid,text,text,jsonb,bigint),public.mt_purchase_batch(uuid,uuid,uuid,text,text,jsonb,bigint),public.mt_list_purchase_batches(uuid,uuid,integer) to authenticated;
commit;