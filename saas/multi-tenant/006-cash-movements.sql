-- Development cash ledger; amounts in integer hundredths of each currency.
begin;
do $$ begin
 if to_regclass('tenant_private.sale_currencies') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required'; end if;
end $$;
create table tenant_private.cash_balances(
 store_id uuid not null,
 currency text not null,
 balance_minor bigint not null default 0 check(balance_minor between 0 and 9007199254740991),
 primary key(store_id,currency),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
create table public.mt_cash_movements(
 store_id uuid not null references tenant_private.workspaces(store_id),
 id uuid not null default gen_random_uuid(),
 request_id uuid,
 sale_id uuid,
 kind text not null check(kind in ('sale','funding','expense','exchange')),
 currency text not null,
 amount_minor bigint not null check(amount_minor between 1 and 100000000000000),
 target_currency text,
 target_amount_minor bigint check(target_amount_minor between 1 and 100000000000000),
 note text not null check(length(note)<=300),
 actor uuid not null,
 created_at timestamptz not null default now(),
 primary key(store_id,id),
 unique(store_id,request_id),unique(store_id,sale_id),
 foreign key(store_id,sale_id) references public.mt_sales(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 foreign key(store_id,target_currency) references tenant_private.sale_currencies(store_id,currency),
 check((kind='sale' and sale_id is not null and request_id is null) or (kind<>'sale' and sale_id is null and request_id is not null)),
 check((kind='exchange' and target_currency is not null and target_currency<>currency and target_amount_minor is not null) or (kind<>'exchange' and target_currency is null and target_amount_minor is null)),
 check(kind='sale' or length(btrim(note))>0)
);
create index mt_cash_movements_page_idx on public.mt_cash_movements(store_id,created_at desc,id desc);
alter table tenant_private.cash_balances enable row level security;
alter table public.mt_cash_movements enable row level security;
revoke all on tenant_private.cash_balances,public.mt_cash_movements from public,anon,authenticated,service_role;
grant select on public.mt_cash_movements to authenticated;
create policy mt_cash_movement_owner on public.mt_cash_movements for select to authenticated using (tenant_private.member_role(store_id)='owner');
create function tenant_private.cash_post() returns trigger
language plpgsql security definer set search_path='' as $$
declare d bigint;
begin
 -- Existing sale and manual paths serialize on the same tenant registry row.
 perform 1 from public.saas_stores where id=new.store_id for update;
 if new.kind in ('sale','funding') then
  insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.currency,new.amount_minor)
  on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;
 else
  update tenant_private.cash_balances set balance_minor=balance_minor-new.amount_minor where store_id=new.store_id and currency=new.currency and balance_minor>=new.amount_minor;
  if not found then raise exception 'Insufficient cash in source currency' using errcode='22023';end if;
  if new.kind='exchange' then
   insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.target_currency,new.target_amount_minor)
   on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;
  end if;
 end if;
 return new;
end $$;
create trigger mt_post_cash after insert on public.mt_cash_movements for each row execute function tenant_private.cash_post();
create function tenant_private.cash_from_sale() returns trigger
language plpgsql security definer set search_path='' as $$
declare s public.mt_sales%rowtype;
begin
 select * into strict s from public.mt_sales where store_id=new.store_id and id=new.sale_id;
 if s.currency<>new.currency or s.total_minor<>new.amount_minor then raise exception 'Receipt mismatch';end if;
 insert into public.mt_cash_movements(store_id,sale_id,kind,currency,amount_minor,note,actor,created_at)
 values(new.store_id,new.sale_id,'sale',new.currency,new.amount_minor,'Cash sale',s.actor,new.recorded_at);
 return new;
end $$;
create trigger mt_cash_receipt_post after insert on public.mt_cash_receipts for each row execute function tenant_private.cash_from_sale();
-- Preserve existing historical receipts, without relabeling currencies.
insert into public.mt_cash_movements(store_id,sale_id,kind,currency,amount_minor,note,actor,created_at)
select r.store_id,r.sale_id,'sale',r.currency,r.amount_minor,'Cash sale',s.actor,r.recorded_at from public.mt_cash_receipts r join public.mt_sales s on s.store_id=r.store_id and s.id=r.sale_id;
create function tenant_private.cash_record(p_store uuid,p_request uuid,p_kind text,p_currency text,p_amount bigint,p_note text,p_target_currency text,p_target_amount bigint) returns uuid
language plpgsql security definer set search_path='' as $$
declare m public.mt_cash_movements%rowtype;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_kind is null or p_kind not in ('funding','expense','exchange') or p_currency is null or p_amount is null or p_amount not between 1 and 100000000000000 or p_note is null or length(btrim(p_note)) not between 1 and 300 or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Invalid cash movement' using errcode='22023';end if;
 if p_kind='exchange' then
  if p_target_currency is null or p_target_currency=p_currency or p_target_amount is null or p_target_amount not between 1 and 100000000000000 or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_target_currency) then raise exception 'Invalid exchange' using errcode='22023';end if;
 elsif p_target_currency is not null or p_target_amount is not null then raise exception 'Unexpected exchange fields' using errcode='22023';end if;
 select * into m from public.mt_cash_movements where store_id=p_store and request_id=p_request;
 if found then
  if m.actor<>auth.uid() or m.kind<>p_kind or m.currency<>p_currency or m.amount_minor<>p_amount or m.note<>btrim(p_note) or m.target_currency is distinct from p_target_currency or m.target_amount_minor is distinct from p_target_amount then raise exception 'Conflicting cash request' using errcode='22023';end if;
  return m.id;
 end if;
 insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,target_currency,target_amount_minor)
 values(p_store,p_request,p_kind,p_currency,p_amount,btrim(p_note),auth.uid(),p_target_currency,p_target_amount) returning * into m;
 return m.id;
end $$;
create function tenant_private.cash_overview(p_store uuid,p_before timestamptz,p_before_id uuid,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 or (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page' using errcode='22023';end if;
 select jsonb_build_object('balances',coalesce((select jsonb_agg(jsonb_build_object('currency',c.currency,'balance_minor',coalesce(b.balance_minor,0)) order by c.currency) from tenant_private.sale_currencies c left join tenant_private.cash_balances b on b.store_id=c.store_id and b.currency=c.currency where c.store_id=p_store),'[]'::jsonb),
 'movements',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at desc,m.id desc) from (select id,request_id,sale_id,kind,currency,amount_minor,target_currency,target_amount_minor,note,created_at from public.mt_cash_movements where store_id=p_store and (p_before is null or (created_at,id)<(p_before,p_before_id)) order by created_at desc,id desc limit p_limit) m),'[]'::jsonb)) into r;
 return r;
end $$;
create function public.mt_record_cash(p_store uuid,p_request uuid,p_kind text,p_currency text,p_amount bigint,p_note text,p_target_currency text default null,p_target_amount bigint default null) returns uuid
language sql security invoker set search_path='' as $$ select tenant_private.cash_record(p_store,p_request,p_kind,p_currency,p_amount,p_note,p_target_currency,p_target_amount) $$;
create function public.mt_cash_overview(p_store uuid,p_before timestamptz default null,p_before_id uuid default null,p_limit integer default 50) returns jsonb
language sql stable security invoker set search_path='' as $$ select tenant_private.cash_overview(p_store,p_before,p_before_id,p_limit) $$;
revoke all on function tenant_private.cash_post(),tenant_private.cash_from_sale(),tenant_private.cash_record(uuid,uuid,text,text,bigint,text,text,bigint),tenant_private.cash_overview(uuid,timestamptz,uuid,integer),public.mt_record_cash(uuid,uuid,text,text,bigint,text,text,bigint),public.mt_cash_overview(uuid,timestamptz,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.cash_record(uuid,uuid,text,text,bigint,text,text,bigint),tenant_private.cash_overview(uuid,timestamptz,uuid,integer),public.mt_record_cash(uuid,uuid,text,text,bigint,text,text,bigint),public.mt_cash_overview(uuid,timestamptz,uuid,integer) to authenticated;
commit;