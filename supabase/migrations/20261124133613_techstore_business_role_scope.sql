begin;
create or replace function techstore_private.business_action(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; inv public.ts_invoices%rowtype; e public.ts_business_entries%rowtype; req uuid; iid uuid; amount_value numeric; paid numeric; bal numeric; day_value date:=(now() at time zone 'UTC')::date; expected_value numeric; counted_value numeric; note text; k text; c public.ts_invoice_settings%rowtype;
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
 return jsonb_build_object('total',(inv.document->>'total')::numeric,'paid',paid,'balance',greatest(0,(inv.document->>'total')::numeric-paid),'receipts',coalesce((select jsonb_agg(jsonb_build_object('id',id,'amount',amount,'created_at',created_at,'memo',memo)) from public.ts_business_entries where invoice_id=inv.id and kind='receipt'),'[]'));
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
 paid:=(techstore_private.business_action('balance',jsonb_build_object('id',iid))->>'paid')::numeric;
 bal:=(inv.document->>'total')::numeric-paid;
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

commit;