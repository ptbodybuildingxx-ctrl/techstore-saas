-- Immutable optional sale invoice metadata, committed atomically with the canonical sale.
begin;
create table tenant_private.sale_invoice_details (
 store_id uuid not null,sale_id uuid not null,request_id uuid not null,actor uuid not null,payload jsonb not null,document jsonb not null,result jsonb not null,created_at timestamptz not null default now(),primary key(store_id,sale_id),unique(store_id,request_id),foreign key(store_id,sale_id) references public.mt_sales(store_id,id)
);
alter table tenant_private.sale_invoice_details enable row level security;
revoke all on tenant_private.sale_invoice_details from public,anon,authenticated,service_role;
create function tenant_private.issue_sale_invoice(s uuid,b uuid,r uuid,c text,items jsonb,meta jsonb,terms jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare prev tenant_private.sale_invoice_details%rowtype;payload jsonb;doc jsonb;result jsonb;ln jsonb;p uuid;months integer;serial text;customer uuid;customer_name text;customer_phone text;title text;note text;issued date;sid uuid;warranties jsonb:='[]';
begin
 perform 1 from public.saas_stores where id=s for update;
 if not coalesce(tenant_private.can_sell(s),false) or not coalesce(tenant_private.staff_action_allowed(s,'sell'),false) or (tenant_private.current_branch_scope(s) is not null and tenant_private.current_branch_scope(s) is distinct from b) then raise exception 'Sale denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 if r is null or c is null or jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items) not between 1 and 100 or jsonb_typeof(meta) is distinct from 'object' or octet_length(meta::text)>40000 or (select count(*) from jsonb_object_keys(meta))<>5 or not(meta ?& array['title','customer','phone','terms','lines']) then raise exception 'Invalid invoice metadata';end if;
 if jsonb_typeof(meta->'title') is distinct from 'string' or jsonb_typeof(meta->'customer') is distinct from 'string' or jsonb_typeof(meta->'phone') is distinct from 'string' or jsonb_typeof(meta->'terms') is distinct from 'string' or jsonb_typeof(meta->'lines') is distinct from 'array' then raise exception 'Invalid invoice metadata';end if;
 title:=btrim(meta->>'title');customer_name:=btrim(meta->>'customer');customer_phone:=btrim(meta->>'phone');note:=btrim(meta->>'terms');
 if length(title)>100 or length(customer_name)>160 or length(customer_phone)>100 or length(note)>1000 or jsonb_array_length(meta->'lines')<>jsonb_array_length(items) then raise exception 'Invalid invoice metadata';end if;
 if terms is not null and (jsonb_typeof(terms) is distinct from 'object' or (select count(*) from jsonb_object_keys(terms))<>4 or not(terms ?& array['customer','deposit','count','due'])) then raise exception 'Invalid credit terms';end if;
 if terms is not null and tenant_private.member_role(s)<>'owner' then raise exception 'Owner required for credit' using errcode='42501';end if;
 payload:=jsonb_build_object('branch',b,'currency',c,'items',items,'meta',meta,'terms',terms);
 select * into prev from tenant_private.sale_invoice_details where store_id=s and request_id=r;
 if found then if prev.actor<>auth.uid() or prev.payload is distinct from payload then raise exception 'Conflicting invoice request';end if;return prev.result;end if;
 if exists(select 1 from public.mt_sales where store_id=s and request_id=r) then raise exception 'Existing sale cannot receive new invoice details';end if;
 issued:=(now() at time zone 'Asia/Damascus')::date;
 for ln in select value from jsonb_array_elements(meta->'lines') loop
  if jsonb_typeof(ln) is distinct from 'object' or (select count(*) from jsonb_object_keys(ln))<>3 or not (ln ?& array['product_id','months','serial']) or jsonb_typeof(ln->'product_id') is distinct from 'string' or jsonb_typeof(ln->'months') is distinct from 'number' or jsonb_typeof(ln->'serial') is distinct from 'string' or coalesce(ln->>'months','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid warranty line';end if;
  p:=(ln->>'product_id')::uuid;months:=(ln->>'months')::integer;serial:=btrim(ln->>'serial');
  if p is null or months not between 0 and 120 or length(serial)>150 or not exists(select 1 from jsonb_array_elements(items) i where (i->>'product_id')::uuid=p) or exists(select 1 from jsonb_array_elements(warranties) i where (i->>'product_id')::uuid=p) then raise exception 'Invalid warranty line';end if;
  warranties:=warranties||jsonb_build_array(jsonb_build_object('product_id',p,'months',months,'serial',serial,'until',case when months>0 then (issued+make_interval(months=>months))::date else null end));
 end loop;
 if terms is not null then
  customer:=(terms->>'customer')::uuid;
  select name,phone into customer_name,customer_phone from public.mt_customers where store_id=s and id=customer;
  if not found then raise exception 'Unknown customer';end if;
  if b is null then result:=tenant_private.record_credit_sale(s,r,c,items,customer,(terms->>'deposit')::bigint,(terms->>'count')::integer,(terms->>'due')::date);
  else result:=tenant_private.branch_credit_sale(s,b,r,c,items,customer,(terms->>'deposit')::bigint,(terms->>'count')::integer,(terms->>'due')::date);end if;
 else
  if b is null then result:=tenant_private.record_currency_sale(s,r,c,items);
  else result:=tenant_private.branch_cash_sale(s,b,r,c,items);end if;
 end if;
 sid:=(result->>'id')::uuid;
 doc:=jsonb_build_object('title',title,'customer',customer_name,'phone',customer_phone,'terms',note,'lines',warranties,'issued',issued);
 insert into tenant_private.sale_invoice_details values(s,sid,r,auth.uid(),payload,doc,result,now());return result;
end $$;
create function tenant_private.sale_invoice_read(s uuid,p uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(s);sc uuid:=tenant_private.current_branch_scope(s);doc jsonb;
begin
 if role_now is null or role_now not in ('owner','cashier') or not coalesce(tenant_private.staff_action_allowed(s,'sales_read'),false) or not exists(select 1 from public.mt_sales a left join tenant_private.branch_sales b on b.store_id=a.store_id and b.sale_id=a.id where a.store_id=s and a.id=p and (role_now='owner' or a.actor=auth.uid()) and (sc is null or sc=b.branch_id)) then raise exception 'Invoice read denied' using errcode='42501';end if;
 select document into doc from tenant_private.sale_invoice_details where store_id=s and sale_id=p;
 if not found then return null;end if;
 return doc||jsonb_build_object('returned',coalesce((select jsonb_agg(jsonb_build_object('product_id',x.product_id,'units',x.units)) from (select product_id,sum(units)::bigint units from public.mt_returns where store_id=s and sale_id=p group by product_id)x),'[]'::jsonb));
end $$;
create function public.mt_issue_sale_invoice(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb,p_metadata jsonb,p_terms jsonb default null) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.issue_sale_invoice(p_store,p_branch,p_request,p_currency,p_lines,p_metadata,p_terms)$$;
create function public.mt_sale_invoice_read(p_store uuid,p_sale uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.sale_invoice_read(p_store,p_sale)$$;
revoke all on function tenant_private.issue_sale_invoice(uuid,uuid,uuid,text,jsonb,jsonb,jsonb),tenant_private.sale_invoice_read(uuid,uuid),public.mt_issue_sale_invoice(uuid,uuid,uuid,text,jsonb,jsonb,jsonb),public.mt_sale_invoice_read(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.issue_sale_invoice(uuid,uuid,uuid,text,jsonb,jsonb,jsonb),tenant_private.sale_invoice_read(uuid,uuid),public.mt_issue_sale_invoice(uuid,uuid,uuid,text,jsonb,jsonb,jsonb),public.mt_sale_invoice_read(uuid,uuid) to authenticated;
commit;
