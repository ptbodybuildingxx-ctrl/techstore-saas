begin;
create table public.ts_sync_receipts(
 request_id uuid primary key,
 actor uuid not null references public.ts_profiles(user_id),
 kind text not null check(kind in ('pos','count','transfer','sale')),
 args jsonb not null,
 result jsonb not null,
 created_at timestamptz not null default now()
);
alter table public.ts_sync_receipts enable row level security;
revoke all on public.ts_sync_receipts from public,anon,authenticated;
create function techstore_private.sync_operation(p_action text,p_args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; prior public.ts_sync_receipts%rowtype;
 req uuid; pid text; k text; q bigint; src uuid; dst uuid; prod jsonb; ix int; central bigint; actual bigint; actual_dst bigint; price_value numeric; cost_value numeric; expected bigint; expected_dst bigint; expected_price numeric; result jsonb; data_value jsonb; records_value jsonb; sale_id uuid; sale jsonb; delta bigint; amount numeric;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found or u.role not in ('admin','cashier','stock') then raise exception 'Access denied' using errcode='42501';end if;
 if p_action not in ('snapshot','apply') or jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>12000 then raise exception 'Invalid request';end if;
 select * into w from public.ts_workspace where id=1 for update;
 if p_action='snapshot' then
 return jsonb_build_object('role',u.role,'revision',w.revision,'captured_at',now(),
 'products',coalesce((select jsonb_agg(jsonb_build_object('id',p->>'id','name',left(p->>'name',200),'sku',left(p->>'sku',100),'qty',p->'qty','price',p->'price')) from jsonb_array_elements(coalesce(w.payload->'data'->'products','[]'::jsonb)) p),'[]'::jsonb),
 'branches',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title)) from public.ts_pro_entries where kind='branches' and not archived),'[]'::jsonb) else '[]'::jsonb end,
 'stock',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('branch_id',branch_id,'product_id',product_id,'qty',qty)) from public.ts_branch_stock),'[]'::jsonb) else '[]'::jsonb end);
 end if;
 req:=(p_args->>'request_id')::uuid;k:=p_args->>'kind';pid:=p_args->>'product';q:=(p_args->>'qty')::bigint;src:=nullif(p_args->>'from','')::uuid;dst:=nullif(p_args->>'to','')::uuid;
 if req is null or pid is null or length(pid)>200 or q is null or q<0 or q>1000000 or k not in ('pos','count','transfer','sale') then raise exception 'Invalid operation';end if;
 if (k='pos' and u.role not in ('admin','cashier')) or (k='count' and u.role not in ('admin','stock')) or (k in ('transfer','sale') and u.role<>'admin') then raise exception 'Access denied' using errcode='42501';end if;
 if k<>'count' and q=0 then raise exception 'Quantity must be positive';end if;
 if k in ('pos','count') and (src is not null or dst is not null) then raise exception 'Central operation only';end if;
 if k='sale' and (src is null or dst is not null) then raise exception 'Invalid branch sale';end if;
 if k='transfer' and src is not distinct from dst then raise exception 'Different locations required';end if;
 select * into prior from public.ts_sync_receipts where request_id=req;
 if found then if prior.actor<>u.user_id or prior.kind<>k or prior.args is distinct from p_args then raise exception 'Request ID conflict';end if;return prior.result||jsonb_build_object('duplicate',true);end if;
 data_value:=w.payload->'data';records_value:=coalesce(w.payload->'records','{}'::jsonb);
 select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(data_value->'products','[]'::jsonb)) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null then return jsonb_build_object('status','conflict','reason','product_missing');end if;
 if src is not null and not exists(select 1 from public.ts_pro_entries where id=src and kind='branches' and not archived) then return jsonb_build_object('status','conflict','reason','source_closed');end if;
 if dst is not null and not exists(select 1 from public.ts_pro_entries where id=dst and kind='branches' and not archived) then return jsonb_build_object('status','conflict','reason','destination_closed');end if;
 central:=(prod->>'qty')::bigint;price_value:=(prod->>'price')::numeric;cost_value:=(prod->>'cost')::numeric;
 actual:=case when src is null then central else coalesce((select qty from public.ts_branch_stock where branch_id=src and product_id=pid),0) end;
 actual_dst:=case when dst is null then central else coalesce((select qty from public.ts_branch_stock where branch_id=dst and product_id=pid),0) end;
 expected:=(p_args->>'expected_qty')::bigint;expected_dst:=(p_args->>'expected_dst_qty')::bigint;expected_price:=(p_args->>'expected_price')::numeric;
 if actual is distinct from expected or (k='transfer' and actual_dst is distinct from expected_dst) or (k in ('pos','sale') and price_value is distinct from expected_price) or (k<>'count' and actual<q) then
 return jsonb_build_object('status','conflict','reason','stock_or_price_changed','actual_qty',actual,'actual_dst_qty',actual_dst,'actual_price',price_value);
 end if;
 if k in ('transfer','sale') then
 result:=techstore_private.branch_operation(k,jsonb_build_object('request_id',req,'from',coalesce(src::text,''),'to',coalesce(dst::text,''),'product',pid,'qty',q));
 else
 sale_id:=gen_random_uuid();delta:=case when k='pos' then -q else q-central end;
 data_value:=jsonb_set(data_value,array['products',ix::text,'qty'],to_jsonb(central+delta));
 data_value:=jsonb_set(data_value,'{stockMoves}',coalesce(data_value->'stockMoves','[]'::jsonb)||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',pid,'name',prod->>'name','qty',delta,'reason','offline sync '||k,'date',current_date)),true);
 if k='pos' then
 amount:=round(price_value*q,2);sale:=jsonb_build_object('id',sale_id,'number','POS-'||sale_id::text,'date',current_date,'customer','','payment','cash','paid',true,'items',jsonb_build_array(jsonb_build_object('id',pid,'name',prod->>'name','qty',q,'price',price_value,'cost',cost_value)),'total',amount,'cost',round(cost_value*q,2));
 data_value:=jsonb_set(data_value,'{sales}',coalesce(data_value->'sales','[]'::jsonb)||jsonb_build_array(sale),true);
 else
 amount:=0;records_value:=jsonb_set(records_value,'{inventory}',jsonb_build_array(jsonb_build_object('id',sale_id,'owner',null,'created',now(),'product',pid,'name',prod->>'name','before',central,'qty',q,'delta',delta,'barcode',coalesce(prod->>'sku',pid)))||coalesce(records_value->'inventory','[]'::jsonb),true);
 end if;
 update public.ts_workspace set payload=jsonb_set(jsonb_set(w.payload,'{data}',data_value),'{records}',records_value),revision=revision+1,updated_at=now() where id=1;
 result:=jsonb_build_object('id',sale_id,'amount',amount);
 end if;
 result:=result||jsonb_build_object('status','applied');
 insert into public.ts_sync_receipts(request_id,actor,kind,args,result) values(req,u.user_id,k,p_args,result);
 insert into public.ts_audit(actor,action) values(u.user_id,'offline sync '||k||' '||req::text);
 return result;
end $$;
revoke all on function techstore_private.sync_operation(text,jsonb) from public,anon;
grant execute on function techstore_private.sync_operation(text,jsonb) to authenticated;
create function public.ts_sync_operation(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.sync_operation(p_action,p_args); $$;
revoke all on function public.ts_sync_operation(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_sync_operation(text,jsonb) to authenticated;
commit;