-- One-use buyer-authorized POS points, cash-only, same net unit prices as online rewards.
begin;
create table tenant_private.pos_authorizations (
 store_id uuid not null references public.saas_stores(id),token uuid not null default gen_random_uuid(),buyer uuid not null,request_id uuid not null,currency text not null check(currency in ('SYP','USD','EUR')),gross_minor bigint not null check(gross_minor between 1 and 100000000000000),points integer not null check(points between 0 and 100),basis_points integer not null check(basis_points between 0 and 5000),expires_at timestamptz not null,revoked boolean not null default false,created_at timestamptz not null default now(),primary key(store_id,token),unique(store_id,buyer,request_id)
);
create table tenant_private.pos_loyalty_sales (
 store_id uuid not null,sale_id uuid not null,token uuid not null,buyer uuid not null,points integer not null check(points between 0 and 100),basis_points integer not null check(basis_points between 0 and 5000),gross_minor bigint not null,discount_minor bigint not null check(discount_minor>=0 and discount_minor<gross_minor),actor uuid not null,request_id uuid not null,branch_id uuid,payload jsonb not null,result jsonb not null,created_at timestamptz not null default now(),primary key(store_id,sale_id),unique(store_id,token),unique(store_id,request_id),foreign key(store_id,sale_id) references public.mt_sales(store_id,id)
);
alter table tenant_private.pos_authorizations enable row level security;
alter table tenant_private.pos_loyalty_sales enable row level security;
revoke all on tenant_private.pos_authorizations,tenant_private.pos_loyalty_sales from public,anon,authenticated,service_role;
create index pos_auth_buyer on tenant_private.pos_authorizations(store_id,buyer,created_at desc);
create index pos_loyalty_buyer on tenant_private.pos_loyalty_sales(store_id,buyer,created_at desc);
CREATE OR REPLACE FUNCTION tenant_private.points_balance(p_store uuid, p_buyer uuid)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select (select count(*) from public.mt_online_orders o where o.store_id=p_store and o.buyer=p_buyer and o.state='fulfilled'
 and o.total_minor>(select coalesce(sum(r.total_minor),0) from public.mt_returns r where r.store_id=o.store_id and r.sale_id=o.sale_id)
 and not exists(select 1 from tenant_private.order_discounts d where d.store_id=o.store_id and d.order_id=o.id and d.reward_points is not null))
 + (select count(*) from tenant_private.pos_loyalty_sales p join public.mt_sales a on a.store_id=p.store_id and a.id=p.sale_id where p.store_id=p_store and p.buyer=p_buyer and p.points=0 and a.total_minor>(select coalesce(sum(r.total_minor),0) from public.mt_returns r where r.store_id=p.store_id and r.sale_id=p.sale_id))
 - (select coalesce(sum(p.points),0) from tenant_private.pos_loyalty_sales p where p.store_id=p_store and p.buyer=p_buyer)
 - (select coalesce(sum(d.reward_points),0) from tenant_private.order_discounts d join public.mt_online_orders o on o.store_id=d.store_id and o.id=d.order_id where d.store_id=p_store and d.buyer=p_buyer and d.reward_points is not null and o.state<>'cancelled')
$function$;
CREATE OR REPLACE FUNCTION tenant_private.snapshot_channel_invoice(s uuid, sid uuid, channel text, source_id uuid, meta jsonb, known_name text, known_phone text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.mt_sales%rowtype;ln jsonb;w jsonb:='[]';doc jsonb;payload jsonb;result jsonb;pid uuid;m integer;serial text;title text;customer text;phone text;terms text;issued date;cnt integer;
begin
 select * into strict a from public.mt_sales where store_id=s and id=sid;
 if a.actor<>auth.uid() or channel not in ('online','guest','tradein','pos') or source_id is null then raise exception 'Invalid invoice source';end if;
 issued:=(a.created_at at time zone 'Asia/Damascus')::date;
 select count(*) into cnt from public.mt_sale_lines where store_id=s and sale_id=sid;
 if cnt not between 1 and 100 then raise exception 'Invalid invoice lines';end if;
 payload:=jsonb_build_object('channel',channel,'source',source_id,'meta',meta);
 if meta is null then
  title:='';customer:='';phone:='';terms:='';
  select jsonb_agg(jsonb_build_object('product_id',product_id,'months',0,'serial','','until',null) order by product_id) into w from public.mt_sale_lines where store_id=s and sale_id=sid;
 else
  if jsonb_typeof(meta) is distinct from 'object' or octet_length(meta::text)>40000 or (select count(*) from jsonb_object_keys(meta))<>5 or not(meta ?& array['title','customer','phone','terms','lines']) or jsonb_typeof(meta->'title') is distinct from 'string' or jsonb_typeof(meta->'customer') is distinct from 'string' or jsonb_typeof(meta->'phone') is distinct from 'string' or jsonb_typeof(meta->'terms') is distinct from 'string' or jsonb_typeof(meta->'lines') is distinct from 'array' or jsonb_array_length(meta->'lines')<>cnt then raise exception 'Invalid invoice metadata';end if;
  title:=btrim(meta->>'title');customer:=btrim(meta->>'customer');phone:=btrim(meta->>'phone');terms:=btrim(meta->>'terms');
  if length(title)>100 or length(customer)>160 or length(phone)>100 or length(terms)>1000 then raise exception 'Invalid invoice details';end if;
  for ln in select value from jsonb_array_elements(meta->'lines') loop
   if jsonb_typeof(ln) is distinct from 'object' or (select count(*) from jsonb_object_keys(ln))<>3 or not(ln ?& array['product_id','months','serial']) or jsonb_typeof(ln->'product_id') is distinct from 'string' or jsonb_typeof(ln->'months') is distinct from 'number' or jsonb_typeof(ln->'serial') is distinct from 'string' or coalesce(ln->>'months','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid warranty line';end if;
   pid:=(ln->>'product_id')::uuid;m:=(ln->>'months')::integer;serial:=btrim(ln->>'serial');
   if pid is null or m not between 0 and 120 or length(serial)>150 or not exists(select 1 from public.mt_sale_lines where store_id=s and sale_id=sid and product_id=pid) or exists(select 1 from jsonb_array_elements(w) x where (x->>'product_id')::uuid=pid) then raise exception 'Invalid warranty line';end if;
   w:=w||jsonb_build_array(jsonb_build_object('product_id',pid,'months',m,'serial',serial,'until',case when m>0 then (issued+make_interval(months=>m))::date else null end));
  end loop;
 end if;
 if known_name is not null then customer:=known_name;end if;
 if known_phone is not null then phone:=known_phone;end if;
 doc:=jsonb_build_object('title',title,'customer',customer,'phone',phone,'terms',terms,'lines',w,'issued',issued,'channel',channel,'source',source_id);
 result:=jsonb_build_object('id',a.id,'number',a.number,'currency',a.currency,'total_minor',a.total_minor,'request_id',a.request_id);
 insert into tenant_private.sale_invoice_details values(s,sid,a.request_id,auth.uid(),payload,doc,result,now());
end $function$;

create function tenant_private.pos_authorize(s uuid,r uuid,c text,gross bigint,use_reward boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare a tenant_private.pos_authorizations%rowtype;l tenant_private.loyalty_settings%rowtype;
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) or not tenant_private.storefront_active(s) then raise exception 'Live buyer required' using errcode='42501';end if;
 if r is null or c is null or c not in ('SYP','USD','EUR') or gross is null or gross not between 1 and 100000000000000 or use_reward is null then raise exception 'Invalid POS authorization';end if;
 perform 1 from public.saas_stores where id=s for update;
 if not exists(select 1 from tenant_private.sale_currencies where store_id=s and currency=c) then raise exception 'Currency unavailable';end if;
 select * into a from tenant_private.pos_authorizations where store_id=s and buyer=auth.uid() and request_id=r;
 if found then
 if a.currency<>c or a.gross_minor<>gross or (a.points>0) is distinct from use_reward then raise exception 'Conflicting authorization';end if;
 else
 if (select count(*) from tenant_private.pos_authorizations where store_id=s and buyer=auth.uid() and created_at>now()-interval '10 minutes')>=10 then raise exception 'Too many authorizations';end if;
 select * into l from tenant_private.loyalty_settings where store_id=s;
 if use_reward and (not found or not l.enabled or tenant_private.points_balance(s,auth.uid())<l.points_required) then raise exception 'Reward unavailable';end if;
 update tenant_private.pos_authorizations set revoked=true where store_id=s and buyer=auth.uid() and expires_at>now() and not revoked;
 insert into tenant_private.pos_authorizations(store_id,buyer,request_id,currency,gross_minor,points,basis_points,expires_at) values(s,auth.uid(),r,c,gross,case when use_reward then l.points_required else 0 end,case when use_reward then l.basis_points else 0 end,now()+interval '10 minutes') returning * into a;
 end if;
 return jsonb_build_object('token',a.token,'currency',a.currency,'gross_minor',a.gross_minor,'points',a.points,'basis_points',a.basis_points,'expires_at',a.expires_at,'revoked',a.revoked,'used',exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and token=a.token));
end $$;
create function tenant_private.pos_revoke(s uuid,t uuid) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=s for update;
 update tenant_private.pos_authorizations set revoked=true where store_id=s and token=t and buyer=auth.uid() and not exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and token=t);return found;
end $$;
create function tenant_private.pos_quote(s uuid,b uuid,t uuid,c text,items jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a tenant_private.pos_authorizations%rowtype;l tenant_private.loyalty_settings%rowtype;x jsonb;pid uuid;u bigint;price bigint;quoted bigint;gross bigint:=0;discount bigint:=0;net bigint;loc bigint;
begin
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.current_branch_scope(s) is not null and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 if t is null or c is null or c not in ('SYP','USD','EUR') or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or octet_length(items::text)>50000 then raise exception 'Invalid POS cart';end if;
 select * into a from tenant_private.pos_authorizations where store_id=s and token=t;
 if not found or a.revoked or a.expires_at<=now() or a.currency<>c or exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and token=t) then raise exception 'Authorization unavailable';end if;
 if a.points>0 then
 select * into l from tenant_private.loyalty_settings where store_id=s;
 if not found or not l.enabled or l.points_required<>a.points or l.basis_points<>a.basis_points or tenant_private.points_balance(s,a.buyer)<a.points then raise exception 'Reward changed';end if;
 end if;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(items))<>jsonb_array_length(items) then raise exception 'Duplicate product';end if;
 for x in select value from jsonb_array_elements(items) loop
 if jsonb_typeof(x) is distinct from 'object' or (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid sale line';end if;
 pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;quoted:=(x->>'expected_price_minor')::bigint;
 if u not between 1 and 10000 or quoted not between 1 and 100000000 then raise exception 'Invalid line amount';end if;
 select price_minor into price from public.mt_product_prices where store_id=s and product_id=pid and currency=c;
 if not found or price<>quoted then raise exception 'Price changed';end if;
 if b is null then loc:=tenant_private.main_available(s,pid);else select units into loc from tenant_private.branch_stock where store_id=s and branch_id=b and product_id=pid;end if;
 if coalesce(loc,0)<u then raise exception 'Insufficient stock';end if;
 net:=price-price*a.basis_points/10000;
 if net<1 then raise exception 'Invalid net price';end if;
 gross:=gross+u*price;discount:=discount+u*(price-net);
 end loop;
 if gross<>a.gross_minor or gross>100000000000000 or (a.points>0 and discount<=0) then raise exception 'Authorized amount changed';end if;
 return jsonb_build_object('currency',c,'gross_minor',gross,'discount_minor',discount,'total_minor',gross-discount,'points',a.points,'basis_points',a.basis_points);
end $$;
create function tenant_private.pos_commit(s uuid,b uuid,r uuid,t uuid,c text,items jsonb,meta jsonb,expected bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare a tenant_private.pos_authorizations%rowtype;old tenant_private.pos_loyalty_sales%rowtype;v_settings tenant_private.sales_settings%rowtype;v_sale public.mt_sales%rowtype;pr public.mt_products%rowtype;x jsonb;pid uuid;u bigint;net bigint;quote jsonb;payload jsonb;result jsonb;
begin
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.current_branch_scope(s) is not null and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if r is null or t is null or expected is null or expected<1 or meta is null then raise exception 'Invalid confirmed POS sale';end if;
 perform 1 from public.saas_stores where id=s for update;
 payload:=jsonb_build_object('branch',b,'token',t,'currency',c,'lines',items,'meta',meta,'expected',expected);
 select * into old from tenant_private.pos_loyalty_sales where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting POS sale';end if;return old.result;end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale request';end if;
 quote:=tenant_private.pos_quote(s,b,t,c,items);
 if (quote->>'total_minor')::bigint<>expected then raise exception 'Net total changed';end if;
 select * into strict a from tenant_private.pos_authorizations where store_id=s and token=t;
 select * into strict v_settings from tenant_private.sales_settings where store_id=s for update;
 if b is not null then perform tenant_private.branch_take(s,b,items);insert into tenant_private.branch_sale_context(store_id,request_id,branch_id,actor) values(s,r,b,auth.uid());end if;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(s,v_settings.next_number,r,auth.uid(),c,expected,'cash') returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=s;
 for x in select value from jsonb_array_elements(items) loop
 pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;net:=(x->>'expected_price_minor')::bigint-(x->>'expected_price_minor')::bigint*a.basis_points/10000;
 update public.mt_products set quantity=quantity-u where store_id=s and id=pid returning * into pr;
 insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(s,v_sale.id,pid,pr.sku,pr.name,u,net);
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(s,gen_random_uuid(),pid,-u,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 if b is not null then delete from tenant_private.branch_sale_context where store_id=s and request_id=r;insert into tenant_private.branch_sales(store_id,sale_id,branch_id) values(s,v_sale.id,b);end if;
 insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(s,v_sale.id,c,expected);
 result:=quote||jsonb_build_object('id',v_sale.id,'number',v_sale.number,'request_id',r);
 insert into tenant_private.pos_loyalty_sales(store_id,sale_id,token,buyer,points,basis_points,gross_minor,discount_minor,actor,request_id,branch_id,payload,result) values(s,v_sale.id,t,a.buyer,a.points,a.basis_points,a.gross_minor,(quote->>'discount_minor')::bigint,auth.uid(),r,b,payload,result);
 perform tenant_private.snapshot_channel_invoice(s,v_sale.id,'pos',v_sale.id,meta,null,null);
 update tenant_private.sale_invoice_details set document=document||jsonb_build_object('loyalty',jsonb_build_object('gross_minor',a.gross_minor,'discount_minor',(quote->>'discount_minor')::bigint,'points',a.points)) where store_id=s and sale_id=v_sale.id;
 return result;
end $$;
create function tenant_private.buyer_pos_sales(s uuid,off integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) or off is null or off not between 0 and 100000 then raise exception 'Buyer access denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.number desc) from (select a.id,a.id sale_id,a.number,a.currency,a.total_minor,a.created_at,p.points,p.discount_minor from tenant_private.pos_loyalty_sales p join public.mt_sales a on a.store_id=p.store_id and a.id=p.sale_id where p.store_id=s and p.buyer=auth.uid() order by a.number desc offset off limit 50)x),'[]'::jsonb);
end $$;
CREATE OR REPLACE FUNCTION tenant_private.buyer_invoice(s uuid, o uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.mt_sales%rowtype;doc jsonb;settings jsonb;lines jsonb;sid uuid;
begin
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 select sale_id into sid from public.mt_online_orders where store_id=s and id=o and buyer=auth.uid() and state='fulfilled';
 if not found then select sale_id into sid from tenant_private.pos_loyalty_sales where store_id=s and sale_id=o and buyer=auth.uid();end if;
 if sid is null then raise exception 'Invoice unavailable' using errcode='42501';end if;
 select * into strict a from public.mt_sales where store_id=s and id=sid;
 select d.document into doc from tenant_private.sale_invoice_details d where store_id=s and sale_id=sid;
 select r.settings into settings from tenant_private.receipt_snapshots r where store_id=s and kind='sale' and document_id=sid;
 select coalesce(jsonb_agg(jsonb_build_object('product_id',l.product_id,'product_name',l.product_name,'sku',l.sku,'units',l.units,'unit_price_minor',l.unit_price_minor,'line_total_minor',l.line_total_minor) order by l.product_id),'[]') into lines from public.mt_sale_lines l where l.store_id=s and l.sale_id=sid;
 if doc is not null then doc:=doc||jsonb_build_object('returned',coalesce((select jsonb_agg(jsonb_build_object('product_id',x.product_id,'units',x.units)) from (select product_id,sum(units)::bigint units from public.mt_returns where store_id=s and sale_id=sid group by product_id)x),'[]'::jsonb));end if;
 return jsonb_build_object('sale',jsonb_build_object('id',a.id,'number',a.number,'currency',a.currency,'total_minor',a.total_minor,'payment_mode',a.payment_mode,'created_at',a.created_at,'request_id',a.request_id),'identity',settings,'invoice',doc,'lines',lines);
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.sale_claim_open(s uuid, r uuid, sid uuid, pid uuid, u bigint, why text, from_buyer boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old tenant_private.sale_warranty_claims%rowtype;b uuid;w jsonb;available bigint;out_id uuid;
begin
 if from_buyer is null or r is null or sid is null or pid is null or u is null or u not between 1 and 10000 or why is null or length(btrim(why)) not between 1 and 300 then raise exception 'Invalid claim';end if;
 if from_buyer then
  if auth.uid() is null or not coalesce(saas_private.live_session(),false) or not (exists(select 1 from public.mt_online_orders where store_id=s and sale_id=sid and state='fulfilled' and buyer=auth.uid()) or exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and sale_id=sid and buyer=auth.uid())) then raise exception 'Claim access denied' using errcode='42501';end if;
  b:=auth.uid();
 else
  perform tenant_private.owner_write(s);
  select buyer into b from public.mt_online_orders where store_id=s and sale_id=sid and state='fulfilled';if not found then select buyer into b from tenant_private.pos_loyalty_sales where store_id=s and sale_id=sid;end if;
 end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into old from tenant_private.sale_warranty_claims where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.sale_id<>sid or old.product_id<>pid or old.units<>u or old.reason<>btrim(why) or old.buyer is distinct from b then raise exception 'Conflicting claim request';end if;return old.id;end if;
 select x into w from tenant_private.sale_invoice_details d cross join lateral jsonb_array_elements(d.document->'lines')x where d.store_id=s and d.sale_id=sid and (x->>'product_id')::uuid=pid;
 if not found or (w->>'months')::integer<=0 or (w->>'until')::date<(now() at time zone 'Asia/Damascus')::date then raise exception 'Warranty unavailable';end if;
 select l.units-coalesce((select sum(t.units) from public.mt_returns t where t.store_id=s and t.sale_id=sid and t.product_id=pid),0)-coalesce((select sum(c.units) from tenant_private.sale_warranty_claims c where c.store_id=s and c.sale_id=sid and c.product_id=pid and c.state in ('open','accepted')),0) into available from public.mt_sale_lines l where l.store_id=s and l.sale_id=sid and l.product_id=pid;
 if not found or available<u then raise exception 'Claim exceeds available coverage';end if;
 insert into tenant_private.sale_warranty_claims(store_id,sale_id,product_id,request_id,actor,buyer,units,reason) values(s,sid,pid,r,auth.uid(),b,u,btrim(why)) returning id into out_id;return out_id;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.sale_claim_list(s uuid, from_buyer boolean, off integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if from_buyer is null or off is null or off not between 0 and 100000 then raise exception 'Invalid page';end if;
 if from_buyer then
 if auth.uid() is null or not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 elsif tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from (
 select c.id,c.sale_id,c.product_id,c.units,c.reason,c.state,c.created_at,a.number,l.product_name,l.sku,
 coalesce((select jsonb_agg(jsonb_build_object('prior',e.prior_state,'next',e.next_state,'note',e.note,'at',e.created_at) order by e.created_at,e.request_id) from tenant_private.sale_warranty_events e where e.store_id=s and e.claim_id=c.id),'[]'::jsonb) events
 from tenant_private.sale_warranty_claims c join public.mt_sales a on a.store_id=c.store_id and a.id=c.sale_id join public.mt_sale_lines l on l.store_id=c.store_id and l.sale_id=c.sale_id and l.product_id=c.product_id
 where c.store_id=s and (not from_buyer or (c.buyer=auth.uid() and (exists(select 1 from public.mt_online_orders o where o.store_id=s and o.sale_id=c.sale_id and o.buyer=auth.uid() and o.state='fulfilled') or exists(select 1 from tenant_private.pos_loyalty_sales p where p.store_id=s and p.sale_id=c.sale_id and p.buyer=auth.uid())))) order by c.created_at desc,c.id desc offset off limit 50)x),'[]');
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
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales'] loop
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

create function public.mt_pos_authorize(p_slug text,p_request uuid,p_currency text,p_gross bigint,p_reward boolean) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.pos_authorize(tenant_private.buyer_store(p_slug),p_request,p_currency,p_gross,p_reward)$$;
create function public.mt_pos_revoke(p_slug text,p_token uuid) returns boolean language sql security invoker set search_path='' as $$select tenant_private.pos_revoke(tenant_private.buyer_store(p_slug),p_token)$$;
create function public.mt_pos_quote(p_store uuid,p_branch uuid,p_token uuid,p_currency text,p_lines jsonb) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.pos_quote(p_store,p_branch,p_token,p_currency,p_lines)$$;
create function public.mt_pos_commit(p_store uuid,p_branch uuid,p_request uuid,p_token uuid,p_currency text,p_lines jsonb,p_metadata jsonb,p_expected bigint) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.pos_commit(p_store,p_branch,p_request,p_token,p_currency,p_lines,p_metadata,p_expected)$$;
create function public.mt_buyer_pos_sales(p_slug text,p_offset integer) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.buyer_pos_sales(tenant_private.buyer_store(p_slug),p_offset)$$;
revoke all on function tenant_private.pos_authorize(uuid,uuid,text,bigint,boolean),tenant_private.pos_revoke(uuid,uuid),tenant_private.pos_quote(uuid,uuid,uuid,text,jsonb),tenant_private.pos_commit(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint),tenant_private.buyer_pos_sales(uuid,integer),public.mt_pos_authorize(text,uuid,text,bigint,boolean),public.mt_pos_revoke(text,uuid),public.mt_pos_quote(uuid,uuid,uuid,text,jsonb),public.mt_pos_commit(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint),public.mt_buyer_pos_sales(text,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.pos_authorize(uuid,uuid,text,bigint,boolean),tenant_private.pos_revoke(uuid,uuid),tenant_private.pos_quote(uuid,uuid,uuid,text,jsonb),tenant_private.pos_commit(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint),tenant_private.buyer_pos_sales(uuid,integer),public.mt_pos_authorize(text,uuid,text,bigint,boolean),public.mt_pos_revoke(text,uuid),public.mt_pos_quote(uuid,uuid,uuid,text,jsonb),public.mt_pos_commit(uuid,uuid,uuid,uuid,text,jsonb,jsonb,bigint),public.mt_buyer_pos_sales(text,integer) to authenticated;
commit;
