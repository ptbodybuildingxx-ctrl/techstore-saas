-- Store-scoped marketing campaigns and trade-in estimates; no external mail or cash is sent.
begin;
create table tenant_private.marketing_campaigns(store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,title text not null check(length(btrim(title)) between 1 and 120),body text not null check(length(btrim(body)) between 1 and 600),starts_on date not null,ends_on date not null,state text not null default 'draft' check(state in ('draft','published','completed')),actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),check(ends_on>=starts_on and ends_on-starts_on<=90));
create table tenant_private.tradein_estimates(store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,branch_id uuid,customer_id uuid not null,device text not null check(length(btrim(device)) between 1 and 160),serial text not null check(length(serial)<=80),condition_note text not null check(length(btrim(condition_note)) between 1 and 300),currency text not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),state text not null default 'assessment' check(state in ('assessment','offered','accepted','rejected','settled')),purchase_id uuid,sale_id uuid,actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),unique(store_id,purchase_id),unique(store_id,sale_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),foreign key(store_id,customer_id) references public.mt_customers(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),foreign key(store_id,purchase_id) references public.mt_purchases(store_id,id),foreign key(store_id,sale_id) references public.mt_sales(store_id,id),check((state='settled')=(purchase_id is not null and sale_id is not null)));
alter table tenant_private.marketing_campaigns enable row level security;alter table tenant_private.tradein_estimates enable row level security;
revoke all on tenant_private.marketing_campaigns,tenant_private.tradein_estimates from public,anon,authenticated,service_role;
create function tenant_private.campaign_create(p_store uuid,p_request uuid,p_title text,p_body text,p_from date,p_to date) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.marketing_campaigns%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_title is null or length(btrim(p_title)) not between 1 and 120 or p_body is null or length(btrim(p_body)) not between 1 and 600 or p_from is null or p_to is null or p_to<p_from or p_to-p_from>90 then raise exception 'Invalid campaign' using errcode='22023';end if;
 select * into v from tenant_private.marketing_campaigns where store_id=p_store and request_id=p_request;
 if found then if v.actor<>auth.uid() or v.title<>btrim(p_title) or v.body<>btrim(p_body) or v.starts_on<>p_from or v.ends_on<>p_to then raise exception 'Conflicting campaign' using errcode='22023';end if;return v.id;end if;
 insert into tenant_private.marketing_campaigns(store_id,request_id,title,body,starts_on,ends_on,actor) values(p_store,p_request,btrim(p_title),btrim(p_body),p_from,p_to,auth.uid()) returning id into v.id;return v.id;
end
$$;
create function public.mt_campaign_create(p_store uuid,p_request uuid,p_title text,p_body text,p_from date,p_to date) returns uuid language sql security invoker set search_path='' as $$select tenant_private.campaign_create(p_store,p_request,p_title,p_body,p_from,p_to)$$;
create function tenant_private.campaign_state(p_store uuid,p_id uuid,p_state text) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_state not in ('draft','published','completed') or p_state is null then raise exception 'Invalid campaign state' using errcode='22023';end if;
 update tenant_private.marketing_campaigns set state=p_state where store_id=p_store and id=p_id and (state<>'completed' or p_state='completed');return found;
end
$$;
create function public.mt_campaign_state(p_store uuid,p_id uuid,p_state text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.campaign_state(p_store,p_id,p_state)$$;
create function tenant_private.campaign_list(p_store uuid,p_after uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by id) from (select id,title,body,starts_on,ends_on,state from tenant_private.marketing_campaigns where store_id=p_store and (p_after is null or id>p_after) order by id limit 50)x),'[]'::jsonb);
end
$$;
create function public.mt_campaign_list(p_store uuid,p_after uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.campaign_list(p_store,p_after)$$;
create function tenant_private.public_campaigns(p_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid;d date:=(now() at time zone 'Asia/Damascus')::date;begin
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);if not found then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by starts_on desc,id) from (select id,title,body,starts_on,ends_on from tenant_private.marketing_campaigns where store_id=t and state='published' and d between starts_on and ends_on order by starts_on desc,id limit 10)x),'[]'::jsonb);
end
$$;
create function public.mt_public_campaigns(p_slug text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.public_campaigns(p_slug)$$;
create function tenant_private.tradein_create(p_store uuid,p_request uuid,p_branch uuid,p_customer uuid,p_device text,p_serial text,p_note text,p_currency text,p_amount bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.tradein_estimates%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_customer is null or p_device is null or length(btrim(p_device)) not between 1 and 160 or p_serial is null or length(p_serial)>80 or p_note is null or length(btrim(p_note)) not between 1 and 300 or p_currency is null or p_amount is null or p_amount not between 1 and 100000000000000 then raise exception 'Invalid trade-in' using errcode='22023';end if;
 if p_branch is not null then perform tenant_private.require_branch(p_store,p_branch);end if;
 select * into v from tenant_private.tradein_estimates where store_id=p_store and request_id=p_request;
 if found then if v.actor<>auth.uid() or v.branch_id is distinct from p_branch or v.customer_id<>p_customer or v.device<>btrim(p_device) or v.serial<>btrim(p_serial) or v.condition_note<>btrim(p_note) or v.currency<>p_currency or v.amount_minor<>p_amount then raise exception 'Conflicting trade-in' using errcode='22023';end if;return v.id;end if;
 insert into tenant_private.tradein_estimates(store_id,request_id,branch_id,customer_id,device,serial,condition_note,currency,amount_minor,actor) values(p_store,p_request,p_branch,p_customer,btrim(p_device),btrim(p_serial),btrim(p_note),p_currency,p_amount,auth.uid()) returning id into v.id;return v.id;
end
$$;
create function public.mt_tradein_create(p_store uuid,p_request uuid,p_branch uuid,p_customer uuid,p_device text,p_serial text,p_note text,p_currency text,p_amount bigint) returns uuid language sql security invoker set search_path='' as $$select tenant_private.tradein_create(p_store,p_request,p_branch,p_customer,p_device,p_serial,p_note,p_currency,p_amount)$$;
create function tenant_private.tradein_state(p_store uuid,p_id uuid,p_state text) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_state is null or p_state not in ('offered','accepted','rejected') then raise exception 'Invalid state' using errcode='22023';end if;
 update tenant_private.tradein_estimates set state=p_state where store_id=p_store and id=p_id and (state=p_state or (state='assessment' and p_state in ('offered','rejected')) or (state='offered' and p_state in ('accepted','rejected')) or (state='accepted' and p_state='rejected'));return found;
end
$$;
create function public.mt_tradein_state(p_store uuid,p_id uuid,p_state text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.tradein_state(p_store,p_id,p_state)$$;
create function tenant_private.tradein_settle(p_store uuid,p_id uuid,p_purchase uuid,p_sale uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r tenant_private.tradein_estimates%rowtype;pr public.mt_purchases%rowtype;s public.mt_sales%rowtype;bp uuid;bs uuid;
begin
 perform tenant_private.owner_write(p_store);
 select * into r from tenant_private.tradein_estimates where store_id=p_store and id=p_id for update;
 if not found then raise exception 'Unknown estimate' using errcode='22023';end if;
 if r.state='settled' then return r.purchase_id=p_purchase and r.sale_id=p_sale;end if;
 if r.state<>'accepted' then raise exception 'Accepted estimate required' using errcode='22023';end if;
 select * into pr from public.mt_purchases where store_id=p_store and id=p_purchase;
 if not found or pr.currency<>r.currency or pr.units<>1 or pr.total_minor<>r.amount_minor or pr.returned_units<>0 or pr.created_at<r.created_at then raise exception 'Matching purchase required' using errcode='22023';end if;
 select * into s from public.mt_sales where store_id=p_store and id=p_sale;
 if not found or s.currency<>r.currency or s.created_at<r.created_at then raise exception 'Matching sale required' using errcode='22023';end if;
 select branch_id into bp from tenant_private.branch_purchases where store_id=p_store and purchase_id=p_purchase;
 select branch_id into bs from tenant_private.branch_sales where store_id=p_store and sale_id=p_sale;
 if bp is distinct from r.branch_id or bs is distinct from r.branch_id then raise exception 'Branch mismatch' using errcode='22023';end if;
 update tenant_private.tradein_estimates set state='settled',purchase_id=p_purchase,sale_id=p_sale where store_id=p_store and id=p_id;return true;
end
$$;
create function public.mt_tradein_settle(p_store uuid,p_id uuid,p_purchase uuid,p_sale uuid) returns boolean language sql security invoker set search_path='' as $$select tenant_private.tradein_settle(p_store,p_id,p_purchase,p_sale)$$;
create function tenant_private.tradein_list(p_store uuid,p_after uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by id) from (select e.id,c.name as customer,e.device,e.serial,e.condition_note,e.currency,e.amount_minor,e.state,coalesce(b.name,'المستودع الرئيسي') as branch,e.purchase_id,e.sale_id from tenant_private.tradein_estimates e join public.mt_customers c on c.store_id=e.store_id and c.id=e.customer_id left join tenant_private.branches b on b.store_id=e.store_id and b.id=e.branch_id where e.store_id=p_store and (p_after is null or e.id>p_after) order by e.id limit 50)x),'[]'::jsonb);
end
$$;
create function public.mt_tradein_list(p_store uuid,p_after uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tradein_list(p_store,p_after)$$;
revoke all on function tenant_private.campaign_create(uuid,uuid,text,text,date,date),public.mt_campaign_create(uuid,uuid,text,text,date,date),tenant_private.campaign_state(uuid,uuid,text),public.mt_campaign_state(uuid,uuid,text),tenant_private.campaign_list(uuid,uuid),public.mt_campaign_list(uuid,uuid),tenant_private.public_campaigns(text),public.mt_public_campaigns(text),tenant_private.tradein_create(uuid,uuid,uuid,uuid,text,text,text,text,bigint),public.mt_tradein_create(uuid,uuid,uuid,uuid,text,text,text,text,bigint),tenant_private.tradein_state(uuid,uuid,text),public.mt_tradein_state(uuid,uuid,text),tenant_private.tradein_settle(uuid,uuid,uuid,uuid),public.mt_tradein_settle(uuid,uuid,uuid,uuid),tenant_private.tradein_list(uuid,uuid),public.mt_tradein_list(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.campaign_create(uuid,uuid,text,text,date,date),public.mt_campaign_create(uuid,uuid,text,text,date,date),tenant_private.campaign_state(uuid,uuid,text),public.mt_campaign_state(uuid,uuid,text),tenant_private.campaign_list(uuid,uuid),public.mt_campaign_list(uuid,uuid),tenant_private.public_campaigns(text),public.mt_public_campaigns(text),tenant_private.tradein_create(uuid,uuid,uuid,uuid,text,text,text,text,bigint),public.mt_tradein_create(uuid,uuid,uuid,uuid,text,text,text,text,bigint),tenant_private.tradein_state(uuid,uuid,text),public.mt_tradein_state(uuid,uuid,text),tenant_private.tradein_settle(uuid,uuid,uuid,uuid),public.mt_tradein_settle(uuid,uuid,uuid,uuid),tenant_private.tradein_list(uuid,uuid),public.mt_tradein_list(uuid,uuid) to authenticated;
grant execute on function tenant_private.public_campaigns(text),public.mt_public_campaigns(text) to anon;
commit;
