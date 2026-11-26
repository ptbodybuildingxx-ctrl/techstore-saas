-- Read-only branch revenue and original repair invoice details.
begin;
create function public.mt_repair_receipt_lines(p_store uuid,p_invoice uuid) returns setof public.mt_repair_invoice_lines
language sql stable security invoker set search_path='' as $$select * from public.mt_repair_invoice_lines where store_id=p_store and invoice_id=p_invoice order by product_id limit 50$$;
create function tenant_private.branch_sales_report(p_store uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid period' using errcode='22023';end if;
 with sales as (
 select bs.branch_id,s.currency,count(*)::bigint as sale_count,sum(s.total_minor)::numeric as gross from public.mt_sales s left join tenant_private.branch_sales bs on bs.store_id=s.store_id and bs.sale_id=s.id where s.store_id=p_store and s.created_at>=p_from::timestamp at time zone 'Asia/Damascus' and s.created_at<(p_to+1)::timestamp at time zone 'Asia/Damascus' group by bs.branch_id,s.currency
 ),returns as (
 select bs.branch_id,r.currency,sum(r.total_minor)::numeric as refunded from public.mt_returns r left join tenant_private.branch_sales bs on bs.store_id=r.store_id and bs.sale_id=r.sale_id where r.store_id=p_store and r.created_at>=p_from::timestamp at time zone 'Asia/Damascus' and r.created_at<(p_to+1)::timestamp at time zone 'Asia/Damascus' group by bs.branch_id,r.currency
 ),keys as (select branch_id,currency from sales union select branch_id,currency from returns)
 select coalesce(jsonb_agg(jsonb_build_object('branch',k.branch_id,'name',coalesce(b.name,'المستودع الرئيسي'),'currency',k.currency,'sales',coalesce(s.sale_count,0),'gross',coalesce(s.gross,0)::text,'returns',coalesce(v.refunded,0)::text,'net',(coalesce(s.gross,0)-coalesce(v.refunded,0))::text) order by b.name nulls first,k.currency),'[]'::jsonb) into r from keys k left join sales s on s.branch_id is not distinct from k.branch_id and s.currency=k.currency left join returns v on v.branch_id is not distinct from k.branch_id and v.currency=k.currency left join tenant_private.branches b on b.store_id=p_store and b.id=k.branch_id;
 return r;
end $$;
create function public.mt_branch_sales_report(p_store uuid,p_from date,p_to date) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_sales_report(p_store,p_from,p_to)$$;
revoke all on function public.mt_repair_receipt_lines(uuid,uuid),tenant_private.branch_sales_report(uuid,date,date),public.mt_branch_sales_report(uuid,date,date) from public,anon,authenticated,service_role;
grant execute on function public.mt_repair_receipt_lines(uuid,uuid),tenant_private.branch_sales_report(uuid,date,date),public.mt_branch_sales_report(uuid,date,date) to authenticated;
commit;
