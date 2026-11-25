begin;
-- Operational period snapshots: never backdate or overwrite a closed reporting period.
create table public.mt_period_closes(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,
 period_from date not null,period_to date not null,
 trial_balance jsonb not null,operating_report jsonb not null,cash_report jsonb not null,
 note text not null check(length(btrim(note)) between 1 and 300),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id),unique(store_id,period_to),
 foreign key(store_id) references tenant_private.workspaces(store_id),check(period_to>=period_from and period_to-period_from<=365)
);
alter table public.mt_period_closes enable row level security;
revoke all on public.mt_period_closes from public,anon,authenticated,service_role;
grant select on public.mt_period_closes to authenticated;
create policy owner_read on public.mt_period_closes for select to authenticated using (tenant_private.member_role(store_id)='owner');
create function tenant_private.guard_closed_period() returns trigger language plpgsql security definer set search_path='' as $$
declare cutoff date;
begin
 perform 1 from public.saas_stores where id=new.store_id for update;
 select max(period_to) into cutoff from public.mt_period_closes where store_id=new.store_id;
 if cutoff is not null and (new.created_at at time zone 'UTC')::date<=cutoff then raise exception 'Accounting period closed; record current-period correction' using errcode='22023';end if;
 return new;
end $$;
do $$ declare t text;begin foreach t in array array['mt_cash_movements','mt_sales','mt_returns','mt_purchases','mt_supplier_returns','mt_repair_invoices','mt_repair_refunds','mt_stock_events','mt_warranty_parts','mt_debt_payments','mt_supplier_payments'] loop
 execute format('create trigger mt_guard_closed_period before insert on public.%I for each row execute function tenant_private.guard_closed_period()',t);
end loop;
foreach t in array array['cost_postings','return_cost_postings'] loop
 execute format('create trigger mt_guard_closed_period before insert on tenant_private.%I for each row execute function tenant_private.guard_closed_period()',t);
end loop;end $$;
create function tenant_private.close_period(p_store uuid,p_request uuid,p_from date,p_to date,p_note text,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.mt_period_closes%rowtype;cutoff date;tb jsonb;pr jsonb;cr jsonb;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 or p_to>=(now() at time zone 'UTC')::date or p_note is null or length(btrim(p_note)) not between 1 and 300 or p_confirm is distinct from true then raise exception 'Confirm past reporting period' using errcode='22023';end if;
 select * into r from public.mt_period_closes where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.period_from<>p_from or r.period_to<>p_to or r.note<>btrim(p_note) then raise exception 'Conflicting close request' using errcode='22023';end if;return r.id;
 end if;
 select max(period_to) into cutoff from public.mt_period_closes where store_id=p_store;
 if cutoff is not null and p_from<>cutoff+1 then raise exception 'Close contiguous periods in order' using errcode='22023';end if;
 -- First close covers all existing journal history, without silent gaps.
 if cutoff is null and exists(select 1 from tenant_private.journal_pairs(p_store,p_from::timestamp at time zone 'UTC')) then raise exception 'First period must include prior journal entries' using errcode='22023';end if;
 tb:=tenant_private.trial_balance(p_store,p_from,p_to);
 if (tb->>'unknown_cost_events')::bigint<>0 then raise exception 'Unresolved historical cost or FX' using errcode='22023';end if;
 pr:=tenant_private.operating_report(p_store,p_from,p_to);cr:=tenant_private.cash_report(p_store,p_from,p_to);
 insert into public.mt_period_closes(store_id,request_id,period_from,period_to,trial_balance,operating_report,cash_report,note,actor)
 values(p_store,p_request,p_from,p_to,tb,pr,cr,btrim(p_note),auth.uid()) returning * into r;return r.id;
end $$;
create function public.mt_close_period(p_store uuid,p_request uuid,p_from date,p_to date,p_note text,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.close_period(p_store,p_request,p_from,p_to,p_note,p_confirm)$$;
create function public.mt_list_period_closes(p_store uuid,p_after uuid default null,p_limit integer default 50)
returns table(store_id uuid,id uuid,period_from date,period_to date,note text,created_at timestamptz)
language plpgsql stable security invoker set search_path='' as $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select c.store_id,c.id,c.period_from,c.period_to,c.note,c.created_at from public.mt_period_closes c where c.store_id=p_store and (p_after is null or c.id>p_after) order by c.id limit p_limit;
end $$;
create function public.mt_period_snapshot(p_store uuid,p_close uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('trial_balance',c.trial_balance,'operating_report',c.operating_report,'cash_report',c.cash_report,'period_from',c.period_from,'period_to',c.period_to) from public.mt_period_closes c where c.store_id=p_store and c.id=p_close
$$;
revoke all on function tenant_private.guard_closed_period(),tenant_private.close_period(uuid,uuid,date,date,text,boolean),public.mt_close_period(uuid,uuid,date,date,text,boolean),public.mt_list_period_closes(uuid,uuid,integer),public.mt_period_snapshot(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.close_period(uuid,uuid,date,date,text,boolean),public.mt_close_period(uuid,uuid,date,date,text,boolean),public.mt_list_period_closes(uuid,uuid,integer),public.mt_period_snapshot(uuid,uuid) to authenticated;
commit;