-- 117: consistent operation restrictions, direct-read branch isolation, owner-visible effective permissions.
begin;
alter table tenant_private.staff_denials drop constraint staff_denials_action_check;
alter table tenant_private.staff_denials add constraint staff_denials_action_check check(action in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish','repair_create','product_price_edit','customer_create','debt_payment','quote_create','quote_read','receipt_read','warranty_read','receivable_read','customer_edit','credit_sale','standalone_open','standalone_payment','payable_manage','procurement_read','supplier_write','purchase_write','notifications_read'));

create function tenant_private.staff_sale_scope(p_store uuid,p_sale uuid,p_actor uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store)='owner' or (tenant_private.member_role(p_store)='cashier' and p_actor=auth.uid() and (tenant_private.current_branch_scope(p_store) is null or exists(select 1 from tenant_private.branch_sales b where b.store_id=p_store and b.sale_id=p_sale and b.branch_id=tenant_private.current_branch_scope(p_store)))),false)
$$;
revoke all on function tenant_private.staff_sale_scope(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function tenant_private.staff_sale_scope(uuid,uuid,uuid) to authenticated;
create policy mt_staff_sales_branch_restrict on public.mt_sales as restrictive for select to authenticated using(tenant_private.staff_sale_scope(store_id,id,actor));

CREATE OR REPLACE FUNCTION tenant_private.staff_permission_set(p_store uuid, p_user uuid, p_action text, p_allowed boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 perform tenant_private.owner_write(p_store);
 if p_allowed is null or p_action is null or p_action not in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish','repair_create','product_price_edit','customer_create','debt_payment','quote_create','quote_read','receipt_read','warranty_read','receivable_read','customer_edit','credit_sale','standalone_open','standalone_payment','payable_manage','procurement_read','supplier_write','purchase_write','notifications_read') or not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role<>'owner') then raise exception 'Invalid permission' using errcode='22023';end if;
 if p_allowed then delete from tenant_private.staff_denials where store_id=p_store and user_id=p_user and action=p_action;
 else insert into tenant_private.staff_denials(store_id,user_id,action,actor) values(p_store,p_user,p_action,auth.uid()) on conflict do nothing;end if;return p_allowed;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.quote_list(p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare role_now text:=tenant_private.member_role(p_store);r jsonb;
begin
 if not coalesce(role_now in ('owner','cashier'),false) or not tenant_private.staff_action_allowed(p_store,'quote_read') then raise exception 'Quote access denied' using errcode='42501';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page' using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc,id desc),'[]'::jsonb) into r from (select id,customer,currency,valid_until,total_minor,created_at from tenant_private.price_quotes where store_id=p_store and (role_now='owner' or actor=auth.uid()) and (p_before is null or (created_at,id)<(p_before,p_before_id)) order by created_at desc,id desc limit 50)x;return r;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.quote_read(p_store uuid, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare role_now text:=tenant_private.member_role(p_store);r jsonb;
begin
 if not tenant_private.staff_action_allowed(p_store,'quote_read') then raise exception 'Quote read denied' using errcode='42501';end if;
 select jsonb_build_object('id',id,'customer',customer,'currency',currency,'valid_until',valid_until,'total_minor',total_minor,'created_at',created_at,'lines',lines,'identity',identity) into r from tenant_private.price_quotes where store_id=p_store and id=p_id and (role_now='owner' or (role_now='cashier' and actor=auth.uid()));
 if not found then raise exception 'Quote access denied' using errcode='42501';end if;return r;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.quote_create(p_store uuid, p_request uuid, p_customer text, p_currency text, p_until date, p_lines jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q tenant_private.price_quotes%rowtype;x jsonb;pr record;pid uuid;u bigint;price bigint;v_total bigint:=0;v_lines jsonb:='[]'::jsonb;norm jsonb;today date:=(now() at time zone 'Asia/Damascus')::date;
begin
 if not coalesce(tenant_private.can_sell(p_store),false) or not tenant_private.staff_action_allowed(p_store,'quote_create') or not tenant_private.staff_action_allowed(p_store,'catalog_read') then raise exception 'Quote write denied' using errcode='42501';end if;
 if p_request is null or p_customer is null or length(btrim(p_customer)) not between 1 and 160 or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_until is null or jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>50000 then raise exception 'Invalid quote' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' or not (x ?& array['product_id','units','expected_price_minor']) then raise exception 'Invalid line' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line values' using errcode='22023';end if;
  if (x->>'units')::bigint not between 1 and 10000 or (x->>'expected_price_minor')::bigint not between 1 and 100000000 then raise exception 'Invalid amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into norm from jsonb_array_elements(p_lines);
 perform 1 from public.saas_stores where id=p_store for update;
 select * into q from tenant_private.price_quotes where store_id=p_store and request_id=p_request;
 if found then if q.actor<>auth.uid() or q.customer<>btrim(p_customer) or q.currency<>p_currency or q.valid_until<>p_until or q.request_lines is distinct from norm then raise exception 'Conflicting quote' using errcode='22023';end if;return q.id;end if;
 if p_until<today or p_until>today+90 then raise exception 'Invalid validity' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(norm) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;price:=(x->>'expected_price_minor')::bigint;
  select p.name,p.sku,pp.price_minor into pr from public.mt_products p join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and p.id=pid;
  if not found or pr.price_minor is distinct from price then raise exception 'Product unavailable or price changed' using errcode='22023';end if;
  v_total:=v_total+u*price;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('product_name',pr.name,'sku',pr.sku,'units',u,'unit_price_minor',price,'line_total_minor',u*price));
 end loop;
 insert into tenant_private.price_quotes(store_id,request_id,actor,customer,currency,valid_until,total_minor,lines,request_lines,identity) values(p_store,p_request,auth.uid(),btrim(p_customer),p_currency,p_until,v_total,v_lines,norm,tenant_private.effective_receipt_settings(p_store)) returning id into q.id;
 return q.id;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.sale_warranty_register(s uuid, q text, filter_state text, off integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare role_now text:=tenant_private.member_role(s);sc uuid:=tenant_private.current_branch_scope(s);today date:=(now() at time zone 'Asia/Damascus')::date;
begin
 if role_now is null or role_now not in ('owner','cashier') or not coalesce(tenant_private.staff_action_allowed(s,'sales_read'),false) or not tenant_private.staff_action_allowed(s,'warranty_read') then raise exception 'Warranty access denied' using errcode='42501';end if;
 if q is null or length(q)>160 or filter_state is null or filter_state not in ('all','active','expired','returned') or off is null or off not between 0 and 100000 then raise exception 'Invalid warranty page';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.number desc,x.product_id) from (
 select a.id sale_id,a.number,a.currency,a.total_minor,a.payment_mode,a.created_at,a.request_id,l.product_id,l.product_name,l.sku,l.units,coalesce(ret.units,0) returned_units,l.units-coalesce(ret.units,0) covered_units,d.document->>'customer' customer,w->>'serial' serial,(w->>'months')::integer months,(w->>'until')::date until_date,b.branch_id,
 case when l.units<=coalesce(ret.units,0) then 'returned' when (w->>'until')::date<today then 'expired' else 'active' end state
 from tenant_private.sale_invoice_details d join public.mt_sales a on a.store_id=d.store_id and a.id=d.sale_id
 join public.mt_sale_lines l on l.store_id=a.store_id and l.sale_id=a.id
 cross join lateral jsonb_array_elements(d.document->'lines') w
 left join tenant_private.branch_sales b on b.store_id=a.store_id and b.sale_id=a.id
 left join lateral (select sum(r.units)::bigint units from public.mt_returns r where r.store_id=a.store_id and r.sale_id=a.id and r.product_id=l.product_id) ret on true
 where d.store_id=s and (role_now='owner' or a.actor=auth.uid()) and (sc is null or sc=b.branch_id) and (w->>'product_id')::uuid=l.product_id and (w->>'months')::integer>0
 and (btrim(q)='' or strpos(lower(concat_ws(' ',a.number::text,l.product_name,l.sku,d.document->>'customer',w->>'serial')),lower(btrim(q)))>0)
 and (filter_state='all' or filter_state=case when l.units<=coalesce(ret.units,0) then 'returned' when (w->>'until')::date<today then 'expired' else 'active' end)
 order by a.number desc,l.product_id offset off limit 50)x),'[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.receipt_snapshot(p_store uuid, p_kind text, p_document uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare role_now text:=tenant_private.member_role(p_store);v jsonb;
begin
 if p_kind='sale' then
  if not tenant_private.staff_action_allowed(p_store,'receipt_read') or not tenant_private.staff_action_allowed(p_store,'sales_read') or not exists(select 1 from public.mt_sales s where s.store_id=p_store and s.id=p_document and tenant_private.staff_sale_scope(p_store,s.id,s.actor)) then raise exception 'Receipt access denied' using errcode='42501';end if;
 elsif p_kind='repair' then
  if role_now is distinct from 'owner' or not exists(select 1 from public.mt_repair_invoices where store_id=p_store and id=p_document) then raise exception 'Receipt access denied' using errcode='42501';end if;
 else raise exception 'Invalid receipt kind' using errcode='22023';end if;
 select settings into v from tenant_private.receipt_snapshots where store_id=p_store and kind=p_kind and document_id=p_document;
 return v;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.sale_invoice_read(s uuid, p uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare role_now text:=tenant_private.member_role(s);sc uuid:=tenant_private.current_branch_scope(s);doc jsonb;
begin
 if role_now is null or role_now not in ('owner','cashier') or not coalesce(tenant_private.staff_action_allowed(s,'sales_read'),false) or not tenant_private.staff_action_allowed(s,'receipt_read') or not exists(select 1 from public.mt_sales a left join tenant_private.branch_sales b on b.store_id=a.store_id and b.sale_id=a.id where a.store_id=s and a.id=p and (role_now='owner' or a.actor=auth.uid()) and (sc is null or sc=b.branch_id)) then raise exception 'Invoice read denied' using errcode='42501';end if;
 select document into doc from tenant_private.sale_invoice_details where store_id=s and sale_id=p;
 if not found then return null;end if;
 return doc||jsonb_build_object('returned',coalesce((select jsonb_agg(jsonb_build_object('product_id',x.product_id,'units',x.units)) from (select product_id,sum(units)::bigint units from public.mt_returns where store_id=s and sale_id=p group by product_id)x),'[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.repair_tracking(p_store uuid, p_repair uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;
begin
 perform tenant_private.require_repair(p_store,p_repair,false);
 if not tenant_private.staff_action_allowed(p_store,'receipt_read') then raise exception 'Intake receipt denied' using errcode='42501';end if;
 select jsonb_build_object('code',t.code,'identity',t.identity,'device',r0.device,'fault',r0.fault,'state',r0.state,'created_at',r0.created_at,'repair_id',r0.id) into r from tenant_private.repair_tracking t join public.mt_repairs r0 on r0.store_id=t.store_id and r0.id=t.repair_id where t.store_id=p_store and t.repair_id=p_repair;
 return r;
end
$function$;

CREATE OR REPLACE FUNCTION tenant_private.repair_transition(p_store uuid, p_request uuid, p_repair uuid, p_next text, p_note text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.mt_repairs%rowtype; e public.mt_repair_events%rowtype; role_now text;
begin
 role_now:=tenant_private.member_role(p_store);
 if coalesce(role_now,'') not in ('owner','tech') then raise exception 'Repair role required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 role_now:=tenant_private.member_role(p_store);
 if coalesce(role_now,'') not in ('owner','tech') or not tenant_private.shared_licensed(p_store) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_repair is null or p_next is null or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid transition' using errcode='22023';end if;
 if not tenant_private.repair_scope_allowed(p_store,p_repair) or not tenant_private.staff_action_allowed(p_store,'repair_transition') then raise exception 'Repair branch denied' using errcode='42501';end if;
 if p_next in ('delivered','cancelled') and role_now<>'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into e from public.mt_repair_events where store_id=p_store and request_id=p_request;
 if found then
  if e.actor<>auth.uid() or e.repair_id<>p_repair or e.next_state<>p_next or e.note<>btrim(p_note) then raise exception 'Conflicting repair transition' using errcode='22023';end if;
  return e.next_state;
 end if;
 select * into r from public.mt_repairs where store_id=p_store and id=p_repair for update;
 if not found or not ((r.state='received' and p_next in ('diagnosing','cancelled')) or (r.state='diagnosing' and p_next in ('repairing','cancelled')) or (r.state='repairing' and p_next in ('ready','cancelled')) or (r.state='ready' and p_next in ('delivered','repairing','cancelled'))) then raise exception 'Invalid repair transition' using errcode='22023';end if;
 update public.mt_repairs set state=p_next where store_id=p_store and id=p_repair;
 insert into public.mt_repair_events(store_id,request_id,repair_id,prior_state,next_state,note,actor) values(p_store,p_request,p_repair,r.state,p_next,btrim(p_note),auth.uid());
 return p_next;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.repair_evidence_add(p_store uuid, p_repair uuid, p_id uuid, p_kind text, p_note text, p_photo text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old tenant_private.repair_evidence%rowtype;begin
 perform 1 from public.saas_stores where id=p_store for update;perform tenant_private.require_repair(p_store,p_repair,true);
 if not tenant_private.staff_action_allowed(p_store,'repair_evidence') then raise exception 'Evidence write denied' using errcode='42501';end if;
 if p_id is null or p_kind is null or p_kind not in ('before','after','task') or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid evidence' using errcode='22023';end if;
 select * into old from tenant_private.repair_evidence where store_id=p_store and id=p_id;
 if found then if old.actor<>auth.uid() or old.repair_id<>p_repair or old.kind<>p_kind or old.note<>btrim(p_note) or old.photo is distinct from p_photo then raise exception 'Conflicting evidence' using errcode='22023';end if;return p_id;end if;
 if (select count(*) from tenant_private.repair_evidence where store_id=p_store and repair_id=p_repair)>=50 then raise exception 'Evidence limit' using errcode='22023';end if;
 if not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state not in ('delivered','cancelled')) then raise exception 'Repair closed' using errcode='22023';end if;
 insert into tenant_private.repair_evidence(store_id,repair_id,id,kind,note,photo,actor) values(p_store,p_repair,p_id,p_kind,btrim(p_note),p_photo,auth.uid());return p_id;
end
$function$;

CREATE OR REPLACE FUNCTION tenant_private.staff_clock(p_store uuid, p_request uuid, p_start boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v tenant_private.staff_shifts%rowtype;
begin
 if tenant_private.member_role(p_store) is null or p_request is null or p_start is null then raise exception 'Staff access required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if tenant_private.member_role(p_store) is null or not tenant_private.shared_licensed(p_store) or not tenant_private.staff_action_allowed(p_store,'attendance') then raise exception 'Staff access required' using errcode='42501';end if;
 select * into v from tenant_private.staff_shifts where store_id=p_store and (id=p_request or end_request=p_request);
 if found then if v.user_id<>auth.uid() or (p_start and v.id<>p_request) or (not p_start and v.end_request is distinct from p_request) then raise exception 'Conflicting request' using errcode='22023';end if;return v.id;end if;
 if p_start then insert into tenant_private.staff_shifts(store_id,user_id,id,branch_id) values(p_store,auth.uid(),p_request,tenant_private.current_branch_scope(p_store));return p_request;end if;
 update tenant_private.staff_shifts set ended_at=now(),end_request=p_request where store_id=p_store and user_id=auth.uid() and ended_at is null returning * into v;
 if not found then raise exception 'No open shift' using errcode='22023';end if;return v.id;
end
$function$;

CREATE OR REPLACE FUNCTION tenant_private.record_sale_core(p_store uuid, p_request uuid, p_currency text, p_lines jsonb, p_customer uuid, p_deposit bigint, p_count integer, p_due date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare x jsonb; v_product uuid; v_units bigint; v_expected bigint; v_price bigint; v_sum bigint:=0; v_norm jsonb; v_previous jsonb; v_settings tenant_private.sales_settings%rowtype; v_sale public.mt_sales%rowtype; pr public.mt_products%rowtype; d public.mt_debts%rowtype; v_payment uuid; v_remaining bigint; v_part bigint; i integer;
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) or not tenant_private.staff_action_allowed(p_store,'sell') then raise exception 'Sale not permitted' using errcode='42501';end if;
 if p_customer is not null then
  if not tenant_private.receivable_allowed(p_store,'credit_sale') then raise exception 'Credit sale denied' using errcode='42501';end if;
  perform tenant_private.receivable_require_credit_scope(p_store,p_request,p_deposit);
  perform tenant_private.assert_receivable_live(p_store,p_request,'credit');
  if p_deposit is null or p_deposit<0 or p_count is null or p_count not between 1 and 60 or p_due is null then raise exception 'Invalid credit terms' using errcode='22023';end if;
 elsif p_deposit is not null or p_count is not null or p_due is not null then raise exception 'Unexpected credit terms' using errcode='22023';end if;
 if p_currency is null or p_currency not in ('SYP','USD','EUR') or p_request is null or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid sale' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>50000 then raise exception 'Invalid sale size' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid line' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line values' using errcode='22023';end if;
  v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  if v_units not between 1 and 10000 or v_expected not between 1 and 100000000 then raise exception 'Invalid line amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into v_norm from jsonb_array_elements(p_lines);
 select * into v_sale from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then
  if not tenant_private.staff_sale_scope(p_store,v_sale.id,v_sale.actor) then raise exception 'Sale replay scope denied' using errcode='42501';end if;
  select jsonb_agg(jsonb_build_object('product_id',l.product_id,'units',l.units,'expected_price_minor',l.unit_price_minor) order by l.product_id) into v_previous from public.mt_sale_lines l where l.store_id=p_store and l.sale_id=v_sale.id;
  if v_sale.payment_mode<>(case when p_customer is null then 'cash' else 'credit' end) then raise exception 'Conflicting payment mode' using errcode='22023';end if;
  if p_customer is not null then
   select * into d from public.mt_debts where store_id=p_store and sale_id=v_sale.id;
   if not found or d.customer_id<>p_customer or d.deposit_minor<>p_deposit or d.installment_count<>p_count or d.first_due<>p_due then raise exception 'Conflicting credit terms' using errcode='22023';end if;
  end if;
  if v_sale.actor<>auth.uid() or v_sale.currency<>p_currency or v_previous is distinct from v_norm then raise exception 'Conflicting sale request' using errcode='22023';end if;
  return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
 end if;
 select * into v_settings from tenant_private.sales_settings where store_id=p_store for update;
 if not found or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Enable sale currency first' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=v_product for update;
  if not found or pr.quantity<v_units then raise exception 'Insufficient stock or unknown product' using errcode='22023';end if;
  select price_minor into v_price from public.mt_product_prices where store_id=p_store and product_id=v_product and currency=p_currency;
  if not found then raise exception 'Unavailable product';end if;
  v_price:=tenant_private.authorized_sale_unit_price(p_store,p_request,p_currency,v_product,v_price);
  if v_price is distinct from v_expected then raise exception 'Unavailable product, price changed or insufficient stock' using errcode='22023';end if;
  v_sum:=v_sum+v_units*v_price;
 end loop;
 if p_customer is not null then
  if not exists(select 1 from public.mt_customers where store_id=p_store and id=p_customer) or p_deposit>=v_sum or v_sum-p_deposit<p_count or p_due<(now() at time zone 'UTC')::date or p_due>(now() at time zone 'UTC')::date+366 then raise exception 'Invalid customer, deposit or due date' using errcode='22023';end if;
 end if;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(p_store,v_settings.next_number,p_request,auth.uid(),p_currency,v_sum,case when p_customer is null then 'cash' else 'credit' end) returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;
  update public.mt_products set quantity=quantity-v_units where store_id=p_store and id=v_product returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,v_sale.id,pr.id,pr.sku,pr.name,v_units,(x->>'expected_price_minor')::bigint);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pr.id,-v_units,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 if p_customer is null then
  insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(p_store,v_sale.id,v_sale.currency,v_sum);
 else
  v_remaining:=v_sum-p_deposit;
  insert into public.mt_debts(store_id,sale_id,customer_id,currency,principal_minor,deposit_minor,remaining_minor,installment_count,first_due) values(p_store,v_sale.id,p_customer,p_currency,v_sum,p_deposit,v_remaining,p_count,p_due) returning * into d;
  for i in 1..p_count loop
   v_part:=v_remaining/p_count+case when i<=v_remaining%p_count then 1 else 0 end;
   insert into public.mt_installments(store_id,debt_id,number,due_date,amount_minor) values(p_store,d.id,i,(p_due+make_interval(months=>i-1))::date,v_part);
  end loop;
  if p_deposit>0 then
   insert into public.mt_debt_payments(store_id,debt_id,request_id,amount_minor,is_deposit,actor) values(p_store,d.id,gen_random_uuid(),p_deposit,true,auth.uid()) returning id into v_payment;
   insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,debt_payment_id) values(p_store,gen_random_uuid(),'debt_payment',p_currency,p_deposit,'Credit sale deposit',auth.uid(),v_payment);
  end if;
 end if;
 return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.procurement_allowed(s uuid, a text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(tenant_private.member_role(s)='owner' or (tenant_private.member_role(s)='stock' and exists(select 1 from tenant_private.procurement_grants g where g.store_id=s and g.user_id=auth.uid() and g.read_allowed and tenant_private.staff_action_allowed(s,'procurement_read') and case a when 'read' then true when 'supplier' then g.manage_suppliers and tenant_private.staff_action_allowed(s,'supplier_write') when 'receive' then g.receive_credit and tenant_private.staff_action_allowed(s,'purchase_write') else false end)),false)
$function$;

CREATE OR REPLACE FUNCTION tenant_private.procurement_access(s uuid, u uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target uuid:=coalesce(u,auth.uid());g tenant_private.procurement_grants%rowtype;r text;
begin
 r:=tenant_private.member_role(s);
 if r is null or (target<>auth.uid() and r<>'owner') then raise exception 'Access denied' using errcode='42501';end if;
 if target=auth.uid() and r='owner' then return jsonb_build_object('read',true,'supplier',true,'receive',true,'licensed',tenant_private.shared_licensed(s),'branch',null);end if;
 select * into g from tenant_private.procurement_grants where store_id=s and user_id=target and exists(select 1 from tenant_private.members m where m.store_id=s and m.user_id=target and m.active and m.role='stock');
 return jsonb_build_object('read',coalesce(g.read_allowed,false) and not exists(select 1 from tenant_private.staff_denials where store_id=s and user_id=target and action='procurement_read'),'supplier',coalesce(g.manage_suppliers,false) and not exists(select 1 from tenant_private.staff_denials where store_id=s and user_id=target and action in ('procurement_read','supplier_write')),'receive',coalesce(g.receive_credit,false) and not exists(select 1 from tenant_private.staff_denials where store_id=s and user_id=target and action in ('procurement_read','purchase_write')),'licensed',tenant_private.shared_licensed(s),'branch',case when target=auth.uid() then tenant_private.current_branch_scope(s) end);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.receivable_allowed(p_store uuid, p_action text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(tenant_private.member_role(p_store)='owner' or (
 tenant_private.member_role(p_store)='cashier' and tenant_private.shared_licensed(p_store) and
 exists(select 1 from tenant_private.receivable_grants g where g.store_id=p_store and g.user_id=auth.uid()
 and g.branch_id is not distinct from tenant_private.current_branch_scope(p_store)
 and 'read'=any(g.actions) and p_action=any(g.actions)) and tenant_private.staff_action_allowed(p_store,'receivable_read') and
 case p_action when 'customer_create' then tenant_private.staff_action_allowed(p_store,'customer_create')
 when 'debt_payment' then tenant_private.staff_action_allowed(p_store,'debt_payment')
 when 'standalone_payment' then tenant_private.staff_action_allowed(p_store,'debt_payment') and tenant_private.staff_action_allowed(p_store,'standalone_payment')
 when 'credit_sale' then tenant_private.staff_action_allowed(p_store,'sell') and tenant_private.staff_action_allowed(p_store,'credit_sale')
 when 'customer_edit' then tenant_private.staff_action_allowed(p_store,'customer_edit')
 when 'standalone_open' then tenant_private.staff_action_allowed(p_store,'standalone_open')
 when 'payable_manage' then tenant_private.staff_action_allowed(p_store,'payable_manage')
 else true end),false)
$function$;

CREATE OR REPLACE FUNCTION tenant_private.receivable_grant_read(p_store uuid, p_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid:=coalesce(p_user,auth.uid());b uuid;granted text[]:='{}';effective text[]:='{}';role_now text:=tenant_private.member_role(p_store);
begin
 if role_now is null or (u is distinct from auth.uid() and role_now<>'owner') then raise exception 'Access denied' using errcode='42501';end if;
 if u=auth.uid() and role_now='owner' then
 granted:=array['read','customer_create','customer_edit','credit_sale','debt_payment','standalone_open','standalone_payment','payable_manage'];effective:=granted;
 elsif exists(select 1 from tenant_private.members where store_id=p_store and user_id=u and active and role='cashier') then
 select branch_id into b from tenant_private.cashier_branch_scope where store_id=p_store and user_id=u;
 select coalesce((select actions from tenant_private.receivable_grants where store_id=p_store and user_id=u and branch_id is not distinct from b),'{}'::text[]) into granted;
 select coalesce(array_agg(a order by a),'{}'::text[]) into effective from unnest(granted) a where tenant_private.shared_licensed(p_store) and not exists(select 1 from tenant_private.staff_denials d where d.store_id=p_store and d.user_id=u and (d.action='receivable_read' or d.action=a or (a='credit_sale' and d.action='sell') or (a='standalone_payment' and d.action='debt_payment')));
 elsif p_user is not null then raise exception 'Unknown active cashier' using errcode='22023';
 end if;
 return jsonb_build_object('user',u,'branch',b,'granted',to_jsonb(granted),'effective',to_jsonb(effective));
end $function$;

create or replace function public.mt_sale_receipt_lines(p_store uuid,p_sale uuid)
returns setof public.mt_sale_lines language sql stable set search_path='' as $$
 select * from public.mt_sale_lines where store_id=p_store and sale_id=p_sale and tenant_private.staff_action_allowed(p_store,'receipt_read') order by product_id limit 100
$$;
create or replace function public.mt_work_alerts(p_store uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);r jsonb:='{}'::jsonb;
begin
 if role_now is null then raise exception 'Tenant access denied' using errcode='42501';end if;
 if not tenant_private.staff_action_allowed(p_store,'notifications_read') then return r;end if;
 if role_now in ('owner','stock') and tenant_private.staff_action_allowed(p_store,'catalog_read') then r:=r||jsonb_build_object('low_stock',(select count(*) from tenant_private.scoped_products(p_store,null,'',null,100,true)));end if;
 if role_now in ('owner','tech') and tenant_private.staff_action_allowed(p_store,'repair_read') then r:=r||jsonb_build_object('repairs_ready',(select count(*) from public.mt_repairs where store_id=p_store and state='ready'),'repairs_received',(select count(*) from public.mt_repairs where store_id=p_store and state='received'));end if;
 if role_now='owner' then r:=r||jsonb_build_object('orders_pending',(select count(*) from public.mt_online_orders where store_id=p_store and state='pending'),'installments_overdue',(select count(*) from public.mt_installments where store_id=p_store and due_date<(now() at time zone 'Asia/Damascus')::date and paid_minor+waived_minor<amount_minor));end if;
 return r;
end $$;

commit;
