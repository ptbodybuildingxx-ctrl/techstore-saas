-- Management result by attributed branch, not separate statutory books or independent cash balances.
begin;
create function tenant_private.branch_operating_result(p_store uuid,p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;lo timestamptz;hi timestamptz;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid period' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'Asia/Damascus';hi:=(p_to+1)::timestamp at time zone 'Asia/Damascus';
 with sale_branch as (select s.id,s.created_at,s.currency,s.total_minor,b.branch_id from public.mt_sales s join tenant_private.branch_sales b on b.store_id=s.store_id and b.sale_id=s.id where s.store_id=p_store),
 repair_branch as (select i.id,i.created_at,i.currency,i.total_minor,b.branch_id from public.mt_repair_invoices i join tenant_private.branch_repairs b on b.store_id=i.store_id and b.repair_id=i.repair_id where i.store_id=p_store),
 events(branch_id,currency,revenue,cost,expense,unknown) as (
 select branch_id,currency,total_minor::numeric,0::numeric,0::numeric,0 from sale_branch where created_at>=lo and created_at<hi
 union all select branch_id,currency,total_minor,0,0,0 from repair_branch where created_at>=lo and created_at<hi
 union all select b.branch_id,r.currency,-r.total_minor,0,0,0 from public.mt_returns r join sale_branch b on b.id=r.sale_id where r.store_id=p_store and r.created_at>=lo and r.created_at<hi
 union all select b.branch_id,r.currency,-r.amount_minor,0,0,0 from public.mt_repair_refunds r join repair_branch b on b.id=r.invoice_id where r.store_id=p_store and r.created_at>=lo and r.created_at<hi
 union all select coalesce(s.branch_id,b.branch_id),c.invoice_currency,0,coalesce(c.invoice_cost_minor,0),0,case when c.invoice_cost_minor is null then 1 else 0 end from tenant_private.cost_postings c left join sale_branch s on s.id=c.sale_id left join repair_branch b on b.id=c.repair_invoice_id where c.store_id=p_store and c.created_at>=lo and c.created_at<hi and coalesce(s.branch_id,b.branch_id) is not null
 union all select s.branch_id,c.invoice_currency,0,-coalesce(c.invoice_cost_minor,0),0,case when c.invoice_cost_minor is null then 1 else 0 end from tenant_private.return_cost_postings c join public.mt_returns r on r.store_id=c.store_id and r.id=c.return_id join sale_branch s on s.id=r.sale_id where c.store_id=p_store and c.created_at>=lo and c.created_at<hi
 union all select v.branch_id,m.currency,0,0,m.amount_minor,0 from tenant_private.branch_vouchers v join public.mt_cash_movements m on m.store_id=v.store_id and m.id=v.cash_id where v.store_id=p_store and v.branch_id is not null and v.kind<>'receipt' and m.created_at>=lo and m.created_at<hi
 ), grouped as (select branch_id,currency,sum(revenue) as revenue,sum(cost) as cost,sum(expense) as expense,sum(unknown)::bigint as unknown from events group by branch_id,currency)
 select coalesce(jsonb_agg(jsonb_build_object('branch',g.branch_id,'name',b.name,'currency',g.currency,'revenue',trunc(g.revenue)::text,'cost',case when g.unknown=0 then trunc(g.cost)::text end,'expenses',trunc(g.expense)::text,'result',case when g.unknown=0 then trunc(g.revenue-g.cost-g.expense)::text end,'unknown',g.unknown) order by b.name,g.currency),'[]') into r from grouped g join tenant_private.branches b on b.store_id=p_store and b.id=g.branch_id;
 return r;
end $$;
create function public.mt_branch_operating_result(p_store uuid,p_from date,p_to date) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_operating_result(p_store,p_from,p_to)$$;
revoke all on function tenant_private.branch_operating_result(uuid,date,date),public.mt_branch_operating_result(uuid,date,date) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_operating_result(uuid,date,date),public.mt_branch_operating_result(uuid,date,date) to authenticated;
commit;
