begin;
alter table public.ts_staff_capabilities drop constraint ts_staff_capabilities_capability_check;
alter table public.ts_staff_capabilities add constraint ts_staff_capabilities_capability_check check(capability in ('invoice_sale','invoice_repair','receipt','repair_intake','supplier_read','inventory_write','purchase_write','supplier_write','orders_write','repair_write','warranty_write','debt_write','installment_write','used_write','stock_read','customers_read','orders_read','repairs_read','warranty_read','debt_read','installment_read','used_read','purchase_read','inventory_read','returns_read','notifications_read','loyalty_read'));
create or replace function techstore_private.guard_legacy_write(p_actor uuid,p_old jsonb,p_new jsonb) returns void language plpgsql security definer set search_path='' as $$
declare r text; k text; cap text; allowed text[]; before_rows jsonb; after_rows jsonb;
begin
 select role into r from public.ts_profiles where user_id=p_actor and active;
 if r is null then raise exception 'Inactive account' using errcode='42501';end if;
 if coalesce(p_old->'records'->'returns','[]') is distinct from coalesce(p_new->'records'->'returns','[]') then raise exception 'Use integrated return workflow';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(p_old->'records'->'loyalty','[]')) old_row where not exists(select 1 from jsonb_array_elements(coalesce(p_new->'records'->'loyalty','[]')) new_row where new_row=old_row)) then raise exception 'Existing loyalty entries cannot be changed';end if;
 if r='admin' then return;end if;
 allowed:=case r when 'cashier' then array['orders','repairs','warranty','debts','installments','payments','notifications','loyalty','returns'] when 'stock' then array['suppliers','inventory','used'] when 'tech' then array['repairs','warranty','notifications'] when 'customer' then array['orders','notifications'] else array[]::text[] end;
 for k in select key from jsonb_object_keys(coalesce(p_old->'records','{}')||coalesce(p_new->'records','{}')) key loop
 before_rows:=coalesce(p_old->'records'->k,'[]');after_rows:=coalesce(p_new->'records'->k,'[]');
 if before_rows is not distinct from after_rows then continue;end if;
 if not(k=any(allowed)) then raise exception 'Record permission denied: %',k using errcode='42501';end if;
 cap:=case k when 'orders' then 'orders_write' when 'repairs' then 'repair_write' when 'warranty' then 'warranty_write' when 'inventory' then 'inventory_write' when 'suppliers' then 'supplier_write' when 'used' then 'used_write' when 'debts' then 'debt_write' when 'installments' then 'installment_write' else null end;
 if cap is not null and r<>'customer' and not techstore_private.staff_allowed(p_actor,cap) then raise exception 'Operation permission denied: %',cap using errcode='42501';end if;
 if k='returns' then raise exception 'Use integrated return workflow';end if;
 if k='orders' and r='customer' then raise exception 'Use integrated customer checkout';end if;
 end loop;
 if (coalesce(p_old->'data','{}')-'products'-'stockMoves'-'sales') is distinct from (coalesce(p_new->'data','{}')-'products'-'stockMoves'-'sales') then raise exception 'Workspace edit denied' using errcode='42501';end if;
 if coalesce(p_old->'data'->'products','[]') is distinct from coalesce(p_new->'data'->'products','[]') then
 if r='stock' and not techstore_private.staff_allowed(p_actor,'inventory_write') or r='cashier' and not techstore_private.staff_allowed(p_actor,'orders_write') or r not in ('stock','cashier') then raise exception 'Stock permission denied' using errcode='42501';end if;
 end if;
end $$;

create function techstore_private.read_workspace(p_path text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w jsonb; rec jsonb; d jsonb; k text; cap text; roles text[]; result jsonb;
begin
 if techstore_private.live_session() is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found then raise exception 'Access denied' using errcode='42501';end if;
 if p_path='me' then return jsonb_build_object('id',u.user_id,'email',u.email,'name',u.name,'role',u.role);end if;
 if p_path='customers' then
 if u.role not in ('admin','cashier','tech') or (u.role<>'admin' and not techstore_private.staff_allowed(u.user_id,'customers_read')) then raise exception 'Customer read denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',p.user_id,'name',p.name,'email',p.email) order by p.name,p.user_id) from public.ts_profiles p where p.active and p.role='customer'),'[]');
 end if;
 select payload into w from public.ts_workspace where id=1;rec:=coalesce(w->'records','{}');d:=coalesce(w->'data','{}');
 if p_path='stock' then
 if u.role not in ('admin','cashier','stock') or (u.role<>'admin' and not techstore_private.staff_allowed(u.user_id,'stock_read')) then raise exception 'Stock read denied' using errcode='42501';end if;
 return jsonb_build_object('products',coalesce((select jsonb_agg(jsonb_build_object('id',p->'id','name',p->'name','sku',p->'sku','qty',p->'qty','price',p->'price')||case when u.role='cashier' then '{}'::jsonb else jsonb_build_object('cost',p->'cost') end) from jsonb_array_elements(coalesce(d->'products','[]')) p),'[]'),
 'sales',case when u.role='stock' or (u.role='cashier' and not techstore_private.staff_allowed(u.user_id,'orders_read')) then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id',s->'id','number',s->'number','items',coalesce((select jsonb_agg(jsonb_build_object('id',i->'id','name',i->'name','qty',i->'qty','price',i->'price')) from jsonb_array_elements(coalesce(s->'items','[]')) i),'[]'))) from jsonb_array_elements(coalesce(d->'sales','[]')) s),'[]') end);
 end if;
 if p_path='account' then
 return jsonb_build_object('user',jsonb_build_object('id',u.user_id,'email',u.email,'name',u.name,'role',u.role),
 'points',coalesce((select sum((x->>'points')::bigint) from jsonb_array_elements(coalesce(rec->'loyalty','[]')) x where x->>'owner'=u.user_id::text),0),
 'orders',coalesce((select jsonb_agg(jsonb_build_object('id',x->'id','status',x->'status','total',x->'total','created',x->'created')) from jsonb_array_elements(coalesce(rec->'orders','[]')) x where x->>'owner'=u.user_id::text),'[]'),
 'repairs',coalesce((select jsonb_agg(jsonb_build_object('id',x->'id','device',x->'device','status',x->'status','estimate',x->'estimate','created',x->'created')) from jsonb_array_elements(coalesce(rec->'repairs','[]')) x where x->>'customerId'=u.user_id::text),'[]'),
 'warranties',coalesce((select jsonb_agg(jsonb_build_object('id',x->'id','device',x->'device','serial',x->'serial','start',x->'start','end',x->'end','months',x->'months')) from jsonb_array_elements(coalesce(rec->'warranty','[]')) x where x->>'owner'=u.user_id::text),'[]'),
 'notifications',coalesce((select jsonb_agg(jsonb_build_object('id',x->'id','title',x->'title','body',x->'body','created',x->'created')) from jsonb_array_elements(coalesce(rec->'notifications','[]')) x where x->>'owner'=u.user_id::text),'[]'));
 end if;
 if p_path is null or p_path not like 'records/%' then raise exception 'Unknown read';end if;
 k:=substring(p_path from 9);
 roles:=case k when 'suppliers' then array['admin','stock'] when 'purchases' then array['admin','stock'] when 'debts' then array['admin','cashier'] when 'installments' then array['admin','cashier'] when 'inventory' then array['admin','stock'] when 'used' then array['admin','stock'] when 'returns' then array['admin','cashier'] when 'repairs' then array['admin','tech','cashier'] when 'offers' then array['admin'] when 'coupons' then array['admin'] when 'media' then array['admin'] when 'draft' then array['admin'] when 'versions' then array['admin'] when 'notifications' then array['admin','cashier','tech'] when 'orders' then array['admin','cashier'] when 'loyalty' then array['admin','cashier'] when 'warranty' then array['admin','cashier','tech'] else array[]::text[] end;
 cap:=case k when 'suppliers' then 'supplier_read' when 'purchases' then 'purchase_read' when 'debts' then 'debt_read' when 'installments' then 'installment_read' when 'inventory' then 'inventory_read' when 'used' then 'used_read' when 'returns' then 'returns_read' when 'repairs' then 'repairs_read' when 'notifications' then 'notifications_read' when 'orders' then 'orders_read' when 'loyalty' then 'loyalty_read' when 'warranty' then 'warranty_read' else null end;
 if not(u.role=any(roles)) or (u.role<>'admin' and cap is not null and not techstore_private.staff_allowed(u.user_id,cap)) then raise exception 'Record read denied' using errcode='42501';end if;
 result:=coalesce(rec->k,'[]');
 if k='orders' and u.role='cashier' then
 select coalesce(jsonb_agg((x-'cost')||jsonb_build_object('items',coalesce((select jsonb_agg(i-'cost') from jsonb_array_elements(coalesce(x->'items','[]')) i),'[]'))),'[]') into result from jsonb_array_elements(result) x;
 elsif k='returns' and u.role='cashier' then
 select coalesce(jsonb_agg(jsonb_build_object('id',x->'id','name',x->'name','qty',x->'qty','created',x->'created','refund',x->'refund','sale',x->'sale','product',x->'product','reason',x->'reason')),'[]') into result from jsonb_array_elements(result) x;
 end if;
 return result;
end $$;
revoke all on function techstore_private.read_workspace(text) from public,anon,authenticated;
grant execute on function techstore_private.read_workspace(text) to authenticated;
create function public.ts_read_workspace(p_path text) returns jsonb language sql stable security invoker set search_path='' as $$ select techstore_private.read_workspace(p_path) $$;
revoke all on function public.ts_read_workspace(text) from public,anon,authenticated;
grant execute on function public.ts_read_workspace(text) to authenticated;
commit;