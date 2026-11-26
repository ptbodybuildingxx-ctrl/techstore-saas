-- A tracking code is a read capability, not authority to approve a repair.
-- A confirmed signed-in buyer generates a short-lived pairing code; the owner
-- verifies the person and ticket in person and consumes that code exactly once.
begin;
create table tenant_private.repair_pairing_codes(
 store_id uuid not null references tenant_private.workspaces(store_id),buyer uuid not null references auth.users(id),
 code uuid not null default gen_random_uuid(),expires_at timestamptz not null,created_at timestamptz not null default now(),
 primary key(store_id,buyer),unique(code)
);
create table tenant_private.repair_customer_links(
 store_id uuid not null,repair_id uuid not null,buyer uuid not null references auth.users(id),
 actor uuid not null,linked_at timestamptz not null default now(),
 primary key(store_id,repair_id),foreign key(store_id,repair_id) references tenant_private.repair_tracking(store_id,repair_id)
);
alter table tenant_private.repair_pairing_codes enable row level security;
alter table tenant_private.repair_customer_links enable row level security;
revoke all on tenant_private.repair_pairing_codes,tenant_private.repair_customer_links from public,anon,authenticated,service_role;
alter table tenant_private.repair_estimates add column decided_by uuid references auth.users(id),add column decision_session uuid;
create function tenant_private.repair_pairing_code(p_slug text) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);v uuid;
begin
 perform 1 from public.saas_stores where id=t for update;
 if not coalesce(saas_private.live_session(),false) or auth.uid() is null then raise exception 'Live buyer required' using errcode='42501';end if;
 insert into tenant_private.repair_pairing_codes(store_id,buyer,expires_at) values(t,auth.uid(),now()+interval '10 minutes')
 on conflict(store_id,buyer) do update set code=gen_random_uuid(),expires_at=excluded.expires_at,created_at=now()
 returning code into v;return v;
end $$;
create function tenant_private.repair_customer_link(p_store uuid,p_repair uuid,p_code uuid,p_confirm boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare b uuid;
begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_repair(p_store,p_repair,true);
 if p_code is null or p_confirm is distinct from true or not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state in ('received','diagnosing','repairing')) then raise exception 'Open ticket and in-person confirmation required' using errcode='22023';end if;
 if exists(select 1 from tenant_private.repair_customer_links where store_id=p_store and repair_id=p_repair) then raise exception 'Ticket already linked' using errcode='22023';end if;
 delete from tenant_private.repair_pairing_codes c where c.store_id=p_store and c.code=p_code and c.expires_at>now() and exists(select 1 from auth.users u where u.id=c.buyer and u.email_confirmed_at is not null and not u.is_anonymous and (u.banned_until is null or u.banned_until<=now())) returning buyer into b;
 if not found then raise exception 'Invalid or expired pairing code' using errcode='22023';end if;
 insert into tenant_private.repair_customer_links(store_id,repair_id,buyer,actor) values(p_store,p_repair,b,auth.uid());return true;
end $$;
create or replace function tenant_private.repair_decide(p_slug text,p_code uuid,p_estimate uuid,p_accept boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid;r uuid;st text;who uuid;
begin
 if p_accept is null or auth.uid() is null or not coalesce(saas_private.live_session(),false) then raise exception 'Verified live customer required' using errcode='42501';end if;
 select tr.store_id,tr.repair_id into t,r from tenant_private.repair_tracking tr join public.saas_stores s on s.id=tr.store_id where s.slug=p_slug and tr.code=p_code and tenant_private.storefront_active(s.id);
 if not found then return false;end if;
 perform 1 from public.saas_stores where id=t for update;
 if not coalesce(saas_private.live_session(),false) or not exists(select 1 from tenant_private.repair_customer_links where store_id=t and repair_id=r and buyer=auth.uid()) then raise exception 'Linked customer required' using errcode='42501';end if;
 if not exists(select 1 from public.mt_repairs where store_id=t and id=r and state in ('received','diagnosing','repairing')) then return false;end if;
 select state,decided_by into st,who from tenant_private.repair_estimates where store_id=t and repair_id=r and id=p_estimate and superseded_at is null;
 if not found then return false;end if;
 if st=(case when p_accept then 'approved' else 'rejected' end) and who=auth.uid() then return true;end if;
 update tenant_private.repair_estimates set state=case when p_accept then 'approved' else 'rejected' end,decided_at=now(),decided_by=auth.uid(),decision_session=(auth.jwt()->>'session_id')::uuid
 where store_id=t and repair_id=r and id=p_estimate and state='offered';return found;
end $$;
create or replace function tenant_private.repair_approved(p_store uuid,p_repair uuid) returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from tenant_private.repair_tracking where store_id=p_store and repair_id=p_repair)
 or exists(select 1 from tenant_private.repair_estimates e join tenant_private.repair_customer_links l on l.store_id=e.store_id and l.repair_id=e.repair_id and l.buyer=e.decided_by where e.store_id=p_store and e.repair_id=p_repair and e.superseded_at is null and e.state='approved' and e.decision_session is not null)
$$;
create or replace function tenant_private.repair_status(p_slug text,p_code uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid;r uuid;v jsonb;
begin
 select tr.store_id,tr.repair_id into t,r from tenant_private.repair_tracking tr join public.saas_stores s on s.id=tr.store_id where s.slug=p_slug and tr.code=p_code and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 select jsonb_build_object('device',p.device,'state',p.state,'created_at',p.created_at,'can_decide',coalesce(saas_private.live_session(),false) and exists(select 1 from tenant_private.repair_customer_links l where l.store_id=t and l.repair_id=r and l.buyer=auth.uid()),'estimate',(select jsonb_build_object('id',id,'currency',currency,'amount_minor',amount_minor,'description',description,'state',state) from tenant_private.repair_estimates where store_id=t and repair_id=r and superseded_at is null order by created_at desc,id desc limit 1)) into v from public.mt_repairs p where p.store_id=t and p.id=r;return v;
end
$$;

create or replace function tenant_private.repair_evidence_list(p_store uuid,p_repair uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin perform tenant_private.require_repair(p_store,p_repair,false);return jsonb_build_object('customer_linked',exists(select 1 from tenant_private.repair_customer_links l where l.store_id=p_store and l.repair_id=p_repair),'evidence',coalesce((select jsonb_agg(jsonb_build_object('kind',kind,'note',note,'photo',photo,'created_at',created_at) order by created_at) from tenant_private.repair_evidence where store_id=p_store and repair_id=p_repair),'[]'::jsonb),'estimates',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc) from (select id,currency,amount_minor,description,state,created_at,decided_at,(decided_by is not null) verified_decision from tenant_private.repair_estimates where store_id=p_store and repair_id=p_repair order by created_at desc limit 50)x),'[]'::jsonb));end
$$;

create function public.mt_repair_pairing_code(p_slug text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.repair_pairing_code(p_slug)$$;
create function public.mt_repair_customer_link(p_store uuid,p_repair uuid,p_code uuid,p_confirm boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.repair_customer_link(p_store,p_repair,p_code,p_confirm)$$;
revoke all on function tenant_private.repair_pairing_code(text),tenant_private.repair_customer_link(uuid,uuid,uuid,boolean),public.mt_repair_pairing_code(text),public.mt_repair_customer_link(uuid,uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.repair_pairing_code(text),tenant_private.repair_customer_link(uuid,uuid,uuid,boolean),public.mt_repair_pairing_code(text),public.mt_repair_customer_link(uuid,uuid,uuid,boolean) to authenticated;
revoke execute on function tenant_private.repair_decide(text,uuid,uuid,boolean),public.mt_repair_decide(text,uuid,uuid,boolean) from anon;
commit;
