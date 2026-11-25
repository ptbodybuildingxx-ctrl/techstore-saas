begin;
alter table public.ts_business_entries drop constraint ts_business_entries_kind_check;
alter table public.ts_business_entries add constraint ts_business_entries_kind_check check(kind in ('invoice','initial_payment','receipt','expense','cash_in','cost'));
create function techstore_private.business_invoice_cost() returns trigger language plpgsql security definer set search_path='' as $$
declare amount_value numeric;
begin
 if new.kind='sale' then
 select coalesce(sum(round((i->>'qty')::numeric*(p->>'cost')::numeric,2)),0) into amount_value
 from jsonb_array_elements(new.document->'items') i join public.ts_workspace w on w.id=1 cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'products','[]')) p where p->>'id'=i->>'product';
 else
 select coalesce(sum(round(qty*unit_cost,2)),0) into amount_value from public.ts_repair_evidence where repair_id=new.repair_id and kind='part';
 end if;
 if amount_value>0 then insert into public.ts_business_entries(invoice_id,actor,kind,debit,credit,amount,memo) values(new.id,new.actor,'cost',case when new.kind='sale' then 'cost_of_sales' else 'repair_parts_cost' end,'inventory',amount_value,'INV-'||new.number);end if;
 return new;
end $$;
revoke all on function techstore_private.business_invoice_cost() from public,anon,authenticated;
create trigger ts_business_invoice_cost after insert on public.ts_invoices for each row execute function techstore_private.business_invoice_cost();
create function techstore_private.business_summary() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 select jsonb_build_object('sales',coalesce(sum(amount) filter(where credit='sales_revenue'),0),'repairs',coalesce(sum(amount) filter(where credit='repair_revenue'),0),'cost',coalesce(sum(amount) filter(where kind='cost'),0),'expenses',coalesce(sum(amount) filter(where kind='expense'),0),'receivable',coalesce(sum(case when debit='receivables' then amount when credit='receivables' then -amount else 0 end),0)) into result from public.ts_business_entries;
 return result||jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(a)) from (select p.user_id,p.name,count(distinct i.id) as invoices,coalesce(sum(e.amount) filter(where e.debit='receivables'),0) as billed,coalesce(sum(e.amount) filter(where e.credit='receivables'),0) as paid from public.ts_profiles p join public.ts_invoices i on i.customer_id=p.user_id join public.ts_business_entries e on e.invoice_id=i.id group by p.user_id,p.name order by p.name limit 500) a),'[]'));
end $$;
revoke all on function techstore_private.business_summary() from public,anon,authenticated;
grant execute on function techstore_private.business_summary() to authenticated;
create function public.ts_business_summary() returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.business_summary(); $$;
revoke all on function public.ts_business_summary() from public,anon,authenticated;
grant execute on function public.ts_business_summary() to authenticated;
commit;