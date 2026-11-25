begin;
create table public.ts_branch_stock (
 branch_id uuid not null references public.ts_pro_entries(id),
 product_id text not null check(length(product_id) between 1 and 200),
 qty bigint not null check(qty between 0 and 100000000),
 unit_cost numeric(18,4) not null check(unit_cost>=0),
 primary key(branch_id,product_id)
);
create table public.ts_branch_events (
 id uuid primary key default gen_random_uuid(),
 request_id uuid not null unique,
 actor uuid not null references public.ts_profiles(user_id),
 kind text not null check(kind in ('transfer','sale')),
 branch_from uuid references public.ts_pro_entries(id),
 branch_to uuid references public.ts_pro_entries(id),
 product_id text not null,
 qty bigint not null check(qty>0),
 amount numeric(18,2) not null check(amount>=0),
 cost numeric(18,2) not null check(cost>=0),
 created_at timestamptz not null default now()
);
create table public.ts_journal_pairs (
 id uuid primary key default gen_random_uuid(),
 event_id uuid not null references public.ts_branch_events(id),
 debit_account text not null, credit_account text not null,
 amount numeric(18,2) not null check(amount>0), currency text not null default 'USD' check(currency='USD'),
 check(debit_account<>credit_account)
);
create index ts_journal_event_idx on public.ts_journal_pairs(event_id);
alter table public.ts_branch_stock enable row level security;
alter table public.ts_branch_events enable row level security;
alter table public.ts_journal_pairs enable row level security;
revoke all on public.ts_branch_stock,public.ts_branch_events,public.ts_journal_pairs from public,anon,authenticated;
create function techstore_private.branch_operation(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.ts_workspace%rowtype; src uuid; dst uuid; req uuid; pid text; q bigint; prod jsonb; ix integer; available bigint; uc numeric; destcost numeric; destqty bigint; amount numeric; cost numeric; event public.ts_branch_events%rowtype; sale jsonb; data jsonb;
begin
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501'; end if;
 if p_action='list' then
 return jsonb_build_object('branches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title)) from public.ts_pro_entries where kind='branches' and not archived),'[]'::jsonb),'stock',coalesce((select jsonb_agg(to_jsonb(s)) from public.ts_branch_stock s),'[]'::jsonb),'events',coalesce((select jsonb_agg(to_jsonb(e)) from (select * from public.ts_branch_events order by created_at desc limit 200) e),'[]'::jsonb),'journal',coalesce((select jsonb_agg(to_jsonb(j)) from (select jp.*,ev.created_at from public.ts_journal_pairs jp join public.ts_branch_events ev on ev.id=jp.event_id order by ev.created_at desc limit 400) j),'[]'::jsonb));
 end if;
 if p_action not in ('transfer','sale') or p_args is null then raise exception 'Invalid operation'; end if;
 req:=(p_args->>'request_id')::uuid; src:=nullif(p_args->>'from','')::uuid; dst:=nullif(p_args->>'to','')::uuid; pid:=p_args->>'product'; q:=(p_args->>'qty')::bigint;
 if req is null or pid is null or q is null or q<1 or q>1000000 or length(pid)>200 then raise exception 'Invalid quantity or request'; end if;
 if p_action='sale' and (src is null or dst is not null) then raise exception 'Sale requires branch'; end if;
 if p_action='transfer' and src is not distinct from dst then raise exception 'Different source and destination required'; end if;
 -- Serialize with the legacy workspace revision to avoid conflicting saves and stock movement.
 select * into w from public.ts_workspace where id=1 for update;
 select * into event from public.ts_branch_events where request_id=req;
 if found then
 if event.actor<>auth.uid() or event.kind<>p_action or event.product_id<>pid or event.qty<>q or event.branch_from is distinct from src or event.branch_to is distinct from dst then raise exception 'Request ID conflict'; end if;
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
 insert into public.ts_branch_events(request_id,actor,kind,branch_from,branch_to,product_id,qty,amount,cost) values(req,auth.uid(),p_action,src,dst,pid,q,amount,cost) returning * into event;
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
revoke all on function techstore_private.branch_operation(text,jsonb) from public,anon;
grant execute on function techstore_private.branch_operation(text,jsonb) to authenticated;
create function public.ts_branch_operation(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.branch_operation(p_action,p_args); $$;
revoke all on function public.ts_branch_operation(text,jsonb) from public,anon;
grant execute on function public.ts_branch_operation(text,jsonb) to authenticated;
commit;