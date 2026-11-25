begin;
create table public.ts_invoice_installments(
 invoice_id uuid not null references public.ts_invoices(id), sequence int not null check(sequence between 1 and 36), due_date date not null, amount numeric(18,2) not null check(amount>0), primary key(invoice_id,sequence)
);
alter table public.ts_invoice_installments enable row level security;
revoke all on public.ts_invoice_installments from public,anon,authenticated;
create function techstore_private.create_invoice_installments() returns trigger language plpgsql security definer set search_path='' as $$
declare n int; remaining numeric; each_value numeric; due_value date; i int;
begin
 if new.kind<>'sale' or new.document->>'payment_mode' is distinct from 'installment' then return new;end if;
 n:=(new.document->>'installment_count')::int;remaining:=(new.document->>'total')::numeric-(new.document->>'paid')::numeric;due_value:=(new.document->>'first_due')::date;
 if n not between 1 and 36 or remaining<n*0.01 or due_value is null then raise exception 'Invalid installment plan';end if;
 each_value:=floor(remaining*100/n)/100;
 for i in 1..n loop insert into public.ts_invoice_installments(invoice_id,sequence,due_date,amount) values(new.id,i,(due_value+make_interval(months=>i-1))::date,case when i=n then remaining-each_value*(n-1) else each_value end);end loop;
 return new;
end $$;
revoke all on function techstore_private.create_invoice_installments() from public,anon,authenticated;
create trigger ts_invoice_installments_create after insert on public.ts_invoices for each row execute function techstore_private.create_invoice_installments();
create or replace function techstore_private.invoice_action(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; cfg public.ts_invoice_settings%rowtype; inv public.ts_invoices%rowtype; cust uuid; req uuid; rid text; ticket jsonb; d jsonb; rec jsonb; doc jsonb; lines jsonb:='[]'; sale_lines jsonb:='[]'; line jsonb; prod jsonb; pid text; ix int; q int; months int; serial_value text; seen text[]:='{}'; total_value numeric:=0; cost_value numeric:=0; price_value numeric; labor numeric; parts numeric; customer_name text; phone_value text; issue_date date; sale_id uuid; title_value text; warranty_terms text; paid_value numeric; mode_value text:='cash'; installments_value int:=0; due_value date;
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
 mode_value:=coalesce(p_args->>'payment_mode','cash');
 if mode_value='cash' then paid_value:=total_value;
 elsif mode_value='installment' then
 if u.role<>'admin' or cust is null then raise exception 'Owner and linked customer required for installment sale' using errcode='42501';end if;
 paid_value:=round((p_args->>'down_payment')::numeric,2);installments_value:=(p_args->>'installment_count')::int;due_value:=(p_args->>'first_due')::date;
 if paid_value is null or paid_value<0 or paid_value>=total_value or installments_value is null or installments_value not between 1 and 36 or due_value is null or due_value<issue_date or due_value>issue_date+365 or total_value-paid_value<installments_value*0.01 then raise exception 'Invalid installment terms';end if;
 else raise exception 'Invalid payment mode';end if;
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
 doc:=jsonb_build_object('store_name',cfg.store_name,'store_phone',cfg.phone,'store_address',cfg.address,'title',title_value,'footer',cfg.footer,'date',issue_date,'customer',customer_name,'phone',phone_value,'items',lines,'total',total_value,'paid',round(paid_value,2),'currency','USD','warranty_terms',warranty_terms,'payment_mode',mode_value,'installment_count',installments_value,'first_due',due_value);
 insert into public.ts_invoices(request_id,actor,customer_id,kind,repair_id,document,request_args) values(req,u.user_id,cust,p_action,rid,doc,p_args) returning * into inv;
 if p_action='sale' then
 d:=jsonb_set(d,'{sales}',coalesce(d->'sales','[]')||jsonb_build_array(jsonb_build_object('id',inv.id,'number','INV-'||inv.number,'date',issue_date,'customer',customer_name,'payment',mode_value,'paid',paid_value=total_value,'items',sale_lines,'total',total_value,'cost',cost_value)),true);
 update public.ts_workspace set payload=jsonb_set(w.payload,'{data}',d),revision=revision+1,updated_at=now() where id=1;
 end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'invoice '||p_action||' '||inv.id);
 return to_jsonb(inv)-'request_args'-'request_id'-'actor'-'customer_id';
end $$;

create function techstore_private.installment_schedule(p_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or u.role not in ('admin','cashier','customer') then raise exception 'Access denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from (
 select s.invoice_id,i.number,i.document->>'customer' as customer,s.sequence,s.due_date,s.amount,
 least(s.amount,greatest(0,coalesce((select sum(e.amount) from public.ts_business_entries e where e.invoice_id=i.id and e.kind='receipt'),0)-coalesce((select sum(p.amount) from public.ts_invoice_installments p where p.invoice_id=i.id and p.sequence<s.sequence),0))) as paid
 from public.ts_invoice_installments s join public.ts_invoices i on i.id=s.invoice_id
 where (p_id is null or i.id=p_id) and (u.role in ('admin','cashier') or i.customer_id=u.user_id)
 order by s.due_date,i.number,s.sequence limit 500
 ) x),'[]');
end $$;
revoke all on function techstore_private.installment_schedule(uuid) from public,anon,authenticated;
grant execute on function techstore_private.installment_schedule(uuid) to authenticated;
create function public.ts_installment_schedule(p_id uuid default null) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.installment_schedule(p_id); $$;
revoke all on function public.ts_installment_schedule(uuid) from public,anon,authenticated;
grant execute on function public.ts_installment_schedule(uuid) to authenticated;
commit;