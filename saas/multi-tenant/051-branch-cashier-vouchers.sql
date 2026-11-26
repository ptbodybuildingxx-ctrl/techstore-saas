-- Branch cashier authorization and single-posted documented cash vouchers.
begin;
create table tenant_private.cashier_branch_scope(store_id uuid not null,user_id uuid not null,branch_id uuid not null,primary key(store_id,user_id),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
create table tenant_private.branch_sale_context(store_id uuid not null,request_id uuid not null,branch_id uuid not null,actor uuid not null,primary key(store_id,request_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id));
create table tenant_private.branch_vouchers(store_id uuid not null,request_id uuid not null,branch_id uuid, cash_id uuid not null,adjustment_id uuid,kind text not null check(kind in ('salary','commission','bonus','rent','utilities','other','receipt')),party text not null check(length(btrim(party)) between 1 and 160),reference text not null check(length(btrim(reference)) between 1 and 160),primary key(store_id,request_id),unique(store_id,cash_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),foreign key(store_id,cash_id) references public.mt_cash_movements(store_id,id),foreign key(store_id,adjustment_id) references public.mt_accounting_adjustments(store_id,id));
do $$declare t text;begin foreach t in array array['cashier_branch_scope','branch_sale_context','branch_vouchers'] loop execute format('alter table tenant_private.%I enable row level security',t);execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create function tenant_private.guard_cashier_branch() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(new.store_id)='cashier' and exists(select 1 from tenant_private.cashier_branch_scope where store_id=new.store_id and user_id=new.actor) and not exists(select 1 from tenant_private.cashier_branch_scope a join tenant_private.branch_sale_context c on c.store_id=a.store_id and c.branch_id=a.branch_id and c.actor=a.user_id where a.store_id=new.store_id and a.user_id=new.actor and c.request_id=new.request_id) then raise exception 'Assigned branch sale required' using errcode='42501';end if;return new;
end $$;
create trigger mt_guard_cashier_branch before insert on public.mt_sales for each row execute function tenant_private.guard_cashier_branch();
create or replace function tenant_private.branch_cash_sale(p_store uuid,p_branch uuid,p_request uuid,p_currency text,p_lines jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare x jsonb;r jsonb;s uuid;pid uuid;u bigint;
begin
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Sale denied' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if exists(select 1 from tenant_private.cashier_branch_scope where store_id=p_store and user_id=auth.uid() and branch_id<>p_branch) and tenant_private.member_role(p_store)='cashier' then raise exception 'Branch assignment required' using errcode='42501';end if;
 if not exists(select 1 from tenant_private.branches where store_id=p_store and id=p_branch) then raise exception 'Unknown branch' using errcode='22023';end if;
 select id into s from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then if not exists(select 1 from tenant_private.branch_sales where store_id=p_store and sale_id=s and branch_id=p_branch) then raise exception 'Conflicting branch request' using errcode='22023';end if;return tenant_private.record_currency_sale(p_store,p_request,p_currency,p_lines);end if;
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 then raise exception 'Invalid sale' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if coalesce(x->>'units','') !~ '^[0-9]{1,5}$' then raise exception 'Invalid units' using errcode='22023';end if;
  u:=(x->>'units')::bigint;pid:=(x->>'product_id')::uuid;
  if u not between 1 and 10000 then raise exception 'Invalid units' using errcode='22023';end if;
  update tenant_private.branch_stock set units=units-u where store_id=p_store and branch_id=p_branch and product_id=pid and units>=u;
  if not found then raise exception 'Insufficient branch stock' using errcode='22023';end if;
 end loop;
 insert into tenant_private.branch_sale_context(store_id,request_id,branch_id,actor) values(p_store,p_request,p_branch,auth.uid());
 r:=tenant_private.record_currency_sale(p_store,p_request,p_currency,p_lines);
 delete from tenant_private.branch_sale_context where store_id=p_store and request_id=p_request;
 insert into tenant_private.branch_sales(store_id,sale_id,branch_id) values(p_store,(r->>'id')::uuid,p_branch);return r;
end $$;

create function tenant_private.cashier_scope_set(p_store uuid,p_user uuid,p_branch uuid) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role='cashier') then raise exception 'Active cashier required' using errcode='22023';end if;
 if p_branch is null then delete from tenant_private.cashier_branch_scope where store_id=p_store and user_id=p_user;return true;end if;
 perform tenant_private.require_branch(p_store,p_branch);
 insert into tenant_private.cashier_branch_scope values(p_store,p_user,p_branch) on conflict(store_id,user_id) do update set branch_id=excluded.branch_id;return true;
end $$;
create function tenant_private.cashier_scope_read(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;role_now text:=tenant_private.member_role(p_store);
begin
 if not coalesce(role_now in ('owner','cashier'),false) then raise exception 'Scope denied' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('user_id',a.user_id,'branch_id',a.branch_id,'name',b.name)),'[]') into r from tenant_private.cashier_branch_scope a join tenant_private.branches b on b.store_id=a.store_id and b.id=a.branch_id join tenant_private.members m on m.store_id=a.store_id and m.user_id=a.user_id and m.active and m.role='cashier' where a.store_id=p_store and (role_now='owner' or a.user_id=auth.uid());return r;
end $$;
create function tenant_private.branch_voucher(p_store uuid,p_request uuid,p_branch uuid,p_kind text,p_currency text,p_amount bigint,p_party text,p_reference text) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.branch_vouchers%rowtype;cash uuid;adj uuid;note text;k text;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_kind is null or p_kind not in ('salary','commission','bonus','rent','utilities','other','receipt') or p_party is null or length(btrim(p_party)) not between 1 and 160 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 then raise exception 'Invalid voucher' using errcode='22023';end if;
 if p_branch is not null then perform tenant_private.require_branch(p_store,p_branch);end if;
 note:=left(btrim(p_party)||' — '||btrim(p_reference),300);
 select * into v from tenant_private.branch_vouchers where store_id=p_store and request_id=p_request;
 if found then
 if v.branch_id is distinct from p_branch or v.kind<>p_kind or v.party<>btrim(p_party) or v.reference<>btrim(p_reference) then raise exception 'Conflicting voucher' using errcode='22023';end if;
 cash:=tenant_private.cash_record(p_store,p_request,case when p_kind='receipt' then 'funding' else 'expense' end,p_currency,p_amount,note,null,null);return cash;
 end if;
 if exists(select 1 from public.mt_cash_movements where store_id=p_store and request_id=p_request) then raise exception 'Request used' using errcode='22023';end if;
 cash:=tenant_private.cash_record(p_store,p_request,case when p_kind='receipt' then 'funding' else 'expense' end,p_currency,p_amount,note,null,null);
 if p_kind<>'receipt' then
 k:=case when p_kind in ('salary','commission','bonus') then 'expense_payroll' when p_kind='rent' then 'expense_rent' when p_kind='utilities' then 'expense_utilities' else 'expense_other' end;
 adj:=tenant_private.accounting_adjust(p_store,gen_random_uuid(),k,p_request,p_currency,p_amount,btrim(p_reference),note);
 end if;
 insert into tenant_private.branch_vouchers values(p_store,p_request,p_branch,cash,adj,p_kind,btrim(p_party),btrim(p_reference));return cash;
end $$;
create function tenant_private.branch_voucher_list(p_store uuid,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page' using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc,id desc),'[]') into r from (select v.cash_id as id,v.kind,v.party,v.reference,coalesce(b.name,'المستودع الرئيسي') as branch,c.currency,c.amount_minor,c.created_at from tenant_private.branch_vouchers v join public.mt_cash_movements c on c.store_id=v.store_id and c.id=v.cash_id left join tenant_private.branches b on b.store_id=v.store_id and b.id=v.branch_id where v.store_id=p_store and (p_before is null or (c.created_at,c.id)<(p_before,p_before_id)) order by c.created_at desc,c.id desc limit 50)x;return r;
end $$;
create function public.mt_cashier_scope_set(p_store uuid,p_user uuid,p_branch uuid) returns boolean language sql security invoker set search_path='' as $$select tenant_private.cashier_scope_set(p_store,p_user,p_branch)$$;
create function public.mt_cashier_scope_read(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.cashier_scope_read(p_store)$$;
create function public.mt_branch_voucher(p_store uuid,p_request uuid,p_branch uuid,p_kind text,p_currency text,p_amount bigint,p_party text,p_reference text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_voucher(p_store,p_request,p_branch,p_kind,p_currency,p_amount,p_party,p_reference)$$;
create function public.mt_branch_voucher_list(p_store uuid,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_voucher_list(p_store,p_before,p_before_id)$$;
revoke all on function tenant_private.guard_cashier_branch(),tenant_private.cashier_scope_set(uuid,uuid,uuid),tenant_private.cashier_scope_read(uuid),tenant_private.branch_voucher(uuid,uuid,uuid,text,text,bigint,text,text),tenant_private.branch_voucher_list(uuid,timestamptz,uuid),public.mt_cashier_scope_set(uuid,uuid,uuid),public.mt_cashier_scope_read(uuid),public.mt_branch_voucher(uuid,uuid,uuid,text,text,bigint,text,text),public.mt_branch_voucher_list(uuid,timestamptz,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.cashier_scope_set(uuid,uuid,uuid),tenant_private.cashier_scope_read(uuid),tenant_private.branch_voucher(uuid,uuid,uuid,text,text,bigint,text,text),tenant_private.branch_voucher_list(uuid,timestamptz,uuid),public.mt_cashier_scope_set(uuid,uuid,uuid),public.mt_cashier_scope_read(uuid),public.mt_branch_voucher(uuid,uuid,uuid,text,text,bigint,text,text),public.mt_branch_voucher_list(uuid,timestamptz,uuid) to authenticated;
commit;
