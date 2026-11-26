-- Enforce customer consent and technician assignments at the transaction boundary.
begin;
alter table tenant_private.repair_estimates add column superseded_at timestamptz;
with versions as (select store_id,id,row_number() over(partition by store_id,repair_id order by created_at desc,id desc) as n from tenant_private.repair_estimates) update tenant_private.repair_estimates e set superseded_at=now(),state=case when state='offered' then 'superseded' else state end from versions v where e.store_id=v.store_id and e.id=v.id and v.n>1;
create unique index mt_repair_latest_estimate on tenant_private.repair_estimates(store_id,repair_id) where superseded_at is null;
create table tenant_private.repair_assignments(store_id uuid not null,repair_id uuid not null,technician uuid not null,actor uuid not null,assigned_at timestamptz not null default now(),primary key(store_id,repair_id),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id),foreign key(store_id,technician) references tenant_private.members(store_id,user_id));
create table tenant_private.repair_tasks(store_id uuid not null,repair_id uuid not null,id uuid not null,description text not null check(length(btrim(description)) between 1 and 300),state text not null default 'pending' check(state in ('pending','done','cancelled')),actor uuid not null,created_at timestamptz not null default now(),finished_at timestamptz,primary key(store_id,id),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id),check((state='pending')=(finished_at is null)));
alter table tenant_private.repair_assignments enable row level security;alter table tenant_private.repair_tasks enable row level security;revoke all on tenant_private.repair_assignments,tenant_private.repair_tasks from public,anon,authenticated,service_role;
create or replace function tenant_private.repair_scope_allowed(p_store uuid,p_repair uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) in ('owner','tech'),false) and (tenant_private.member_role(p_store)='owner' or not exists(select 1 from tenant_private.repair_assignments where store_id=p_store and repair_id=p_repair) or exists(select 1 from tenant_private.repair_assignments where store_id=p_store and repair_id=p_repair and technician=auth.uid())) and (tenant_private.current_branch_scope(p_store) is null or exists(select 1 from tenant_private.branch_repairs where store_id=p_store and repair_id=p_repair and branch_id=tenant_private.current_branch_scope(p_store)))
$$;
create or replace function tenant_private.repair_offer(p_store uuid,p_repair uuid,p_id uuid,p_currency text,p_amount bigint,p_description text) returns uuid language plpgsql security definer set search_path='' as $$
declare e tenant_private.repair_estimates%rowtype;begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_repair(p_store,p_repair,true);
 if p_id is null or p_amount is null or p_amount not between 0 and 100000000000000 or p_description is null or length(btrim(p_description)) not between 1 and 300 then raise exception 'Invalid estimate' using errcode='22023';end if;
 select * into e from tenant_private.repair_estimates where store_id=p_store and id=p_id;
 if found then if e.actor<>auth.uid() or e.repair_id<>p_repair or e.currency<>p_currency or e.amount_minor<>p_amount or e.description<>btrim(p_description) then raise exception 'Conflicting estimate' using errcode='22023';end if;return p_id;end if;
 if not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state in ('received','diagnosing','repairing')) then raise exception 'Repair closed' using errcode='22023';end if;
 if not exists(select 1 from tenant_private.repair_tracking where store_id=p_store and repair_id=p_repair) then raise exception 'Tracking unavailable for historical ticket' using errcode='22023';end if;
 update tenant_private.repair_estimates set superseded_at=now(),state=case when state='offered' then 'superseded' else state end where store_id=p_store and repair_id=p_repair and superseded_at is null;
 insert into tenant_private.repair_estimates(store_id,repair_id,id,currency,amount_minor,description,actor) values(p_store,p_repair,p_id,p_currency,p_amount,btrim(p_description),auth.uid());return p_id;
end
$$;
create or replace function tenant_private.repair_decide(p_slug text,p_code uuid,p_estimate uuid,p_accept boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid;r uuid;st text;
begin
 if p_accept is null then raise exception 'Invalid decision' using errcode='22023';end if;
 select tr.store_id,tr.repair_id into t,r from tenant_private.repair_tracking tr join public.saas_stores s on s.id=tr.store_id where s.slug=p_slug and tr.code=p_code and tenant_private.storefront_active(s.id);
 if not found then return false;end if;
 perform 1 from public.saas_stores where id=t for update;
 if not exists(select 1 from public.mt_repairs where store_id=t and id=r and state in ('received','diagnosing','repairing')) then return false;end if;
 select state into st from tenant_private.repair_estimates where store_id=t and repair_id=r and id=p_estimate and superseded_at is null;
 if not found then return false;end if;
 if st=(case when p_accept then 'approved' else 'rejected' end) then return true;end if;
 update tenant_private.repair_estimates set state=case when p_accept then 'approved' else 'rejected' end,decided_at=now() where store_id=t and repair_id=r and id=p_estimate and state='offered';return found;
end
$$;
create or replace function tenant_private.repair_status(p_slug text,p_code uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid;r uuid;v jsonb;
begin
 select tr.store_id,tr.repair_id into t,r from tenant_private.repair_tracking tr join public.saas_stores s on s.id=tr.store_id where s.slug=p_slug and tr.code=p_code and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 select jsonb_build_object('device',p.device,'state',p.state,'created_at',p.created_at,'estimate',(select jsonb_build_object('id',id,'currency',currency,'amount_minor',amount_minor,'description',description,'state',state) from tenant_private.repair_estimates where store_id=t and repair_id=r and superseded_at is null order by created_at desc,id desc limit 1)) into v from public.mt_repairs p where p.store_id=t and p.id=r;return v;
end
$$;
create function tenant_private.repair_approved(p_store uuid,p_repair uuid) returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from tenant_private.repair_tracking where store_id=p_store and repair_id=p_repair) or exists(select 1 from tenant_private.repair_estimates where store_id=p_store and repair_id=p_repair and superseded_at is null and state='approved')
$$;
create function tenant_private.guard_repair_approval() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='mt_repairs' then
 if new.state is distinct from old.state and new.state in ('repairing','ready','delivered') and not tenant_private.repair_approved(new.store_id,new.id) then raise exception 'Customer estimate approval required' using errcode='22023';end if;
 if new.state in ('ready','delivered') and new.state is distinct from old.state and exists(select 1 from tenant_private.repair_tasks where store_id=new.store_id and repair_id=new.id and state='pending') then raise exception 'Finish assigned tasks first' using errcode='22023';end if;
 else
 if not tenant_private.repair_approved(new.store_id,new.repair_id) then raise exception 'Approved estimate required' using errcode='22023';end if;
 if exists(select 1 from tenant_private.repair_tracking where store_id=new.store_id and repair_id=new.repair_id) and not exists(select 1 from tenant_private.repair_estimates where store_id=new.store_id and repair_id=new.repair_id and superseded_at is null and state='approved' and currency=new.currency and amount_minor=new.service_minor+new.parts_minor) then raise exception 'Invoice differs from approved total' using errcode='22023';end if;
 end if;return new;
end $$;
create trigger mt_repair_approval before update of state on public.mt_repairs for each row execute function tenant_private.guard_repair_approval();
create trigger mt_repair_invoice_approval before insert on public.mt_repair_invoices for each row execute function tenant_private.guard_repair_approval();
create function tenant_private.repair_assign(p_store uuid,p_repair uuid,p_tech uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare b uuid;begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_repair(p_store,p_repair,true);
 if not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state not in ('delivered','cancelled')) then raise exception 'Closed ticket' using errcode='22023';end if;
 if p_tech is null then delete from tenant_private.repair_assignments where store_id=p_store and repair_id=p_repair;return true;end if;
 if not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_tech and active and role='tech') then raise exception 'Active technician required' using errcode='22023';end if;
 select branch_id into b from tenant_private.branch_repairs where store_id=p_store and repair_id=p_repair;
 if exists(select 1 from tenant_private.staff_branch_scope where store_id=p_store and user_id=p_tech and branch_id is distinct from b) then raise exception 'Technician branch mismatch' using errcode='22023';end if;
 insert into tenant_private.repair_assignments(store_id,repair_id,technician,actor) values(p_store,p_repair,p_tech,auth.uid()) on conflict(store_id,repair_id) do update set technician=excluded.technician,actor=excluded.actor,assigned_at=now();return true;
end $$;
create function tenant_private.repair_task_add(p_store uuid,p_repair uuid,p_id uuid,p_description text) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.repair_tasks%rowtype;begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_repair(p_store,p_repair,true);
 if p_id is null or p_description is null or length(btrim(p_description)) not between 1 and 300 then raise exception 'Invalid task' using errcode='22023';end if;
 select * into v from tenant_private.repair_tasks where store_id=p_store and id=p_id;
 if found then if v.repair_id<>p_repair or v.actor<>auth.uid() or v.description<>btrim(p_description) then raise exception 'Conflicting task' using errcode='22023';end if;return p_id;end if;
 if not exists(select 1 from tenant_private.repair_assignments where store_id=p_store and repair_id=p_repair) or not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state in ('received','diagnosing','repairing')) or (select count(*) from tenant_private.repair_tasks where store_id=p_store and repair_id=p_repair)>=50 then raise exception 'Assign technician to open ticket first' using errcode='22023';end if;
 insert into tenant_private.repair_tasks(store_id,repair_id,id,description,actor) values(p_store,p_repair,p_id,btrim(p_description),auth.uid());return p_id;
end $$;
create function tenant_private.repair_task_finish(p_store uuid,p_id uuid,p_next text) returns boolean language plpgsql security definer set search_path='' as $$
declare v tenant_private.repair_tasks%rowtype;begin
 perform 1 from public.saas_stores where id=p_store for update;
 select * into v from tenant_private.repair_tasks where store_id=p_store and id=p_id for update;
 if not found then raise exception 'Unknown task' using errcode='22023';end if;
 perform tenant_private.require_repair(p_store,v.repair_id,true);
 if p_next is null or p_next not in ('done','cancelled') or (p_next='cancelled' and tenant_private.member_role(p_store)<>'owner') or not tenant_private.staff_action_allowed(p_store,'repair_transition') then raise exception 'Task action denied' using errcode='42501';end if;
 if v.state=p_next then return true;end if;
 if v.state<>'pending' or (p_next='done' and not tenant_private.repair_approved(p_store,v.repair_id)) or not exists(select 1 from public.mt_repairs where store_id=p_store and id=v.repair_id and state not in ('delivered','cancelled')) then raise exception 'Task not actionable' using errcode='22023';end if;
 update tenant_private.repair_tasks set state=p_next,finished_at=now() where store_id=p_store and id=p_id;return true;
end $$;
create function tenant_private.repair_task_list(p_store uuid,p_repair uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin perform tenant_private.require_repair(p_store,p_repair,false);return jsonb_build_object('technician',(select technician from tenant_private.repair_assignments where store_id=p_store and repair_id=p_repair),'approved',tenant_private.repair_approved(p_store,p_repair),'tasks',coalesce((select jsonb_agg(to_jsonb(x) order by created_at,id) from (select id,description,state,created_at,finished_at from tenant_private.repair_tasks where store_id=p_store and repair_id=p_repair)x),'[]'::jsonb));end $$;
create function public.mt_repair_assign(p_store uuid,p_repair uuid,p_tech uuid) returns boolean language sql security invoker set search_path='' as $$select tenant_private.repair_assign(p_store,p_repair,p_tech)$$;
create function public.mt_repair_task_add(p_store uuid,p_repair uuid,p_id uuid,p_description text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.repair_task_add(p_store,p_repair,p_id,p_description)$$;
create function public.mt_repair_task_finish(p_store uuid,p_id uuid,p_next text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.repair_task_finish(p_store,p_id,p_next)$$;
create function public.mt_repair_task_list(p_store uuid,p_repair uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.repair_task_list(p_store,p_repair)$$;
revoke all on function tenant_private.repair_approved(uuid,uuid),tenant_private.guard_repair_approval(),tenant_private.repair_assign(uuid,uuid,uuid),tenant_private.repair_task_add(uuid,uuid,uuid,text),tenant_private.repair_task_finish(uuid,uuid,text),tenant_private.repair_task_list(uuid,uuid),public.mt_repair_assign(uuid,uuid,uuid),public.mt_repair_task_add(uuid,uuid,uuid,text),public.mt_repair_task_finish(uuid,uuid,text),public.mt_repair_task_list(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.repair_assign(uuid,uuid,uuid),tenant_private.repair_task_add(uuid,uuid,uuid,text),tenant_private.repair_task_finish(uuid,uuid,text),tenant_private.repair_task_list(uuid,uuid),public.mt_repair_assign(uuid,uuid,uuid),public.mt_repair_task_add(uuid,uuid,uuid,text),public.mt_repair_task_finish(uuid,uuid,text),public.mt_repair_task_list(uuid,uuid) to authenticated;
commit;
