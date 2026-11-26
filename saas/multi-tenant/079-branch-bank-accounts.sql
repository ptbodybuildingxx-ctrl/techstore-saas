-- Location-bound bank accounts, with cash legs posted to the same branch.
begin;
alter table tenant_private.bank_accounts add column branch_id uuid,add foreign key(store_id,branch_id) references tenant_private.branches(store_id,id);
-- Existing accounts remain central; location cannot be reassigned after creation.
create function tenant_private.branch_bank_create(p_store uuid,p_id uuid,p_branch uuid,p_name text,p_currency text) returns uuid language plpgsql security definer set search_path='' as $$
declare a tenant_private.bank_accounts%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_name is null or length(btrim(p_name)) not between 1 and 120 then raise exception 'Invalid bank account' using errcode='22023';end if;
 if p_branch is not null then perform tenant_private.require_branch(p_store,p_branch);
 if not exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then raise exception 'Activate branch cashboxes first' using errcode='22023';end if;end if;
 select * into a from tenant_private.bank_accounts where store_id=p_store and id=p_id;
 if found then if a.branch_id is distinct from p_branch or a.name<>btrim(p_name) or a.currency<>p_currency then raise exception 'Conflicting bank account' using errcode='22023';end if;return p_id;end if;
 if (select count(*) from tenant_private.bank_accounts where store_id=p_store)>=50 then raise exception 'Account limit' using errcode='22023';end if;
 insert into tenant_private.bank_accounts(store_id,id,name,currency,branch_id) values(p_store,p_id,btrim(p_name),p_currency,p_branch);return p_id;
end $$;
create or replace function tenant_private.bank_create(p_store uuid,p_id uuid,p_name text,p_currency text) returns uuid language sql security definer set search_path='' as $$select tenant_private.branch_bank_create(p_store,p_id,null,p_name,p_currency)$$;
create or replace function tenant_private.branch_cash_post() returns trigger language plpgsql security definer set search_path='' as $$
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
 elsif exists(select 1 from tenant_private.bank_transfers where store_id=m.store_id and cash_id=m.id) then select a.branch_id into b from tenant_private.bank_transfers t join tenant_private.bank_accounts a on a.store_id=t.store_id and a.id=t.account_id where t.store_id=m.store_id and t.cash_id=m.id;
 else select branch_id into b from tenant_private.branch_vouchers where store_id=m.store_id and cash_id=m.id;end if;
 delta:=case when m.kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then m.amount_minor when m.kind in ('expense','exchange','return','return_refund','supplier_payment','repair_refund') then -m.amount_minor else null end;
 -- Fail closed on new cash types; known sale returns may be called refund.
 if m.kind='refund' then delta:=-m.amount_minor;end if;
 if delta is null then raise exception 'Unknown cash type for branch treasury';end if;
 perform tenant_private.branch_cash_apply(m.store_id,b,m.currency,delta);
 if m.kind='exchange' then perform tenant_private.branch_cash_apply(m.store_id,b,m.target_currency,m.target_amount_minor);end if;
 update tenant_private.branch_cash_attribution set branch_id=b,posted=true where store_id=m.store_id and cash_id=m.id;return new;
end $$;
create or replace function tenant_private.bank_overview(p_store uuid,p_before timestamptz,p_before_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid cursor' using errcode='22023';end if;
 return jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(x) order by name,currency) from (select id,name,currency,balance_minor,branch_id from tenant_private.bank_accounts where store_id=p_store)x),'[]'::jsonb),'transfers',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id desc) from (select t.request_id,a.name,a.currency,a.branch_id,t.direction,t.amount_minor,t.reference,t.created_at from tenant_private.bank_transfers t join tenant_private.bank_accounts a on a.store_id=t.store_id and a.id=t.account_id where t.store_id=p_store and (p_before is null or (t.created_at,t.request_id)<(p_before,p_before_id)) order by t.created_at desc,t.request_id desc limit 50)x),'[]'::jsonb));
end $$;
create or replace function tenant_private.branch_account_balances(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return (with locations as (
 select null::uuid branch_id,'المستودع الرئيسي'::text name union all select id,name from tenant_private.branches where store_id=p_store
 ), entries as (
 select b.branch_id,d.currency,'receivable'::text account,d.remaining_minor::numeric amount from public.mt_debts d left join tenant_private.branch_sales b on b.store_id=d.store_id and b.sale_id=d.sale_id where d.store_id=p_store
 union all select b.branch_id,p.currency,'payable',p.total_minor::numeric-p.returned_units::numeric*p.unit_cost_minor-p.paid_minor+p.refunded_minor from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=p_store
 union all select branch_id,currency,'payroll',tenant_private.payroll_due(store_id,id)::numeric from tenant_private.staff_payroll where store_id=p_store and paid_at is null
 union all select branch_id,currency,'advance',tenant_private.advance_remaining(store_id,id)::numeric from tenant_private.staff_advances where store_id=p_store
 ), totals as (select branch_id,currency,sum(amount) filter(where account='receivable') receivable,sum(amount) filter(where account='payable') payable,sum(amount) filter(where account='payroll') payroll,sum(amount) filter(where account='advance') advances from entries group by branch_id,currency),
 units as (select branch_id,sum(units)::numeric units from tenant_private.branch_stock where store_id=p_store group by branch_id union all select null::uuid,coalesce(sum(p.quantity-tenant_private.branch_allocated(p.store_id,p.id)),0)::numeric from public.mt_products p where store_id=p_store),
 bank as (select branch_id,currency,sum(balance_minor)::numeric amount from tenant_private.bank_accounts where store_id=p_store group by branch_id,currency),
 valuation as (select a.branch_id,k.currency,sum(a.units::numeric*k.unit_cost_minor) amount from tenant_private.branch_fifo_lots a join tenant_private.stock_layers k on k.store_id=a.store_id and k.product_id=a.product_id and k.id=a.layer_id where a.store_id=p_store and a.units>0 and k.currency is not null group by a.branch_id,k.currency),
 unknown as (select a.branch_id,sum(a.units)::numeric units from tenant_private.branch_fifo_lots a join tenant_private.stock_layers k on k.store_id=a.store_id and k.product_id=a.product_id and k.id=a.layer_id where a.store_id=p_store and a.units>0 and k.currency is null group by a.branch_id),
 rows as (select l.branch_id,l.name,c.currency,case when exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then coalesce(a.balance_minor,0)::text else null end cash,coalesce(bk.amount,0)::text bank,case when exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then coalesce(v.amount,0)::text else null end known_stock_cost,case when exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then coalesce(un.units,0)::text else null end unknown_cost_units,coalesce(t.receivable,0)::text receivable,coalesce(t.payable,0)::text payable,coalesce(t.payroll,0)::text payroll,coalesce(t.advances,0)::text advances,coalesce(u.units,0)::text stock_units from locations l cross join tenant_private.sale_currencies c left join totals t on t.branch_id is not distinct from l.branch_id and t.currency=c.currency left join tenant_private.branch_cash_accounts a on a.store_id=p_store and a.branch_id is not distinct from l.branch_id and a.currency=c.currency left join units u on u.branch_id is not distinct from l.branch_id left join bank bk on bk.branch_id is not distinct from l.branch_id and bk.currency=c.currency left join valuation v on v.branch_id is not distinct from l.branch_id and v.currency=c.currency left join unknown un on un.branch_id is not distinct from l.branch_id where c.store_id=p_store)
 select jsonb_build_object('mode','attributed_subledgers','stock_valuation_available',exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store),'rows',coalesce(jsonb_agg(to_jsonb(r) order by r.name,r.currency),'[]'::jsonb)) from rows r);
end $$;
create function public.mt_branch_bank_create(p_store uuid,p_id uuid,p_branch uuid,p_name text,p_currency text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_bank_create(p_store,p_id,p_branch,p_name,p_currency)$$;
revoke all on function tenant_private.branch_bank_create(uuid,uuid,uuid,text,text),public.mt_branch_bank_create(uuid,uuid,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_bank_create(uuid,uuid,uuid,text,text),public.mt_branch_bank_create(uuid,uuid,uuid,text,text) to authenticated;
commit;
