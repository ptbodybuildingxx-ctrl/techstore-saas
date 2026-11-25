begin;
create or replace function techstore_private.guest_request(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.ts_workspace%rowtype; g public.ts_guest_requests%rowtype; token_value uuid; hash_value text; customer_value text; phone_value text; normalized text; address_value text; pid text; q int; line jsonb; prod jsonb; items_value jsonb:='[]'; order_items jsonb:='[]'; total_value numeric:=0; cost_value numeric:=0; data_value jsonb; record_value jsonb; order_value jsonb; order_ref uuid; ix int; seen text[]:='{}';
begin
 if p_args is null or jsonb_typeof(p_args)<>'object' or octet_length(p_args::text)>24000 then raise exception 'Invalid request';end if;
 if p_action='list' or p_action='review' then
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role in ('admin','cashier')) then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='review' and exists(select 1 from public.ts_profiles where user_id=auth.uid() and role='cashier') and not techstore_private.staff_allowed(auth.uid(),'orders_write') then raise exception 'Order review permission denied' using errcode='42501';end if;
 if p_action='list' then return coalesce((select jsonb_agg(to_jsonb(r)-'tracking_hash') from (select * from public.ts_guest_requests order by created_at desc limit 200) r),'[]'::jsonb);end if;
 select * into w from public.ts_workspace where id=1 for update;
 select * into g from public.ts_guest_requests where id=(p_args->>'id')::uuid for update;
 if not found or g.status<>'awaiting_review' then raise exception 'Request already reviewed or missing';end if;
 if p_args->>'decision'='reject' then update public.ts_guest_requests set status='cancelled',reviewed_at=now() where id=g.id;insert into public.ts_audit(actor,action) values(auth.uid(),'guest request rejected '||g.id);return jsonb_build_object('id',g.id,'status','cancelled');end if;
 if p_args->>'decision' is distinct from 'accept' or p_args->'contact_confirmed' is distinct from 'true'::jsonb then raise exception 'Confirm customer contact first';end if;
 data_value:=w.payload->'data';
 if data_value->'owner'->>'maintenance'='true' then raise exception 'Store closed';end if;
 for line in select value from jsonb_array_elements(g.items) loop
 pid:=line->>'id';q:=(line->>'qty')::int;
 select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(data_value->'products','[]'::jsonb)) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null or prod->>'hidden'='true' or (coalesce(data_value->'owner'->'hiddenCategories','[]'::jsonb) ? coalesce(prod->>'type','')) or (prod->>'qty')::int<q or (prod->>'price')::numeric is distinct from (line->>'price')::numeric then raise exception 'Stock or price changed; contact customer';end if;
 cost_value:=cost_value+q*(prod->>'cost')::numeric;
 order_items:=order_items||jsonb_build_array(line||jsonb_build_object('cost',(prod->>'cost')::numeric));
 data_value:=jsonb_set(data_value,array['products',ix::text,'qty'],to_jsonb((prod->>'qty')::int-q));
 end loop;
 order_ref:=gen_random_uuid(); order_value:=jsonb_build_object('id',order_ref,'owner',null,'created',now(),'customer',g.customer,'phone',g.phone,'address',g.address,'items',order_items,'total',g.total,'cost',cost_value,'discount',0,'status','confirmed','payment','cod');
 record_value:=coalesce(w.payload->'records','{}'::jsonb);record_value:=jsonb_set(record_value,'{orders}',jsonb_build_array(order_value)||coalesce(record_value->'orders','[]'::jsonb));
 update public.ts_workspace set payload=jsonb_set(jsonb_set(w.payload,'{data}',data_value),'{records}',record_value),revision=revision+1,updated_at=now() where id=1;
 update public.ts_guest_requests set status='accepted',order_id=order_ref::text,reviewed_at=now() where id=g.id;
 insert into public.ts_audit(actor,action) values(auth.uid(),'guest request accepted '||g.id);
 return jsonb_build_object('id',g.id,'status','accepted','order_id',order_ref);
 end if;
 if p_action not in ('submit','status') then raise exception 'Invalid action';end if;
 token_value:=(p_args->>'token')::uuid;if token_value is null then raise exception 'Invalid tracking code';end if;
 hash_value:=encode(extensions.digest(token_value::text,'sha256'),'hex');
 select * into g from public.ts_guest_requests where tracking_hash=hash_value;
 if found then
  if g.order_id is not null then select r into order_value from public.ts_workspace w0 cross join lateral jsonb_array_elements(coalesce(w0.payload->'records'->'orders','[]'::jsonb)) r where w0.id=1 and r->>'id'=g.order_id;end if;
  return jsonb_build_object('id',g.id,'status',coalesce(order_value->>'status',g.status),'total',g.total);
 end if;
 if p_action='status' then raise exception 'Request not found';end if;
 customer_value:=btrim(coalesce(p_args->>'customer',''));phone_value:=btrim(coalesce(p_args->>'phone',''));normalized:=regexp_replace(phone_value,'[^0-9]','','g');address_value:=btrim(coalesce(p_args->>'address',''));
 if length(customer_value) not between 1 and 150 or length(phone_value) not between 7 and 40 or length(normalized) not between 7 and 18 or length(address_value) not between 1 and 500 or p_args->'consent' is distinct from 'true'::jsonb then raise exception 'Valid name, phone, address and consent required';end if;
 if jsonb_typeof(p_args->'items') is distinct from 'array' then raise exception 'Invalid cart';end if;
 if jsonb_array_length(p_args->'items') not between 1 and 30 then raise exception 'Invalid cart';end if;
 select * into w from public.ts_workspace where id=1;data_value:=w.payload->'data';
 if data_value->'owner'->>'maintenance'='true' then raise exception 'Store closed';end if;
 for line in select value from jsonb_array_elements(p_args->'items') loop
 pid:=line->>'id';q:=(line->>'qty')::int;if pid is null or length(pid)>200 or q is null or q not between 1 and 20 or pid=any(seen) then raise exception 'Invalid cart item';end if;seen:=array_append(seen,pid);
 select p into prod from jsonb_array_elements(coalesce(data_value->'products','[]'::jsonb)) p where p->>'id'=pid;
 if prod is null or prod->>'hidden'='true' or (coalesce(data_value->'owner'->'hiddenCategories','[]'::jsonb) ? coalesce(prod->>'type','')) or (prod->>'qty')::int<q then raise exception 'Product unavailable';end if;
 items_value:=items_value||jsonb_build_array(jsonb_build_object('id',pid,'name',left(prod->>'name',200),'qty',q,'price',(prod->>'price')::numeric));
 total_value:=total_value+q*(prod->>'price')::numeric;
 end loop;
 if not public.ts_guest_reserve(encode(extensions.digest('guest:'||normalized,'sha256'),'hex')) then raise exception 'Too many requests';end if;
 insert into public.ts_guest_requests(tracking_hash,customer,phone,address,items,total) values(hash_value,customer_value,phone_value,address_value,items_value,round(total_value,2)) on conflict(tracking_hash) do nothing returning * into g;
 if not found then select * into g from public.ts_guest_requests where tracking_hash=hash_value;end if;
 return jsonb_build_object('id',g.id,'status',g.status,'total',g.total);
end $$;

commit;