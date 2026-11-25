begin;
alter table public.ts_business_entries drop constraint ts_business_entries_kind_check;
alter table public.ts_business_entries add constraint ts_business_entries_kind_check check(kind in ('invoice','initial_payment','receipt','expense','cash_in','cost','refund','cost_reverse'));
create table public.ts_invoice_refunds(
 invoice_id uuid primary key references public.ts_invoices(id), id uuid not null unique default gen_random_uuid(), request_id uuid not null unique, actor uuid not null references public.ts_profiles(user_id), reason text not null check(length(reason) between 1 and 500), amount numeric(18,2) not null check(amount>0), created_at timestamptz not null default now()
);
alter table public.ts_invoice_refunds enable row level security;
revoke all on public.ts_invoice_refunds from public,anon,authenticated;
create function techstore_private.protect_invoice_legacy_returns() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.payload->'records'->'returns' is not distinct from new.payload->'records'->'returns' then return new;end if;
 if exists(select 1 from jsonb_array_elements(coalesce(new.payload->'records'->'returns','[]')) r join public.ts_invoices i on i.id::text=r->>'sale' where not exists(select 1 from jsonb_array_elements(coalesce(old.payload->'records'->'returns','[]')) o where o=r)) then raise exception 'Use invoice refund workflow for this sale';end if;
 return new;
end $$;
revoke all on function techstore_private.protect_invoice_legacy_returns() from public,anon,authenticated;
create trigger ts_invoice_legacy_return_guard before update of payload on public.ts_workspace for each row execute function techstore_private.protect_invoice_legacy_returns();
create function techstore_private.invoice_refund(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; i public.ts_invoices%rowtype; w public.ts_workspace%rowtype; r public.ts_invoice_refunds%rowtype; d jsonb; line jsonb; p jsonb; original jsonb; ix int; qty int; oldqty int; unit_cost numeric; c numeric; cash_value numeric; req uuid; reason_value text; iid uuid; refund_value numeric;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>4000 then raise exception 'Invalid request';end if;
 iid:=(p_args->>'id')::uuid;
 select * into i from public.ts_invoices where id=iid and (u.role in ('admin','cashier') or (u.role='customer' and customer_id=u.user_id));
 if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;
 if p_action='get' then return coalesce((select to_jsonb(x)-'actor'-'request_id' from public.ts_invoice_refunds x where invoice_id=iid),'null');end if;
 if p_action<>'refund' or u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 req:=(p_args->>'request_id')::uuid;reason_value:=btrim(coalesce(p_args->>'reason',''));
 if req is null or length(reason_value) not between 1 and 500 or p_args->'inspected' is distinct from 'true'::jsonb then raise exception 'Confirm all goods inspected and resalable';end if;
 select * into w from public.ts_workspace where id=1 for update;
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 select * into r from public.ts_invoice_refunds where request_id=req;
 if found then if r.actor<>u.user_id or r.invoice_id<>iid or r.reason<>reason_value then raise exception 'Request ID conflict';end if;return to_jsonb(r)-'actor'-'request_id';end if;
 if exists(select 1 from public.ts_invoice_refunds where invoice_id=iid) then raise exception 'Already refunded';end if;
 if i.kind<>'sale' or coalesce(i.document->>'payment_mode','cash')<>'cash' then raise exception 'Only paid cash sale invoices can be fully refunded';end if;
 if exists(select 1 from public.ts_business_closings where day=(now() at time zone 'UTC')::date) then raise exception 'Cash day closed';end if;
 refund_value:=(i.document->>'total')::numeric;
 if refund_value<=0 or not exists(select 1 from public.ts_business_entries where invoice_id=iid and kind='invoice') or (select coalesce(sum(amount),0) from public.ts_business_entries where invoice_id=iid and kind in ('initial_payment','receipt'))<>refund_value then raise exception 'Invoice not fully paid in new ledger';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(w.payload->'records'->'returns','[]')) x where x->>'sale'=iid::text) then raise exception 'Legacy return exists';end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into cash_value from public.ts_business_entries;
 if cash_value<refund_value then raise exception 'Insufficient recorded cash';end if;
 d:=w.payload->'data';
 select x into original from jsonb_array_elements(coalesce(d->'sales','[]')) x where x->>'id'=iid::text;
 if original is null then raise exception 'Original stock cost unavailable';end if;
 for line in select value from jsonb_array_elements(i.document->'items') loop
 qty:=(line->>'qty')::int;
 select x,ord::int-1 into p,ix from jsonb_array_elements(coalesce(d->'products','[]')) with ordinality a(x,ord) where x->>'id'=line->>'product';
 select (x->>'cost')::numeric into unit_cost from jsonb_array_elements(original->'items') x where x->>'id'=line->>'product';
 if p is null or unit_cost is null or unit_cost<0 or qty<=0 then raise exception 'Product or original cost unavailable';end if;
 oldqty:=(p->>'qty')::int;
 d:=jsonb_set(jsonb_set(d,array['products',ix::text,'qty'],to_jsonb(oldqty+qty)),array['products',ix::text,'cost'],to_jsonb(round((oldqty*(p->>'cost')::numeric+qty*unit_cost)/(oldqty+qty),4)));
 d:=jsonb_set(d,'{stockMoves}',coalesce(d->'stockMoves','[]')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'product',line->>'product','name',line->>'name','qty',qty,'reason','invoice full refund','date',current_date)),true);
 end loop;
 select coalesce(sum(amount),0) into c from public.ts_business_entries where invoice_id=iid and kind='cost';
 insert into public.ts_invoice_refunds(invoice_id,request_id,actor,reason,amount) values(iid,req,u.user_id,reason_value,refund_value) returning * into r;
 insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(iid,u.user_id,'refund','sales_revenue','cash',refund_value,'Refund INV-'||i.number);
 if c>0 then insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(iid,u.user_id,'cost_reverse','inventory','cost_of_sales',c,'Refund INV-'||i.number);end if;
 -- Keep legacy profit calculation consistent without deleting the original sale.
 d:=jsonb_set(d,'{expenses}',coalesce(d->'expenses','[]')||jsonb_build_array(jsonb_build_object('id',r.id,'date',current_date,'desc','Full invoice refund INV-'||i.number,'amount',refund_value-c)),true);
 update public.ts_workspace set payload=jsonb_set(w.payload,'{data}',d),revision=revision+1,updated_at=now() where id=1;
 insert into public.ts_audit(actor,action) values(u.user_id,'full invoice refund '||iid);
 return to_jsonb(r)-'actor'-'request_id';
end $$;
revoke all on function techstore_private.invoice_refund(text,jsonb) from public,anon,authenticated;
grant execute on function techstore_private.invoice_refund(text,jsonb) to authenticated;
create function public.ts_invoice_refund(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.invoice_refund(p_action,p_args); $$;
revoke all on function public.ts_invoice_refund(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_invoice_refund(text,jsonb) to authenticated;
create or replace function techstore_private.business_action(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; inv public.ts_invoices%rowtype; e public.ts_business_entries%rowtype; req uuid; iid uuid; amount_value numeric; paid numeric; refunded numeric; bal numeric; day_value date:=(now() at time zone 'UTC')::date; expected_value numeric; counted_value numeric; note text; k text; c public.ts_invoice_settings%rowtype;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>200000 then raise exception 'Invalid request';end if;
 if p_action='warranties' then return coalesce((select jsonb_agg(to_jsonb(x)) from (select w.*,i.number,i.kind,i.document->>'customer' as customer,i.document->>'warranty_terms' as terms from public.ts_invoice_warranties w join public.ts_invoices i on i.id=w.invoice_id where u.role in ('admin','cashier') or (u.role='tech' and i.kind='repair') or (u.role='customer' and i.customer_id=u.user_id) order by w.ends desc limit 300) x),'[]');end if;
 if p_action='balance' then
 select * into inv from public.ts_invoices i where i.id=(p_args->>'id')::uuid and (u.role in ('admin','cashier') or (u.role='customer' and i.customer_id=u.user_id) or (u.role='tech' and i.kind='repair'));
 if not found then raise exception 'Invoice unavailable' using errcode='42501';end if;
 select coalesce(sum(amount),0) into paid from public.ts_business_entries where invoice_id=inv.id and kind in ('initial_payment','receipt');
 -- Legacy invoice fallback; new invoice initial payment is recorded by the trigger.
 if not exists(select 1 from public.ts_business_entries where invoice_id=inv.id and kind='invoice') then paid:=coalesce((inv.document->>'paid')::numeric,0)+coalesce((select sum(amount) from public.ts_business_entries where invoice_id=inv.id and kind='receipt'),0);end if;
 select coalesce(sum(amount),0) into refunded from public.ts_business_entries where invoice_id=inv.id and kind='refund';
 return jsonb_build_object('total',(inv.document->>'total')::numeric-refunded,'original_total',(inv.document->>'total')::numeric,'refunded',refunded,'paid',paid-refunded,'balance',greatest(0,(inv.document->>'total')::numeric-paid),'receipts',coalesce((select jsonb_agg(jsonb_build_object('id',id,'amount',amount,'created_at',created_at,'memo',memo)) from public.ts_business_entries where invoice_id=inv.id and kind='receipt'),'[]'));
 end if;
 if u.role not in ('admin','cashier') then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='branding' then select * into c from public.ts_invoice_settings where id=1;return jsonb_build_object('syp_rate',c.syp_rate,'logo',c.logo);end if;
 if p_action='configure' then if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;update public.ts_invoice_settings set syp_rate=(p_args->>'syp_rate')::numeric,logo=coalesce(p_args->>'logo','') where id=1 returning * into c;insert into public.ts_audit(actor,action) values(u.user_id,'business branding updated');return jsonb_build_object('ok',true);end if;
 if p_action='list' then
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into expected_value from public.ts_business_entries;
 return jsonb_build_object('day',day_value,'cash_expected',expected_value,'closed',exists(select 1 from public.ts_business_closings where day=day_value),'entries',coalesce((select jsonb_agg(to_jsonb(x)) from (select id,invoice_id,kind,debit,credit,amount,memo,created_at from public.ts_business_entries order by created_at desc,id limit 200) x),'[]'),'closings',coalesce((select jsonb_agg(to_jsonb(x)) from (select day,expected,counted,created_at from public.ts_business_closings order by day desc limit 30) x),'[]'));
 end if;
 perform pg_catalog.pg_advisory_xact_lock(593227600);
 if p_action='close' then
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 counted_value:=round((p_args->>'counted')::numeric,2);
 if counted_value is null or counted_value<0 or counted_value>1000000000 then raise exception 'Invalid counted amount';end if;
 select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into expected_value from public.ts_business_entries;
 insert into public.ts_business_closings(day,expected,counted,actor) values(day_value,expected_value,counted_value,u.user_id);
 insert into public.ts_audit(actor,action) values(u.user_id,'cash day closed '||day_value);
 return jsonb_build_object('expected',expected_value,'counted',counted_value,'difference',counted_value-expected_value);
 end if;
 if p_action not in ('receipt','expense','cash_in') then raise exception 'Invalid action';end if;
 if p_action<>'receipt' and u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 req:=(p_args->>'request_id')::uuid;amount_value:=round((p_args->>'amount')::numeric,2);note:=left(btrim(coalesce(p_args->>'memo','')),500);iid:=nullif(p_args->>'invoice_id','')::uuid;
 if req is null or amount_value is null or amount_value<=0 or amount_value>1000000000 or note='' then raise exception 'Invalid amount or reference';end if;
 select * into e from public.ts_business_entries where request_id=req;
 if found then if e.actor<>u.user_id or e.kind<>p_action or e.invoice_id is distinct from iid or e.amount<>amount_value or e.memo<>note then raise exception 'Request ID conflict';end if;return to_jsonb(e);end if;
 if exists(select 1 from public.ts_business_closings where day=day_value) then raise exception 'Cash day is closed';end if;
 if p_action='receipt' then
 select * into inv from public.ts_invoices where id=iid for update;if not found then raise exception 'Invoice unavailable';end if;
 bal:=(techstore_private.business_action('balance',jsonb_build_object('id',iid))->>'balance')::numeric;
 if amount_value>bal then raise exception 'Payment exceeds balance';end if;
 insert into public.ts_business_entries(request_id,invoice_id,actor,kind,debit,credit,amount,memo) values(req,iid,u.user_id,'receipt','cash','receivables',amount_value,note) returning * into e;
 else
 if iid is not null then raise exception 'Invoice not allowed';end if;
 if p_action='expense' then select coalesce(sum(case when debit='cash' then amount when credit='cash' then -amount else 0 end),0) into expected_value from public.ts_business_entries;if amount_value>expected_value then raise exception 'Insufficient recorded cash';end if;end if;
 insert into public.ts_business_entries(request_id,actor,kind,debit,credit,amount,memo) values(req,u.user_id,p_action,case when p_action='expense' then 'operating_expense' else 'cash' end,case when p_action='expense' then 'cash' else 'owner_contribution' end,amount_value,note) returning * into e;
 end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'business '||p_action||' '||e.id);
 return to_jsonb(e);
end $$;


create or replace function techstore_private.business_summary() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 select jsonb_build_object('sales',coalesce(sum(case when credit='sales_revenue' then amount when debit='sales_revenue' then -amount else 0 end),0),'repairs',coalesce(sum(amount) filter(where credit='repair_revenue'),0),'cost',coalesce(sum(case when kind='cost' then amount when kind='cost_reverse' then -amount else 0 end),0),'expenses',coalesce(sum(amount) filter(where kind='expense'),0),'receivable',coalesce(sum(case when debit='receivables' then amount when credit='receivables' then -amount else 0 end),0)) into result from public.ts_business_entries;
 return result||jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(a)) from (select p.user_id,p.name,count(distinct i.id) as invoices,coalesce(sum(e.amount) filter(where e.debit='receivables' and e.kind='invoice'),0) -coalesce(sum(e.amount) filter(where e.kind='refund'),0) as billed,coalesce(sum(case when e.credit='receivables' then e.amount when e.kind='refund' then -e.amount else 0 end),0) as paid from public.ts_profiles p join public.ts_invoices i on i.customer_id=p.user_id join public.ts_business_entries e on e.invoice_id=i.id group by p.user_id,p.name order by p.name limit 500) a),'[]'));
end $$;

commit;