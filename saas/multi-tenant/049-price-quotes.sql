-- Immutable price quotes; do not post sales, inventory, cash or tax.
begin;
create table tenant_private.price_quotes(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,actor uuid not null,
 customer text not null check(length(btrim(customer)) between 1 and 160),currency text not null check(currency in ('SYP','USD','EUR')),valid_until date not null,
 total_minor bigint not null check(total_minor between 1 and 100000000000000),lines jsonb not null,request_lines jsonb not null,identity jsonb not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id)
);
alter table tenant_private.price_quotes enable row level security;
revoke all on tenant_private.price_quotes from public,anon,authenticated,service_role;
create function tenant_private.quote_create(p_store uuid,p_request uuid,p_customer text,p_currency text,p_until date,p_lines jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare q tenant_private.price_quotes%rowtype;x jsonb;pr record;pid uuid;u bigint;price bigint;v_total bigint:=0;v_lines jsonb:='[]'::jsonb;norm jsonb;today date:=(now() at time zone 'Asia/Damascus')::date;
begin
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Quote write denied' using errcode='42501';end if;
 if p_request is null or p_customer is null or length(btrim(p_customer)) not between 1 and 160 or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_until is null or jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>50000 then raise exception 'Invalid quote' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' or not (x ?& array['product_id','units','expected_price_minor']) then raise exception 'Invalid line' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line values' using errcode='22023';end if;
  if (x->>'units')::bigint not between 1 and 10000 or (x->>'expected_price_minor')::bigint not between 1 and 100000000 then raise exception 'Invalid amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into norm from jsonb_array_elements(p_lines);
 perform 1 from public.saas_stores where id=p_store for update;
 select * into q from tenant_private.price_quotes where store_id=p_store and request_id=p_request;
 if found then if q.actor<>auth.uid() or q.customer<>btrim(p_customer) or q.currency<>p_currency or q.valid_until<>p_until or q.request_lines is distinct from norm then raise exception 'Conflicting quote' using errcode='22023';end if;return q.id;end if;
 if p_until<today or p_until>today+90 then raise exception 'Invalid validity' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(norm) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;price:=(x->>'expected_price_minor')::bigint;
  select p.name,p.sku,pp.price_minor into pr from public.mt_products p join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and p.id=pid;
  if not found or pr.price_minor is distinct from price then raise exception 'Product unavailable or price changed' using errcode='22023';end if;
  v_total:=v_total+u*price;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('product_name',pr.name,'sku',pr.sku,'units',u,'unit_price_minor',price,'line_total_minor',u*price));
 end loop;
 insert into tenant_private.price_quotes(store_id,request_id,actor,customer,currency,valid_until,total_minor,lines,request_lines,identity) values(p_store,p_request,auth.uid(),btrim(p_customer),p_currency,p_until,v_total,v_lines,norm,tenant_private.effective_receipt_settings(p_store)) returning id into q.id;
 return q.id;
end $$;
create function tenant_private.quote_list(p_store uuid,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);r jsonb;
begin
 if not coalesce(role_now in ('owner','cashier'),false) then raise exception 'Quote access denied' using errcode='42501';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page' using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc,id desc),'[]'::jsonb) into r from (select id,customer,currency,valid_until,total_minor,created_at from tenant_private.price_quotes where store_id=p_store and (role_now='owner' or actor=auth.uid()) and (p_before is null or (created_at,id)<(p_before,p_before_id)) order by created_at desc,id desc limit 50)x;return r;
end $$;
create function tenant_private.quote_read(p_store uuid,p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);r jsonb;
begin
 select jsonb_build_object('id',id,'customer',customer,'currency',currency,'valid_until',valid_until,'total_minor',total_minor,'created_at',created_at,'lines',lines,'identity',identity) into r from tenant_private.price_quotes where store_id=p_store and id=p_id and (role_now='owner' or (role_now='cashier' and actor=auth.uid()));
 if not found then raise exception 'Quote access denied' using errcode='42501';end if;return r;
end $$;
create function public.mt_quote_create(p_store uuid,p_request uuid,p_customer text,p_currency text,p_until date,p_lines jsonb) returns uuid language sql security invoker set search_path='' as $$select tenant_private.quote_create(p_store,p_request,p_customer,p_currency,p_until,p_lines)$$;
create function public.mt_quote_list(p_store uuid,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.quote_list(p_store,p_before,p_before_id)$$;
create function public.mt_quote_read(p_store uuid,p_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.quote_read(p_store,p_id)$$;
revoke all on function tenant_private.quote_create(uuid,uuid,text,text,date,jsonb),tenant_private.quote_list(uuid,timestamptz,uuid),tenant_private.quote_read(uuid,uuid),public.mt_quote_create(uuid,uuid,text,text,date,jsonb),public.mt_quote_list(uuid,timestamptz,uuid),public.mt_quote_read(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.quote_create(uuid,uuid,text,text,date,jsonb),tenant_private.quote_list(uuid,timestamptz,uuid),tenant_private.quote_read(uuid,uuid),public.mt_quote_create(uuid,uuid,text,text,date,jsonb),public.mt_quote_list(uuid,timestamptz,uuid),public.mt_quote_read(uuid,uuid) to authenticated;
commit;
