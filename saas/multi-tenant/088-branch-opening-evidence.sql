-- Evidence-backed current opening checkpoint; not a backdated statutory balance.
begin;
create table tenant_private.branch_opening_checks(
 store_id uuid not null references tenant_private.workspaces(store_id),request_id uuid not null,actor uuid not null,
 reference text not null check(length(btrim(reference)) between 1 and 160),
 evidence jsonb not null check(jsonb_typeof(evidence)='object' and evidence->>'ready'='true'),
 created_at timestamptz not null default now(),primary key(store_id,request_id)
);
alter table tenant_private.branch_opening_checks enable row level security;
revoke all on tenant_private.branch_opening_checks from public,anon,authenticated,service_role;
create function tenant_private.branch_opening_review(p_store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare d date:=(now() at time zone 'Asia/Damascus')::date;
 balances jsonb;journal jsonb;treasury jsonb;reconciliation jsonb;rows jsonb;ready boolean;unknown numeric;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 balances:=tenant_private.branch_account_balances(p_store);
 journal:=tenant_private.branch_journal_projection(p_store,d,d);
 treasury:=tenant_private.branch_treasury_read(p_store,null,null);
 reconciliation:=tenant_private.financial_reconciliation(p_store);
 with b as (
  select x->>'branch_id' branch_id,x->>'name' name,x->>'currency' currency,x
  from jsonb_array_elements(balances->'rows') x
 ), expected as (
  select b.branch_id,b.name,b.currency,v.account,v.recorded
  from b cross join lateral (values
   ('cash', (b.x->>'cash')::numeric),('bank',(b.x->>'bank')::numeric),
   ('inventory',(b.x->>'known_stock_cost')::numeric),('accounts_receivable',(b.x->>'receivable')::numeric),
   ('accounts_payable',-(b.x->>'payable')::numeric),('payroll_payable',-(b.x->>'payroll')::numeric),
   ('employee_advances',(b.x->>'advances')::numeric)
  ) v(account,recorded)
 ), actual as (
  select x->>'branch_id' branch_id,x->>'name' name,x->>'currency' currency,x->>'account' account,(x->>'closing')::numeric closing
  from jsonb_array_elements(journal->'rows') x where x->>'account' in ('cash','bank','inventory','accounts_receivable','accounts_payable','payroll_payable','employee_advances')
 ), compared as (
  select coalesce(e.branch_id,a.branch_id) branch_id,coalesce(e.name,a.name) name,coalesce(e.currency,a.currency) currency,coalesce(e.account,a.account) account,
    e.recorded,coalesce(a.closing,0) journal,
    e.recorded-coalesce(a.closing,0) difference
  from expected e full join actual a on coalesce(e.branch_id,'')=coalesce(a.branch_id,'') and e.currency=a.currency and e.account=a.account
 )
 select coalesce(jsonb_agg(jsonb_build_object('branch_id',c.branch_id,'name',c.name,'currency',c.currency,'account',c.account,'recorded',c.recorded::text,'journal',c.journal::text,'difference',c.difference::text,'balanced',coalesce(c.difference=0,false)) order by c.name,c.currency,c.account),'[]') into rows from compared c;
 select coalesce(max((x->>'unknown_cost_units')::numeric),0) into unknown from jsonb_array_elements(balances->'rows') x;
 ready:=coalesce((treasury->>'enabled')::boolean,false) and coalesce((treasury->>'reconciled')::boolean,false)
  and coalesce((balances->>'stock_valuation_available')::boolean,false)
  and coalesce((reconciliation->>'balanced')::boolean,false)
  and unknown=0 and (journal->>'unknown_transfer_units')::numeric=0 and jsonb_array_length(rows)>0
  and not exists(select 1 from jsonb_array_elements(rows) x where x->>'balanced' is distinct from 'true');
 return jsonb_build_object('mode','branch_opening_evidence','as_of',now(),'day',d,'ready',ready,'rows',rows,
 'treasury_reconciled',coalesce((treasury->>'reconciled')::boolean,false),
 'fifo_enabled',coalesce((balances->>'stock_valuation_available')::boolean,false),
 'consolidated_reconciled',coalesce((reconciliation->>'balanced')::boolean,false),
 'unknown_cost_present',unknown<>0 or (journal->>'unknown_transfer_units')::numeric<>0,
 'statutory_certified',false,'historical_opening_verified',false);
end $$;
create function tenant_private.branch_opening_confirm(p_store uuid,p_request uuid,p_reference text,p_confirm boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare old tenant_private.branch_opening_checks%rowtype;r jsonb;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_confirm is distinct from true or p_reference is null or length(btrim(p_reference)) not between 1 and 160 then raise exception 'Confirm physical inventory and reconciled balances' using errcode='22023';end if;
 select * into old from tenant_private.branch_opening_checks where store_id=p_store and request_id=p_request;
 if found then
  if old.actor is distinct from auth.uid() or old.reference is distinct from btrim(p_reference) then raise exception 'Conflicting opening request' using errcode='22023';end if;
  return p_request;
 end if;
 r:=tenant_private.branch_opening_review(p_store);
 if r->>'ready' is distinct from 'true' then raise exception 'Opening reconciliation incomplete' using errcode='22023';end if;
 insert into tenant_private.branch_opening_checks(store_id,request_id,actor,reference,evidence) values(p_store,p_request,auth.uid(),btrim(p_reference),r);
 return p_request;
end $$;
create function tenant_private.branch_opening_latest(p_store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return (select jsonb_build_object('request_id',request_id,'reference',reference,'created_at',created_at,'evidence',evidence) from tenant_private.branch_opening_checks where store_id=p_store order by created_at desc,request_id desc limit 1);
end $$;
create function public.mt_branch_opening_review(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_opening_review(p_store)$$;
create function public.mt_branch_opening_confirm(p_store uuid,p_request uuid,p_reference text,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_opening_confirm(p_store,p_request,p_reference,p_confirm)$$;
create function public.mt_branch_opening_latest(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_opening_latest(p_store)$$;
revoke all on function tenant_private.branch_opening_review(uuid),tenant_private.branch_opening_confirm(uuid,uuid,text,boolean),tenant_private.branch_opening_latest(uuid),public.mt_branch_opening_review(uuid),public.mt_branch_opening_confirm(uuid,uuid,text,boolean),public.mt_branch_opening_latest(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_opening_review(uuid),tenant_private.branch_opening_confirm(uuid,uuid,text,boolean),tenant_private.branch_opening_latest(uuid),public.mt_branch_opening_review(uuid),public.mt_branch_opening_confirm(uuid,uuid,text,boolean),public.mt_branch_opening_latest(uuid) to authenticated;
commit;
