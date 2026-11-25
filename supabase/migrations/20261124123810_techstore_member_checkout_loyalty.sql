begin;
create table public.ts_membership_rates(
 tier text primary key check(tier in ('standard','silver','gold','vip','wholesale')),
 discount_percent numeric(5,2) not null default 0 check(discount_percent between 0 and 30)
);
insert into public.ts_membership_rates(tier) values('standard'),('silver'),('gold'),('vip'),('wholesale');
create table public.ts_customer_tiers(
 user_id uuid primary key references public.ts_profiles(user_id),
 tier text not null references public.ts_membership_rates(tier),
 updated_at timestamptz not null default now()
);
create table public.ts_loyalty_config(
 id integer primary key check(id=1),
 points_per_usd integer not null default 100 check(points_per_usd between 1 and 10000),
 max_redeem_percent numeric(5,2) not null default 0 check(max_redeem_percent between 0 and 20)
);
insert into public.ts_loyalty_config(id) values(1);
create table public.ts_member_checkout_keys(
 request_id uuid primary key,user_id uuid not null references public.ts_profiles(user_id),order_id text not null
);
alter table public.ts_membership_rates enable row level security;
alter table public.ts_customer_tiers enable row level security;
alter table public.ts_loyalty_config enable row level security;
alter table public.ts_member_checkout_keys enable row level security;
revoke all on public.ts_membership_rates,public.ts_customer_tiers,public.ts_loyalty_config,public.ts_member_checkout_keys from public,anon,authenticated;
create function techstore_private.member_settings(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; tier_value text; rate_value numeric; customer_id uuid; rate_points int; max_percent numeric; cfg public.ts_loyalty_config%rowtype;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='my' and u.role='customer' then
 select coalesce((select tier from public.ts_customer_tiers where user_id=u.user_id),'standard') into tier_value;
 select discount_percent into rate_value from public.ts_membership_rates where tier=tier_value;
 select * into cfg from public.ts_loyalty_config where id=1;
 return jsonb_build_object('tier',tier_value,'discount_percent',rate_value,'points_per_usd',cfg.points_per_usd,'max_redeem_percent',cfg.max_redeem_percent);
 end if;
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='list' then return jsonb_build_object('rates',(select jsonb_agg(to_jsonb(r) order by tier) from public.ts_membership_rates r),'customers',coalesce((select jsonb_agg(jsonb_build_object('id',p.user_id,'name',p.name,'tier',coalesce(t.tier,'standard'))) from public.ts_profiles p left join public.ts_customer_tiers t on t.user_id=p.user_id where p.role='customer' and p.active),'[]'::jsonb),'config',(select to_jsonb(c) from public.ts_loyalty_config c where id=1));end if;
 -- Lock the workspace so rate updates serialize with checkout.
 perform 1 from public.ts_workspace where id=1 for update;
 if p_action='rate' then tier_value:=p_args->>'tier';rate_value:=(p_args->>'discount_percent')::numeric;update public.ts_membership_rates set discount_percent=rate_value where tier=tier_value;if not found then raise exception 'Unknown tier';end if;
 elsif p_action='assign' then customer_id:=(p_args->>'user_id')::uuid;tier_value:=p_args->>'tier';if not exists(select 1 from public.ts_profiles where user_id=customer_id and active and role='customer') then raise exception 'Unknown customer';end if;
 insert into public.ts_customer_tiers(user_id,tier) values(customer_id,tier_value) on conflict(user_id) do update set tier=excluded.tier,updated_at=now();
 elsif p_action='config' then rate_points:=(p_args->>'points_per_usd')::int;max_percent:=(p_args->>'max_redeem_percent')::numeric;update public.ts_loyalty_config set points_per_usd=rate_points,max_redeem_percent=max_percent where id=1;
 else raise exception 'Invalid action';end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'membership '||p_action);
 return jsonb_build_object('ok',true);
end $$;
revoke all on function techstore_private.member_settings(text,jsonb) from public,anon;
grant execute on function techstore_private.member_settings(text,jsonb) to authenticated;
create function public.ts_member_settings(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.member_settings(p_action,p_args); $$;
revoke all on function public.ts_member_settings(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_member_settings(text,jsonb) to authenticated;
create function techstore_private.member_checkout(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; cfg public.ts_loyalty_config%rowtype; tier_value text; member_rate numeric; coupon_rate numeric:=0; coupon_value text; coupon jsonb; pid text; q int; ix int; line jsonb; prod jsonb; seen text[]:='{}'; items_value jsonb:='[]'; data_value jsonb; records_value jsonb; subtotal numeric:=0; cost_value numeric:=0; discount numeric; total_value numeric; points_balance bigint; requested_points bigint; used_points bigint; redeem_value numeric; order_value jsonb; order_id uuid; req uuid; existing text; quote jsonb;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active and role='customer';if not found then raise exception 'Access denied' using errcode='42501';end if;
 if p_action not in ('quote','order') or jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>24000 then raise exception 'Invalid request';end if;
 select * into w from public.ts_workspace where id=1 for update;
 if p_action='order' then req:=(p_args->>'request_id')::uuid;if req is null then raise exception 'Request ID required';end if;
 select k.order_id into existing from public.ts_member_checkout_keys k where k.request_id=req and k.user_id=u.user_id;
 if found then select x into order_value from jsonb_array_elements(coalesce(w.payload->'records'->'orders','[]'::jsonb)) x where x->>'id'=existing;return jsonb_build_object('id',existing,'total',order_value->'total','duplicate',true);end if;end if;
 data_value:=w.payload->'data';records_value:=coalesce(w.payload->'records','{}'::jsonb);
 if data_value->'owner'->>'maintenance'='true' then raise exception 'Store closed';end if;
 if jsonb_typeof(p_args->'items') is distinct from 'array' or jsonb_array_length(p_args->'items') not between 1 and 30 then raise exception 'Invalid cart';end if;
 for line in select value from jsonb_array_elements(p_args->'items') loop
 pid:=line->>'id';q:=(line->>'qty')::int;
 if pid is null or length(pid)>200 or q is null or q not between 1 and 100 or pid=any(seen) then raise exception 'Invalid cart item';end if;seen:=array_append(seen,pid);
 select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(data_value->'products','[]'::jsonb)) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null or prod->>'hidden'='true' or (coalesce(data_value->'owner'->'hiddenCategories','[]'::jsonb) ? coalesce(prod->>'type','')) or (prod->>'qty')::int<q then raise exception 'Product unavailable';end if;
 subtotal:=subtotal+q*(prod->>'price')::numeric;cost_value:=cost_value+q*(prod->>'cost')::numeric;
 items_value:=items_value||jsonb_build_array(jsonb_build_object('id',pid,'name',left(prod->>'name',200),'qty',q,'price',(prod->>'price')::numeric,'cost',(prod->>'cost')::numeric));
 if p_action='order' then data_value:=jsonb_set(data_value,array['products',ix::text,'qty'],to_jsonb((prod->>'qty')::int-q));end if;
 end loop;
 select coalesce((select tier from public.ts_customer_tiers where user_id=u.user_id),'standard') into tier_value;
 select discount_percent into member_rate from public.ts_membership_rates where tier=tier_value;
 coupon_value:=upper(btrim(coalesce(p_args->>'coupon','')));
 if coupon_value<>'' then
 select x into coupon from jsonb_array_elements(coalesce(records_value->'coupons','[]'::jsonb)) x where x->>'code'=coupon_value and (coalesce(x->>'end','')='' or (x->>'end')::date>=current_date) limit 1;
 if coupon is null then raise exception 'Coupon unavailable';end if;coupon_rate:=least(100,greatest(0,(coupon->>'percent')::numeric));
 end if;
 select * into cfg from public.ts_loyalty_config where id=1;
 select greatest(0,coalesce(sum((x->>'points')::bigint),0)) into points_balance from jsonb_array_elements(coalesce(records_value->'loyalty','[]'::jsonb)) x where x->>'owner'=u.user_id::text;
 requested_points:=coalesce((p_args->>'points')::bigint,0);if requested_points<0 then raise exception 'Invalid points';end if;
 discount:=round(subtotal*greatest(member_rate,coupon_rate)/100,2);
 used_points:=least(requested_points,points_balance,floor((subtotal-discount)*cfg.max_redeem_percent/100*cfg.points_per_usd)::bigint);
 -- Redeem only complete cent increments, to avoid spending points for zero money.
 redeem_value:=floor(used_points::numeric*100/cfg.points_per_usd)/100;
 used_points:=ceil(redeem_value*cfg.points_per_usd)::bigint;
 total_value:=round(subtotal-discount-redeem_value,2);
 quote:=jsonb_build_object('subtotal',subtotal,'tier',tier_value,'discount_percent',greatest(member_rate,coupon_rate),'discount',discount,'points_balance',points_balance,'points_used',used_points,'points_discount',redeem_value,'total',total_value);
 if p_action='quote' then return quote;end if;
 if (p_args->>'expected_total')::numeric is distinct from total_value then raise exception 'Price changed; refresh quote';end if;
 if length(btrim(coalesce(p_args->>'phone',''))) not between 7 and 40 or length(btrim(coalesce(p_args->>'address',''))) not between 1 and 500 then raise exception 'Valid phone and address required';end if;
 order_id:=gen_random_uuid();
 order_value:=jsonb_build_object('id',order_id,'owner',u.user_id,'created',now(),'customer',u.name,'phone',left(p_args->>'phone',40),'address',left(p_args->>'address',500),'items',items_value,'total',total_value,'cost',cost_value,'discount',discount+redeem_value,'pointsRedeemed',used_points,'status','pending','payment','cod');
 records_value:=jsonb_set(records_value,'{orders}',jsonb_build_array(order_value)||coalesce(records_value->'orders','[]'::jsonb));
 if used_points>0 then records_value:=jsonb_set(records_value,'{loyalty}',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',u.user_id,'created',now(),'points',-used_points,'order',order_id,'kind','redemption'))||coalesce(records_value->'loyalty','[]'::jsonb));end if;
 insert into public.ts_member_checkout_keys(request_id,user_id,order_id) values(req,u.user_id,order_id::text);
 update public.ts_workspace set payload=jsonb_set(jsonb_set(w.payload,'{data}',data_value),'{records}',records_value),revision=revision+1,updated_at=now() where id=1;
 insert into public.ts_audit(actor,action) values(u.user_id,'member checkout '||order_id);
 return quote||jsonb_build_object('id',order_id,'status','pending');
end $$;
revoke all on function techstore_private.member_checkout(text,jsonb) from public,anon;
grant execute on function techstore_private.member_checkout(text,jsonb) to authenticated;
create function public.ts_member_checkout(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.member_checkout(p_action,p_args); $$;
revoke all on function public.ts_member_checkout(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_member_checkout(text,jsonb) to authenticated;
create function techstore_private.refund_member_points() returns trigger language plpgsql security definer set search_path='' as $$
declare o jsonb; old_o jsonb; loyalty jsonb; n bigint;
begin
 if old.payload->'records'->'orders' is not distinct from new.payload->'records'->'orders' then return new;end if;
 loyalty:=coalesce(new.payload->'records'->'loyalty','[]'::jsonb);
 for o in select x from jsonb_array_elements(coalesce(new.payload->'records'->'orders','[]'::jsonb)) x where x->>'status'='cancelled' and coalesce(x->>'pointsRedeemed','0')<>'0' loop
 select x into old_o from jsonb_array_elements(coalesce(old.payload->'records'->'orders','[]'::jsonb)) x where x->>'id'=o->>'id';
 if old_o is null or old_o->>'status'='cancelled' then continue;end if;
 n:=(old_o->>'pointsRedeemed')::bigint;
 if n>0 and not exists(select 1 from jsonb_array_elements(loyalty) x where x->>'order'=o->>'id' and x->>'kind'='redemption_refund') then
 loyalty:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',old_o->>'owner','created',now(),'points',n,'order',o->>'id','kind','redemption_refund'))||loyalty;
 end if;
 end loop;
 new.payload:=jsonb_set(new.payload,'{records,loyalty}',loyalty,true);
 return new;
end $$;
revoke all on function techstore_private.refund_member_points() from public,anon,authenticated;
create trigger ts_member_points_refund before update of payload on public.ts_workspace for each row execute function techstore_private.refund_member_points();
commit;