-- Procurement metadata, explicit staff grants, credit-only delegated receipts and maturity dates.
begin;
alter table public.mt_suppliers add column phone text not null default '' check(length(phone)<=80),add column email text not null default '' check(length(email)<=160),add column address text not null default '' check(length(address)<=300),add column archived boolean not null default false;
alter table public.mt_purchases add column due_date date;
create table tenant_private.procurement_grants(store_id uuid not null,user_id uuid not null,read_allowed boolean not null,manage_suppliers boolean not null,receive_credit boolean not null,actor uuid not null,updated_at timestamptz not null default now(),primary key(store_id,user_id),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id),check(read_allowed or (not manage_suppliers and not receive_credit)));
create table tenant_private.procurement_requests(store_id uuid not null references public.saas_stores(id),request_id uuid not null,actor uuid not null,kind text not null,payload jsonb not null,result uuid not null,created_at timestamptz not null default now(),primary key(store_id,request_id));
alter table tenant_private.procurement_grants enable row level security;
alter table tenant_private.procurement_requests enable row level security;
revoke all on tenant_private.procurement_grants,tenant_private.procurement_requests from public,anon,authenticated,service_role;
create index mt_purchases_due on public.mt_purchases(store_id,due_date) where due_date is not null;
create function tenant_private.procurement_allowed(s uuid,a text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(s)='owner' or (tenant_private.member_role(s)='stock' and exists(select 1 from tenant_private.procurement_grants g where g.store_id=s and g.user_id=auth.uid() and g.read_allowed and case a when 'read' then true when 'supplier' then g.manage_suppliers when 'receive' then g.receive_credit else false end)),false)
$$;
create function tenant_private.procurement_access(s uuid,u uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare target uuid:=coalesce(u,auth.uid());g tenant_private.procurement_grants%rowtype;r text;
begin
 r:=tenant_private.member_role(s);
 if r is null or (target<>auth.uid() and r<>'owner') then raise exception 'Access denied' using errcode='42501';end if;
 if target=auth.uid() and r='owner' then return jsonb_build_object('read',true,'supplier',true,'receive',true,'licensed',tenant_private.shared_licensed(s),'branch',null);end if;
 select * into g from tenant_private.procurement_grants where store_id=s and user_id=target and exists(select 1 from tenant_private.members m where m.store_id=s and m.user_id=target and m.active and m.role='stock');
 return jsonb_build_object('read',coalesce(g.read_allowed,false),'supplier',coalesce(g.manage_suppliers,false),'receive',coalesce(g.receive_credit,false),'licensed',tenant_private.shared_licensed(s),'branch',case when target=auth.uid() then tenant_private.current_branch_scope(s) end);
end $$;
create function tenant_private.procurement_grant(s uuid,u uuid,can_read boolean,can_supplier boolean,can_receive boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(s);
 if u is null or can_read is null or can_supplier is null or can_receive is null or (not can_read and (can_supplier or can_receive)) or not exists(select 1 from tenant_private.members where store_id=s and user_id=u and active and role='stock') then raise exception 'Invalid procurement grant';end if;
 insert into tenant_private.procurement_grants(store_id,user_id,read_allowed,manage_suppliers,receive_credit,actor) values(s,u,can_read,can_supplier,can_receive,auth.uid()) on conflict(store_id,user_id) do update set read_allowed=excluded.read_allowed,manage_suppliers=excluded.manage_suppliers,receive_credit=excluded.receive_credit,actor=excluded.actor,updated_at=now();
 return true;
end $$;
create function tenant_private.procurement_write(s uuid,a text,b uuid default null) returns void language plpgsql security definer set search_path='' as $$
declare sc uuid:=tenant_private.current_branch_scope(s);
begin
 perform 1 from public.saas_stores where id=s for update;
 if not tenant_private.procurement_allowed(s,a) or not coalesce(tenant_private.shared_licensed(s),false) then raise exception 'Procurement write denied' using errcode='42501';end if;
 if a='receive' and (not coalesce(tenant_private.staff_action_allowed(s,'catalog_read'),false) or not coalesce(tenant_private.staff_action_allowed(s,'stock_adjust'),false) or (sc is not null and sc is distinct from b)) then raise exception 'Stock or branch denied' using errcode='42501';end if;
 if a='receive' and b is not null then perform tenant_private.require_branch(s,b);end if;
end $$;
create function tenant_private.supplier_save(s uuid,r uuid,supplier uuid,n text,c text,ph text,em text,addr text,arch boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare old tenant_private.procurement_requests%rowtype;payload jsonb;out_id uuid;was_archived boolean;
begin
 perform tenant_private.procurement_write(s,'supplier');
 if r is null or n is null or length(btrim(n)) not between 1 and 160 or c is null or length(c)>160 or ph is null or length(ph)>80 or em is null or length(em)>160 or addr is null or length(addr)>300 or arch is null then raise exception 'Invalid supplier profile';end if;
 payload:=jsonb_build_object('supplier',supplier,'name',btrim(n),'contact',btrim(c),'phone',btrim(ph),'email',btrim(em),'address',btrim(addr),'archived',arch);
 select * into old from tenant_private.procurement_requests where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.kind<>'supplier' or old.payload is distinct from payload then raise exception 'Conflicting supplier request';end if;return old.result;end if;
 if supplier is null then
  if arch then raise exception 'New supplier must be active';end if;
  insert into public.mt_suppliers(store_id,request_id,name,contact,phone,email,address,actor) values(s,r,btrim(n),btrim(c),btrim(ph),btrim(em),btrim(addr),auth.uid()) returning id into out_id;
 else
  select archived into was_archived from public.mt_suppliers where store_id=s and id=supplier for update;
  if not found then raise exception 'Unknown supplier';end if;
  if was_archived is distinct from arch and tenant_private.member_role(s)<>'owner' then raise exception 'Owner required for archive' using errcode='42501';end if;
  update public.mt_suppliers set name=btrim(n),contact=btrim(c),phone=btrim(ph),email=btrim(em),address=btrim(addr),archived=arch where store_id=s and id=supplier returning id into out_id;
 end if;
 insert into tenant_private.procurement_requests values(s,r,auth.uid(),'supplier',payload,out_id,now());return out_id;
end $$;
create function tenant_private.guard_archived_supplier() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.mt_suppliers where store_id=new.store_id and id=new.supplier_id and archived) then raise exception 'Supplier archived';end if;return new;
end $$;
create trigger mt_active_supplier before insert on public.mt_purchases for each row execute function tenant_private.guard_archived_supplier();
create trigger mt_active_supplier_batch before insert on public.mt_purchase_batches for each row execute function tenant_private.guard_archived_supplier();
CREATE OR REPLACE FUNCTION tenant_private.procurement_intake_core(p_store uuid, p_product uuid, p_request uuid, p_units bigint, p_currency text, p_cost bigint, p_note text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare i tenant_private.cost_intakes%rowtype; e public.mt_stock_events%rowtype; q bigint;
begin
 perform 1 from public.saas_stores where id=p_store for update;
 if not tenant_private.procurement_allowed(p_store,'receive') or not tenant_private.shared_licensed(p_store) then raise exception 'Procurement intake denied' using errcode='42501';end if;
 if p_request is null or p_product is null or p_units is null or p_units not between 1 and 1000000000 or p_currency is null or p_cost is null or p_cost not between 0 and 100000000 or p_note is null or length(btrim(p_note)) not between 1 and 300 or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Invalid intake' using errcode='22023';end if;
 select * into i from tenant_private.cost_intakes where store_id=p_store and request_id=p_request;
 if found then
  if i.product_id<>p_product or i.units<>p_units or i.currency<>p_currency or i.unit_cost_minor<>p_cost or i.note<>btrim(p_note) or i.actor<>auth.uid() then raise exception 'Conflicting intake request' using errcode='22023';end if;
  select * into strict e from public.mt_stock_events where store_id=p_store and request_id=p_request;
  return e.balance;
 end if;
 if exists(select 1 from public.mt_stock_events where store_id=p_store and request_id=p_request) then raise exception 'Request already used' using errcode='22023';end if;
 select quantity into q from public.mt_products where store_id=p_store and id=p_product for update;
 if not found or q+p_units>1000000000 then raise exception 'Invalid stock balance' using errcode='22023';end if;
 insert into tenant_private.cost_intakes(store_id,request_id,product_id,units,currency,unit_cost_minor,note,actor) values(p_store,p_request,p_product,p_units,p_currency,p_cost,btrim(p_note),auth.uid());
 update public.mt_products set quantity=quantity+p_units where store_id=p_store and id=p_product returning quantity into q;
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(p_store,p_request,p_product,p_units,q,auth.uid());
 return q;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.procurement_purchase_core(p_store uuid, p_request uuid, p_supplier uuid, p_product uuid, p_currency text, p_units bigint, p_cost bigint, p_paid bigint, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.mt_purchases%rowtype; v_payment uuid; intake_id uuid:=gen_random_uuid();
begin
 if not tenant_private.procurement_allowed(p_store,'receive') or not tenant_private.shared_licensed(p_store) or (tenant_private.member_role(p_store)<>'owner' and p_paid is distinct from 0) then raise exception 'Procurement purchase denied' using errcode='42501';end if;
 if p_request is null or p_supplier is null or p_product is null or p_currency is null or p_units is null or p_units not between 1 and 1000000 or p_cost is null or p_cost not between 1 and 100000000 or p_paid is null or p_paid<0 or p_paid>p_units*p_cost or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid purchase' using errcode='22023';end if;
 select * into r from public.mt_purchases where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.supplier_id<>p_supplier or r.product_id<>p_product or r.currency<>p_currency or r.units<>p_units or r.unit_cost_minor<>p_cost or r.initial_paid_minor<>p_paid or r.note<>btrim(p_note) then raise exception 'Conflicting purchase request' using errcode='22023';end if;
  return r.id;
 end if;
 if not exists(select 1 from public.mt_suppliers where store_id=p_store and id=p_supplier) or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Invalid purchase references' using errcode='22023';end if;
 -- A dedicated internal stock event ID cannot alias a prior standalone intake.
 perform tenant_private.procurement_intake_core(p_store,p_product,intake_id,p_units,p_currency,p_cost,btrim(p_note));
 insert into public.mt_purchases(store_id,request_id,supplier_id,product_id,currency,units,unit_cost_minor,paid_minor,initial_paid_minor,note,actor,intake_request) values(p_store,p_request,p_supplier,p_product,p_currency,p_units,p_cost,p_paid,p_paid,btrim(p_note),auth.uid(),intake_id) returning * into r;
 if p_paid>0 then
  insert into public.mt_supplier_payments(store_id,request_id,purchase_id,amount_minor,is_initial,actor) values(p_store,gen_random_uuid(),r.id,p_paid,true,auth.uid()) returning id into v_payment;
  insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,supplier_payment_id) values(p_store,gen_random_uuid(),'supplier_payment',p_currency,p_paid,'Purchase initial payment',auth.uid(),v_payment);
 end if;
 return r.id;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.procurement_batch_core(p_store uuid, p_request uuid, p_supplier uuid, p_currency text, p_reference text, p_lines jsonb, p_paid bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.mt_purchase_batches%rowtype;x jsonb;norm jsonb;total numeric:=0;left_paid bigint;alloc bigint;line_total bigint;purchase_id uuid;
begin
 if not tenant_private.procurement_allowed(p_store,'receive') or not tenant_private.shared_licensed(p_store) or (tenant_private.member_role(p_store)<>'owner' and p_paid is distinct from 0) then raise exception 'Procurement batch denied' using errcode='42501';end if;
 if p_request is null or p_supplier is null or p_currency is null or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_paid is null or p_paid<0 or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid purchase invoice' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>30000 then raise exception 'Invalid lines' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
 if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid line' using errcode='22023';end if;
 if (select count(*) from jsonb_object_keys(x))<>3 or not(x ?& array['product_id','units','unit_cost_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'unit_cost_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,7}$' or coalesce(x->>'unit_cost_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line values' using errcode='22023';end if;
 if (x->>'units')::bigint not between 1 and 1000000 or (x->>'unit_cost_minor')::bigint not between 1 and 100000000 then raise exception 'Line amount out of range' using errcode='22023';end if;
 total:=total+(x->>'units')::numeric*(x->>'unit_cost_minor')::numeric;
 end loop;
 if total not between 1 and 100000000000000 or p_paid>total or (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Invalid invoice total or duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'unit_cost_minor',(value->>'unit_cost_minor')::bigint) order by (value->>'product_id')::uuid) into norm from jsonb_array_elements(p_lines);
 select * into r from public.mt_purchase_batches where store_id=p_store and request_id=p_request;
 if found then
 if r.actor<>auth.uid() or r.supplier_id<>p_supplier or r.currency<>p_currency or r.reference<>btrim(p_reference) or r.lines is distinct from norm or r.initial_paid_minor<>p_paid then raise exception 'Conflicting purchase invoice' using errcode='22023';end if;return r.id;
 end if;
 insert into public.mt_purchase_batches(store_id,request_id,supplier_id,currency,reference,lines,total_minor,initial_paid_minor,actor) values(p_store,p_request,p_supplier,p_currency,btrim(p_reference),norm,total::bigint,p_paid,auth.uid()) returning * into r;
 left_paid:=p_paid;
 for x in select value from jsonb_array_elements(norm) loop
 line_total:=(x->>'units')::bigint*(x->>'unit_cost_minor')::bigint;alloc:=least(left_paid,line_total);
 purchase_id:=tenant_private.procurement_purchase_core(p_store,gen_random_uuid(),p_supplier,(x->>'product_id')::uuid,p_currency,(x->>'units')::bigint,(x->>'unit_cost_minor')::bigint,alloc,btrim(p_reference));
 update public.mt_purchases set batch_id=r.id where store_id=p_store and id=purchase_id;
 left_paid:=left_paid-alloc;
 end loop;
 if left_paid<>0 then raise exception 'Purchase allocation mismatch';end if;return r.id;
end $function$;
revoke all on function tenant_private.procurement_intake_core(uuid,uuid,uuid,bigint,text,bigint,text),tenant_private.procurement_purchase_core(uuid,uuid,uuid,uuid,text,bigint,bigint,bigint,text),tenant_private.procurement_batch_core(uuid,uuid,uuid,text,text,jsonb,bigint) from public,anon,authenticated,service_role;
create function tenant_private.procurement_receive(s uuid,b uuid,r uuid,supplier uuid,c text,reference text,items jsonb,paid bigint,due date,is_batch boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare old tenant_private.procurement_requests%rowtype;payload jsonb;out_id uuid;line record;x jsonb;
begin
 perform tenant_private.procurement_write(s,'receive',b);
 if r is null or is_batch is null or paid is null or paid<0 or (tenant_private.member_role(s)<>'owner' and paid<>0) or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or (not is_batch and jsonb_array_length(items)<>1) or (due is not null and due>(now() at time zone 'Asia/Damascus')::date+3650) then raise exception 'Invalid receipt';end if;
 payload:=jsonb_build_object('branch',b,'supplier',supplier,'currency',c,'reference',reference,'items',items,'paid',paid,'due',due,'batch',is_batch);
 select * into old from tenant_private.procurement_requests where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.kind<>'receive' or old.payload is distinct from payload then raise exception 'Conflicting receipt';end if;return old.result;end if;
 if exists(select 1 from public.mt_purchases where store_id=s and request_id=r) or exists(select 1 from public.mt_purchase_batches where store_id=s and request_id=r) then raise exception 'Request already used';end if;
 if is_batch then
  out_id:=tenant_private.procurement_batch_core(s,r,supplier,c,reference,items,paid);
  if b is not null then insert into tenant_private.branch_batches values(s,out_id,b);end if;
  for line in select id,product_id,units from public.mt_purchases where store_id=s and batch_id=out_id loop
   if b is not null then perform tenant_private.branch_add(s,b,line.product_id,line.units);insert into tenant_private.branch_purchases values(s,line.id,b);end if;
  end loop;
  update public.mt_purchases set due_date=due where store_id=s and batch_id=out_id;
 else
  x:=items->0;
  if jsonb_typeof(x) is distinct from 'object' or (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','unit_cost_minor']) then raise exception 'Invalid line';end if;
  out_id:=tenant_private.procurement_purchase_core(s,r,supplier,(x->>'product_id')::uuid,c,(x->>'units')::bigint,(x->>'unit_cost_minor')::bigint,paid,reference);
  if b is not null then perform tenant_private.branch_add(s,b,(x->>'product_id')::uuid,(x->>'units')::bigint);insert into tenant_private.branch_purchases values(s,out_id,b);end if;
  update public.mt_purchases set due_date=due where store_id=s and id=out_id;
 end if;
 insert into tenant_private.procurement_requests values(s,r,auth.uid(),'receive',payload,out_id,now());return out_id;
end $$;
create function tenant_private.procurement_due(s uuid,r uuid,p uuid,d date) returns uuid language plpgsql security definer set search_path='' as $$
declare old tenant_private.procurement_requests%rowtype;payload jsonb;
begin
 perform tenant_private.owner_write(s);
 if r is null or p is null or (d is not null and d>(now() at time zone 'Asia/Damascus')::date+3650) then raise exception 'Invalid due date';end if;
 payload:=jsonb_build_object('purchase',p,'due',d);
 select * into old from tenant_private.procurement_requests where store_id=s and request_id=r;
 if found then if old.actor<>auth.uid() or old.kind<>'due' or old.payload is distinct from payload then raise exception 'Conflicting due request';end if;return old.result;end if;
 update public.mt_purchases set due_date=d where store_id=s and id=p;
 if not found then raise exception 'Unknown purchase';end if;
 insert into tenant_private.procurement_requests values(s,r,auth.uid(),'due',payload,p,now());return p;
end $$;
create function tenant_private.procurement_list(s uuid,k text,after_id uuid,lim integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare sc uuid:=tenant_private.current_branch_scope(s);out_data jsonb;
begin
 if not tenant_private.procurement_allowed(s,'read') then raise exception 'Procurement read denied' using errcode='42501';end if;
 if k is null or k not in ('suppliers','purchases','batches','returns') or lim is null or lim not between 1 and 100 then raise exception 'Invalid page';end if;
 if k='suppliers' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into out_data from (select id,name,contact,phone,email,address,archived from public.mt_suppliers where store_id=s and (after_id is null or id>after_id) order by id limit lim)x;
 elsif k='purchases' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into out_data from (select p.id,p.supplier_id,p.product_id,v.name supplier_name,pr.name product_name,pr.sku,p.currency,p.units,p.returned_units,p.unit_cost_minor,p.total_minor,p.paid_minor,p.refunded_minor,p.note,p.due_date,p.created_at,b.branch_id,p.batch_id from public.mt_purchases p join public.mt_suppliers v on v.store_id=p.store_id and v.id=p.supplier_id join public.mt_products pr on pr.store_id=p.store_id and pr.id=p.product_id left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=s and (sc is null or sc=b.branch_id) and (after_id is null or p.id>after_id) order by p.id limit lim)x;
 elsif k='batches' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into out_data from (select p.id,p.supplier_id,v.name supplier_name,p.currency,p.reference,p.created_at,b.branch_id,p.total_minor-(select coalesce(sum(t.returned_units*t.unit_cost_minor),0)::bigint from public.mt_purchases t where t.store_id=s and t.batch_id=p.id) total_minor,(select coalesce(sum(t.paid_minor-t.refunded_minor),0)::bigint from public.mt_purchases t where t.store_id=s and t.batch_id=p.id) paid_minor from public.mt_purchase_batches p join public.mt_suppliers v on v.store_id=p.store_id and v.id=p.supplier_id left join tenant_private.branch_batches b on b.store_id=p.store_id and b.batch_id=p.id where p.store_id=s and (sc is null or sc=b.branch_id) and (after_id is null or p.id>after_id) order by p.id limit lim)x;
 else
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into out_data from (select r.id,r.purchase_id,r.currency,r.units,r.debt_reduction_minor,r.refund_minor,r.reason,r.created_at,b.branch_id from public.mt_supplier_returns r left join tenant_private.branch_purchases b on b.store_id=r.store_id and b.purchase_id=r.purchase_id where r.store_id=s and (sc is null or sc=b.branch_id) and (after_id is null or r.id>after_id) order by r.id limit lim)x;
 end if;return out_data;
end $$;
create function tenant_private.procurement_aging(s uuid,c text,b uuid,all_locations boolean,asof date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare sc uuid:=tenant_private.current_branch_scope(s);
begin
 if not tenant_private.procurement_allowed(s,'read') or (sc is not null and (all_locations or sc is distinct from b)) then raise exception 'Procurement read denied' using errcode='42501';end if;
 if c is null or c not in ('SYP','USD','EUR') or asof is distinct from (now() at time zone 'Asia/Damascus')::date or all_locations is null or (all_locations and b is not null) then raise exception 'Invalid aging query';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.name,x.id) from (select v.id,v.name,coalesce(sum(p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor) filter(where p.due_date is null),0)::text no_due,coalesce(sum(p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor) filter(where p.due_date>=asof),0)::text not_due,coalesce(sum(p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor) filter(where p.due_date<asof),0)::text overdue,sum(p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor)::text total from public.mt_purchases p join public.mt_suppliers v on v.store_id=p.store_id and v.id=p.supplier_id left join tenant_private.branch_purchases bp on bp.store_id=p.store_id and bp.purchase_id=p.id where p.store_id=s and p.currency=c and (all_locations or bp.branch_id is not distinct from b) and p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor>0 group by v.id,v.name order by v.name,v.id limit 501)x),'[]'::jsonb);
end $$;
CREATE OR REPLACE FUNCTION tenant_private.supplier_statement(p_store uuid, p_supplier uuid, p_currency text, p_all boolean, p_branch uuid, p_from date, p_to date, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare lo timestamptz;hi timestamptz;result jsonb; supplier_name text;
begin
 if not tenant_private.procurement_allowed(p_store,'read') or (tenant_private.current_branch_scope(p_store) is not null and (p_all or tenant_private.current_branch_scope(p_store) is distinct from p_branch)) then raise exception 'Procurement read denied' using errcode='42501';end if;
 if p_supplier is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_all is null or (p_all and p_branch is not null) or p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 or p_to>(now() at time zone 'Asia/Damascus')::date or p_offset is null or p_offset not between 0 and 100000 then raise exception 'Invalid statement query' using errcode='22023';end if;
 if p_branch is not null and not exists(select 1 from tenant_private.branches where store_id=p_store and id=p_branch) then raise exception 'Unknown branch' using errcode='22023';end if;
 select name into supplier_name from public.mt_suppliers where store_id=p_store and id=p_supplier;
 if not found then raise exception 'Unknown supplier' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'Asia/Damascus';hi:=(p_to+1)::timestamp at time zone 'Asia/Damascus';
 with purchases as (
  select p.*,b.branch_id from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id
  where p.store_id=p_store and p.supplier_id=p_supplier and p.currency=p_currency and (p_all or b.branch_id is not distinct from p_branch)
 ), movements(at,kind,id,purchase,branch_id,amount,refund,note) as (
  select created_at,'purchase',id,id,branch_id,total_minor::numeric,0::numeric,note from purchases where created_at<hi
  union all select m.created_at,case when m.settlement_method='tradein_offset' then 'offset' else 'payment' end,m.id,p.id,p.branch_id,-m.amount_minor::numeric,0::numeric,'' from public.mt_supplier_payments m join purchases p on p.store_id=m.store_id and p.id=m.purchase_id where m.store_id=p_store and m.created_at<hi
  union all select r.created_at,'return',r.id,p.id,p.branch_id,-r.debt_reduction_minor::numeric,r.refund_minor::numeric,r.reason from public.mt_supplier_returns r join purchases p on p.store_id=r.store_id and p.id=r.purchase_id where r.store_id=p_store and r.created_at<hi
 ), balances as (
  select *,sum(amount) over(order by at,case kind when 'purchase' then 0 when 'return' then 2 else 1 end,id rows unbounded preceding) as balance from movements
 ), totals as (
  select coalesce(sum(amount) filter(where at<lo),0) opening,coalesce(sum(amount),0) closing,coalesce(sum(amount) filter(where at>=lo and kind='purchase'),0) purchases,coalesce(-sum(amount) filter(where at>=lo and kind in ('payment','offset')),0) paid,coalesce(-sum(amount) filter(where at>=lo and kind='return'),0) debt_reduced,coalesce(sum(refund) filter(where at>=lo),0) refunded,count(*) filter(where at>=lo) total_rows from movements
 ), page as (
  select at,kind,id,purchase,branch_id,amount::text,refund::text,note,balance::text from balances where at>=lo order by at,case kind when 'purchase' then 0 when 'return' then 2 else 1 end,id offset p_offset limit 50
 )
 select jsonb_build_object('supplier',p_supplier,'name',supplier_name,'currency',p_currency,'opening',opening::text,'closing',closing::text,'purchases',purchases::text,'paid',paid::text,'debt_reduced',debt_reduced::text,'refunded',refunded::text,'total_rows',total_rows,'rows',coalesce((select jsonb_agg(to_jsonb(page) order by at,case kind when 'purchase' then 0 when 'return' then 2 else 1 end,id) from page),'[]'::jsonb)) into result from totals;
 return result;
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
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests'] loop
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
create function public.mt_procurement_access(p_store uuid,p_user uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.procurement_access(p_store,p_user)$$;
revoke all on function tenant_private.procurement_access(uuid,uuid),public.mt_procurement_access(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.procurement_access(uuid,uuid),public.mt_procurement_access(uuid,uuid) to authenticated;
create function public.mt_procurement_grant(p_store uuid,p_user uuid,p_read boolean,p_supplier boolean,p_receive boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.procurement_grant(p_store,p_user,p_read,p_supplier,p_receive)$$;
revoke all on function tenant_private.procurement_grant(uuid,uuid,boolean,boolean,boolean),public.mt_procurement_grant(uuid,uuid,boolean,boolean,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.procurement_grant(uuid,uuid,boolean,boolean,boolean),public.mt_procurement_grant(uuid,uuid,boolean,boolean,boolean) to authenticated;
create function public.mt_supplier_save(p_store uuid,p_request uuid,p_supplier uuid,p_name text,p_contact text,p_phone text,p_email text,p_address text,p_archived boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.supplier_save(p_store,p_request,p_supplier,p_name,p_contact,p_phone,p_email,p_address,p_archived)$$;
revoke all on function tenant_private.supplier_save(uuid,uuid,uuid,text,text,text,text,text,boolean),public.mt_supplier_save(uuid,uuid,uuid,text,text,text,text,text,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.supplier_save(uuid,uuid,uuid,text,text,text,text,text,boolean),public.mt_supplier_save(uuid,uuid,uuid,text,text,text,text,text,boolean) to authenticated;
create function public.mt_procurement_receive(p_store uuid,p_branch uuid,p_request uuid,p_supplier uuid,p_currency text,p_reference text,p_items jsonb,p_paid bigint,p_due date,p_batch boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.procurement_receive(p_store,p_branch,p_request,p_supplier,p_currency,p_reference,p_items,p_paid,p_due,p_batch)$$;
revoke all on function tenant_private.procurement_receive(uuid,uuid,uuid,uuid,text,text,jsonb,bigint,date,boolean),public.mt_procurement_receive(uuid,uuid,uuid,uuid,text,text,jsonb,bigint,date,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.procurement_receive(uuid,uuid,uuid,uuid,text,text,jsonb,bigint,date,boolean),public.mt_procurement_receive(uuid,uuid,uuid,uuid,text,text,jsonb,bigint,date,boolean) to authenticated;
create function public.mt_procurement_due(p_store uuid,p_request uuid,p_purchase uuid,p_due date) returns uuid language sql security invoker set search_path='' as $$select tenant_private.procurement_due(p_store,p_request,p_purchase,p_due)$$;
revoke all on function tenant_private.procurement_due(uuid,uuid,uuid,date),public.mt_procurement_due(uuid,uuid,uuid,date) from public,anon,authenticated,service_role;
grant execute on function tenant_private.procurement_due(uuid,uuid,uuid,date),public.mt_procurement_due(uuid,uuid,uuid,date) to authenticated;
create function public.mt_procurement_list(p_store uuid,p_kind text,p_after uuid,p_limit integer) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.procurement_list(p_store,p_kind,p_after,p_limit)$$;
revoke all on function tenant_private.procurement_list(uuid,text,uuid,integer),public.mt_procurement_list(uuid,text,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.procurement_list(uuid,text,uuid,integer),public.mt_procurement_list(uuid,text,uuid,integer) to authenticated;
create function public.mt_procurement_aging(p_store uuid,p_currency text,p_branch uuid,p_all boolean,p_asof date) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.procurement_aging(p_store,p_currency,p_branch,p_all,p_asof)$$;
revoke all on function tenant_private.procurement_aging(uuid,text,uuid,boolean,date),public.mt_procurement_aging(uuid,text,uuid,boolean,date) from public,anon,authenticated,service_role;
grant execute on function tenant_private.procurement_aging(uuid,text,uuid,boolean,date),public.mt_procurement_aging(uuid,text,uuid,boolean,date) to authenticated;
revoke all on function tenant_private.procurement_allowed(uuid,text),tenant_private.procurement_write(uuid,text,uuid),tenant_private.guard_archived_supplier() from public,anon,authenticated,service_role;
commit;
