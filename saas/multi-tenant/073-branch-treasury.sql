-- Optional physical cash subdivision. Consolidated cash remains authoritative.
begin;
create table tenant_private.branch_treasury_enabled(store_id uuid primary key references tenant_private.workspaces(store_id),activated_at timestamptz not null default now(),actor uuid not null);
create table tenant_private.branch_cash_accounts(store_id uuid not null,branch_id uuid,location_id uuid generated always as (coalesce(branch_id,'00000000-0000-0000-0000-000000000000'::uuid)) stored,currency text not null,balance_minor bigint not null check(balance_minor between 0 and 9007199254740991),primary key(store_id,location_id,currency),foreign key(store_id) references tenant_private.branch_treasury_enabled(store_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),check(branch_id is null or branch_id<>'00000000-0000-0000-0000-000000000000'::uuid));
create table tenant_private.branch_cash_attribution(store_id uuid not null,cash_id uuid not null,branch_id uuid,posted boolean not null default false,primary key(store_id,cash_id),foreign key(store_id,cash_id) references public.mt_cash_movements(store_id,id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
create table tenant_private.branch_cash_transfers(store_id uuid not null,id uuid not null,source uuid,target uuid,currency text not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),reference text not null check(length(btrim(reference)) between 1 and 160),actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),foreign key(store_id,source) references tenant_private.branches(store_id,id),foreign key(store_id,target) references tenant_private.branches(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),check(source is distinct from target));
do $$declare t text;begin foreach t in array array['branch_treasury_enabled','branch_cash_accounts','branch_cash_attribution','branch_cash_transfers'] loop execute format('alter table tenant_private.%I enable row level security',t);execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create function tenant_private.branch_cash_apply(p_store uuid,p_branch uuid,p_currency text,p_delta bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 if p_delta>0 then insert into tenant_private.branch_cash_accounts(store_id,branch_id,currency,balance_minor) values(p_store,p_branch,p_currency,p_delta) on conflict(store_id,location_id,currency) do update set balance_minor=branch_cash_accounts.balance_minor+excluded.balance_minor;
 elsif p_delta<0 then update tenant_private.branch_cash_accounts set balance_minor=balance_minor+p_delta where store_id=p_store and branch_id is not distinct from p_branch and currency=p_currency and balance_minor>=-p_delta;
 if not found then raise exception 'Insufficient cash at attributed location' using errcode='22023';end if;
 end if;
end $$;
create function tenant_private.branch_cash_enqueue() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from tenant_private.branch_treasury_enabled where store_id=new.store_id) then insert into tenant_private.branch_cash_attribution(store_id,cash_id) values(new.store_id,new.id);end if;return new;
end $$;
create trigger mt_branch_cash_enqueue after insert on public.mt_cash_movements for each row execute function tenant_private.branch_cash_enqueue();
-- Source branch mappings may be written after the cash row, within the same transaction.
create function tenant_private.branch_cash_post() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.mt_cash_movements%rowtype;b uuid;sid uuid;pid uuid;rid uuid;delta bigint;begin
 select * into strict m from public.mt_cash_movements where store_id=new.store_id and id=new.cash_id;
 perform 1 from public.saas_stores where id=m.store_id for update;
 if exists(select 1 from tenant_private.branch_cash_attribution where store_id=m.store_id and cash_id=m.id and posted) then return new;end if;
 sid:=coalesce(m.sale_id,m.mixed_sale_id);
 if m.debt_payment_id is not null then select d.sale_id into sid from public.mt_debt_payments p join public.mt_debts d on d.store_id=p.store_id and d.id=p.debt_id where p.store_id=m.store_id and p.id=m.debt_payment_id;end if;
 if m.return_id is not null then select sale_id into sid from public.mt_returns where store_id=m.store_id and id=m.return_id;end if;
 if m.supplier_payment_id is not null then select purchase_id into pid from public.mt_supplier_payments where store_id=m.store_id and id=m.supplier_payment_id;end if;
 if m.supplier_return_id is not null then select purchase_id into pid from public.mt_supplier_returns where store_id=m.store_id and id=m.supplier_return_id;end if;
 if m.repair_invoice_id is not null then select repair_id into rid from public.mt_repair_invoices where store_id=m.store_id and id=m.repair_invoice_id;end if;
 if m.repair_refund_id is not null then select i.repair_id into rid from public.mt_repair_refunds r join public.mt_repair_invoices i on i.store_id=r.store_id and i.id=r.invoice_id where r.store_id=m.store_id and r.id=m.repair_refund_id;end if;
 if sid is not null then select branch_id into b from tenant_private.branch_sales where store_id=m.store_id and sale_id=sid;
 elsif pid is not null then select branch_id into b from tenant_private.branch_purchases where store_id=m.store_id and purchase_id=pid;
 elsif rid is not null then select branch_id into b from tenant_private.branch_repairs where store_id=m.store_id and repair_id=rid;
 else select branch_id into b from tenant_private.branch_vouchers where store_id=m.store_id and cash_id=m.id;end if;
 delta:=case when m.kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then m.amount_minor when m.kind in ('expense','exchange','return','supplier_payment','repair_refund') then -m.amount_minor else null end;
 -- Fail closed on new cash types; known sale returns may be called refund.
 if m.kind='refund' then delta:=-m.amount_minor;end if;
 if delta is null then raise exception 'Unknown cash type for branch treasury';end if;
 perform tenant_private.branch_cash_apply(m.store_id,b,m.currency,delta);
 if m.kind='exchange' then perform tenant_private.branch_cash_apply(m.store_id,b,m.target_currency,m.target_amount_minor);end if;
 update tenant_private.branch_cash_attribution set branch_id=b,posted=true where store_id=m.store_id and cash_id=m.id;return new;
end $$;
create constraint trigger mt_branch_cash_post after insert on tenant_private.branch_cash_attribution deferrable initially deferred for each row execute function tenant_private.branch_cash_post();
create function tenant_private.branch_treasury_start(p_store uuid,p_confirm boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_confirm is distinct from true then raise exception 'Confirm opening allocation' using errcode='22023';end if;
 if exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then return true;end if;
 insert into tenant_private.branch_treasury_enabled(store_id,actor) values(p_store,auth.uid());
 insert into tenant_private.branch_cash_accounts(store_id,currency,balance_minor) select store_id,currency,balance_minor from tenant_private.cash_balances where store_id=p_store;
 return true;
end $$;
create function tenant_private.branch_cash_transfer(p_store uuid,p_id uuid,p_source uuid,p_target uuid,p_currency text,p_amount bigint,p_reference text,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.branch_cash_transfers%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_source is not distinct from p_target or p_amount is null or p_amount not between 1 and 100000000000000 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_confirm is distinct from true or not exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then raise exception 'Invalid treasury transfer' using errcode='22023';end if;
 if p_source is not null then perform tenant_private.require_branch(p_store,p_source);end if;
 if p_target is not null then perform tenant_private.require_branch(p_store,p_target);end if;
 select * into v from tenant_private.branch_cash_transfers where store_id=p_store and id=p_id;
 if found then if v.actor<>auth.uid() or v.source is distinct from p_source or v.target is distinct from p_target or v.currency<>p_currency or v.amount_minor<>p_amount or v.reference<>btrim(p_reference) then raise exception 'Conflicting treasury transfer' using errcode='22023';end if;return p_id;end if;
 perform tenant_private.branch_cash_apply(p_store,p_source,p_currency,-p_amount);
 perform tenant_private.branch_cash_apply(p_store,p_target,p_currency,p_amount);
 insert into tenant_private.branch_cash_transfers(store_id,id,source,target,currency,amount_minor,reference,actor) values(p_store,p_id,p_source,p_target,p_currency,p_amount,btrim(p_reference),auth.uid());return p_id;
end $$;
create trigger mt_guard_closed_period before insert on tenant_private.branch_cash_transfers for each row execute function tenant_private.guard_closed_period();
create function tenant_private.branch_treasury_read(p_store uuid,p_before timestamptz,p_before_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare enabled boolean;begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid cursor' using errcode='22023';end if;
 enabled:=exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store);
 return jsonb_build_object('enabled',enabled,'accounts',coalesce((select jsonb_agg(to_jsonb(x) order by x.name,x.currency) from (select a.branch_id,coalesce(b.name,'المستودع الرئيسي') name,a.currency,a.balance_minor from tenant_private.branch_cash_accounts a left join tenant_private.branches b on b.store_id=a.store_id and b.id=a.branch_id where a.store_id=p_store)x),'[]'),'transfers',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from (select id,source,target,currency,amount_minor,reference,created_at from tenant_private.branch_cash_transfers where store_id=p_store and (p_before is null or (created_at,id)<(p_before,p_before_id)) order by created_at desc,id desc limit 50)x),'[]'),'reconciled',enabled and not exists(select 1 from tenant_private.sale_currencies c left join tenant_private.cash_balances a on a.store_id=c.store_id and a.currency=c.currency where c.store_id=p_store and coalesce(a.balance_minor,0)::numeric<>(select coalesce(sum(b.balance_minor),0) from tenant_private.branch_cash_accounts b where b.store_id=c.store_id and b.currency=c.currency)) and not exists(select 1 from tenant_private.branch_cash_attribution where store_id=p_store and not posted));
end $$;
create function public.mt_branch_treasury_start(p_store uuid,p_confirm boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.branch_treasury_start(p_store,p_confirm)$$;
create function public.mt_branch_cash_transfer(p_store uuid,p_id uuid,p_source uuid,p_target uuid,p_currency text,p_amount bigint,p_reference text,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_cash_transfer(p_store,p_id,p_source,p_target,p_currency,p_amount,p_reference,p_confirm)$$;
create function public.mt_branch_treasury_read(p_store uuid,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_treasury_read(p_store,p_before,p_before_id)$$;
revoke all on function tenant_private.branch_cash_apply(uuid,uuid,text,bigint),tenant_private.branch_cash_enqueue(),tenant_private.branch_cash_post(),tenant_private.branch_treasury_start(uuid,boolean),tenant_private.branch_cash_transfer(uuid,uuid,uuid,uuid,text,bigint,text,boolean),tenant_private.branch_treasury_read(uuid,timestamptz,uuid),public.mt_branch_treasury_start(uuid,boolean),public.mt_branch_cash_transfer(uuid,uuid,uuid,uuid,text,bigint,text,boolean),public.mt_branch_treasury_read(uuid,timestamptz,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_treasury_start(uuid,boolean),tenant_private.branch_cash_transfer(uuid,uuid,uuid,uuid,text,bigint,text,boolean),tenant_private.branch_treasury_read(uuid,timestamptz,uuid),public.mt_branch_treasury_start(uuid,boolean),public.mt_branch_cash_transfer(uuid,uuid,uuid,uuid,text,bigint,text,boolean),public.mt_branch_treasury_read(uuid,timestamptz,uuid) to authenticated;
commit;
