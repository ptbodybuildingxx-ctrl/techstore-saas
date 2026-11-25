begin;
create table public.ts_invoice_settings(id int primary key check(id=1), store_name text not null default 'TechStore' check(length(store_name) between 1 and 150), phone text not null default '' check(length(phone)<=100), address text not null default '' check(length(address)<=300), sale_title text not null default 'فاتورة بيع' check(length(sale_title) between 1 and 100), repair_title text not null default 'فاتورة صيانة' check(length(repair_title) between 1 and 100), footer text not null default '' check(length(footer)<=500));
insert into public.ts_invoice_settings(id) values(1);
create table public.ts_invoices(id uuid primary key default gen_random_uuid(), number bigint generated always as identity unique, request_id uuid not null unique, actor uuid not null references public.ts_profiles(user_id), customer_id uuid references public.ts_profiles(user_id), kind text not null check(kind in ('sale','repair')), repair_id text unique, created_at timestamptz not null default now(), document jsonb not null, request_args jsonb not null, check((kind='repair')=(repair_id is not null)));
alter table public.ts_invoice_settings enable row level security;
alter table public.ts_invoices enable row level security;
revoke all on public.ts_invoice_settings,public.ts_invoices from public,anon,authenticated;
create index ts_invoice_customer_idx on public.ts_invoices(customer_id,number desc);
create function techstore_private.invoice_action(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; cfg public.ts_invoice_settings%rowtype; inv public.ts_invoices%rowtype; cust uuid; req uuid; rid text; ticket jsonb; d jsonb; rec jsonb; doc jsonb; lines jsonb:='[]'; sale_lines jsonb:='[]'; line jsonb; prod jsonb; pid text; ix int; q int; months int; serial_value text; seen text[]:='{}'; total_value numeric:=0; cost_value numeric:=0; price_value numeric; labor numeric; parts numeric; customer_name text; phone_value text; issue_date date; sale_id uuid; title_value text; warranty_terms text; paid_value numeric;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>48000 then raise exception 'Invalid request';end if;
 select * into cfg from public.ts_invoice_settings where id=1;
 if p_action='settings' and u.role in ('admin','cashier','tech') then return to_jsonb(cfg);end if;
 if p_action='configure' then
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 update public.ts_invoice_settings set store_name=btrim(p_args->>'store_name'),phone=coalesce(p_args->>'phone',''),address=coalesce(p_args->>'address',''),sale_title=btrim(p_args->>'sale_title'),repair_title=btrim(p_args->>'repair_title'),footer=coalesce(p_args->>'footer','') where id=1 returning * into cfg;
 insert into public.ts_audit(actor,action) values(u.user_id,'invoice settings updated');return to_jsonb(cfg);
 end if;
 if p_action='list' then return coalesce((select jsonb_agg(to_jsonb(x) order by x.number desc) from (select i.id,i.number,i.kind,i.repair_id,i.created_at,i.document from public.ts_invoices i where (u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id)) order by i.number desc limit 100 offset greatest(0,least(100000,coalesce((p_args->>'offset')::int,0)))) x),'[]'::jsonb);end if;
 if p_action='get' then select * into inv from public.ts_invoices i where i.id=(p_args->>'id')::uuid and (u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id));if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;return to_jsonb(inv)-'request_args'-'request_id'-'actor'-'customer_id';end if;
 if u.role not in ('admin','cashier') or p_action not in ('sale','repair') then raise exception 'Access denied' using errcode='42501';end if;
 req:=(p_args->>'request_id')::uuid;if req is null then raise exception 'Request ID required';end if;
 select * into w from public.ts_workspace where id=1 for update;
 select * into inv from public.ts_invoices where request_id=req;
 if found then if inv.actor<>u.user_id or inv.kind<>p_action or inv.request_args is distinct from p_args then raise exception 'Request ID conflict';end if;return to_jsonb(inv)-'request_args'-'request_id'-'actor'-'customer_id';end if;
 d:=w.payload->'data';rec:=coalesce(w.payload->'records','{}');issue_date:=(now() at time zone 'UTC')::date;
 title_value:=btrim(coalesce(p_args->>'title',case when p_action='sale' then cfg.sale_title else cfg.repair_title end));if length(title_value) not between 1 and 100 then raise exception 'Invalid title';end if;
 warranty_terms:=left(coalesce(p_args->>'warranty_terms',''),1000);
 customer_name:=left(btrim(coalesce(p_args->>'customer','')),150);phone_value:=left(coalesce(p_args->>'phone',''),100);
 if p_action='sale' then
 cust:=nullif(p_args->>'customer_id','')::uuid;
 if cust is not null then select name into customer_name from public.ts_profiles where user_id=cust and role='customer' and active;if not found then raise exception 'Invalid customer';end if;end if;
 if jsonb_typeof(p_args->'items') is distinct from 'array' then raise exception 'Invalid items';end if;
 if jsonb_array_length(p_args->'items') not between 1 and 30 then raise exception 'Invalid items';end if;
 for line in select value from jsonb_array_elements(p_args->'items') loop
 pid:=line->>'product';q:=(line->>'qty')::int;months:=coalesce((line->>'months')::int,0);serial_value:=left(coalesce(line->>'serial',''),150);
 if pid is null or pid=any(seen) or q is null or q not between 1 and 1000000 or months not between 0 and 120 then raise exception 'Invalid item';end if;seen:=array_append(seen,pid);
 select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(d->'products','[]')) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null or (prod->>'qty')::int<q then raise exception 'Insufficient stock';end if;
 price_value:=(prod->>'price')::numeric;if price_value<0 or price_value is null or price_value is distinct from (line->>'expected_price')::numeric then raise exception 'Price changed; reload';end if;
 total_value:=total_value+round(price_value*q,2);cost_value:=cost_value+round((prod->>'cost')::numeric*q,2);
 line:=jsonb_build_object('product',pid,'name',prod->>'name','qty',q,'price',price_value,'total',round(price_value*q,2),'serial',serial_value,'warranty_months',months,'warranty_end',case when months>0 then (issue_date+make_interval(months=>months))::date else null end);
 lines:=lines||jsonb_build_array(line);sale_lines:=sale_lines||jsonb_build_array(line||jsonb_build_object('id',pid,'cost',(prod->>'cost')::numeric));
 d:=jsonb_set(d,array['products',ix::text,'qty'],to_jsonb((prod->>'qty')::int-q));
 d:=jsonb_set(d,'{stockMoves}',coalesce(d->'stockMoves','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',pid,'name',prod->>'name','qty',-q,'reason','invoice sale','date',issue_date)),true);
 end loop;
 paid_value:=total_value;
 else
 rid:=p_args->>'repair_id';select x into ticket from jsonb_array_elements(coalesce(rec->'repairs','[]')) x where x->>'id'=rid;
 if ticket is null or ticket->>'status' not in ('ready','delivered') then raise exception 'Repair must be ready or delivered';end if;
 if exists(select 1 from public.ts_invoices where repair_id=rid) then raise exception 'Repair invoice already issued';end if;
 cust:=nullif(ticket->>'customerId','')::uuid;customer_name:=coalesce(ticket->>'customer','');phone_value:=coalesce(ticket->>'phone','');
 labor:=(p_args->>'labor')::numeric;parts:=(p_args->>'parts')::numeric;months:=coalesce((p_args->>'months')::int,0);paid_value:=coalesce((p_args->>'paid')::numeric,0);
 if labor is null or parts is null or labor<0 or parts<0 or labor>100000000 or parts>100000000 or months not between 0 and 120 then raise exception 'Invalid repair amounts';end if;
 total_value:=round(labor+parts,2);if paid_value<0 or paid_value>total_value then raise exception 'Invalid paid amount';end if;
 lines:=jsonb_build_array(jsonb_build_object('name',coalesce(ticket->>'device','Repair'),'qty',1,'price',total_value,'total',total_value,'serial',coalesce(ticket->>'serial',''),'warranty_months',months,'warranty_end',case when months>0 then (issue_date+make_interval(months=>months))::date else null end,'fault',coalesce(ticket->>'fault',''),'labor',labor,'parts',parts,'work',left(coalesce(p_args->>'work',''),1000)));
 end if;
 doc:=jsonb_build_object('store_name',cfg.store_name,'store_phone',cfg.phone,'store_address',cfg.address,'title',title_value,'footer',cfg.footer,'date',issue_date,'customer',customer_name,'phone',phone_value,'items',lines,'total',total_value,'paid',round(paid_value,2),'currency','USD','warranty_terms',warranty_terms);
 insert into public.ts_invoices(request_id,actor,customer_id,kind,repair_id,document,request_args) values(req,u.user_id,cust,p_action,rid,doc,p_args) returning * into inv;
 if p_action='sale' then
 d:=jsonb_set(d,'{sales}',coalesce(d->'sales','[]')||jsonb_build_array(jsonb_build_object('id',inv.id,'number','INV-'||inv.number,'date',issue_date,'customer',customer_name,'payment','cash','paid',true,'items',sale_lines,'total',total_value,'cost',cost_value)),true);
 update public.ts_workspace set payload=jsonb_set(w.payload,'{data}',d),revision=revision+1,updated_at=now() where id=1;
 end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'invoice '||p_action||' '||inv.id);
 return to_jsonb(inv)-'request_args'-'request_id'-'actor'-'customer_id';
end $$;
revoke all on function techstore_private.invoice_action(text,jsonb) from public,anon,authenticated;
grant execute on function techstore_private.invoice_action(text,jsonb) to authenticated;
create function public.ts_invoice_action(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.invoice_action(p_action,p_args); $$;
revoke all on function public.ts_invoice_action(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_invoice_action(text,jsonb) to authenticated;
commit;