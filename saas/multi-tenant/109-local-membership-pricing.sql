alter table tenant_private.receivable_resolutions drop constraint receivable_resolutions_kind_check;
alter table tenant_private.receivable_resolutions add constraint receivable_resolutions_kind_check check(kind in ('customer','customerEdit','pay','credit','standaloneOpen','standalonePay','cashSale','mixed'));

-- Locally registered customers have separate merchant-approved membership terms.
-- No online buyer identity or points balance is inferred from a local customer ID.
create table tenant_private.local_membership_terms(
 store_id uuid not null,customer_id uuid not null,tier text not null check(tier in ('standard','member','silver','gold','vip','wholesale')),
 use_default boolean not null,basis_points int not null check(basis_points between 0 and 5000),
 min_units int not null check(min_units between 1 and 5000),enabled boolean not null,
 actor uuid not null,updated_at timestamptz not null default now(),primary key(store_id,customer_id),
 foreign key(store_id,customer_id) references public.mt_customers(store_id,id)
);
create table tenant_private.local_customer_prices(
 store_id uuid not null,customer_id uuid not null,product_id uuid not null,currency text not null,
 price_minor bigint not null check(price_minor between 1 and 100000000),min_units int not null check(min_units between 1 and 100),
 actor uuid not null,updated_at timestamptz not null default now(),primary key(store_id,customer_id,product_id,currency),
 foreign key(store_id,customer_id) references public.mt_customers(store_id,id),
 foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
create table tenant_private.local_membership_sales(
 store_id uuid not null,sale_id uuid not null,request_id uuid not null,customer_id uuid not null,actor uuid not null,
 tier text not null check(tier in ('standard','member','silver','gold','vip','wholesale')),payload jsonb not null,result jsonb not null,created_at timestamptz not null default now(),
 primary key(store_id,sale_id),unique(store_id,request_id),foreign key(store_id,sale_id) references public.mt_sales(store_id,id),
 foreign key(store_id,customer_id) references public.mt_customers(store_id,id)
);
alter table tenant_private.local_membership_terms enable row level security;
alter table tenant_private.local_customer_prices enable row level security;
alter table tenant_private.local_membership_sales enable row level security;
revoke all on tenant_private.local_membership_terms,tenant_private.local_customer_prices,tenant_private.local_membership_sales from public,anon,authenticated,service_role;

create function tenant_private.local_membership_access(s uuid,b uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.can_sell(s),false) and coalesce(tenant_private.staff_action_allowed(s,'sell'),false) and tenant_private.receivable_allowed(s,'read') and tenant_private.receivable_branch_allowed(s,b)
$$;
create function tenant_private.local_membership_directory(s uuid,q text,a uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if q is null or length(q)>160 then raise exception 'Invalid query';end if;
 return (select coalesce(jsonb_agg(to_jsonb(x) order by customer_id),'[]') from (
 select c.id customer_id,c.name,c.phone,coalesce(t.tier,'standard') tier,coalesce(t.enabled,false) enabled,coalesce(t.use_default,true) use_default,
 coalesce(case when t.use_default is false then t.basis_points else r.basis_points end,0) basis_points,
 coalesce(case when t.use_default is false then t.min_units else r.min_units end,1) min_units
 from public.mt_customers c left join tenant_private.local_membership_terms t on t.store_id=c.store_id and t.customer_id=c.id
 left join tenant_private.membership_rates r on r.store_id=c.store_id and r.tier=coalesce(t.tier,'standard')
 where c.store_id=s and (a is null or c.id>a) and (q='' or strpos(lower(c.name),lower(q))>0 or strpos(c.phone,q)>0 or strpos(c.id::text,lower(q))>0)
 order by c.id limit 51)x);
end $$;
create function tenant_private.local_membership_set(s uuid,u uuid,t text,defaults boolean,bps integer,m integer,enabled_value boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(s);
 if not exists(select 1 from public.mt_customers where store_id=s and id=u) or t is null or t not in ('standard','member','silver','gold','vip','wholesale') or defaults is null or bps is null or bps not between 0 and 5000 or m is null or m not between 1 and 5000 or enabled_value is null then raise exception 'Invalid local membership';end if;
 insert into tenant_private.local_membership_terms values(s,u,t,defaults,case when defaults then 0 else bps end,case when defaults then 1 else m end,enabled_value,auth.uid(),now())
 on conflict(store_id,customer_id) do update set tier=excluded.tier,use_default=excluded.use_default,basis_points=excluded.basis_points,min_units=excluded.min_units,enabled=excluded.enabled,actor=excluded.actor,updated_at=now();
 return true;
end $$;
create function tenant_private.local_customer_price_set(s uuid,u uuid,p uuid,c text,price bigint,m integer,enabled_value boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(s);
 if not exists(select 1 from public.mt_customers where store_id=s and id=u) or not exists(select 1 from public.mt_products where store_id=s and id=p) or c is null or c not in ('SYP','USD','EUR') or enabled_value is null then raise exception 'Invalid local price';end if;
 if not enabled_value then delete from tenant_private.local_customer_prices where store_id=s and customer_id=u and product_id=p and currency=c;return false;end if;
 if price is null or price not between 1 and 100000000 or m is null or m not between 1 and 100 or not exists(select 1 from public.mt_product_prices where store_id=s and product_id=p and currency=c and price_minor>=price) then raise exception 'Invalid local price';end if;
 insert into tenant_private.local_customer_prices values(s,u,p,c,price,m,auth.uid(),now()) on conflict(store_id,customer_id,product_id,currency) do update set price_minor=excluded.price_minor,min_units=excluded.min_units,actor=excluded.actor,updated_at=now();
 return true;
end $$;
create function tenant_private.local_customer_price_list(s uuid,u uuid,p uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'price_minor',price_minor,'min_units',min_units) order by currency),'[]') from tenant_private.local_customer_prices where store_id=s and customer_id=u and product_id=p);
end $$;
create function tenant_private.local_membership_quote(s uuid,b uuid,u uuid,c text,items jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v tenant_private.local_membership_terms%rowtype;x jsonb;p uuid;qty bigint;retail bigint;net bigint;loc bigint;units bigint:=0;gross bigint:=0;total bigint:=0;prices jsonb:='{}';
begin
 if not tenant_private.local_membership_access(s,b) then raise exception 'Local membership access denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 if u is null or c is null or c not in ('SYP','USD','EUR') or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or octet_length(items::text)>50000 then raise exception 'Invalid quote';end if;
 select * into v from tenant_private.local_membership_terms where store_id=s and customer_id=u and enabled;
 if not found then raise exception 'Local membership disabled';end if;
 if v.use_default then select basis_points,min_units into v.basis_points,v.min_units from tenant_private.membership_rates where store_id=s and tier=v.tier;v.basis_points:=coalesce(v.basis_points,0);v.min_units:=coalesce(v.min_units,1);end if;
 for x in select value from jsonb_array_elements(items) loop
 if jsonb_typeof(x) is distinct from 'object' or (select count(*) from jsonb_object_keys(x))<>3 or not(x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line';end if;
 p:=(x->>'product_id')::uuid;qty:=(x->>'units')::bigint;
 if p is null or qty not between 1 and 10000 or prices ? p::text then raise exception 'Invalid product/quantity';end if;
 select price_minor into retail from public.mt_product_prices where store_id=s and product_id=p and currency=c;
 if not found or retail is distinct from (x->>'expected_price_minor')::bigint then raise exception 'Retail price changed';end if;
 if b is null then loc:=tenant_private.main_available(s,p);else select units into loc from tenant_private.branch_stock where store_id=s and branch_id=b and product_id=p;end if;
 if coalesce(loc,0)<qty then raise exception 'Stock changed';end if;
 select price_minor into net from tenant_private.local_customer_prices where store_id=s and customer_id=u and product_id=p and currency=c and min_units<=qty and price_minor<=retail;
 if not found then select price_minor into net from tenant_private.product_tier_prices where store_id=s and product_id=p and currency=c and tier=v.tier and min_units<=qty and price_minor<=retail;end if;
 net:=coalesce(net,retail-retail*v.basis_points/10000);
 prices:=prices||jsonb_build_object(p::text,net);units:=units+qty;gross:=gross+qty*retail;total:=total+qty*net;
 end loop;
 if units<v.min_units or total not between 1 and 100000000000000 or gross>100000000000000 then raise exception 'Local membership minimum or amount';end if;
 return jsonb_build_object('customer',u,'price_tier',v.tier,'prices',prices,'currency',c,'gross_minor',gross,'total_minor',total,'discount_minor',gross-total);
end $$;
create function tenant_private.local_membership_sale(s uuid,b uuid,r uuid,u uuid,c text,items jsonb,meta jsonb,terms jsonb,expected bigint,prices jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare old tenant_private.local_membership_sales%rowtype;q jsonb;payload jsonb;net_items jsonb;result jsonb;sid uuid;customer_name text;customer_phone text;
begin
 if not tenant_private.local_membership_access(s,b) or r is null or u is null or expected is null or expected<1 or jsonb_typeof(prices) is distinct from 'object' or jsonb_typeof(meta) is distinct from 'object' then raise exception 'Invalid local membership sale';end if;
 if terms is not null then
 if jsonb_typeof(terms) is distinct from 'object' then raise exception 'Invalid terms';end if;
 if terms ? 'customer' then
 if (terms->>'customer')::uuid is distinct from u or not tenant_private.receivable_allowed(s,'credit_sale') then raise exception 'Customer mismatch';end if;
 elsif terms ? 'tenders' then if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required';end if;
 else raise exception 'Invalid terms';end if;end if;
 perform 1 from public.saas_stores where id=s for update;
 perform tenant_private.assert_receivable_live(s,r,case when terms ? 'customer' then 'credit' when terms ? 'tenders' then 'mixed' else 'cashSale' end);
 payload:=jsonb_build_object('branch',b,'customer',u,'currency',c,'lines',items,'meta',meta,'terms',terms,'expected',expected,'prices',prices);
 select * into old from tenant_private.local_membership_sales where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting local membership request';end if;return old.result;end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale request';end if;
 q:=tenant_private.local_membership_quote(s,b,u,c,items);
 if q->'prices' is distinct from prices or (q->>'total_minor')::bigint<>expected then raise exception 'Local prices changed; review draft';end if;
 select name,phone into strict customer_name,customer_phone from public.mt_customers where store_id=s and id=u;
 select jsonb_agg(jsonb_build_object('product_id',(x->>'product_id')::uuid,'units',(x->>'units')::bigint,'expected_price_minor',(prices->>(x->>'product_id'))::bigint) order by (x->>'product_id')::uuid) into net_items from jsonb_array_elements(items)x;
 insert into tenant_private.membership_sale_context values(s,r,auth.uid(),c,prices);
 result:=tenant_private.issue_sale_invoice(s,b,r,c,net_items,meta||jsonb_build_object('customer',customer_name,'phone',customer_phone),terms);
 delete from tenant_private.membership_sale_context where store_id=s and request_id=r;
 sid:=(result->>'id')::uuid;
 if (result->>'total_minor')::bigint<>expected then raise exception 'Invoice mismatch';end if;
 result:=result||q;
 insert into tenant_private.local_membership_sales(store_id,sale_id,request_id,customer_id,actor,tier,payload,result) values(s,sid,r,u,auth.uid(),q->>'price_tier',payload,result);
 update tenant_private.sale_invoice_details set document=document||jsonb_build_object('local_membership',jsonb_build_object('tier',q->>'price_tier','gross_minor',q->'gross_minor','discount_minor',q->'discount_minor')) where store_id=s and sale_id=sid;
 return result;
end $$;
create function tenant_private.local_membership_snapshot(s uuid,b uuid,c text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v jsonb;
begin
 if not tenant_private.local_membership_access(s,b) or c is null or c not in ('SYP','USD','EUR') then raise exception 'Local pricing denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 with terms as materialized (
 select t.customer_id,t.tier,coalesce(case when t.use_default then r.basis_points else t.basis_points end,0) basis_points,coalesce(case when t.use_default then r.min_units else t.min_units end,1) min_units
 from tenant_private.local_membership_terms t left join tenant_private.membership_rates r on r.store_id=t.store_id and r.tier=t.tier where t.store_id=s and t.enabled order by t.customer_id limit 2001
 ),tiers as materialized (
 select p.product_id,p.tier,p.price_minor,p.min_units from tenant_private.product_tier_prices p where p.store_id=s and p.currency=c and exists(select 1 from terms t where t.tier=p.tier) order by p.product_id,p.tier limit 12001
 ),prices as materialized (
 select p.customer_id,p.product_id,p.price_minor,p.min_units from tenant_private.local_customer_prices p join terms t on t.customer_id=p.customer_id where p.store_id=s and p.currency=c order by p.customer_id,p.product_id limit 6001
 ) select case when (select count(*) from terms)>2000 or (select count(*) from tiers)>12000 or (select count(*) from prices)>6000 then null else jsonb_build_object('version',1,'store',s,'actor',auth.uid(),'branch',b,'currency',c,'capturedAt',now(),'terms',coalesce((select jsonb_agg(to_jsonb(t)) from terms t),'[]'),'tiers',coalesce((select jsonb_agg(to_jsonb(t)) from tiers t),'[]'),'prices',coalesce((select jsonb_agg(to_jsonb(p)) from prices p),'[]')) end into v;
 if v is null or octet_length(v::text)>800000 then raise exception 'Local pricing snapshot exceeds capacity';end if;
 return v;
end $$;

create function public.mt_local_membership_directory(p_store uuid,p_query text,p_after uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.local_membership_directory(p_store,p_query,p_after)$$;
revoke all on function tenant_private.local_membership_directory(uuid,text,uuid),public.mt_local_membership_directory(uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.local_membership_directory(uuid,text,uuid),public.mt_local_membership_directory(uuid,text,uuid) to authenticated;
create function public.mt_local_membership_set(p_store uuid,p_customer uuid,p_tier text,p_defaults boolean,p_bps integer,p_min integer,p_enabled boolean) returns boolean language sql  security invoker set search_path='' as $$select tenant_private.local_membership_set(p_store,p_customer,p_tier,p_defaults,p_bps,p_min,p_enabled)$$;
revoke all on function tenant_private.local_membership_set(uuid,uuid,text,boolean,integer,integer,boolean),public.mt_local_membership_set(uuid,uuid,text,boolean,integer,integer,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.local_membership_set(uuid,uuid,text,boolean,integer,integer,boolean),public.mt_local_membership_set(uuid,uuid,text,boolean,integer,integer,boolean) to authenticated;
create function public.mt_local_customer_price_set(p_store uuid,p_customer uuid,p_product uuid,p_currency text,p_price bigint,p_min integer,p_enabled boolean) returns boolean language sql  security invoker set search_path='' as $$select tenant_private.local_customer_price_set(p_store,p_customer,p_product,p_currency,p_price,p_min,p_enabled)$$;
revoke all on function tenant_private.local_customer_price_set(uuid,uuid,uuid,text,bigint,integer,boolean),public.mt_local_customer_price_set(uuid,uuid,uuid,text,bigint,integer,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.local_customer_price_set(uuid,uuid,uuid,text,bigint,integer,boolean),public.mt_local_customer_price_set(uuid,uuid,uuid,text,bigint,integer,boolean) to authenticated;
create function public.mt_local_customer_price_list(p_store uuid,p_customer uuid,p_product uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.local_customer_price_list(p_store,p_customer,p_product)$$;
revoke all on function tenant_private.local_customer_price_list(uuid,uuid,uuid),public.mt_local_customer_price_list(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.local_customer_price_list(uuid,uuid,uuid),public.mt_local_customer_price_list(uuid,uuid,uuid) to authenticated;
create function public.mt_local_membership_quote(p_store uuid,p_branch uuid,p_customer uuid,p_currency text,p_lines jsonb) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.local_membership_quote(p_store,p_branch,p_customer,p_currency,p_lines)$$;
revoke all on function tenant_private.local_membership_quote(uuid,uuid,uuid,text,jsonb),public.mt_local_membership_quote(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.local_membership_quote(uuid,uuid,uuid,text,jsonb),public.mt_local_membership_quote(uuid,uuid,uuid,text,jsonb) to authenticated;
create function public.mt_local_membership_sale(p_store uuid,p_branch uuid,p_request uuid,p_customer uuid,p_currency text,p_lines jsonb,p_metadata jsonb,p_terms jsonb,p_expected bigint,p_prices jsonb) returns jsonb language sql  security invoker set search_path='' as $$select tenant_private.local_membership_sale(p_store,p_branch,p_request,p_customer,p_currency,p_lines,p_metadata,p_terms,p_expected,p_prices)$$;
revoke all on function tenant_private.local_membership_sale(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,bigint,jsonb),public.mt_local_membership_sale(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.local_membership_sale(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,bigint,jsonb),public.mt_local_membership_sale(uuid,uuid,uuid,uuid,text,jsonb,jsonb,jsonb,bigint,jsonb) to authenticated;
create function public.mt_local_membership_snapshot(p_store uuid,p_branch uuid,p_currency text) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.local_membership_snapshot(p_store,p_branch,p_currency)$$;
revoke all on function tenant_private.local_membership_snapshot(uuid,uuid,text),public.mt_local_membership_snapshot(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.local_membership_snapshot(uuid,uuid,text),public.mt_local_membership_snapshot(uuid,uuid,text) to authenticated;
revoke all on function tenant_private.local_membership_access(uuid,uuid) from public,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION tenant_private.resolve_receivable(s uuid, op jsonb, mode text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r uuid;k text;u uuid:=auth.uid();x jsonb;v jsonb;old_n text;old_p text;found_record boolean:=false;same boolean:=false;prior text;sid uuid;b uuid;items jsonb;meta jsonb;terms jsonb;invoice_payload jsonb;
begin
 if u is null or tenant_private.member_role(s) is null then raise exception 'Active membership required' using errcode='42501';end if;
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>100000 or (op->>'store')::uuid is distinct from s or mode is null or mode not in ('inspect','cancel','acknowledge') then raise exception 'Invalid resolution request' using errcode='22023';end if;
 r:=(op->>'requestId')::uuid;k:=op->>'kind';
 if r is null or k is null or k not in ('customer','customerEdit','pay','credit','standaloneOpen','standalonePay','cashSale','mixed') or (k in ('cashSale','mixed') and jsonb_typeof(op->'localPricing') is distinct from 'object') then raise exception 'Invalid resolution reference' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=s for update;
 if tenant_private.member_role(s) is null then raise exception 'Membership ended' using errcode='42501';end if;
 select outcome into prior from tenant_private.receivable_resolutions where store_id=s and actor=u and request_id=r and kind=k;
 if prior is not null then return prior;end if;
 x:=op->'payload';
 case k
 when 'customer' then
  select to_jsonb(c) into v from public.mt_customers c where c.store_id=s and c.request_id=r and c.actor=u;
  found_record:=found;
  if found_record then
   select e.old_name,e.old_phone into old_n,old_p from tenant_private.customer_profile_edits e where e.store_id=s and e.customer_id=(v->>'id')::uuid order by e.revision limit 1;
   same:=coalesce(old_n,v->>'name')=btrim(op->>'name') and coalesce(old_p,v->>'phone')=btrim(op->>'phone');
  end if;
 when 'customerEdit' then
  select to_jsonb(e) into v from tenant_private.customer_profile_edits e where e.store_id=s and e.id=r and e.actor=u;
  found_record:=found;
  if found_record then same:=(v->>'customer_id')::uuid=(op->>'customer')::uuid and v->>'old_name'=op->>'oldName' and v->>'old_phone'=op->>'oldPhone' and v->>'new_name'=btrim(op->>'name') and v->>'new_phone'=btrim(op->>'phone');end if;
 when 'pay' then
  select to_jsonb(p)||jsonb_build_object('currency',d.currency) into v from public.mt_debt_payments p join public.mt_debts d on d.store_id=p.store_id and d.id=p.debt_id where p.store_id=s and p.request_id=r and p.actor=u;
  found_record:=found;
  if found_record then same:=not (v->>'is_deposit')::boolean and v->>'settlement_method'='cash' and (v->>'debt_id')::uuid=(op->>'debt')::uuid and (v->>'amount_minor')::bigint=(op->>'amount')::bigint and v->>'currency'=op->>'currency';end if;
 when 'standaloneOpen' then
  select to_jsonb(d) into v from tenant_private.standalone_debts d where d.store_id=s and d.id=r and d.actor=u;
  found_record:=found;
  if found_record then same:=(v->>'customer_id')::uuid is not distinct from (x->>'customer')::uuid and (v->>'branch_id')::uuid is not distinct from (x->>'branch')::uuid and v->>'direction'=x->>'direction' and v->>'party'=btrim(x->>'party') and v->>'phone'=btrim(x->>'phone') and v->>'currency'=x->>'currency' and (v->>'principal_minor')::bigint=(x->>'amount')::bigint and (v->>'installment_count')::integer=(x->>'count')::integer and (v->>'first_due')::date=(x->>'due')::date and v->>'notes'=btrim(x->>'notes');end if;
 when 'standalonePay' then
  select to_jsonb(p) into v from tenant_private.standalone_debt_payments p where p.store_id=s and p.id=r and p.actor=u;
  found_record:=found;
  if found_record then same:=(v->>'debt_id')::uuid=(x->>'debt')::uuid and (v->>'amount_minor')::bigint=(x->>'amount')::bigint and v->>'memo'=btrim(x->>'memo');end if;
 when 'cashSale','mixed' then
  x:=op;terms:=case when k='mixed' then jsonb_build_object('tenders',op->'tenders','refund_policy',op->>'refundPolicy') else null end;
  select a.id,to_jsonb(a) into sid,v from public.mt_sales a where a.store_id=s and a.request_id=r and a.actor=u;
  found_record:=found;
  if found_record and v->>'payment_mode'=(case when k='mixed' then 'mixed' else 'cash' end) then
   same:=exists(select 1 from tenant_private.local_membership_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'customer',(x->'localPricing'->>'customer')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'localPricing'->>'expected')::bigint,'prices',x->'localPricing'->'prices'));
  end if;
 when 'credit' then
  x:=op->'sale';terms:=op->'terms';
  select a.id,to_jsonb(a) into sid,v from public.mt_sales a where a.store_id=s and a.request_id=r and a.actor=u;
  found_record:=found;
  if found_record and v->>'payment_mode'='credit' then
   select branch_id into b from tenant_private.branch_sales where store_id=s and sale_id=sid;
   select jsonb_agg(jsonb_build_object('product_id',l.product_id,'units',l.units,'expected_price_minor',l.unit_price_minor) order by l.product_id) into items from public.mt_sale_lines l where l.store_id=s and l.sale_id=sid;
   select payload into invoice_payload from tenant_private.sale_invoice_details where store_id=s and sale_id=sid;
   same:=((x->>'store')::uuid=s and (x->>'requestId')::uuid=r and b is not distinct from (x->>'branch')::uuid and v->>'currency'=x->>'currency' and items=x->'lines' and exists(select 1 from public.mt_debts d where d.store_id=s and d.sale_id=sid and d.customer_id=(terms->>'customer')::uuid and d.deposit_minor=(terms->>'deposit')::bigint and d.installment_count=(terms->>'count')::integer and d.first_due=(terms->>'due')::date));
   if x ? 'localPricing' then
    same:=exists(select 1 from tenant_private.local_membership_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'customer',(x->'localPricing'->>'customer')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'localPricing'->>'expected')::bigint,'prices',x->'localPricing'->'prices'));
   elsif x ? 'membership' then
    same:=exists(select 1 from tenant_private.pos_loyalty_sales p where p.store_id=s and p.sale_id=sid and p.actor=u and p.payload=jsonb_build_object('branch',(x->>'branch')::uuid,'token',(x->'membership'->>'token')::uuid,'currency',x->>'currency','lines',x->'lines','meta',x->'invoice','terms',terms,'expected',(x->'membership'->>'expected')::bigint,'prices',x->'membership'->'prices'));
   elsif x ? 'invoice' then same:=same and invoice_payload=jsonb_build_object('branch',(x->>'branch')::uuid,'currency',x->>'currency','items',x->'lines','meta',x->'invoice','terms',terms);else same:=same and invoice_payload is null;end if;
  end if;
 end case;
 if found_record and coalesce(same,false) then return 'confirmed';end if;
 if found_record then
  if mode<>'acknowledge' then return 'conflict';end if;
  insert into tenant_private.receivable_resolutions values(s,u,r,k,'conflict_acknowledged',now());return 'conflict_acknowledged';
 end if;
 if mode<>'cancel' then return 'not_recorded';end if;
 insert into tenant_private.receivable_resolutions values(s,u,r,k,'cancelled',now());return 'cancelled';
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
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_debt_payments','tenant_private.standalone_payment_allocations','tenant_private.receivable_grants','tenant_private.receivable_resolutions','tenant_private.membership_rates','tenant_private.membership_directory','tenant_private.buyer_product_prices','tenant_private.product_tier_prices','tenant_private.local_membership_terms','tenant_private.local_customer_prices','tenant_private.local_membership_sales'] loop
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
