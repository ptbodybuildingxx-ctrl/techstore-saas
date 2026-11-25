begin;
create table public.ts_staff_terms(
 user_id uuid primary key references public.ts_profiles(user_id), monthly_salary numeric(16,2) not null check(monthly_salary between 0 and 1000000), commission_percent numeric(5,2) not null check(commission_percent between 0 and 30), updated_at timestamptz not null default now()
);
create table public.ts_staff_shifts(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.ts_profiles(user_id), started_at timestamptz not null default now(), ended_at timestamptz, check(ended_at is null or ended_at>=started_at)
);
create unique index ts_staff_one_open_shift on public.ts_staff_shifts(user_id) where ended_at is null;
create table public.ts_staff_payroll(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.ts_profiles(user_id), period date not null check(extract(day from period)=1), salary numeric(16,2) not null, commission numeric(16,2) not null, total numeric(16,2) not null check(total>=0), actor uuid not null references public.ts_profiles(user_id), created_at timestamptz not null default now(), unique(user_id,period)
);
create table public.ts_staff_capabilities(user_id uuid not null references public.ts_profiles(user_id), capability text not null check(capability in ('invoice_sale','invoice_repair','receipt','repair_intake','supplier_read')), allowed boolean not null, primary key(user_id,capability));
alter table public.ts_staff_terms enable row level security;
alter table public.ts_staff_shifts enable row level security;
alter table public.ts_staff_payroll enable row level security;
alter table public.ts_staff_capabilities enable row level security;
revoke all on public.ts_staff_terms,public.ts_staff_shifts,public.ts_staff_payroll,public.ts_staff_capabilities from public,anon,authenticated;
create function techstore_private.staff_allowed(p_user uuid,p_cap text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select allowed from public.ts_staff_capabilities where user_id=p_user and capability=p_cap),true)
$$;
revoke all on function techstore_private.staff_allowed(uuid,text) from public,anon,authenticated;
create function techstore_private.staff_invoice_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.ts_profiles where user_id=new.actor and role='cashier') and not techstore_private.staff_allowed(new.actor,case when new.kind='sale' then 'invoice_sale' else 'invoice_repair' end) then raise exception 'Invoice permission denied' using errcode='42501';end if;
 return new;
end $$;
revoke all on function techstore_private.staff_invoice_guard() from public,anon,authenticated;
create trigger ts_staff_invoice_guard before insert on public.ts_invoices for each row execute function techstore_private.staff_invoice_guard();
create function techstore_private.staff_receipt_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.kind='receipt' and exists(select 1 from public.ts_profiles where user_id=new.actor and role='cashier') and not techstore_private.staff_allowed(new.actor,'receipt') then raise exception 'Receipt permission denied' using errcode='42501';end if;
 return new;
end $$;
revoke all on function techstore_private.staff_receipt_guard() from public,anon,authenticated;
create trigger ts_staff_receipt_guard before insert on public.ts_business_entries for each row execute function techstore_private.staff_receipt_guard();
create function techstore_private.staff_intake_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.ts_profiles where user_id=new.actor and role='cashier') and not techstore_private.staff_allowed(new.actor,'repair_intake') then raise exception 'Intake permission denied' using errcode='42501';end if;
 return new;
end $$;
revoke all on function techstore_private.staff_intake_guard() from public,anon,authenticated;
create trigger ts_staff_intake_guard before insert or update on public.ts_repair_intake for each row execute function techstore_private.staff_intake_guard();
create function techstore_private.staff_action(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; target uuid; s public.ts_staff_shifts%rowtype; terms public.ts_staff_terms%rowtype; period_value date; comm numeric; pay public.ts_staff_payroll%rowtype; cap text;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active and role in ('admin','cashier','stock','tech');if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>8000 then raise exception 'Invalid request';end if;
 if p_action='my' then return jsonb_build_object('shifts',coalesce((select jsonb_agg(to_jsonb(x)) from (select * from public.ts_staff_shifts where user_id=u.user_id order by started_at desc limit 100) x),'[]'),'payroll',coalesce((select jsonb_agg(to_jsonb(x)-'actor') from (select * from public.ts_staff_payroll where user_id=u.user_id order by period desc limit 24) x),'[]'),'terms',(select to_jsonb(x) from public.ts_staff_terms x where user_id=u.user_id));end if;
 if p_action in ('clock_in','clock_out') then
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended(u.user_id::text,593227700));
 select * into s from public.ts_staff_shifts where user_id=u.user_id and ended_at is null;
 if p_action='clock_in' then if not found then insert into public.ts_staff_shifts(user_id) values(u.user_id) returning * into s;end if;
 else if not found then raise exception 'No open shift';end if;update public.ts_staff_shifts set ended_at=now() where id=s.id returning * into s;end if;
 return to_jsonb(s);
 end if;
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='list' then return jsonb_build_object('staff',coalesce((select jsonb_agg(jsonb_build_object('id',p.user_id,'name',p.name,'role',p.role,'salary',coalesce(t.monthly_salary,0),'commission',coalesce(t.commission_percent,0))) from public.ts_profiles p left join public.ts_staff_terms t on t.user_id=p.user_id where p.active and p.role in ('cashier','stock','tech')),'[]'),'shifts',coalesce((select jsonb_agg(to_jsonb(x)) from (select s.*,p.name from public.ts_staff_shifts s join public.ts_profiles p on p.user_id=s.user_id order by s.started_at desc limit 200) x),'[]'),'payroll',coalesce((select jsonb_agg(to_jsonb(x)) from (select s.*,p.name from public.ts_staff_payroll s join public.ts_profiles p on p.user_id=s.user_id order by s.period desc limit 200) x),'[]'),'permissions',coalesce((select jsonb_agg(to_jsonb(x)) from public.ts_staff_capabilities x),'[]'));end if;
 target:=(p_args->>'user_id')::uuid;
 if not exists(select 1 from public.ts_profiles where user_id=target and active and role in ('cashier','stock','tech')) then raise exception 'Invalid employee';end if;
 if p_action='terms' then insert into public.ts_staff_terms(user_id,monthly_salary,commission_percent) values(target,(p_args->>'salary')::numeric,(p_args->>'commission')::numeric) on conflict(user_id) do update set monthly_salary=excluded.monthly_salary,commission_percent=excluded.commission_percent,updated_at=now();
 elsif p_action='permission' then cap:=p_args->>'capability';insert into public.ts_staff_capabilities(user_id,capability,allowed) values(target,cap,(p_args->>'allowed')::boolean) on conflict(user_id,capability) do update set allowed=excluded.allowed;
 elsif p_action='payroll' then
 period_value:=(p_args->>'period')::date;if period_value is null or extract(day from period_value)<>1 or period_value>=date_trunc('month',current_date)::date then raise exception 'Use completed month';end if;
 select * into terms from public.ts_staff_terms where user_id=target;if not found then raise exception 'Configure salary first';end if;
 select * into pay from public.ts_staff_payroll where user_id=target and period=period_value;if found then return to_jsonb(pay);end if;
 select round(coalesce(sum((i.document->>'total')::numeric),0)*terms.commission_percent/100,2) into comm from public.ts_invoices i where i.actor=target and i.kind='sale' and coalesce(i.document->>'payment_mode','cash')='cash' and (i.created_at at time zone 'UTC')::date>=period_value and (i.created_at at time zone 'UTC')::date<(period_value+interval '1 month')::date and not exists(select 1 from public.ts_invoice_refunds r where r.invoice_id=i.id);
 insert into public.ts_staff_payroll(user_id,period,salary,commission,total,actor) values(target,period_value,terms.monthly_salary,comm,terms.monthly_salary+comm,u.user_id) returning * into pay;
 else raise exception 'Unknown action';end if;
 insert into public.ts_audit(actor,action) values(u.user_id,'staff '||p_action||' '||target);return jsonb_build_object('ok',true);
end $$;
revoke all on function techstore_private.staff_action(text,jsonb) from public,anon,authenticated;
grant execute on function techstore_private.staff_action(text,jsonb) to authenticated;
create function public.ts_staff_action(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.staff_action(p_action,p_args); $$;
revoke all on function public.ts_staff_action(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_staff_action(text,jsonb) to authenticated;
commit;