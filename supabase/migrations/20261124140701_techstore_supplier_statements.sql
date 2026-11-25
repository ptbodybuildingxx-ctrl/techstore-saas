begin;
create table public.ts_supplier_bills(purchase_id text primary key,supplier_id text not null,amount numeric(18,2) not null check(amount>0),due_date date,actor uuid not null references public.ts_profiles(user_id),created_at timestamptz not null default now());
create table public.ts_supplier_payments(id uuid primary key default gen_random_uuid(),request_id uuid not null unique,purchase_id text not null references public.ts_supplier_bills(purchase_id),amount numeric(18,2) not null check(amount>0),actor uuid not null references public.ts_profiles(user_id),memo text not null,created_at timestamptz not null default now());
alter table public.ts_supplier_bills enable row level security;
alter table public.ts_supplier_payments enable row level security;
revoke all on public.ts_supplier_bills,public.ts_supplier_payments from public,anon,authenticated;
create function techstore_private.supplier_finance(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; pur jsonb; b public.ts_supplier_bills%rowtype; pay public.ts_supplier_payments%rowtype; pid text; req uuid; a numeric; paid numeric; memo_value text;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found or (u.role='admin' or (u.role='stock' and p_action='list' and techstore_private.staff_allowed(u.user_id,'supplier_read'))) is distinct from true then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='list' then
 select * into w from public.ts_workspace where id=1;
 return jsonb_build_object('suppliers',coalesce(w.payload->'records'->'suppliers','[]'),'purchases',coalesce(w.payload->'records'->'purchases','[]'),'bills',coalesce((select jsonb_agg(to_jsonb(x)) from (select b.*,coalesce((select sum(p.amount) from public.ts_supplier_payments p where p.purchase_id=b.purchase_id),0) as paid from public.ts_supplier_bills b order by b.created_at desc limit 500) x),'[]'),'branch_totals',case when u.role='admin' then coalesce((select jsonb_agg(to_jsonb(x)) from (select e.branch_from as branch_id,sum(e.amount) as revenue,sum(e.cost) as cost,count(*) as sales from public.ts_branch_events e where e.kind='sale' group by e.branch_from) x),'[]') else '[]' end,'branches',case when u.role='admin' then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title)) from public.ts_pro_entries where kind='branches'),'[]') else '[]' end);
 end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>8000 then raise exception 'Invalid request';end if;
 pid:=p_args->>'purchase_id';
 select * into w from public.ts_workspace where id=1 for update;
 if p_action='register' then
 select x into pur from jsonb_array_elements(coalesce(w.payload->'records'->'purchases','[]')) x where x->>'id'=pid;
 if pur is null or (pur->>'total')::numeric<=0 or pur->>'supplier' is null then raise exception 'Purchase unavailable';end if;
 insert into public.ts_supplier_bills(purchase_id,supplier_id,amount,due_date,actor) values(pid,pur->>'supplier',round((pur->>'total')::numeric,2),nullif(p_args->>'due_date','')::date,u.user_id) on conflict(purchase_id) do nothing;
 elsif p_action='payment' then
 req:=(p_args->>'request_id')::uuid;a:=round((p_args->>'amount')::numeric,2);memo_value:=btrim(coalesce(p_args->>'memo',''));
 if req is null or a is null or a<=0 or a>1000000000 or length(memo_value) not between 1 and 500 then raise exception 'Invalid payment';end if;
 select * into pay from public.ts_supplier_payments where request_id=req;
 if found then if pay.actor<>u.user_id or pay.purchase_id<>pid or pay.amount<>a or pay.memo<>memo_value then raise exception 'Request conflict';end if;return to_jsonb(pay);end if;
 select * into b from public.ts_supplier_bills where purchase_id=pid for update;if not found then raise exception 'Register purchase first';end if;
 select coalesce(sum(amount),0) into paid from public.ts_supplier_payments where purchase_id=pid;
 if a>b.amount-paid then raise exception 'Payment exceeds supplier balance';end if;
 insert into public.ts_supplier_payments(request_id,purchase_id,amount,actor,memo) values(req,pid,a,u.user_id,memo_value) returning * into pay;
 else raise exception 'Unknown action';end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'supplier '||p_action||' '||pid);return jsonb_build_object('ok',true);
end $$;
revoke all on function techstore_private.supplier_finance(text,jsonb) from public,anon,authenticated;
grant execute on function techstore_private.supplier_finance(text,jsonb) to authenticated;
create function public.ts_supplier_finance(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.supplier_finance(p_action,p_args); $$;
revoke all on function public.ts_supplier_finance(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_supplier_finance(text,jsonb) to authenticated;
commit;