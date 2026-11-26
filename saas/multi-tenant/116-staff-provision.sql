-- 116: branch continuity and employee directory. Account creation is deferred until the server endpoint is available.
-- Original provisioning migration is retained in commit e80eb2eac80fe7b0090a12e203a9340cc6c995a2.
begin;
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
