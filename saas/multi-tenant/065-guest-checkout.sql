-- Optional guest pickup orders. A random bearer code is required for public tracking.
begin;
create table tenant_private.guest_settings(store_id uuid primary key references tenant_private.workspaces(store_id),enabled boolean not null default false);
create table tenant_private.guest_orders(store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),code uuid not null,customer_name text not null check(length(btrim(customer_name)) between 1 and 120),phone text not null check(length(btrim(phone)) between 5 and 40),currency text not null,lines jsonb not null,total_minor bigint not null check(total_minor between 1 and 100000000000000),state text not null default 'pending' check(state in ('pending','cancelled','fulfilled')),sale_id uuid,created_at timestamptz not null default now(),finished_at timestamptz,primary key(store_id,id),unique(store_id,code),unique(store_id,sale_id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),foreign key(store_id,sale_id) references public.mt_sales(store_id,id),check((state='fulfilled')=(sale_id is not null)),check((state='pending')=(finished_at is null)));
create index mt_guest_queue on tenant_private.guest_orders(store_id,state,created_at);
alter table tenant_private.guest_settings enable row level security;alter table tenant_private.guest_orders enable row level security;
revoke all on tenant_private.guest_settings,tenant_private.guest_orders from public,anon,authenticated,service_role;
create function tenant_private.guest_enabled(p_slug text) returns boolean language plpgsql security definer set search_path='' as $$
begin return exists(select 1 from public.saas_stores s join tenant_private.guest_settings g on g.store_id=s.id and g.enabled where s.slug=p_slug and tenant_private.storefront_active(s.id));end
$$;
create function public.mt_guest_enabled(p_slug text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.guest_enabled(p_slug)$$;
create function tenant_private.guest_enable(p_store uuid,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin perform tenant_private.owner_write(p_store);if p_enabled is null then raise exception 'Invalid option' using errcode='22023';end if;insert into tenant_private.guest_settings values(p_store,p_enabled) on conflict(store_id) do update set enabled=excluded.enabled;return p_enabled;end
$$;
create function public.mt_guest_enable(p_store uuid,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.guest_enable(p_store,p_enabled)$$;
create function tenant_private.guest_submit(p_slug text,p_code uuid,p_name text,p_phone text,p_currency text,p_lines jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid;x jsonb;norm jsonb;o tenant_private.guest_orders%rowtype;pid uuid;units bigint;price bigint;total bigint:=0;begin
 if p_code is null or p_name is null or length(btrim(p_name)) not between 1 and 120 or p_phone is null or length(btrim(p_phone)) not between 5 and 40 or p_phone !~ '^[0-9+() -]+$' or p_currency is null or p_currency not in ('USD','EUR','SYP') or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid guest order' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 20 or octet_length(p_lines::text)>12000 then raise exception 'Guest cart limit' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
 if jsonb_typeof(x) is distinct from 'object' or (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,2}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line' using errcode='22023';end if;
 if (x->>'units')::bigint not between 1 and 10 or (x->>'expected_price_minor')::bigint not between 1 and 100000000 then raise exception 'Invalid line value' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into norm from jsonb_array_elements(p_lines);
 select id into t from public.saas_stores where slug=p_slug for update;
 if not found then raise exception 'Unavailable' using errcode='22023';end if;
 select * into o from tenant_private.guest_orders where store_id=t and code=p_code;
 if found then if o.customer_name<>btrim(p_name) or o.phone<>btrim(p_phone) or o.currency<>p_currency or o.lines is distinct from norm then raise exception 'Conflicting guest request' using errcode='22023';end if;return p_code;end if;
 if not tenant_private.guest_enabled(p_slug) then raise exception 'Guest checkout unavailable' using errcode='22023';end if;
 if (select count(*) from tenant_private.guest_orders where store_id=t and created_at>now()-interval '24 hours')>=100 or (select count(*) from tenant_private.guest_orders where store_id=t and state='pending')>=30 or (select count(*) from tenant_private.guest_orders where store_id=t and phone=btrim(p_phone) and state='pending')>=3 then raise exception 'Guest queue limit' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(norm) loop
 pid:=(x->>'product_id')::uuid;units:=(x->>'units')::bigint;
 select pp.price_minor into price from public.mt_product_prices pp join tenant_private.storefront_products l on l.store_id=pp.store_id and l.product_id=pp.product_id and l.listed where pp.store_id=t and pp.product_id=pid and pp.currency=p_currency;
 if not found or price<>(x->>'expected_price_minor')::bigint or coalesce(tenant_private.main_available(t,pid),0)<units then raise exception 'Price or availability changed' using errcode='22023';end if;total:=total+price*units;
 end loop;
 insert into tenant_private.guest_orders(store_id,code,customer_name,phone,currency,lines,total_minor) values(t,p_code,btrim(p_name),btrim(p_phone),p_currency,norm,total);return p_code;
end
$$;
create function public.mt_guest_submit(p_slug text,p_code uuid,p_name text,p_phone text,p_currency text,p_lines jsonb) returns uuid language sql security invoker set search_path='' as $$select tenant_private.guest_submit(p_slug,p_code,p_name,p_phone,p_currency,p_lines)$$;
create function tenant_private.guest_track(p_slug text,p_code uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;begin
 select jsonb_build_object('state',g.state,'total_minor',g.total_minor,'currency',g.currency,'created_at',g.created_at) into r from tenant_private.guest_orders g join public.saas_stores s on s.id=g.store_id where s.slug=p_slug and g.code=p_code and tenant_private.storefront_active(s.id);return r;
end
$$;
create function public.mt_guest_track(p_slug text,p_code uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.guest_track(p_slug,p_code)$$;
create function tenant_private.guest_list(p_store uuid,p_after uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return jsonb_build_object('enabled',coalesce((select enabled from tenant_private.guest_settings where store_id=p_store),false),'orders',coalesce((select jsonb_agg(to_jsonb(x) order by id) from (select id,customer_name,phone,currency,total_minor,lines,state,created_at,sale_id from tenant_private.guest_orders where store_id=p_store and (p_after is null or id>p_after) order by id limit 50)x),'[]'::jsonb));
end
$$;
create function public.mt_guest_list(p_store uuid,p_after uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.guest_list(p_store,p_after)$$;
create function tenant_private.guest_finish(p_store uuid,p_id uuid,p_action text,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare o tenant_private.guest_orders%rowtype;r jsonb;sid uuid;begin
 perform tenant_private.owner_write(p_store);
 if p_action is null or p_action not in ('cancel','fulfill') or p_confirm is distinct from true then raise exception 'Confirm action' using errcode='22023';end if;
 select * into o from tenant_private.guest_orders where store_id=p_store and id=p_id for update;
 if not found then raise exception 'Unknown order' using errcode='22023';end if;
 if o.state='fulfilled' and p_action='fulfill' or o.state='cancelled' and p_action='cancel' then return p_id;end if;
 if o.state<>'pending' then raise exception 'Order already closed' using errcode='22023';end if;
 if p_action='fulfill' then
 if exists(select 1 from public.mt_sales where store_id=p_store and request_id=p_id) then raise exception 'Conflicting sale request' using errcode='22023';end if;
 r:=tenant_private.record_currency_sale(p_store,p_id,o.currency,o.lines);sid:=(r->>'id')::uuid;
 if (r->>'total_minor')::bigint<>o.total_minor then raise exception 'Order total changed' using errcode='22023';end if;
 end if;
 update tenant_private.guest_orders set state=case when p_action='fulfill' then 'fulfilled' else 'cancelled' end,sale_id=sid,finished_at=now() where store_id=p_store and id=p_id;return p_id;
end
$$;
create function public.mt_guest_finish(p_store uuid,p_id uuid,p_action text,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.guest_finish(p_store,p_id,p_action,p_confirm)$$;
revoke all on function tenant_private.guest_enabled(text),public.mt_guest_enabled(text),tenant_private.guest_enable(uuid,boolean),public.mt_guest_enable(uuid,boolean),tenant_private.guest_submit(text,uuid,text,text,text,jsonb),public.mt_guest_submit(text,uuid,text,text,text,jsonb),tenant_private.guest_track(text,uuid),public.mt_guest_track(text,uuid),tenant_private.guest_list(uuid,uuid),public.mt_guest_list(uuid,uuid),tenant_private.guest_finish(uuid,uuid,text,boolean),public.mt_guest_finish(uuid,uuid,text,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.guest_enabled(text),public.mt_guest_enabled(text),tenant_private.guest_enable(uuid,boolean),public.mt_guest_enable(uuid,boolean),tenant_private.guest_submit(text,uuid,text,text,text,jsonb),public.mt_guest_submit(text,uuid,text,text,text,jsonb),tenant_private.guest_track(text,uuid),public.mt_guest_track(text,uuid),tenant_private.guest_list(uuid,uuid),public.mt_guest_list(uuid,uuid),tenant_private.guest_finish(uuid,uuid,text,boolean),public.mt_guest_finish(uuid,uuid,text,boolean) to authenticated;
grant execute on function tenant_private.guest_enabled(text),public.mt_guest_enabled(text),tenant_private.guest_submit(text,uuid,text,text,text,jsonb),public.mt_guest_submit(text,uuid,text,text,text,jsonb),tenant_private.guest_track(text,uuid),public.mt_guest_track(text,uuid) to anon;
commit;
