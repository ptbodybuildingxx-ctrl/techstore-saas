begin;
create table public.ts_repair_intake(
 repair_id text primary key check(length(repair_id) between 1 and 100),
 condition text not null check(length(condition)<=1000), accessories text not null check(length(accessories)<=1000),
 technician uuid references public.ts_profiles(user_id), actor uuid not null references public.ts_profiles(user_id),
 updated_at timestamptz not null default now()
);
create table public.ts_repair_history(
 id bigint generated always as identity primary key, repair_id text not null, status text not null, recorded_at timestamptz not null default now()
);
create index ts_repair_history_ticket_idx on public.ts_repair_history(repair_id,id);
alter table public.ts_repair_intake enable row level security;
alter table public.ts_repair_history enable row level security;
revoke all on public.ts_repair_intake,public.ts_repair_history from public,anon,authenticated;
create function techstore_private.capture_repair_status() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.payload->'records'->'repairs' is not distinct from old.payload->'records'->'repairs' then return new;end if;
 insert into public.ts_repair_history(repair_id,status)
 select r->>'id',r->>'status' from jsonb_array_elements(coalesce(new.payload->'records'->'repairs','[]')) r
 left join lateral (select o from jsonb_array_elements(coalesce(old.payload->'records'->'repairs','[]')) o where o->>'id'=r->>'id' limit 1) prev on true
 where r->>'id' is not null and r->>'status' in ('received','diagnosed','approval','repairing','testing','ready','delivered','cancelled') and (prev.o->>'status') is distinct from r->>'status';
 return new;
end $$;
revoke all on function techstore_private.capture_repair_status() from public,anon,authenticated;
create trigger ts_repair_status_history after update of payload on public.ts_workspace for each row execute function techstore_private.capture_repair_status();
create function techstore_private.repair_workflow(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; r jsonb; rid text; tech uuid; result jsonb;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;if not found then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>10000 then raise exception 'Invalid request';end if;
 if p_action='staff' then if u.role not in ('admin','cashier') then raise exception 'Access denied' using errcode='42501';end if;return coalesce((select jsonb_agg(jsonb_build_object('id',user_id,'name',name)) from public.ts_profiles where role='tech' and active),'[]');end if;
 if p_action='report' then
 if u.role<>'admin' then raise exception 'Access denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from (select p.name,count(*) as assigned,count(*) filter(where r->>'status' in ('ready','delivered')) as completed,count(*) filter(where r->>'status' not in ('ready','delivered','cancelled')) as open from public.ts_repair_intake a join public.ts_profiles p on p.user_id=a.technician join public.ts_workspace w on w.id=1 cross join lateral jsonb_array_elements(coalesce(w.payload->'records'->'repairs','[]')) r where r->>'id'=a.repair_id group by p.user_id,p.name) x),'[]');
 end if;
 rid:=p_args->>'repair_id';select * into w from public.ts_workspace where id=1 for update;
 select x into r from jsonb_array_elements(coalesce(w.payload->'records'->'repairs','[]')) x where x->>'id'=rid;
 if r is null or not (u.role in ('admin','cashier','tech') or (u.role='customer' and r->>'customerId'=u.user_id::text)) then raise exception 'Ticket unavailable' using errcode='42501';end if;
 if p_action='get' then
 return jsonb_build_object('intake',(select jsonb_build_object('condition',a.condition,'accessories',a.accessories,'technician',a.technician,'technician_name',p.name,'updated_at',a.updated_at) from public.ts_repair_intake a left join public.ts_profiles p on p.user_id=a.technician where a.repair_id=rid),'history',coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from (select id,status,recorded_at from public.ts_repair_history where repair_id=rid order by id desc limit 100) x),'[]'));
 end if;
 if p_action<>'save' or u.role not in ('admin','cashier') then raise exception 'Access denied' using errcode='42501';end if;
 if r->>'status' in ('delivered','cancelled') then raise exception 'Closed ticket';end if;
 tech:=nullif(p_args->>'technician','')::uuid;
 if tech is not null and not exists(select 1 from public.ts_profiles where user_id=tech and role='tech' and active) then raise exception 'Invalid technician';end if;
 insert into public.ts_repair_intake(repair_id,condition,accessories,technician,actor) values(rid,coalesce(p_args->>'condition',''),coalesce(p_args->>'accessories',''),tech,u.user_id)
 on conflict(repair_id) do update set condition=excluded.condition,accessories=excluded.accessories,technician=excluded.technician,actor=excluded.actor,updated_at=now();
 insert into public.ts_audit(actor,action) values(u.user_id,'repair intake updated '||rid);return jsonb_build_object('ok',true);
end $$;
revoke all on function techstore_private.repair_workflow(text,jsonb) from public,anon,authenticated;
grant execute on function techstore_private.repair_workflow(text,jsonb) to authenticated;
create function public.ts_repair_workflow(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.repair_workflow(p_action,p_args); $$;
revoke all on function public.ts_repair_workflow(text,jsonb) from public,anon,authenticated;
grant execute on function public.ts_repair_workflow(text,jsonb) to authenticated;
commit;