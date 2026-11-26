-- 114: owner-only employee directory; preserve the existing RPC and keyset cursor.
begin;
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
         sc.branch_id,b.name as branch_name,
         t.currency,t.salary_minor,t.commission_bps,
         coalesce(sh.ended_at is null and sh.started_at is not null,false) as clock_open,
         sh.started_at as last_started_at,sh.ended_at as last_ended_at
  from tenant_private.members m
  left join tenant_private.staff_profiles pr on pr.store_id=m.store_id and pr.user_id=m.user_id
  left join tenant_private.staff_terms t on t.store_id=m.store_id and t.user_id=m.user_id
  left join tenant_private.staff_branch_scope sc on sc.store_id=m.store_id and sc.user_id=m.user_id
  left join tenant_private.branches b on b.store_id=sc.store_id and b.id=sc.branch_id
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
-- Keep the existing function ACL and public wrapper; no extra role grants.
commit;
