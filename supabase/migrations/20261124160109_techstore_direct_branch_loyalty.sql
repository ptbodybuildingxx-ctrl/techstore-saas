begin;
alter table public.ts_branch_events add column customer_id uuid references public.ts_profiles(user_id);
create table techstore_private.loyalty_sale_links(
 source_kind text not null check(source_kind in ('invoice','branch')), source_id uuid not null, customer_id uuid not null references public.ts_profiles(user_id), total numeric not null check(total>0), earned bigint not null check(earned>=0), target bigint not null check(target>=0 and target<=earned), posted bigint not null default 0 check(posted>=0 and posted<=earned),primary key(source_kind,source_id)
);
alter table techstore_private.loyalty_sale_links enable row level security;
revoke all on techstore_private.loyalty_sale_links from public,anon,authenticated;
create index ts_loyalty_links_pending_idx on techstore_private.loyalty_sale_links(source_kind,source_id) where target<>posted;
create function techstore_private.capture_sale_loyalty() returns trigger language plpgsql security definer set search_path='' as $$
declare gross numeric; points bigint;
begin
 if tg_table_name='ts_invoices' then
 if new.kind<>'sale' or new.customer_id is null or new.document->>'source'='web_order' or coalesce(new.document->>'payment_mode','cash')<>'cash' then return new;end if;
 gross:=(new.document->>'total')::numeric;
 else
 if new.kind<>'sale' or new.customer_id is null then return new;end if;
 gross:=new.amount;
 end if;
 if gross<=0 then return new;end if;
 points:=floor(gross)::bigint;
 insert into techstore_private.loyalty_sale_links(source_kind,source_id,customer_id,total,earned,target) values(case when tg_table_name='ts_invoices' then 'invoice' else 'branch' end,new.id,new.customer_id,gross,points,points);
 return new;
end $$;
revoke all on function techstore_private.capture_sale_loyalty() from public,anon,authenticated;
create trigger ts_capture_direct_sale_loyalty after insert on public.ts_invoices for each row execute function techstore_private.capture_sale_loyalty();
create trigger ts_capture_branch_sale_loyalty after insert on public.ts_branch_events for each row execute function techstore_private.capture_sale_loyalty();
create function techstore_private.capture_sale_loyalty_return() returns trigger language plpgsql security definer set search_path='' as $$
declare sid uuid; typ text; amount_value numeric;
begin
 if tg_table_name='ts_branch_events' then
 if new.kind<>'return' then return new;end if;
 sid:=new.original_sale_id;typ:='branch';
 select coalesce(sum(amount),0) into amount_value from public.ts_branch_events where original_sale_id=sid and kind='return';
 else
 sid:=new.invoice_id;typ:='invoice';
 select coalesce(sum(gross),0) into amount_value from public.ts_invoice_adjustments where invoice_id=sid;
 if exists(select 1 from public.ts_invoice_refunds where invoice_id=sid) then
 select total into amount_value from techstore_private.loyalty_sale_links where source_kind=typ and source_id=sid;
 end if;
 end if;
 update techstore_private.loyalty_sale_links set target=earned-floor(earned*least(1,greatest(0,amount_value/total)))::bigint where source_kind=typ and source_id=sid;
 return new;
end $$;
revoke all on function techstore_private.capture_sale_loyalty_return() from public,anon,authenticated;
create trigger ts_capture_branch_loyalty_return after insert on public.ts_branch_events for each row execute function techstore_private.capture_sale_loyalty_return();
create trigger ts_capture_adjustment_loyalty_return after insert on public.ts_invoice_adjustments for each row execute function techstore_private.capture_sale_loyalty_return();
create trigger ts_capture_full_loyalty_return after insert on public.ts_invoice_refunds for each row execute function techstore_private.capture_sale_loyalty_return();
create function techstore_private.post_sale_loyalty() returns trigger language plpgsql security definer set search_path='' as $$
declare r techstore_private.loyalty_sale_links%rowtype; l jsonb; delta bigint;
begin
 l:=coalesce(new.payload->'records'->'loyalty','[]');
 for r in select * from techstore_private.loyalty_sale_links where target<>posted order by source_kind,source_id for update loop
 delta:=r.target-r.posted;
 l:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'owner',r.customer_id,'created',now(),'points',delta,'order',r.source_id,'kind',case when delta>0 then 'earn' else 'return_earn_reverse' end,'source',r.source_kind))||l;
 update techstore_private.loyalty_sale_links set posted=target where source_kind=r.source_kind and source_id=r.source_id;
 end loop;
 if l is distinct from coalesce(new.payload->'records'->'loyalty','[]') then new.payload:=jsonb_set(new.payload,'{records}',coalesce(new.payload->'records','{}')||jsonb_build_object('loyalty',l),true);end if;
 return new;
end $$;
revoke all on function techstore_private.post_sale_loyalty() from public,anon,authenticated;
create trigger ts_post_direct_branch_loyalty before update of payload,revision on public.ts_workspace for each row execute function techstore_private.post_sale_loyalty();
create or replace function techstore_private.branch_operation(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.ts_workspace%rowtype; src uuid; dst uuid; req uuid; pid text; q bigint; prod jsonb; ix integer; available bigint; uc numeric; destcost numeric; destqty bigint; amount numeric; cost numeric; event public.ts_branch_events%rowtype; sale jsonb; data jsonb; cust uuid;
begin
 if techstore_private.live_session() is distinct from true or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501'; end if;
 if p_action='list' then
 return jsonb_build_object('branches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title)) from public.ts_pro_entries where kind='branches' and not archived),'[]'::jsonb),'stock',coalesce((select jsonb_agg(to_jsonb(s)) from public.ts_branch_stock s),'[]'::jsonb),'events',coalesce((select jsonb_agg(to_jsonb(e)) from (select * from public.ts_branch_events order by created_at desc limit 200) e),'[]'::jsonb),'journal',coalesce((select jsonb_agg(to_jsonb(j)) from (select jp.*,ev.created_at from public.ts_journal_pairs jp join public.ts_branch_events ev on ev.id=jp.event_id order by ev.created_at desc limit 400) j),'[]'::jsonb));
 end if;
 if p_action is null or p_action not in ('transfer','sale') or jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>8000 then raise exception 'Invalid operation'; end if;
 req:=(p_args->>'request_id')::uuid; src:=nullif(p_args->>'from','')::uuid; dst:=nullif(p_args->>'to','')::uuid; pid:=p_args->>'product'; q:=(p_args->>'qty')::bigint;cust:=nullif(p_args->>'customer_id','')::uuid;
 if cust is not null and (p_action<>'sale' or not exists(select 1 from public.ts_profiles where user_id=cust and role='customer' and active)) then raise exception 'Invalid linked customer';end if;
 if req is null or pid is null or q is null or q<1 or q>1000000 or length(pid)>200 then raise exception 'Invalid quantity or request'; end if;
 if p_action='sale' and (src is null or dst is not null) then raise exception 'Sale requires branch'; end if;
 if p_action='transfer' and src is not distinct from dst then raise exception 'Different source and destination required'; end if;
 -- Serialize with the legacy workspace revision to avoid conflicting saves and stock movement.
 select * into w from public.ts_workspace where id=1 for update;
 select * into event from public.ts_branch_events where request_id=req;
 if found then
 if event.actor<>auth.uid() or event.kind<>p_action or event.product_id<>pid or event.qty<>q or event.branch_from is distinct from src or event.branch_to is distinct from dst or event.customer_id is distinct from cust then raise exception 'Request ID conflict'; end if;
 return jsonb_build_object('id',event.id,'amount',event.amount,'duplicate',true);
 end if;
 if src is not null and not exists(select 1 from public.ts_pro_entries where id=src and kind='branches' and not archived) then raise exception 'Invalid source branch'; end if;
 if dst is not null and not exists(select 1 from public.ts_pro_entries where id=dst and kind='branches' and not archived) then raise exception 'Invalid destination branch'; end if;
 data:=w.payload->'data';
 select p,ord::integer-1 into prod,ix from jsonb_array_elements(coalesce(data->'products','[]'::jsonb)) with ordinality as t(p,ord) where p->>'id'=pid;
 if prod is null then raise exception 'Product not found'; end if;
 if src is null then available:=(prod->>'qty')::bigint; uc:=(prod->>'cost')::numeric;
 else select qty,unit_cost into available,uc from public.ts_branch_stock where branch_id=src and product_id=pid for update; end if;
 if available is null or available<q or uc is null or uc<0 then raise exception 'Insufficient or invalid stock'; end if;
 cost:=round(uc*q,2); amount:=case when p_action='sale' then round((prod->>'price')::numeric*q,2) else cost end;
 if amount is null or amount<0 then raise exception 'Invalid price'; end if;
 if src is null then data:=jsonb_set(data,array['products',ix::text,'qty'],to_jsonb(available-q));
 else update public.ts_branch_stock set qty=qty-q where branch_id=src and product_id=pid; end if;
 if p_action='transfer' then
  if dst is null then
   destqty:=(prod->>'qty')::bigint; destcost:=(prod->>'cost')::numeric;
   data:=jsonb_set(jsonb_set(data,array['products',ix::text,'qty'],to_jsonb(destqty+q)),array['products',ix::text,'cost'],to_jsonb(round((destqty*destcost+q*uc)/(destqty+q),4)));
  else
   insert into public.ts_branch_stock(branch_id,product_id,qty,unit_cost) values(dst,pid,q,uc)
   on conflict(branch_id,product_id) do update set unit_cost=round((public.ts_branch_stock.qty*public.ts_branch_stock.unit_cost+excluded.qty*excluded.unit_cost)/(public.ts_branch_stock.qty+excluded.qty),4),qty=public.ts_branch_stock.qty+excluded.qty;
  end if;
 end if;
 insert into public.ts_branch_events(request_id,actor,kind,branch_from,branch_to,product_id,qty,amount,cost,customer_id) values(req,auth.uid(),p_action,src,dst,pid,q,amount,cost,cust) returning * into event;
 if p_action='sale' then
 if amount>0 then insert into public.ts_journal_pairs(event_id,debit_account,credit_account,amount) values(event.id,'cash:'||src::text,'sales',amount); end if;
 if cost>0 then insert into public.ts_journal_pairs(event_id,debit_account,credit_account,amount) values(event.id,'cost_of_sales','inventory:'||src::text,cost); end if;
 -- Branch sales are held in their own immutable register, not legacy invoices; avoid legacy return restocking the wrong location.
 else
 if cost>0 then insert into public.ts_journal_pairs(event_id,debit_account,credit_account,amount) values(event.id,'inventory:'||coalesce(dst::text,'central'),'inventory:'||coalesce(src::text,'central'),cost); end if;
 end if;
 update public.ts_workspace set payload=jsonb_set(w.payload,'{data}',data),revision=revision+1,updated_at=now() where id=1;
 insert into public.ts_audit(actor,action) values(auth.uid(),'branch '||p_action||' '||event.id::text);
 return jsonb_build_object('id',event.id,'amount',amount,'cost',cost,'duplicate',false);
end $$;

commit;