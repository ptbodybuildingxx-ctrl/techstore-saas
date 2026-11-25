CREATE OR REPLACE FUNCTION techstore_private.capture_sale_loyalty()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare gross numeric; points bigint;
begin
 if tg_table_name='ts_invoices' then
 if new.kind<>'sale' or new.customer_id is null or new.document->>'source'='web_order' or coalesce(new.document->>'payment_mode','cash') not in ('cash','installment') then return new;end if;
 gross:=(new.document->>'total')::numeric;
 points:=floor(case when coalesce(new.document->>'payment_mode','cash')='installment' then (new.document->>'paid')::numeric else gross end)::bigint;
 else
 if new.kind<>'sale' or new.customer_id is null then return new;end if;
 gross:=new.amount;
 points:=floor(gross)::bigint;
 end if;
 if gross<=0 then return new;end if;
 
 insert into techstore_private.loyalty_sale_links(source_kind,source_id,customer_id,total,earned,target) values(case when tg_table_name='ts_invoices' then 'invoice' else 'branch' end,new.id,new.customer_id,gross,points,points);
 return new;
end $function$
;
