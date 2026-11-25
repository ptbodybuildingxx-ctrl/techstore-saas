-- Currency selection for shared development tenants. Do not relabel historical money.
begin;
do $$ begin
 if to_regclass('tenant_private.placements') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
 if exists(select 1 from tenant_private.sales_settings where currency='SEK') or exists(select 1 from public.mt_sales where currency='SEK') or exists(select 1 from public.mt_cash_receipts where currency='SEK') then raise exception 'Existing SEK records require explicit migration; no currency relabeling';end if;
end $$;
alter table tenant_private.sales_settings drop constraint sales_settings_currency_check, add constraint sales_settings_currency_check check(currency in ('SYP','USD','EUR'));
alter table public.mt_sales drop constraint mt_sales_currency_check, add constraint mt_sales_currency_check check(currency in ('SYP','USD','EUR'));
alter table public.mt_cash_receipts drop constraint mt_cash_receipts_currency_check, add constraint mt_cash_receipts_currency_check check(currency in ('SYP','USD','EUR'));
create or replace function tenant_private.configure_sales(p_store uuid,p_currency text) returns text
language plpgsql security definer set search_path='' as $$
declare c text;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_currency is null or p_currency not in ('SYP','USD','EUR') then raise exception 'Unsupported currency' using errcode='22023';end if;
 insert into tenant_private.sales_settings(store_id,currency) values(p_store,p_currency) on conflict(store_id) do nothing;
 select currency into c from tenant_private.sales_settings where store_id=p_store;
 if c<>p_currency then raise exception 'Currency is immutable in development' using errcode='22023';end if;
 return c;
end $$;
commit;
