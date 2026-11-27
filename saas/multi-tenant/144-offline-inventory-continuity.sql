-- 144: encrypted inventory snapshot support, reviewed catalog/pricing, terminal receipts and typed dependencies.
begin;
create function tenant_private.offline_inventory_page(s uuid,d uuid,secret uuid,after_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;customer_read boolean;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 if tenant_private.member_role(s) is distinct from 'owner' or not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Owner catalog access required' using errcode='42501';end if;
 customer_read:=tenant_private.central_read_permitted(s,'all_customer_read');
 select coalesce(jsonb_agg(x.row_data order by x.id),'[]'::jsonb) into result from (
 select p.id,jsonb_build_object(
 'catalog',c.item,'digest',tenant_private.finance_review_digest(c.item),
 'retail',coalesce((select jsonb_agg(jsonb_build_object('currency',currency,'price',price_minor) order by currency) from public.mt_product_prices where store_id=s and product_id=p.id),'[]'),
 'tiers',coalesce((select jsonb_agg(jsonb_build_object('subject',tier,'currency',currency,'price',price_minor,'min',min_units) order by tier,currency) from tenant_private.product_tier_prices where store_id=s and product_id=p.id),'[]'),
 'customers',case when customer_read then coalesce((select jsonb_agg(jsonb_build_object('subject',customer_id,'currency',currency,'price',price_minor,'min',min_units) order by customer_id,currency) from tenant_private.local_customer_prices where store_id=s and product_id=p.id),'[]') else null end,
 'buyers',case when customer_read then coalesce((select jsonb_agg(jsonb_build_object('subject',buyer,'currency',currency,'price',price_minor,'min',min_units) order by buyer,currency) from tenant_private.buyer_product_prices where store_id=s and product_id=p.id),'[]') else null end) row_data
 from (select id from public.mt_products where store_id=s and (after_id is null or id>after_id) order by id limit 5)p
 cross join lateral (select tenant_private.catalog_item(s,p.id) item)c
 )x;
 return result;
end $$;

create function tenant_private.offline_inventory_write(s uuid,d uuid,secret uuid,op jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare req uuid;k text;pid uuid;old tenant_private.offline_reviewed_requests%rowtype;res jsonb;item jsonb;desired jsonb;expected jsonb;actual jsonb;cur text;subject text;price bigint;minimum integer;enabled boolean;rid uuid;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Catalog denied' using errcode='42501';end if;
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>300000 or (op->>'store')::uuid is distinct from s then raise exception 'Invalid inventory payload' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;k:=op->>'kind';pid:=(op->>'product')::uuid;
 if req is null or pid is null or k is null or k not in ('catalogEdit','retailPrice','tierPrice','customerPrice','buyerPrice') then raise exception 'Invalid inventory action' using errcode='22023';end if;
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
  return old.result;
 end if;
 if k='catalogEdit' then
  if tenant_private.central_action_denied(s,'product_profile_edit') then raise exception 'Product edit denied' using errcode='42501';end if;
  desired:=op->'desired';
  if op->>'digest' is null or op->>'digest' !~ '^[a-f0-9]{64}$' or jsonb_typeof(desired) is distinct from 'object' then raise exception 'Review required' using errcode='22023';end if;
  perform 1 from public.mt_products where store_id=s and id=pid for update;
  if not found then res:=jsonb_build_object('status','conflict','requestId',req,'current','missing');
  else
   item:=tenant_private.catalog_item(s,pid);
   if tenant_private.finance_review_digest(item) is distinct from op->>'digest' then res:=jsonb_build_object('status','conflict','requestId',req,'current',tenant_private.finance_review_digest(item));
   else
    rid:=public.mt_catalog_save(s,req,pid,desired->>'name',desired->>'sku',desired->'profile',desired->'specs',(desired->>'listed')::boolean,null,null);
    if rid is distinct from pid then raise exception 'Catalog unconfirmed';end if;
   end if;
  end if;
 else
  if tenant_private.central_action_denied(s,'product_price_change') then raise exception 'Price edit denied' using errcode='42501';end if;
  cur:=op->>'currency';subject:=op->>'subject';expected:=nullif(op->'expected','null'::jsonb);desired:=nullif(op->'desired','null'::jsonb);
  if not (op ?& array['expected','desired']) or cur is null or cur not in ('USD','SYP','EUR') then raise exception 'Invalid price review' using errcode='22023';end if;
  if k in ('customerPrice','buyerPrice') and not tenant_private.central_read_permitted(s,'all_customer_read') then raise exception 'Customer access denied' using errcode='42501';end if;
  perform 1 from public.mt_products where store_id=s and id=pid for update;
  if not found then res:=jsonb_build_object('status','conflict','requestId',req,'current','missing');
  else
   if k='retailPrice' then
    select jsonb_build_object('price',price_minor) into actual from public.mt_product_prices where store_id=s and product_id=pid and currency=cur;
   elsif k='tierPrice' then
    if subject is null or subject not in ('standard','member','silver','gold','vip','wholesale') then raise exception 'Invalid tier' using errcode='22023';end if;
    select jsonb_build_object('price',price_minor,'min',min_units) into actual from tenant_private.product_tier_prices where store_id=s and product_id=pid and tier=subject and currency=cur;
   elsif k='customerPrice' then
    if subject is null or not exists(select 1 from public.mt_customers where store_id=s and id=subject::uuid) then raise exception 'Invalid customer' using errcode='22023';end if;
    select jsonb_build_object('price',price_minor,'min',min_units) into actual from tenant_private.local_customer_prices where store_id=s and product_id=pid and customer_id=subject::uuid and currency=cur;
   else
    if subject is null or not tenant_private.known_membership_buyer(s,subject::uuid) then raise exception 'Invalid buyer' using errcode='22023';end if;
    select jsonb_build_object('price',price_minor,'min',min_units) into actual from tenant_private.buyer_product_prices where store_id=s and product_id=pid and buyer=subject::uuid and currency=cur;
   end if;
   if actual is distinct from expected then res:=jsonb_build_object('status','conflict','requestId',req,'current',actual);
   else
    enabled:=desired is not null;
    price:=(desired->>'price')::bigint;minimum:=(desired->>'min')::integer;
    if enabled and (price is null or price not between 1 and 100000000 or k<>'retailPrice' and (minimum is null or minimum not between 1 and 100)) then raise exception 'Invalid special price' using errcode='22023';end if;
    if k='retailPrice' then
     if not enabled then raise exception 'Retail removal not supported' using errcode='22023';end if;
     if public.mt_set_currency_price(s,pid,cur,price) is distinct from price then raise exception 'Price unconfirmed';end if;
    elsif k='tierPrice' then
     if public.mt_product_tier_set(s,pid,subject,cur,price,minimum,enabled) is distinct from enabled then raise exception 'Tier unconfirmed';end if;
    elsif k='customerPrice' then
     if public.mt_local_customer_price_set(s,subject::uuid,pid,cur,price,minimum,enabled) is distinct from enabled then raise exception 'Customer price unconfirmed';end if;
    else
     if public.mt_buyer_product_price_set(s,subject::uuid,pid,cur,price,minimum,enabled) is distinct from enabled then raise exception 'Buyer price unconfirmed';end if;
    end if;
   end if;
  end if;
 end if;
 if res is null then res:=jsonb_build_object('status','confirmed','requestId',req,'resultId',pid);end if;
 insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,res);
 return res;
end $$;

-- Only validation/constraint rejections are terminal. Permission, connectivity, deadlock,
-- and unexpected errors are not translated into success or cancellation.
create function tenant_private.offline_dispatch_v2(s uuid,d uuid,secret uuid,req uuid,method text,args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;payload jsonb;old tenant_private.offline_reviewed_requests%rowtype;
begin
 if tenant_private.member_role(s) is null then raise exception 'Membership required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=s for update;
 perform tenant_private.offline_device_require(s,d,secret);
 if req is null or method is null or jsonb_typeof(args) is distinct from 'object' or octet_length(args::text)>100000 or (args->>'p_store')::uuid is distinct from s then raise exception 'Invalid dispatch' using errcode='22023';end if;
 payload:=jsonb_build_object('method',method,'args',args);
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from payload then raise exception 'Request identity conflict' using errcode='22023';end if;
  result:=old.result;
 else
  begin
   result:=tenant_private.offline_dispatch(s,d,secret,req,method,args);
  exception when sqlstate '22023' or unique_violation or check_violation or foreign_key_violation then
   result:=jsonb_build_object('offline_terminal',true,'status','conflict','requestId',req,'code',SQLSTATE);
   insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,payload,result);
  end;
 end if;
 if result->>'offline_terminal'='true' then return result;end if;
 return jsonb_build_object('status','confirmed','requestId',req,'value',result);
end $$;

create function tenant_private.offline_review_v2(s uuid,d uuid,secret uuid,op jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;req uuid;old tenant_private.offline_reviewed_requests%rowtype;
begin
 perform tenant_private.owner_write(s);
 perform tenant_private.offline_device_require(s,d,secret);
 if jsonb_typeof(op) is distinct from 'object' or octet_length(op::text)>300000 or (op->>'store')::uuid is distinct from s then raise exception 'Invalid operation' using errcode='22023';end if;
 req:=(op->>'requestId')::uuid;if req is null then raise exception 'Request required' using errcode='22023';end if;
 select * into old from tenant_private.offline_reviewed_requests where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.device_id<>d or old.payload is distinct from op then raise exception 'Request identity conflict' using errcode='22023';end if;
  return old.result;
 end if;
 begin
  if op->>'kind' in ('catalogEdit','retailPrice','tierPrice','customerPrice','buyerPrice') then result:=tenant_private.offline_inventory_write(s,d,secret,op);
  else result:=tenant_private.offline_reviewed_write(s,d,secret,op);end if;
 exception when sqlstate '22023' or unique_violation or check_violation or foreign_key_violation then
  result:=jsonb_build_object('offline_terminal',true,'status','conflict','requestId',req,'code',SQLSTATE);
  insert into tenant_private.offline_reviewed_requests(store_id,request_id,actor,device_id,payload,result) values(s,req,auth.uid(),d,op,result);
 end;
 return result;
end $$;

create function tenant_private.offline_receipt(s uuid,d uuid,secret uuid,req uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare x tenant_private.offline_reviewed_requests%rowtype;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 select * into x from tenant_private.offline_reviewed_requests where store_id=s and request_id=req and actor=auth.uid() and device_id=d;
 if not found then return jsonb_build_object('status','unknown','requestId',req);end if;
 return jsonb_build_object('status',case when x.result->>'status'='conflict' then 'conflict' else 'confirmed' end,'requestId',req,'recorded_at',x.created_at);
end $$;

-- Typed dependency references: only a confirmed creation by the same live account.
-- A second approved installation of that account can use the creation receipt.
create function tenant_private.offline_dependency(s uuid,d uuid,secret uuid,parent uuid,entity text) returns uuid
language plpgsql security definer set search_path='' as $$
declare x tenant_private.offline_reviewed_requests%rowtype;rid uuid;method text;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 if entity is null or entity not in ('product','customer','supplier','repair','purchase') then raise exception 'Invalid dependency' using errcode='22023';end if;
 select * into x from tenant_private.offline_reviewed_requests where store_id=s and request_id=parent and actor=auth.uid();
 if not found or x.result->>'status'='conflict' then return null;end if;
 method:=x.payload->>'method';
 if entity='product' and x.payload->>'kind'='catalogCreate' then
  if not tenant_private.central_read_permitted(s,'all_catalog_read') then raise exception 'Catalog denied' using errcode='42501';end if;
  select (result->>'id')::uuid into rid from tenant_private.catalog_requests where store_id=s and request_id=parent and actor=auth.uid();
 elsif entity='customer' and method='mt_add_customer' then
  if not tenant_private.central_read_permitted(s,'all_customer_read') then raise exception 'Customer denied' using errcode='42501';end if;
  if jsonb_typeof(x.result)='string' then rid:=(x.result#>>'{}')::uuid;end if;
 elsif entity='supplier' and (method='mt_add_supplier' or method='mt_supplier_save' and x.payload#>>'{args,p_supplier}' is null) then
  if not tenant_private.central_read_permitted(s,'all_supplier_read') then raise exception 'Supplier denied' using errcode='42501';end if;
  if jsonb_typeof(x.result)='string' then rid:=(x.result#>>'{}')::uuid;end if;
 elsif entity='repair' and method in ('mt_add_repair','mt_branch_add_repair') then
  if not tenant_private.central_read_permitted(s,'all_repair_read') then raise exception 'Repair denied' using errcode='42501';end if;
  if jsonb_typeof(x.result)='string' then rid:=(x.result#>>'{}')::uuid;end if;
 elsif entity='purchase' and method in ('mt_purchase','mt_branch_purchase') then
  if not tenant_private.central_read_permitted(s,'all_purchase_read') then raise exception 'Purchase denied' using errcode='42501';end if;
  if jsonb_typeof(x.result)='string' then rid:=(x.result#>>'{}')::uuid;end if;
 end if;
 return rid;
end $$;

create function public.mt_offline_inventory_page(s uuid,d uuid,secret uuid,after_id uuid) returns jsonb language sql set search_path='' as $$select tenant_private.offline_inventory_page(s,d,secret,after_id)$$;
create function public.mt_offline_dispatch_v2(s uuid,d uuid,secret uuid,req uuid,method text,args jsonb) returns jsonb language sql set search_path='' as $$select tenant_private.offline_dispatch_v2(s,d,secret,req,method,args)$$;
create function public.mt_offline_review_v2(s uuid,d uuid,secret uuid,op jsonb) returns jsonb language sql set search_path='' as $$select tenant_private.offline_review_v2(s,d,secret,op)$$;
create function public.mt_offline_receipt(s uuid,d uuid,secret uuid,req uuid) returns jsonb language sql set search_path='' as $$select tenant_private.offline_receipt(s,d,secret,req)$$;
create function public.mt_offline_dependency(s uuid,d uuid,secret uuid,parent uuid,entity text) returns uuid language sql set search_path='' as $$select tenant_private.offline_dependency(s,d,secret,parent,entity)$$;
revoke all on function tenant_private.offline_inventory_page(uuid,uuid,uuid,uuid),tenant_private.offline_inventory_write(uuid,uuid,uuid,jsonb),tenant_private.offline_dispatch_v2(uuid,uuid,uuid,uuid,text,jsonb),tenant_private.offline_review_v2(uuid,uuid,uuid,jsonb),tenant_private.offline_receipt(uuid,uuid,uuid,uuid),tenant_private.offline_dependency(uuid,uuid,uuid,uuid,text),public.mt_offline_inventory_page(uuid,uuid,uuid,uuid),public.mt_offline_dispatch_v2(uuid,uuid,uuid,uuid,text,jsonb),public.mt_offline_review_v2(uuid,uuid,uuid,jsonb),public.mt_offline_receipt(uuid,uuid,uuid,uuid),public.mt_offline_dependency(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_inventory_page(uuid,uuid,uuid,uuid),tenant_private.offline_dispatch_v2(uuid,uuid,uuid,uuid,text,jsonb),tenant_private.offline_review_v2(uuid,uuid,uuid,jsonb),tenant_private.offline_receipt(uuid,uuid,uuid,uuid),tenant_private.offline_dependency(uuid,uuid,uuid,uuid,text),public.mt_offline_inventory_page(uuid,uuid,uuid,uuid),public.mt_offline_dispatch_v2(uuid,uuid,uuid,uuid,text,jsonb),public.mt_offline_review_v2(uuid,uuid,uuid,jsonb),public.mt_offline_receipt(uuid,uuid,uuid,uuid),public.mt_offline_dependency(uuid,uuid,uuid,uuid,text) to authenticated;
commit;
