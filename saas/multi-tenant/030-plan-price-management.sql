begin;
do $$ begin if to_regclass('tenant_private.billing_configuration') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS only';end if;end $$;
create table tenant_private.plan_price_history(
 id uuid primary key default gen_random_uuid(),request_id uuid not null unique,plan_code text not null references public.saas_plans(code),
 previous_cents integer not null check(previous_cents>0),new_cents integer not null check(new_cents between 100 and 10000000),
 actor uuid not null,note text not null check(length(btrim(note)) between 1 and 300),created_at timestamptz not null default now()
);
alter table tenant_private.plan_price_history enable row level security;
revoke all on tenant_private.plan_price_history from public,anon,authenticated,service_role;
create function tenant_private.admin_plan_prices() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return jsonb_build_object('plans',(select jsonb_agg(to_jsonb(p) order by p.code) from public.saas_plans p),'editable',not exists(select 1 from tenant_private.billing_configuration where live_enabled) and not exists(select 1 from tenant_private.payment_bindings),'history',coalesce((select jsonb_agg(to_jsonb(h) order by h.created_at desc,h.id) from (select id,plan_code,previous_cents,new_cents,note,created_at from tenant_private.plan_price_history order by created_at desc,id limit 50) h),'[]'::jsonb));
end $$;
create function tenant_private.admin_plan_price_change(p_request uuid,p_plan text,p_expected integer,p_price integer,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare v integer;r tenant_private.plan_price_history%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_request is null or p_plan is null or p_plan not in ('basic','business','pro') or p_expected is null or p_price is null or p_price not between 100 and 10000000 or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid price change' using errcode='22023';end if;
 perform 1 from tenant_private.billing_configuration where singleton for update;
 lock table tenant_private.payment_bindings in share mode;
 select * into r from tenant_private.plan_price_history where request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.plan_code<>p_plan or r.previous_cents<>p_expected or r.new_cents<>p_price or r.note<>btrim(p_note) then raise exception 'Conflicting request' using errcode='22023';end if;return r.id;
 end if;
 if exists(select 1 from tenant_private.billing_configuration where live_enabled) or exists(select 1 from tenant_private.payment_bindings) then raise exception 'Provider price version migration required' using errcode='22023';end if;
 select monthly_usd_cents into strict v from public.saas_plans where code=p_plan for update;
 if v<>p_expected or v=p_price then raise exception 'Price changed or unchanged' using errcode='22023';end if;
 update public.saas_plans set monthly_usd_cents=p_price where code=p_plan;
 insert into tenant_private.plan_price_history(request_id,plan_code,previous_cents,new_cents,actor,note) values(p_request,p_plan,v,p_price,auth.uid(),btrim(p_note)) returning * into r;
 return r.id;
end $$;
create function public.mt_admin_plan_prices() returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.admin_plan_prices()$$;
create function public.mt_admin_plan_price_change(p_request uuid,p_plan text,p_expected integer,p_price integer,p_note text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.admin_plan_price_change(p_request,p_plan,p_expected,p_price,p_note)$$;
revoke all on function tenant_private.admin_plan_prices(),tenant_private.admin_plan_price_change(uuid,text,integer,integer,text),public.mt_admin_plan_prices(),public.mt_admin_plan_price_change(uuid,text,integer,integer,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.admin_plan_prices(),tenant_private.admin_plan_price_change(uuid,text,integer,integer,text),public.mt_admin_plan_prices(),public.mt_admin_plan_price_change(uuid,text,integer,integer,text) to authenticated;
commit;