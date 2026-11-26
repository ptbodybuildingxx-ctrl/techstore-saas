-- Attendance and monthly payroll snapshots, paid through the existing branch voucher engine.
begin;
create table tenant_private.staff_shifts(store_id uuid not null,user_id uuid not null,id uuid not null,branch_id uuid,started_at timestamptz not null default now(),ended_at timestamptz,end_request uuid,primary key(store_id,id),unique(store_id,end_request),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),check((ended_at is null)=(end_request is null)),check(ended_at is null or ended_at>=started_at));
create unique index mt_staff_open_shift on tenant_private.staff_shifts(store_id,user_id) where ended_at is null;
create table tenant_private.staff_terms(store_id uuid not null,user_id uuid not null,currency text not null,salary_minor bigint not null check(salary_minor between 0 and 100000000000),commission_bps int not null check(commission_bps between 0 and 3000),updated_at timestamptz not null default now(),primary key(store_id,user_id),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency));
create table tenant_private.staff_payroll(store_id uuid not null,user_id uuid not null,id uuid not null,period date not null,branch_id uuid,currency text not null,salary_minor bigint not null,commission_bps int not null,net_sales_minor numeric not null,commission_minor bigint not null,total_minor bigint not null,created_at timestamptz not null default now(),paid_at timestamptz,payment_request uuid,actor uuid not null,primary key(store_id,id),unique(store_id,user_id,period),unique(store_id,payment_request),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),foreign key(store_id,payment_request) references tenant_private.branch_vouchers(store_id,request_id),check(total_minor=salary_minor+commission_minor and total_minor>0),check((paid_at is null)=(payment_request is null)));
do $$declare t text;begin foreach t in array array['staff_shifts','staff_terms','staff_payroll'] loop execute format('alter table tenant_private.%I enable row level security',t);execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create function tenant_private.staff_clock(p_store uuid,p_request uuid,p_start boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.staff_shifts%rowtype;
begin
 if tenant_private.member_role(p_store) is null or p_request is null or p_start is null then raise exception 'Staff access required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if tenant_private.member_role(p_store) is null or not tenant_private.shared_licensed(p_store) then raise exception 'Staff access required' using errcode='42501';end if;
 select * into v from tenant_private.staff_shifts where store_id=p_store and (id=p_request or end_request=p_request);
 if found then if v.user_id<>auth.uid() or (p_start and v.id<>p_request) or (not p_start and v.end_request is distinct from p_request) then raise exception 'Conflicting request' using errcode='22023';end if;return v.id;end if;
 if p_start then insert into tenant_private.staff_shifts(store_id,user_id,id,branch_id) values(p_store,auth.uid(),p_request,tenant_private.current_branch_scope(p_store));return p_request;end if;
 update tenant_private.staff_shifts set ended_at=now(),end_request=p_request where store_id=p_store and user_id=auth.uid() and ended_at is null returning * into v;
 if not found then raise exception 'No open shift' using errcode='22023';end if;return v.id;
end
$$;
create function public.mt_staff_clock(p_store uuid,p_request uuid,p_start boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.staff_clock(p_store,p_request,p_start)$$;
create function tenant_private.staff_attendance(p_store uuid,p_user uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);u uuid:=coalesce(p_user,auth.uid());begin
 if role_now is null or (role_now<>'owner' and u<>auth.uid()) then raise exception 'Staff access denied' using errcode='42501';end if;
 return jsonb_build_object('open',exists(select 1 from tenant_private.staff_shifts where store_id=p_store and user_id=u and ended_at is null),'shifts',coalesce((select jsonb_agg(to_jsonb(x) order by started_at desc) from (select started_at,ended_at,branch_id from tenant_private.staff_shifts where store_id=p_store and user_id=u order by started_at desc limit 50)x),'[]'::jsonb),'terms',(select jsonb_build_object('currency',currency,'salary_minor',salary_minor,'commission_bps',commission_bps) from tenant_private.staff_terms where store_id=p_store and user_id=u),'payroll',coalesce((select jsonb_agg(to_jsonb(x) order by period desc) from (select id,period,currency,salary_minor,commission_minor,total_minor,net_sales_minor::text,paid_at from tenant_private.staff_payroll where store_id=p_store and user_id=u order by period desc limit 36)x),'[]'::jsonb));
end
$$;
create function public.mt_staff_attendance(p_store uuid,p_user uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.staff_attendance(p_store,p_user)$$;
create function tenant_private.staff_terms_set(p_store uuid,p_user uuid,p_currency text,p_salary bigint,p_bps int) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role<>'owner') or p_salary is null or p_salary not between 0 and 100000000000 or p_bps is null or p_bps not between 0 and 3000 then raise exception 'Invalid employee terms' using errcode='22023';end if;
 insert into tenant_private.staff_terms(store_id,user_id,currency,salary_minor,commission_bps) values(p_store,p_user,p_currency,p_salary,p_bps) on conflict(store_id,user_id) do update set currency=excluded.currency,salary_minor=excluded.salary_minor,commission_bps=excluded.commission_bps,updated_at=now();return true;
end
$$;
create function public.mt_staff_terms_set(p_store uuid,p_user uuid,p_currency text,p_salary bigint,p_bps int) returns boolean language sql security invoker set search_path='' as $$select tenant_private.staff_terms_set(p_store,p_user,p_currency,p_salary,p_bps)$$;
create function tenant_private.staff_payroll_create(p_store uuid,p_id uuid,p_user uuid,p_period date,p_branch uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare terms tenant_private.staff_terms%rowtype;v tenant_private.staff_payroll%rowtype;lo timestamptz;hi timestamptz;n numeric;commission bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_user is null or p_period is null or extract(day from p_period)<>1 or p_period>=date_trunc('month',now() at time zone 'Asia/Damascus')::date then raise exception 'Completed month required' using errcode='22023';end if;
 if p_branch is not null then perform tenant_private.require_branch(p_store,p_branch);end if;
 select * into v from tenant_private.staff_payroll where store_id=p_store and id=p_id;
 if found then if v.actor<>auth.uid() or v.user_id<>p_user or v.period<>p_period or v.branch_id is distinct from p_branch then raise exception 'Conflicting payroll' using errcode='22023';end if;return p_id;end if;
 select * into terms from tenant_private.staff_terms where store_id=p_store and user_id=p_user;
 if not found then raise exception 'Set staff terms first' using errcode='22023';end if;
 lo:=p_period::timestamp at time zone 'Asia/Damascus';hi:=(p_period+interval '1 month') at time zone 'Asia/Damascus';
 select coalesce(sum(greatest(0,s.total_minor-coalesce((select sum(r.total_minor) from public.mt_returns r where r.store_id=s.store_id and r.sale_id=s.id),0))),0) into n from public.mt_sales s where s.store_id=p_store and s.actor=p_user and s.payment_mode='cash' and s.currency=terms.currency and s.created_at>=lo and s.created_at<hi;
 commission:=floor(n*terms.commission_bps/10000)::bigint;
 if terms.salary_minor+commission<=0 or terms.salary_minor+commission>100000000000000 then raise exception 'Invalid payroll total' using errcode='22023';end if;
 insert into tenant_private.staff_payroll(store_id,user_id,id,period,branch_id,currency,salary_minor,commission_bps,net_sales_minor,commission_minor,total_minor,actor) values(p_store,p_user,p_id,p_period,p_branch,terms.currency,terms.salary_minor,terms.commission_bps,n,commission,terms.salary_minor+commission,auth.uid());return p_id;
end
$$;
create function public.mt_staff_payroll_create(p_store uuid,p_id uuid,p_user uuid,p_period date,p_branch uuid) returns uuid language sql security invoker set search_path='' as $$select tenant_private.staff_payroll_create(p_store,p_id,p_user,p_period,p_branch)$$;
create function tenant_private.staff_payroll_pay(p_store uuid,p_id uuid,p_request uuid,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.staff_payroll%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_confirm is distinct from true then raise exception 'Confirm actual disbursement' using errcode='22023';end if;
 select * into v from tenant_private.staff_payroll where store_id=p_store and id=p_id for update;
 if not found then raise exception 'Unknown statement' using errcode='22023';end if;
 if v.paid_at is not null then if v.payment_request<>p_request then raise exception 'Already paid' using errcode='22023';end if;return p_id;end if;
 if exists(select 1 from tenant_private.branch_vouchers where store_id=p_store and request_id=p_request) then raise exception 'Request used' using errcode='22023';end if;
 perform tenant_private.branch_voucher(p_store,p_request,v.branch_id,'salary',v.currency,v.total_minor,v.user_id::text,'Payroll '||v.period::text||' / '||v.id::text);
 update tenant_private.staff_payroll set paid_at=now(),payment_request=p_request where store_id=p_store and id=p_id;return p_id;
end
$$;
create function public.mt_staff_payroll_pay(p_store uuid,p_id uuid,p_request uuid,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.staff_payroll_pay(p_store,p_id,p_request,p_confirm)$$;
revoke all on function tenant_private.staff_clock(uuid,uuid,boolean),public.mt_staff_clock(uuid,uuid,boolean),tenant_private.staff_attendance(uuid,uuid),public.mt_staff_attendance(uuid,uuid),tenant_private.staff_terms_set(uuid,uuid,text,bigint,int),public.mt_staff_terms_set(uuid,uuid,text,bigint,int),tenant_private.staff_payroll_create(uuid,uuid,uuid,date,uuid),public.mt_staff_payroll_create(uuid,uuid,uuid,date,uuid),tenant_private.staff_payroll_pay(uuid,uuid,uuid,boolean),public.mt_staff_payroll_pay(uuid,uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.staff_clock(uuid,uuid,boolean),public.mt_staff_clock(uuid,uuid,boolean),tenant_private.staff_attendance(uuid,uuid),public.mt_staff_attendance(uuid,uuid),tenant_private.staff_terms_set(uuid,uuid,text,bigint,int),public.mt_staff_terms_set(uuid,uuid,text,bigint,int),tenant_private.staff_payroll_create(uuid,uuid,uuid,date,uuid),public.mt_staff_payroll_create(uuid,uuid,uuid,date,uuid),tenant_private.staff_payroll_pay(uuid,uuid,uuid,boolean),public.mt_staff_payroll_pay(uuid,uuid,uuid,boolean) to authenticated;
commit;
