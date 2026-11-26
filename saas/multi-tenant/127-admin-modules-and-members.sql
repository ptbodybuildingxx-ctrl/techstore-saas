-- 127: per-plan new-operation gates and per-shop administrative account holds.
-- Existing records, returns, debt payments, warranty service and corrections are not deleted.
begin;
create table tenant_private.admin_module_policy(
 plan_code text primary key references public.saas_plans(code) on delete cascade,
 revision bigint not null check(revision>=1),flags jsonb not null,updated_at timestamptz not null default now()
);
create table tenant_private.admin_module_events(
 request_id uuid primary key,plan_code text not null,actor uuid not null,reference text not null check(length(btrim(reference)) between 1 and 200),
 previous_revision bigint not null,before_flags jsonb not null,after_flags jsonb not null,created_at timestamptz not null default now()
);
alter table tenant_private.admin_module_policy enable row level security;
alter table tenant_private.admin_module_events enable row level security;
revoke all on tenant_private.admin_module_policy,tenant_private.admin_module_events from public,anon,authenticated;
create function tenant_private.default_module_flags() returns jsonb language sql immutable set search_path='' as $$select '{"catalog":true,"sales":true,"purchases":true,"suppliers":true,"customers":true,"credit":true,"standalone_debts":true,"repairs":true,"quotes":true,"stock_counts":true,"stock_transfers":true,"branches":true,"payroll":true,"tradein":true,"coupons":true}'::jsonb$$;
create function tenant_private.plan_module_enabled(s uuid,k text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select (coalesce(p.flags,tenant_private.default_module_flags())->>k)::boolean from public.saas_subscriptions sub left join tenant_private.admin_module_policy p on p.plan_code=sub.plan_code where sub.store_id=s),false)
$$;
revoke all on function tenant_private.default_module_flags(),tenant_private.plan_module_enabled(uuid,text) from public,anon,authenticated;
create function tenant_private.guard_module_intake() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from tenant_private.workspaces where store_id=new.store_id) and not tenant_private.plan_module_enabled(new.store_id,tg_argv[0]) then raise exception 'New operation disabled by subscription plan: %',tg_argv[0] using errcode='22023';end if;
 return new;
end $$;
revoke all on function tenant_private.guard_module_intake() from public,anon,authenticated;
create trigger mt_plan_gate_catalog before insert on public.mt_products for each row execute function tenant_private.guard_module_intake('catalog');
create trigger mt_plan_gate_sales before insert on public.mt_sales for each row execute function tenant_private.guard_module_intake('sales');
create trigger mt_plan_gate_purchases before insert on public.mt_purchases for each row execute function tenant_private.guard_module_intake('purchases');
create trigger mt_plan_gate_suppliers before insert on public.mt_suppliers for each row execute function tenant_private.guard_module_intake('suppliers');
create trigger mt_plan_gate_customers before insert on public.mt_customers for each row execute function tenant_private.guard_module_intake('customers');
create trigger mt_plan_gate_credit before insert on public.mt_debts for each row execute function tenant_private.guard_module_intake('credit');
create trigger mt_plan_gate_standalone_debts before insert on tenant_private.standalone_debts for each row execute function tenant_private.guard_module_intake('standalone_debts');
create trigger mt_plan_gate_repairs before insert on public.mt_repairs for each row execute function tenant_private.guard_module_intake('repairs');
create trigger mt_plan_gate_quotes before insert on tenant_private.price_quotes for each row execute function tenant_private.guard_module_intake('quotes');
create trigger mt_plan_gate_stock_counts before insert on tenant_private.stock_counts for each row execute function tenant_private.guard_module_intake('stock_counts');
create trigger mt_plan_gate_stock_transfers before insert on tenant_private.branch_transfers for each row execute function tenant_private.guard_module_intake('stock_transfers');
create trigger mt_plan_gate_branches before insert on tenant_private.branches for each row execute function tenant_private.guard_module_intake('branches');
create trigger mt_plan_gate_payroll before insert on tenant_private.staff_payroll for each row execute function tenant_private.guard_module_intake('payroll');
create trigger mt_plan_gate_tradein before insert on tenant_private.tradein_estimates for each row execute function tenant_private.guard_module_intake('tradein');
create trigger mt_plan_gate_coupons before insert on public.mt_coupons for each row execute function tenant_private.guard_module_intake('coupons');
create function tenant_private.admin_modules_review() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return jsonb_build_object('plans',coalesce((select jsonb_agg(to_jsonb(x) order by code) from (select p.code,p.name,coalesce(m.revision,1) revision,coalesce(m.flags,tenant_private.default_module_flags()) flags from public.saas_plans p left join tenant_private.admin_module_policy m on m.plan_code=p.code)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id) from (select request_id,plan_code,actor,reference,previous_revision,before_flags,after_flags,created_at from tenant_private.admin_module_events order by created_at desc,request_id limit 50)x),'[]'::jsonb));
end $$;
create function tenant_private.admin_modules_change(req uuid,plan text,expected bigint,flags_value jsonb,proof text) returns uuid language plpgsql security definer set search_path='' as $$
declare previous_flags jsonb;rev bigint;e tenant_private.admin_module_events%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if req is null or plan is null or expected is null or expected<1 or jsonb_typeof(flags_value) is distinct from 'object' or octet_length(flags_value::text)>2000 or (select count(*) from jsonb_object_keys(flags_value))<>15 or not(flags_value ?& array['catalog','sales','purchases','suppliers','customers','credit','standalone_debts','repairs','quotes','stock_counts','stock_transfers','branches','payroll','tradein','coupons']) or exists(select 1 from jsonb_each(flags_value) where jsonb_typeof(value)<>'boolean') or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid module flags';end if;
 perform 1 from public.saas_plans where code=plan for update;if not found then raise exception 'Unknown plan';end if;
 select * into e from tenant_private.admin_module_events where request_id=req;
 if found then
  if e.plan_code<>plan or e.actor<>auth.uid() or e.reference<>btrim(proof) or e.previous_revision<>expected or e.after_flags<>flags_value then raise exception 'Conflicting module policy request';end if;return req;
 end if;
 select revision,flags into rev,previous_flags from tenant_private.admin_module_policy where plan_code=plan;
 rev:=coalesce(rev,1);previous_flags:=coalesce(previous_flags,tenant_private.default_module_flags());
 if rev<>expected or previous_flags=flags_value then raise exception 'Module policy changed or unchanged';end if;
 insert into tenant_private.admin_module_policy(plan_code,revision,flags) values(plan,rev+1,flags_value) on conflict(plan_code) do update set revision=excluded.revision,flags=excluded.flags,updated_at=now();
 insert into tenant_private.admin_module_events(request_id,plan_code,actor,reference,previous_revision,before_flags,after_flags) values(req,plan,auth.uid(),btrim(proof),rev,previous_flags,flags_value);
 return req;
end $$;
create function tenant_private.member_module_status(s uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is null then raise exception 'Membership required' using errcode='42501';end if;
 return coalesce((select coalesce(m.flags,tenant_private.default_module_flags()) from public.saas_subscriptions sub left join tenant_private.admin_module_policy m on m.plan_code=sub.plan_code where sub.store_id=s),'{}'::jsonb);
end $$;

create table tenant_private.admin_member_holds(
 store_id uuid not null references tenant_private.workspaces(store_id),user_id uuid not null,
 blocked boolean not null,revision bigint not null check(revision>=1),updated_at timestamptz not null default now(),
 primary key(store_id,user_id)
);
create table tenant_private.admin_member_events(
 request_id uuid primary key,store_id uuid not null references tenant_private.workspaces(store_id),user_id uuid not null,
 actor uuid not null,reference text not null check(length(btrim(reference)) between 1 and 200),
 previous_revision bigint not null,previous_blocked boolean not null,blocked boolean not null,created_at timestamptz not null default now()
);
create index admin_member_events_store on tenant_private.admin_member_events(store_id,created_at desc,request_id);
alter table tenant_private.admin_member_holds enable row level security;
alter table tenant_private.admin_member_events enable row level security;
revoke all on tenant_private.admin_member_holds,tenant_private.admin_member_events from public,anon,authenticated;
CREATE OR REPLACE FUNCTION saas_private.can_read_store(p_store uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select saas_private.is_operator() or (saas_private.live_session() and exists(
    select 1 from public.saas_memberships m where m.store_id=p_store and m.user_id=auth.uid() and m.active and not exists(select 1 from tenant_private.admin_member_holds h where h.store_id=m.store_id and h.user_id=m.user_id and h.blocked)
  ))
$function$
;

CREATE OR REPLACE FUNCTION tenant_private.member_role(p_store uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select m.role from tenant_private.members m join auth.users u on u.id=m.user_id where m.store_id=p_store and m.user_id=auth.uid() and m.active and not exists(select 1 from tenant_private.admin_member_holds h where h.store_id=m.store_id and h.user_id=m.user_id and h.blocked) and not u.is_anonymous and saas_private.live_session()
 and (not exists(select 1 from auth.mfa_factors f where f.user_id=m.user_id and f.factor_type::text='totp' and f.status::text='verified') or auth.jwt()->>'aal'='aal2')
$function$
;
create function tenant_private.admin_members_review(s uuid,off integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare members jsonb;h jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if s is null or off is null or off not between 0 and 100000 or not exists(select 1 from tenant_private.workspaces where store_id=s) then raise exception 'Invalid shared store';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by role,user_id),'[]'::jsonb) into members from (
 select m.user_id,m.role,m.active,coalesce(p.display_name,'') display_name,coalesce(a.blocked,false) blocked,coalesce(a.revision,0) revision
 from tenant_private.members m left join tenant_private.staff_profiles p on p.store_id=m.store_id and p.user_id=m.user_id left join tenant_private.admin_member_holds a on a.store_id=m.store_id and a.user_id=m.user_id where m.store_id=s order by m.role,m.user_id offset off limit 51
 )x;
 select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc,request_id),'[]'::jsonb) into h from (select request_id,user_id,actor,reference,previous_blocked,blocked,created_at from tenant_private.admin_member_events where store_id=s order by created_at desc,request_id limit 50)x;
 return jsonb_build_object('members',case when jsonb_array_length(members)>50 then members-50 else members end,'more',jsonb_array_length(members)>50,'history',h);
end $$;
create function tenant_private.admin_member_change(s uuid,req uuid,u uuid,expected bigint,expected_role text,expected_active boolean,blocked_value boolean,proof text) returns uuid language plpgsql security definer set search_path='' as $$
declare e tenant_private.admin_member_events%rowtype;m tenant_private.members%rowtype;h tenant_private.admin_member_holds%rowtype;rev bigint;old_block boolean;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if s is null or req is null or u is null or expected is null or expected<0 or expected_role not in ('owner','cashier','stock','tech') or expected_active is null or blocked_value is null or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid account hold';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into e from tenant_private.admin_member_events where request_id=req;
 if found then
  if e.store_id<>s or e.user_id<>u or e.actor<>auth.uid() or e.previous_revision<>expected or e.blocked<>blocked_value or e.reference<>btrim(proof) then raise exception 'Conflicting account hold request';end if;return req;
 end if;
 select * into m from tenant_private.members where store_id=s and user_id=u for update;
 if not found or m.role is distinct from expected_role or m.active is distinct from expected_active or exists(select 1 from saas_private.operators where user_id=u) then raise exception 'Membership changed or unavailable';end if;
 select * into h from tenant_private.admin_member_holds where store_id=s and user_id=u;
 rev:=coalesce(h.revision,0);old_block:=coalesce(h.blocked,false);
 if rev<>expected or old_block=blocked_value then raise exception 'Account hold changed or unchanged';end if;
 insert into tenant_private.admin_member_holds(store_id,user_id,blocked,revision) values(s,u,blocked_value,rev+1) on conflict(store_id,user_id) do update set blocked=excluded.blocked,revision=excluded.revision,updated_at=now();
 insert into tenant_private.admin_member_events(request_id,store_id,user_id,actor,reference,previous_revision,previous_blocked,blocked) values(req,s,u,auth.uid(),btrim(proof),rev,old_block,blocked_value);
 return req;
end $$;
create function public.mt_admin_modules_review() returns jsonb language sql stable set search_path='' as $$select tenant_private.admin_modules_review()$$;
create function public.mt_admin_modules_change(req uuid,plan text,expected bigint,flags_value jsonb,proof text) returns uuid language sql set search_path='' as $$select tenant_private.admin_modules_change(req,plan,expected,flags_value,proof)$$;
create function public.mt_member_module_status(s uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.member_module_status(s)$$;
create function public.mt_admin_members_review(s uuid,off integer) returns jsonb language sql stable set search_path='' as $$select tenant_private.admin_members_review(s,off)$$;
create function public.mt_admin_member_change(s uuid,req uuid,u uuid,expected bigint,expected_role text,expected_active boolean,blocked_value boolean,proof text) returns uuid language sql set search_path='' as $$select tenant_private.admin_member_change(s,req,u,expected,expected_role,expected_active,blocked_value,proof)$$;
revoke all on function tenant_private.admin_modules_review(),public.mt_admin_modules_review() from public,anon,authenticated;
grant execute on function tenant_private.admin_modules_review(),public.mt_admin_modules_review() to authenticated;
revoke all on function tenant_private.admin_modules_change(uuid,text,bigint,jsonb,text),public.mt_admin_modules_change(uuid,text,bigint,jsonb,text) from public,anon,authenticated;
grant execute on function tenant_private.admin_modules_change(uuid,text,bigint,jsonb,text),public.mt_admin_modules_change(uuid,text,bigint,jsonb,text) to authenticated;
revoke all on function tenant_private.member_module_status(uuid),public.mt_member_module_status(uuid) from public,anon,authenticated;
grant execute on function tenant_private.member_module_status(uuid),public.mt_member_module_status(uuid) to authenticated;
revoke all on function tenant_private.admin_members_review(uuid,integer),public.mt_admin_members_review(uuid,integer) from public,anon,authenticated;
grant execute on function tenant_private.admin_members_review(uuid,integer),public.mt_admin_members_review(uuid,integer) to authenticated;
revoke all on function tenant_private.admin_member_change(uuid,uuid,uuid,bigint,text,boolean,boolean,text),public.mt_admin_member_change(uuid,uuid,uuid,bigint,text,boolean,boolean,text) from public,anon,authenticated;
grant execute on function tenant_private.admin_member_change(uuid,uuid,uuid,bigint,text,boolean,boolean,text),public.mt_admin_member_change(uuid,uuid,uuid,bigint,text,boolean,boolean,text) to authenticated;
commit;
