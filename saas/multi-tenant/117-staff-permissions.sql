-- 117: consistent operation restrictions, direct-read branch isolation, owner-visible effective permissions.
begin;
alter table tenant_private.staff_denials drop constraint staff_denials_action_check;
alter table tenant_private.staff_denials add constraint staff_denials_action_check check(action in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish','repair_create','product_price_edit','customer_create','debt_payment','quote_create','quote_read','receipt_read','warranty_read','receivable_read','customer_edit','credit_sale','standalone_open','standalone_payment','payable_manage','procurement_read','supplier_write','purchase_write','notifications_read','customer_read','debt_read','installment_read','supplier_read','purchase_read'));

create function tenant_private.staff_sale_scope(p_store uuid,p_sale uuid,p_actor uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store)='owner' or (tenant_private.member_role(p_store)='cashier' and p_actor=auth.uid() and exists(select 1 from public.mt_sales a where a.store_id=p_store and a.id=p_sale and a.actor=auth.uid()) and (tenant_private.current_branch_scope(p_store) is null or exists(select 1 from tenant_private.branch_sales b where b.store_id=p_store and b.sale_id=p_sale and b.branch_id=tenant_private.current_branch_scope(p_store)))),false)
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
 if p_allowed is null or p_action is null or p_action not in ('sell','stock_adjust','stock_transfer','product_create','repair_transition','repair_evidence','attendance','catalog_read','stock_history_read','sales_read','repair_read','product_edit','repair_task_finish','repair_create','product_price_edit','customer_create','debt_payment','quote_create','quote_read','receipt_read','warranty_read','receivable_read','customer_edit','credit_sale','standalone_open','standalone_payment','payable_manage','procurement_read','supplier_write','purchase_write','notifications_read','customer_read','debt_read','installment_read','supplier_read','purchase_read') or not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role<>'owner') then raise exception 'Invalid permission' using errcode='22023';end if;
 if p_allowed then delete from tenant_private.staff_denials where store_id=p_store and user_id=p_user and action=p_action;
 else insert into tenant_private.staff_denials(store_id,user_id,action,actor) values(p_store,p_user,p_action,auth.uid()) on conflict do nothing;end if;return p_allowed;
end $function$;

alter table tenant_private.price_quotes add column branch_id uuid;
alter table tenant_private.price_quotes add foreign key(store_id,branch_id) references tenant_private.branches(store_id,id);

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
 select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc,id desc),'[]'::jsonb) into r from (select id,customer,currency,valid_until,total_minor,created_at from tenant_private.price_quotes where store_id=p_store and (role_now='owner' or (actor=auth.uid() and (tenant_private.current_branch_scope(p_store) is null or branch_id=tenant_private.current_branch_scope(p_store)))) and (p_before is null or (created_at,id)<(p_before,p_before_id)) order by created_at desc,id desc limit 50)x;return r;
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
 select jsonb_build_object('id',id,'customer',customer,'currency',currency,'valid_until',valid_until,'total_minor',total_minor,'created_at',created_at,'lines',lines,'identity',identity) into r from tenant_private.price_quotes where store_id=p_store and id=p_id and (role_now='owner' or (role_now='cashier' and actor=auth.uid() and (tenant_private.current_branch_scope(p_store) is null or branch_id=tenant_private.current_branch_scope(p_store))));
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
 if found then if q.actor<>auth.uid() or q.branch_id is distinct from tenant_private.current_branch_scope(p_store) or q.customer<>btrim(p_customer) or q.currency<>p_currency or q.valid_until<>p_until or q.request_lines is distinct from norm then raise exception 'Conflicting quote' using errcode='22023';end if;return q.id;end if;
 if p_until<today or p_until>today+90 then raise exception 'Invalid validity' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(norm) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;price:=(x->>'expected_price_minor')::bigint;
  select p.name,p.sku,pp.price_minor into pr from public.mt_products p join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and p.id=pid and (tenant_private.current_branch_scope(p_store) is null or exists(select 1 from tenant_private.branch_stock bs where bs.store_id=p_store and bs.product_id=pid and bs.branch_id=tenant_private.current_branch_scope(p_store)));
  if not found or pr.price_minor is distinct from price then raise exception 'Product unavailable or price changed' using errcode='22023';end if;
  v_total:=v_total+u*price;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('product_name',pr.name,'sku',pr.sku,'units',u,'unit_price_minor',price,'line_total_minor',u*price));
 end loop;
 insert into tenant_private.price_quotes(store_id,request_id,actor,customer,currency,valid_until,total_minor,lines,request_lines,identity,branch_id) values(p_store,p_request,auth.uid(),btrim(p_customer),p_currency,p_until,v_total,v_lines,norm,tenant_private.effective_receipt_settings(p_store),tenant_private.current_branch_scope(p_store)) returning id into q.id;
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
 select coalesce(tenant_private.member_role(s)='owner' or (tenant_private.member_role(s)='stock' and exists(select 1 from tenant_private.procurement_grants g where g.store_id=s and g.user_id=auth.uid() and g.read_allowed and tenant_private.staff_action_allowed(s,'procurement_read') and case a when 'read' then (tenant_private.staff_action_allowed(s,'supplier_read') or tenant_private.staff_action_allowed(s,'purchase_read')) when 'supplier_read' then tenant_private.staff_action_allowed(s,'supplier_read') when 'purchase_read' then tenant_private.staff_action_allowed(s,'purchase_read') when 'supplier' then g.manage_suppliers and tenant_private.staff_action_allowed(s,'supplier_read') and tenant_private.staff_action_allowed(s,'supplier_write') when 'receive' then g.receive_credit and tenant_private.staff_action_allowed(s,'supplier_read') and tenant_private.staff_action_allowed(s,'purchase_read') and tenant_private.staff_action_allowed(s,'catalog_read') and tenant_private.staff_action_allowed(s,'stock_adjust') and tenant_private.staff_action_allowed(s,'purchase_write') else false end)),false)
$function$;

CREATE OR REPLACE FUNCTION tenant_private.procurement_access(s uuid, u uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target uuid:=coalesce(u,auth.uid());g tenant_private.procurement_grants%rowtype;r text;sr boolean;pr boolean;
begin
 r:=tenant_private.member_role(s);
 if r is null or (target<>auth.uid() and r<>'owner') then raise exception 'Access denied' using errcode='42501';end if;
 if target=auth.uid() and r='owner' then return jsonb_build_object('read',true,'supplier_read',true,'purchase_read',true,'supplier',true,'receive',true,'licensed',tenant_private.shared_licensed(s),'branch',null);end if;
 select * into g from tenant_private.procurement_grants where store_id=s and user_id=target and exists(select 1 from tenant_private.members m where m.store_id=s and m.user_id=target and m.active and m.role='stock');
 sr:=coalesce(g.read_allowed,false) and not exists(select 1 from tenant_private.staff_denials where store_id=s and user_id=target and action in ('procurement_read','supplier_read'));
 pr:=coalesce(g.read_allowed,false) and not exists(select 1 from tenant_private.staff_denials where store_id=s and user_id=target and action in ('procurement_read','purchase_read'));
 return jsonb_build_object('read',sr or pr,'supplier_read',sr,'purchase_read',pr,'supplier',sr and coalesce(g.manage_suppliers,false) and not exists(select 1 from tenant_private.staff_denials where store_id=s and user_id=target and action='supplier_write'),'receive',sr and pr and coalesce(g.receive_credit,false) and not exists(select 1 from tenant_private.staff_denials where store_id=s and user_id=target and action in ('purchase_write','catalog_read','stock_adjust')),'licensed',tenant_private.shared_licensed(s),'branch',case when target=auth.uid() then tenant_private.current_branch_scope(s) end);
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
 case p_action when 'customer_create' then tenant_private.staff_action_allowed(p_store,'customer_create') and tenant_private.staff_action_allowed(p_store,'customer_read')
 when 'debt_payment' then tenant_private.staff_action_allowed(p_store,'debt_payment') and tenant_private.staff_action_allowed(p_store,'debt_read')
 when 'standalone_payment' then tenant_private.staff_action_allowed(p_store,'debt_payment') and tenant_private.staff_action_allowed(p_store,'debt_read') and tenant_private.staff_action_allowed(p_store,'standalone_payment')
 when 'credit_sale' then tenant_private.staff_action_allowed(p_store,'sell') and tenant_private.staff_action_allowed(p_store,'customer_read') and tenant_private.staff_action_allowed(p_store,'debt_read') and tenant_private.staff_action_allowed(p_store,'credit_sale')
 when 'customer_edit' then tenant_private.staff_action_allowed(p_store,'customer_edit') and tenant_private.staff_action_allowed(p_store,'customer_read')
 when 'standalone_open' then tenant_private.staff_action_allowed(p_store,'standalone_open') and tenant_private.staff_action_allowed(p_store,'debt_read')
 when 'payable_manage' then tenant_private.staff_action_allowed(p_store,'payable_manage') and tenant_private.staff_action_allowed(p_store,'debt_read')
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
 select coalesce(array_agg(a order by a),'{}'::text[]) into effective from unnest(granted) a where tenant_private.shared_licensed(p_store) and not exists(select 1 from tenant_private.staff_denials d where d.store_id=p_store and d.user_id=u and (d.action='receivable_read' or d.action=a or (a='credit_sale' and d.action='sell') or (a='standalone_payment' and d.action='debt_payment') or (a in ('customer_create','customer_edit','credit_sale') and d.action='customer_read') or (a in ('credit_sale','debt_payment','standalone_open','standalone_payment','payable_manage') and d.action='debt_read')));
 elsif p_user is not null then raise exception 'Unknown active cashier' using errcode='22023';
 end if;
 return jsonb_build_object('user',u,'branch',b,'granted',to_jsonb(granted),'effective',to_jsonb(effective));
end $function$;

create or replace function public.mt_sale_receipt_lines(p_store uuid,p_sale uuid)
returns setof public.mt_sale_lines language sql stable set search_path='' as $$
 select * from public.mt_sale_lines where store_id=p_store and sale_id=p_sale and tenant_private.staff_action_allowed(p_store,'receipt_read') order by product_id limit 100
$$;
create function tenant_private.staff_low_stock_count(p_store uuid)
returns bigint language sql stable security definer set search_path='' as $$
 select case when tenant_private.member_role(p_store) in ('owner','stock') and tenant_private.staff_action_allowed(p_store,'catalog_read') then case when tenant_private.current_branch_scope(p_store) is null then (select count(*) from public.mt_products where store_id=p_store and quantity<=5) else (select count(*) from tenant_private.branch_stock where store_id=p_store and branch_id=tenant_private.current_branch_scope(p_store) and units<=5) end else 0 end
$$;
revoke all on function tenant_private.staff_low_stock_count(uuid) from public,anon,authenticated;
grant execute on function tenant_private.staff_low_stock_count(uuid) to authenticated;
create or replace function public.mt_work_alerts(p_store uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);r jsonb:='{}'::jsonb;
begin
 if role_now is null then raise exception 'Tenant access denied' using errcode='42501';end if;
 if not tenant_private.staff_action_allowed(p_store,'notifications_read') then return r;end if;
 if role_now in ('owner','stock') and tenant_private.staff_action_allowed(p_store,'catalog_read') then r:=r||jsonb_build_object('low_stock',tenant_private.staff_low_stock_count(p_store));end if;
 if role_now in ('owner','tech') and tenant_private.staff_action_allowed(p_store,'repair_read') then r:=r||jsonb_build_object('repairs_ready',(select count(*) from public.mt_repairs where store_id=p_store and state='ready'),'repairs_received',(select count(*) from public.mt_repairs where store_id=p_store and state='received'));end if;
 if role_now='owner' then r:=r||jsonb_build_object('orders_pending',(select count(*) from public.mt_online_orders where store_id=p_store and state='pending'),'installments_overdue',(select count(*) from public.mt_installments where store_id=p_store and due_date<(now() at time zone 'Asia/Damascus')::date and paid_minor+waived_minor<amount_minor));end if;
 return r;
end $$;

-- Moving a staff member invalidates explicit grants, including a move back to an old branch.
create function tenant_private.revoke_moved_staff_grants()
returns trigger language plpgsql security definer set search_path='' as $$
declare s uuid;u uuid;
begin
 if tg_op='UPDATE' and old.branch_id is not distinct from new.branch_id then return new;end if;
 if tg_op='DELETE' then s:=old.store_id;u:=old.user_id;else s:=new.store_id;u:=new.user_id;end if;
 delete from tenant_private.procurement_grants where store_id=s and user_id=u;
 delete from tenant_private.receivable_grants where store_id=s and user_id=u;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function tenant_private.revoke_moved_staff_grants() from public,anon,authenticated;
create trigger mt_revoke_moved_staff_grants after insert or update or delete on tenant_private.staff_branch_scope for each row execute function tenant_private.revoke_moved_staff_grants();
create trigger mt_revoke_moved_cashier_grants after insert or update or delete on tenant_private.cashier_branch_scope for each row execute function tenant_private.revoke_moved_staff_grants();

-- Direct API reads must obey the same role and branch restrictions as catalog screens.
create policy mt_staff_catalog_role_restrict on public.mt_products as restrictive for select to authenticated using(tenant_private.member_role(store_id) in ('owner','stock','cashier'));
create function tenant_private.staff_price_scope(p_store uuid,p_product uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) in ('owner','stock','cashier') and tenant_private.staff_action_allowed(p_store,'catalog_read') and (tenant_private.current_branch_scope(p_store) is null or exists(select 1 from tenant_private.branch_stock b where b.store_id=p_store and b.product_id=p_product and b.branch_id=tenant_private.current_branch_scope(p_store))),false)
$$;
revoke all on function tenant_private.staff_price_scope(uuid,uuid) from public,anon,authenticated;
grant execute on function tenant_private.staff_price_scope(uuid,uuid) to authenticated;
create policy mt_staff_price_branch_restrict on public.mt_product_prices as restrictive for select to authenticated using(tenant_private.staff_price_scope(store_id,product_id));
-- Individual directory, debt, schedule, supplier and purchase permissions.
CREATE OR REPLACE FUNCTION tenant_private.adjust_stock(p_store uuid, p_product uuid, p_delta bigint, p_request uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q bigint; e public.mt_stock_events%rowtype;
begin
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_write(p_store),false) or not tenant_private.staff_action_allowed(p_store,'catalog_read') or not tenant_private.staff_action_allowed(p_store,'stock_adjust') then raise exception 'Tenant write not permitted' using errcode='42501';end if;
 if p_product is null or p_request is null or p_delta is null or p_delta=0 or p_delta not between -1000000000 and 1000000000 then raise exception 'Invalid stock adjustment' using errcode='22023';end if;
 select * into e from public.mt_stock_events where store_id=p_store and request_id=p_request;
 if found then
  if e.product_id<>p_product or e.delta<>p_delta or e.actor<>auth.uid() then raise exception 'Conflicting request' using errcode='22023';end if;
  return e.balance;
 end if;
 select quantity into q from public.mt_products where store_id=p_store and id=p_product for update;
 if not found or q+p_delta not between 0 and 1000000000 then raise exception 'Invalid product or balance' using errcode='22023';end if;
 q:=q+p_delta;
 update public.mt_products set quantity=q where store_id=p_store and id=p_product;
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor) values(p_store,p_request,p_product,p_delta,q,auth.uid());
 return q;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.local_membership_access(s uuid, b uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(tenant_private.can_sell(s),false) and coalesce(tenant_private.staff_action_allowed(s,'sell'),false) and tenant_private.receivable_allowed(s,'read') and tenant_private.staff_action_allowed(s,'customer_read') and tenant_private.receivable_branch_allowed(s,b)
$function$;

CREATE OR REPLACE FUNCTION tenant_private.offline_receivable_snapshot(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare role_now text:=tenant_private.member_role(p_store);u uuid:=auth.uid();scope uuid;grants jsonb;result jsonb;
begin
 if u is null or not tenant_private.receivable_allowed(p_store,'read') or not tenant_private.staff_action_allowed(p_store,'customer_read') or not tenant_private.staff_action_allowed(p_store,'debt_read') or not tenant_private.staff_action_allowed(p_store,'installment_read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 scope:=tenant_private.current_branch_scope(p_store);
 grants:=tenant_private.receivable_grant_read(p_store,null);
 with customers as materialized (
  select c.id,c.name,c.phone from public.mt_customers c where c.store_id=p_store order by c.id limit 2001
 ), branches as materialized (
  select b.id,b.name from tenant_private.branches b where b.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,b.id) order by b.id limit 201
 ), invoice_debts as materialized (
  select 'invoice'::text kind,d.id,d.customer_id,c.name party,c.phone,bs.branch_id,coalesce(b.name,'') branch_name,'receivable'::text direction,d.currency,d.principal_minor,d.deposit_minor,d.remaining_minor,d.installment_count,d.first_due,d.created_at,s.number::text invoice_number,''::text notes
  from public.mt_debts d join public.mt_customers c on c.store_id=d.store_id and c.id=d.customer_id
  join public.mt_sales s on s.store_id=d.store_id and s.id=d.sale_id
  left join tenant_private.branch_sales bs on bs.store_id=d.store_id and bs.sale_id=d.sale_id
  left join tenant_private.branches b on b.store_id=bs.store_id and b.id=bs.branch_id
  where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,bs.branch_id) order by d.id limit 2001
 ), standalone as materialized (
  select 'standalone'::text kind,d.id,d.customer_id,d.party,d.phone,d.branch_id,coalesce(b.name,'') branch_name,d.direction,d.currency,d.principal_minor,0::bigint deposit_minor,d.remaining_minor,d.installment_count,d.first_due,d.created_at,null::text invoice_number,d.notes
  from tenant_private.standalone_debts d left join tenant_private.branches b on b.store_id=d.store_id and b.id=d.branch_id
  where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,d.branch_id) and (d.direction='receivable' or tenant_private.receivable_allowed(p_store,'payable_manage'))
  order by d.id limit 2001
 ), debts as materialized (
  select * from invoice_debts union all select * from standalone
 ), schedule as materialized (
  select * from (
   select d.kind,i.debt_id,i.number,i.due_date,i.amount_minor,i.paid_minor,i.waived_minor from invoice_debts d join public.mt_installments i on i.store_id=p_store and i.debt_id=d.id
   union all
   select d.kind,i.debt_id,i.number,i.due_date,i.amount_minor,i.paid_minor,0::bigint waived_minor from standalone d join tenant_private.standalone_installments i on i.store_id=p_store and i.debt_id=d.id
  ) t order by kind,debt_id,number limit 12001
 ), payments as materialized (
  select * from (
   select d.kind,p.debt_id,p.id,p.amount_minor,p.created_at,p.settlement_method method,p.is_deposit,''::text memo from invoice_debts d join public.mt_debt_payments p on p.store_id=p_store and p.debt_id=d.id
   union all
   select d.kind,p.debt_id,p.id,p.amount_minor,p.created_at,'cash'::text method,false is_deposit,p.memo from standalone d join tenant_private.standalone_debt_payments p on p.store_id=p_store and p.debt_id=d.id
  ) t order by created_at desc,kind,id limit 6001
 )
 select case when (select count(*) from customers)>2000 or (select count(*) from branches)>200 or (select count(*) from debts)>2000 or (select count(*) from schedule)>12000 or (select count(*) from payments)>6000 then null else jsonb_build_object(
 'version',1,'store',p_store,'actor',u,'role',role_now,'branch',scope,'capturedAt',now(),'actions',grants->'effective',
 'customers',coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from customers c),'[]'::jsonb),
 'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.id) from branches b),'[]'::jsonb),
 'debts',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at desc,d.kind,d.id) from debts d),'[]'::jsonb),
 'schedule',coalesce((select jsonb_agg(to_jsonb(i) order by i.kind,i.debt_id,i.number) from schedule i),'[]'::jsonb),
 'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.kind,p.id) from payments p),'[]'::jsonb)
 ) end into result;
 if result is null or octet_length(result::text)>1400000 then raise exception 'Offline ledger capacity exceeded; no partial snapshot' using errcode='22023';end if;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.procurement_aging(s uuid, c text, b uuid, all_locations boolean, asof date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare sc uuid:=tenant_private.current_branch_scope(s);
begin
 if not tenant_private.procurement_allowed(s,'purchase_read') or (sc is not null and (all_locations or sc is distinct from b)) then raise exception 'Procurement read denied' using errcode='42501';end if;
 if c is null or c not in ('SYP','USD','EUR') or asof is distinct from (now() at time zone 'Asia/Damascus')::date or all_locations is null or (all_locations and b is not null) then raise exception 'Invalid aging query';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.name,x.id) from (select v.id,v.name,coalesce(sum(p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor) filter(where p.due_date is null),0)::text no_due,coalesce(sum(p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor) filter(where p.due_date>=asof),0)::text not_due,coalesce(sum(p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor) filter(where p.due_date<asof),0)::text overdue,sum(p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor)::text total from public.mt_purchases p join public.mt_suppliers v on v.store_id=p.store_id and v.id=p.supplier_id left join tenant_private.branch_purchases bp on bp.store_id=p.store_id and bp.purchase_id=p.id where p.store_id=s and p.currency=c and (all_locations or bp.branch_id is not distinct from b) and p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor>0 group by v.id,v.name order by v.name,v.id limit 501)x),'[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.procurement_list(s uuid, k text, after_id uuid, lim integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare sc uuid:=tenant_private.current_branch_scope(s);out_data jsonb;
begin
 if not tenant_private.procurement_allowed(s,'read') then raise exception 'Procurement read denied' using errcode='42501';end if;
 if k is null or k not in ('suppliers','purchases','batches','returns') or lim is null or lim not between 1 and 100 then raise exception 'Invalid page';end if;
 if not tenant_private.procurement_allowed(s,case when k='suppliers' then 'supplier_read' else 'purchase_read' end) then raise exception 'Procurement read denied' using errcode='42501';end if;
 if k='suppliers' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into out_data from (select id,name,contact,phone,email,address,archived from public.mt_suppliers where store_id=s and (after_id is null or id>after_id) order by id limit lim)x;
 elsif k='purchases' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into out_data from (select p.id,p.supplier_id,p.product_id,v.name supplier_name,pr.name product_name,pr.sku,p.currency,p.units,p.returned_units,p.unit_cost_minor,p.total_minor,p.paid_minor,p.refunded_minor,p.note,p.due_date,p.created_at,b.branch_id,p.batch_id from public.mt_purchases p join public.mt_suppliers v on v.store_id=p.store_id and v.id=p.supplier_id join public.mt_products pr on pr.store_id=p.store_id and pr.id=p.product_id left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=s and (sc is null or sc=b.branch_id) and (after_id is null or p.id>after_id) order by p.id limit lim)x;
 elsif k='batches' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into out_data from (select p.id,p.supplier_id,v.name supplier_name,p.currency,p.reference,p.created_at,b.branch_id,p.total_minor-(select coalesce(sum(t.returned_units*t.unit_cost_minor),0)::bigint from public.mt_purchases t where t.store_id=s and t.batch_id=p.id) total_minor,(select coalesce(sum(t.paid_minor-t.refunded_minor),0)::bigint from public.mt_purchases t where t.store_id=s and t.batch_id=p.id) paid_minor from public.mt_purchase_batches p join public.mt_suppliers v on v.store_id=p.store_id and v.id=p.supplier_id left join tenant_private.branch_batches b on b.store_id=p.store_id and b.batch_id=p.id where p.store_id=s and (sc is null or sc=b.branch_id) and (after_id is null or p.id>after_id) order by p.id limit lim)x;
 else
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') into out_data from (select r.id,r.purchase_id,r.currency,r.units,r.debt_reduction_minor,r.refund_minor,r.reason,r.created_at,b.branch_id from public.mt_supplier_returns r left join tenant_private.branch_purchases b on b.store_id=r.store_id and b.purchase_id=r.purchase_id where r.store_id=s and (sc is null or sc=b.branch_id) and (after_id is null or r.id>after_id) order by r.id limit lim)x;
 end if;return out_data;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.receivable_customers(p_store uuid, p_query text, p_after uuid, p_limit integer)
 RETURNS SETOF mt_customers
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not tenant_private.receivable_allowed(p_store,'read') or not tenant_private.staff_action_allowed(p_store,'customer_read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_query is null or length(p_query)>160 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid filters' using errcode='22023';end if;
 return query select c.* from public.mt_customers c where c.store_id=p_store and (p_after is null or c.id>p_after) and (p_query='' or strpos(lower(c.name),lower(p_query))>0 or strpos(c.phone,p_query)>0) order by c.id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.receivable_debts(p_store uuid, p_after uuid, p_limit integer)
 RETURNS SETOF mt_debts
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not tenant_private.receivable_allowed(p_store,'read') or not tenant_private.staff_action_allowed(p_store,'debt_read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select d.* from public.mt_debts d left join tenant_private.branch_sales b on b.store_id=d.store_id and b.sale_id=d.sale_id where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,b.branch_id) and (p_after is null or d.id>p_after) order by d.id limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.receivable_register(p_store uuid, p_mode text, p_query text, p_customer uuid, p_currency text, p_status text, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb; totals jsonb; today date:=(now() at time zone 'Asia/Damascus')::date;
begin
 if not tenant_private.receivable_allowed(p_store,'read') or not tenant_private.staff_action_allowed(p_store,'debt_read') or (p_mode='schedule' and not tenant_private.staff_action_allowed(p_store,'installment_read')) then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_mode is null or p_mode not in ('debts','schedule','payments') or p_query is null or length(p_query)>160 or p_status is null or p_status not in ('all','open','overdue','settled') or p_offset is null or p_offset not between 0 and 100000 or (p_currency is not null and p_currency not in ('SYP','USD','EUR')) then raise exception 'Invalid filters' using errcode='22023';end if;
 with base as (
 select d.*,c.name,c.phone,s.number invoice_number from public.mt_debts d join public.mt_customers c on (c.store_id,c.id)=(d.store_id,d.customer_id) join public.mt_sales s on (s.store_id,s.id)=(d.store_id,d.sale_id)
 left join tenant_private.branch_sales bs on bs.store_id=d.store_id and bs.sale_id=d.sale_id
 where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,bs.branch_id) and (p_customer is null or c.id=p_customer) and (p_currency is null or d.currency=p_currency)
 and (p_query='' or strpos(lower(c.name),lower(p_query))>0 or strpos(c.phone,p_query)>0 or strpos(s.number::text,p_query)>0)
 ), balances as (
 select currency,sum(principal_minor)::text principal,sum(deposit_minor)::text deposit,sum(remaining_minor)::text remaining from base group by currency
 ), items as (
 select b.id debt_id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,b.id item_id,0 installment_number,b.created_at::text recorded_at,b.first_due due_date,b.principal_minor amount_minor,b.deposit_minor paid_minor,0::bigint waived_minor,b.remaining_minor,
 case when b.remaining_minor=0 then 'settled' when exists(select 1 from public.mt_installments i where i.store_id=p_store and i.debt_id=b.id and i.due_date<today and i.paid_minor+i.waived_minor<i.amount_minor) then 'overdue' else 'open' end status,null::text method,false is_deposit from base b where p_mode='debts'
 union all
 select b.id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,b.id,i.number,null,i.due_date,i.amount_minor,i.paid_minor,i.waived_minor,i.amount_minor-i.paid_minor-i.waived_minor,case when i.paid_minor+i.waived_minor=i.amount_minor then 'settled' when i.due_date<today then 'overdue' else 'open' end,null,false from base b join public.mt_installments i on (i.store_id,i.debt_id)=(b.store_id,b.id) where p_mode='schedule'
 union all
 select b.id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,p.id,0,p.created_at::text,null,p.amount_minor,0::bigint,0::bigint,0::bigint,'recorded',p.settlement_method,p.is_deposit from base b join public.mt_debt_payments p on (p.store_id,p.debt_id)=(b.store_id,b.id) where p_mode='payments'
 ), page as (
 select * from items where p_mode='payments' or p_status='all' or status=p_status or (p_status='open' and status='overdue')
 order by due_date asc nulls last,recorded_at desc nulls last,debt_id,installment_number,item_id offset p_offset limit 51
 )
 select (select coalesce(jsonb_agg(to_jsonb(b) order by b.currency),'[]'::jsonb) from balances b),
 (select coalesce(jsonb_agg(to_jsonb(x) order by x.due_date asc nulls last,x.recorded_at desc nulls last,x.debt_id,x.installment_number,x.item_id),'[]'::jsonb) from page x) into totals,rows;
 return jsonb_build_object('store_id',p_store,'mode',p_mode,'today',today,'totals',totals,'rows',rows);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.receivable_schedule(p_store uuid, p_debt uuid)
 RETURNS SETOF mt_installments
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not tenant_private.receivable_allowed(p_store,'read') or not tenant_private.staff_action_allowed(p_store,'debt_read') or not tenant_private.staff_action_allowed(p_store,'installment_read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if not exists(select 1 from public.mt_debts d left join tenant_private.branch_sales b on b.store_id=d.store_id and b.sale_id=d.sale_id where d.store_id=p_store and d.id=p_debt and tenant_private.receivable_branch_allowed(p_store,b.branch_id)) then raise exception 'Unknown debt or scope denied' using errcode='42501';end if;
 return query select i.* from public.mt_installments i where i.store_id=p_store and i.debt_id=p_debt order by i.number;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.standalone_details(p_store uuid, p_debt uuid, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d tenant_private.standalone_debts%rowtype;
begin
 if not tenant_private.receivable_allowed(p_store,'read') or not tenant_private.staff_action_allowed(p_store,'debt_read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_offset is null or p_offset not between 0 and 100000 then raise exception 'Invalid page';end if;
 select * into strict d from tenant_private.standalone_debts where store_id=p_store and id=p_debt;
 if not tenant_private.receivable_branch_allowed(p_store,d.branch_id) or (d.direction='payable' and not tenant_private.receivable_allowed(p_store,'payable_manage')) then raise exception 'Standalone debt scope denied' using errcode='42501';end if;
 return jsonb_build_object('store_id',p_store,'debt',to_jsonb(d),'schedule',case when tenant_private.staff_action_allowed(p_store,'installment_read') then coalesce((select jsonb_agg(to_jsonb(i) order by number) from tenant_private.standalone_installments i where store_id=p_store and debt_id=p_debt),'[]'::jsonb) else '[]'::jsonb end,'payments',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from (select * from tenant_private.standalone_debt_payments where store_id=p_store and debt_id=p_debt order by created_at desc,id desc offset p_offset limit 51)p),'[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.standalone_list(p_store uuid, p_query text, p_customer uuid, p_direction text, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not tenant_private.receivable_allowed(p_store,'read') or not tenant_private.staff_action_allowed(p_store,'debt_read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 if p_query is null or length(p_query)>160 or p_offset is null or p_offset not between 0 and 100000 or (p_direction is not null and p_direction not in ('receivable','payable')) then raise exception 'Invalid filters' using errcode='22023';end if;
 return (with base as (
  select d.*,coalesce(b.name,'المستودع الرئيسي') branch_name,case when d.remaining_minor=0 then 'settled' when exists(select 1 from tenant_private.standalone_installments i where i.store_id=d.store_id and i.debt_id=d.id and i.paid_minor<i.amount_minor and i.due_date<(now() at time zone 'Asia/Damascus')::date) then 'overdue' else 'open' end status
  from tenant_private.standalone_debts d left join tenant_private.branches b on b.store_id=d.store_id and b.id=d.branch_id
  left join public.mt_customers c on c.store_id=d.store_id and c.id=d.customer_id
  where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,d.branch_id) and (d.direction='receivable' or tenant_private.receivable_allowed(p_store,'payable_manage')) and (p_customer is null or d.customer_id=p_customer) and (p_direction is null or d.direction=p_direction)
  and (p_query='' or strpos(lower(d.party),lower(p_query))>0 or strpos(d.phone,p_query)>0 or strpos(d.id::text,lower(p_query))>0 or strpos(lower(coalesce(c.name,'')),lower(p_query))>0 or strpos(coalesce(c.phone,''),p_query)>0)
 ),page as (select * from base order by created_at desc,id desc offset p_offset limit 51),
 totals as (select currency,direction,sum(principal_minor)::text principal,sum(remaining_minor)::text remaining from base group by currency,direction)
 select jsonb_build_object('store_id',p_store,'rows',coalesce((select jsonb_agg(to_jsonb(page) order by created_at desc,id desc) from page),'[]'::jsonb),'totals',coalesce((select jsonb_agg(to_jsonb(totals) order by currency,direction) from totals),'[]'::jsonb)));
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.supplier_statement(p_store uuid, p_supplier uuid, p_currency text, p_all boolean, p_branch uuid, p_from date, p_to date, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare lo timestamptz;hi timestamptz;result jsonb; supplier_name text;
begin
 if (not tenant_private.procurement_allowed(p_store,'supplier_read') or not tenant_private.procurement_allowed(p_store,'purchase_read')) or (tenant_private.current_branch_scope(p_store) is not null and (p_all or tenant_private.current_branch_scope(p_store) is distinct from p_branch)) then raise exception 'Procurement read denied' using errcode='42501';end if;
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


commit;
