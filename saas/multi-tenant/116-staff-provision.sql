-- 116: owner-authorized employee creation, exact retry identity and branch continuity.
begin;
create table tenant_private.staff_provision_requests (
 store_id uuid not null references tenant_private.workspaces(store_id),
 request_id uuid not null,
 actor uuid not null,
 display_name text not null check(length(display_name) between 1 and 120),
 email text not null check(length(email) between 3 and 254),
 role text not null check(role in ('cashier','stock','tech')),
 branch_id uuid,
 user_id uuid,
 created_at timestamptz not null default now(),
 completed_at timestamptz,
 primary key(store_id,request_id),
 foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),
 check((completed_at is null)=(user_id is null))
);
alter table tenant_private.staff_provision_requests enable row level security;
revoke all on tenant_private.staff_provision_requests from public,anon,authenticated;

create or replace function tenant_private.staff_provision(p_store uuid,p_request uuid,p_name text,p_email text,p_role text,p_branch uuid,p_finish boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare q tenant_private.staff_provision_requests%rowtype; a uuid:=auth.uid(); u uuid; n text:=btrim(p_name); e text:=lower(btrim(p_email));
begin
 perform tenant_private.owner_write(p_store);
 if a is null or p_request is null or p_finish is null or n is null or length(n) not between 1 and 120 or e is null or length(e) not between 3 and 254 or e !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or p_role is null or p_role not in ('cashier','stock','tech') then raise exception 'Invalid employee request' using errcode='22023';end if;
 if p_branch is not null then perform tenant_private.require_branch(p_store,p_branch);end if;
 select * into q from tenant_private.staff_provision_requests where store_id=p_store and request_id=p_request;
 if found then
  if q.actor<>a or q.display_name<>n or q.email<>e or q.role<>p_role or q.branch_id is distinct from p_branch then raise exception 'Conflicting employee request' using errcode='22023';end if;
  if q.completed_at is not null then return jsonb_build_object('actor',a,'user_id',q.user_id,'completed',true);end if;
 else
  if p_finish then raise exception 'Unknown employee request' using errcode='22023';end if;
  if (select count(*) from tenant_private.staff_provision_requests where store_id=p_store and created_at>now()-interval '1 hour')>=20 then raise exception 'Employee creation limit' using errcode='22023';end if;
  if exists(select 1 from auth.users where lower(email)=e) then raise exception 'Account unavailable; use existing confirmed account workflow' using errcode='22023';end if;
  insert into tenant_private.staff_provision_requests(store_id,request_id,actor,display_name,email,role,branch_id) values(p_store,p_request,a,n,e,p_role,p_branch);
 end if;
 -- Only the Auth Admin endpoint can write raw_app_meta_data. Never trust user metadata.
 select id into u from auth.users where lower(email)=e and email_confirmed_at is not null and not is_anonymous and (banned_until is null or banned_until<=now()) and raw_app_meta_data->>'techstore_staff_request'=p_request::text and raw_app_meta_data->>'techstore_staff_store'=p_store::text and raw_app_meta_data->>'techstore_staff_actor'=a::text;
 if not p_finish then return jsonb_build_object('actor',a,'user_id',u,'completed',false);end if;
 if u is null then raise exception 'Provisioned Auth account required' using errcode='22023';end if;
 if exists(select 1 from tenant_private.members where store_id=p_store and user_id=u) then raise exception 'Account already assigned; review existing membership' using errcode='22023';end if;
 perform tenant_private.staff_set(p_store,p_request,u,p_role,true);
 insert into tenant_private.staff_profiles(store_id,user_id,display_name,photo) values(p_store,u,n,'');
 if p_branch is not null then perform tenant_private.staff_scope_set(p_store,u,p_branch);end if;
 update tenant_private.staff_provision_requests set user_id=u,completed_at=now() where store_id=p_store and request_id=p_request;
 return jsonb_build_object('actor',a,'user_id',u,'completed',true);
end $$;
create function public.mt_staff_provision(p_store uuid,p_request uuid,p_name text,p_email text,p_role text,p_branch uuid,p_finish boolean)
returns jsonb language sql set search_path='' as $$select tenant_private.staff_provision(p_store,p_request,p_name,p_email,p_role,p_branch,p_finish)$$;
revoke all on function tenant_private.staff_provision(uuid,uuid,text,text,text,uuid,boolean) from public,anon,authenticated;
revoke all on function public.mt_staff_provision(uuid,uuid,text,text,text,uuid,boolean) from public,anon,authenticated;
grant execute on function tenant_private.staff_provision(uuid,uuid,text,text,text,uuid,boolean) to authenticated;
grant execute on function public.mt_staff_provision(uuid,uuid,text,text,text,uuid,boolean) to authenticated;

-- Preserve a branch assignment even when disabled or moved to another staff role.
-- Revoke explicit positive grants on role changes or deactivation. Historical events and denials stay.
create or replace function tenant_private.reset_staff_scope()
returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;
begin
 if old.role<>new.role then
  select coalesce((select branch_id from tenant_private.cashier_branch_scope where store_id=new.store_id and user_id=new.user_id),(select branch_id from tenant_private.staff_branch_scope where store_id=new.store_id and user_id=new.user_id)) into b;
  delete from tenant_private.staff_branch_scope where store_id=new.store_id and user_id=new.user_id;
  delete from tenant_private.cashier_branch_scope where store_id=new.store_id and user_id=new.user_id;
  if b is not null and new.role='cashier' then
   insert into tenant_private.cashier_branch_scope(store_id,user_id,branch_id) values(new.store_id,new.user_id,b);
  elsif b is not null and new.role in ('stock','tech') then
   insert into tenant_private.staff_branch_scope(store_id,user_id,branch_id,role) values(new.store_id,new.user_id,b,new.role);
  end if;
 end if;
 if not new.active or old.role<>new.role then
  delete from tenant_private.procurement_grants where store_id=new.store_id and user_id=new.user_id;
  delete from tenant_private.receivable_grants where store_id=new.store_id and user_id=new.user_id;
 end if;
 return new;
end $$;

create or replace function tenant_private.staff_list(p_store uuid,p_after uuid,p_limit integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then
  raise exception 'Owner required' using errcode='42501';
 end if;
 if p_limit is null or p_limit not between 1 and 100 then
  raise exception 'Invalid page' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.user_id),'[]'::jsonb) into r
 from (
  select m.user_id,m.role,m.active,coalesce(pr.display_name,'') as display_name,
         coalesce(sc.branch_id,cc.branch_id) as branch_id,b.name as branch_name,
         t.currency,t.salary_minor,t.commission_bps,
         coalesce(sh.ended_at is null and sh.started_at is not null,false) as clock_open,
         sh.started_at as last_started_at,sh.ended_at as last_ended_at
  from tenant_private.members m
  left join tenant_private.staff_profiles pr on pr.store_id=m.store_id and pr.user_id=m.user_id
  left join tenant_private.staff_terms t on t.store_id=m.store_id and t.user_id=m.user_id
  left join tenant_private.staff_branch_scope sc on sc.store_id=m.store_id and sc.user_id=m.user_id and sc.role=m.role
  left join tenant_private.cashier_branch_scope cc on cc.store_id=m.store_id and cc.user_id=m.user_id and m.role='cashier'
  left join tenant_private.branches b on b.store_id=m.store_id and b.id=coalesce(sc.branch_id,cc.branch_id)
  left join lateral (
   select s.started_at,s.ended_at from tenant_private.staff_shifts s
   where s.store_id=m.store_id and s.user_id=m.user_id
   order by (s.ended_at is null) desc,s.started_at desc,s.id desc limit 1
  ) sh on true
  where m.store_id=p_store and (p_after is null or m.user_id>p_after)
  order by m.user_id limit p_limit
 ) x;
 return r;
end $$;

commit;
