begin;
create function techstore_private.reconcile_return_loyalty() returns trigger language plpgsql security definer set search_path='' as $$
declare i record; l jsonb; o jsonb; earned bigint; redeemed bigint; target_earned bigint; target_redeemed bigint; actual_earned bigint; actual_redeemed bigint; ratio numeric; total_return numeric; delta bigint;
begin
 l:=coalesce(new.payload->'records'->'loyalty','[]');
 for i in select v.id,v.customer_id,v.document from public.ts_invoices v where v.kind='sale' and v.customer_id is not null and v.document->>'source'='web_order' and (exists(select 1 from public.ts_invoice_adjustments a where a.invoice_id=v.id) or exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=v.id)) loop
 select x into o from jsonb_array_elements(coalesce(new.payload->'records'->'orders','[]')) x where x->>'id'=i.id::text;
 if o is null or o->>'status' is distinct from 'delivered' then continue;end if;
 select coalesce(sum(gross),0) into total_return from public.ts_invoice_adjustments where invoice_id=i.id;
 if exists(select 1 from public.ts_invoice_refunds where invoice_id=i.id) then total_return:=(i.document->>'total')::numeric;end if;
 if coalesce((i.document->>'total')::numeric,0)<=0 then continue;end if;
 ratio:=least(1,greatest(0,total_return/(i.document->>'total')::numeric));
 select coalesce(sum((x->>'points')::bigint),0) into earned from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and coalesce(x->>'kind','earn')='earn' and (x->>'points')::bigint>0;
 select coalesce(-sum((x->>'points')::bigint),0) into redeemed from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and x->>'kind'='redemption';
 target_earned:=-floor(earned*ratio)::bigint;target_redeemed:=floor(redeemed*ratio)::bigint;
 select coalesce(sum((x->>'points')::bigint),0) into actual_earned from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and x->>'kind'='return_earn_reverse';
 select coalesce(sum((x->>'points')::bigint),0) into actual_redeemed from jsonb_array_elements(l) x where x->>'order'=i.id::text and x->>'owner'=i.customer_id::text and x->>'kind'='return_redemption_restore';
 delta:=target_earned-actual_earned;
 if delta<>0 then l:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',i.customer_id,'created',now(),'points',delta,'order',i.id,'kind','return_earn_reverse'))||l;end if;
 delta:=target_redeemed-actual_redeemed;
 if delta<>0 then l:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',i.customer_id,'created',now(),'points',delta,'order',i.id,'kind','return_redemption_restore'))||l;end if;
 end loop;
 if l is distinct from coalesce(new.payload->'records'->'loyalty','[]') then new.payload:=jsonb_set(new.payload,'{records,loyalty}',l,true);end if;
 return new;
end $$;
revoke all on function techstore_private.reconcile_return_loyalty() from public,anon,authenticated;
create trigger ts_return_loyalty_reconcile before update of payload on public.ts_workspace for each row execute function techstore_private.reconcile_return_loyalty();
commit;