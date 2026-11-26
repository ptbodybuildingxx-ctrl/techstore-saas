-- 128: consent-based shop ownership transfer; no administrator changes Auth credentials.
begin;
create table tenant_private.owner_transfers(
 id uuid primary key,store_id uuid not null references tenant_private.workspaces(store_id),
 old_owner uuid not null,new_owner uuid not null,proposed_by uuid not null,
 reference text not null check(length(btrim(reference)) between 1 and 200),
 state text not null default 'pending' check(state in ('pending','completed','cancelled')),
 old_approved_at timestamptz,new_approved_at timestamptz,
 created_at timestamptz not null default now(),expires_at timestamptz not null,
 finished_at timestamptz,finished_by uuid,
 check(old_owner<>new_owner)
);
create unique index owner_transfer_pending on tenant_private.owner_transfers(store_id) where state='pending';
alter table tenant_private.owner_transfers enable row level security;
revoke all on tenant_private.owner_transfers from public,anon,authenticated;

create function tenant_private.transfer_verified(u uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users a where a.id=u and a.email_confirmed_at is not null and not a.is_anonymous and (a.banned_until is null or a.banned_until<=now()))
 and not exists(select 1 from saas_private.operators where user_id=u)
$$;
revoke all on function tenant_private.transfer_verified(uuid) from public,anon,authenticated;

create function tenant_private.transfer_admin_list(s uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id) from (select * from tenant_private.owner_transfers where store_id=s order by created_at desc,id limit 50)x),'[]'::jsonb);
end $$;

create function tenant_private.transfer_propose(s uuid,req uuid,old_u uuid,new_u uuid,proof text) returns uuid language plpgsql security definer set search_path='' as $$
declare r tenant_private.owner_transfers%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Operator MFA required' using errcode='42501';end if;
 if s is null or req is null or old_u is null or new_u is null or old_u=new_u or proof is null or length(btrim(proof)) not between 1 and 200 then raise exception 'Invalid transfer';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into r from tenant_private.owner_transfers where id=req;
 if found then
  if r.store_id<>s or r.old_owner<>old_u or r.new_owner<>new_u or r.proposed_by<>auth.uid() or r.reference<>btrim(proof) then raise exception 'Conflicting transfer';end if;return req;
 end if;
 if not exists(select 1 from tenant_private.workspaces where store_id=s) or not exists(select 1 from tenant_private.members where store_id=s and user_id=old_u and role='owner' and active) or (select count(*) from tenant_private.members where store_id=s and role='owner' and active)<>1 or not tenant_private.transfer_verified(old_u) or not tenant_private.transfer_verified(new_u) or exists(select 1 from tenant_private.members where store_id=s and user_id=new_u) or exists(select 1 from public.saas_memberships where store_id=s and user_id=new_u) or exists(select 1 from tenant_private.admin_member_holds where store_id=s and user_id in (old_u,new_u) and blocked) then raise exception 'Transfer requires one active owner and a separate verified account';end if;
 update tenant_private.owner_transfers set state='cancelled',finished_at=now(),finished_by=auth.uid() where store_id=s and state='pending' and expires_at<=now();
 insert into tenant_private.owner_transfers(id,store_id,old_owner,new_owner,proposed_by,reference,expires_at) values(req,s,old_u,new_u,auth.uid(),btrim(proof),now()+interval '72 hours');return req;
end $$;

create function tenant_private.transfer_self_review(req uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r tenant_private.owner_transfers%rowtype;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Verified account required' using errcode='42501';end if;
 select * into r from tenant_private.owner_transfers where id=req and auth.uid() in (old_owner,new_owner);
 if not found then return null;end if;
 return jsonb_build_object('id',r.id,'store_id',r.store_id,'store_name',(select name from public.saas_stores where id=r.store_id),'role',case when auth.uid()=r.old_owner then 'old' else 'new' end,'other_account',case when auth.uid()=r.old_owner then r.new_owner else r.old_owner end,'state',r.state,'expires_at',r.expires_at,'old_approved_at',r.old_approved_at,'new_approved_at',r.new_approved_at,'mfa',auth.jwt()->>'aal'='aal2');
end $$;

create function tenant_private.transfer_self_decide(req uuid,accept boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare r tenant_private.owner_transfers%rowtype;s uuid;
begin
 if not coalesce(saas_private.live_session(),false) or auth.jwt()->>'aal' is distinct from 'aal2' or accept is null then raise exception 'Verified MFA session required' using errcode='42501';end if;
 select store_id into s from tenant_private.owner_transfers where id=req and auth.uid() in (old_owner,new_owner);
 if not found then raise exception 'Transfer unavailable';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into r from tenant_private.owner_transfers where id=req for update;
 if r.state<>'pending' or r.expires_at<=now() or not tenant_private.transfer_verified(auth.uid()) or exists(select 1 from tenant_private.admin_member_holds where store_id=s and user_id=auth.uid() and blocked) or (auth.uid()=r.old_owner and tenant_private.member_role(s) is distinct from 'owner') then raise exception 'Transfer expired or unavailable';end if;
 if not accept then update tenant_private.owner_transfers set state='cancelled',finished_by=auth.uid(),finished_at=now() where id=req;
 elsif auth.uid()=r.old_owner then update tenant_private.owner_transfers set old_approved_at=coalesce(old_approved_at,now()) where id=req;
 else update tenant_private.owner_transfers set new_approved_at=coalesce(new_approved_at,now()) where id=req;end if;
 return true;
end $$;

create function tenant_private.transfer_finalize(s uuid,req uuid,complete boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare r tenant_private.owner_transfers%rowtype;
begin
 if not coalesce(saas_private.is_operator(),false) or auth.jwt()->>'aal' is distinct from 'aal2' or complete is null then raise exception 'Operator MFA required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=s for update;
 select * into r from tenant_private.owner_transfers where store_id=s and id=req for update;
 if not found then raise exception 'Transfer unavailable';end if;
 if r.state=(case when complete then 'completed' else 'cancelled' end) then return true;end if;
 if r.state<>'pending' then raise exception 'Transfer closed';end if;
 if complete then
  if r.expires_at<=now() or r.old_approved_at is null or r.new_approved_at is null or not tenant_private.transfer_verified(r.old_owner) or not tenant_private.transfer_verified(r.new_owner) or not exists(select 1 from tenant_private.members where store_id=s and user_id=r.old_owner and role='owner' and active) or (select count(*) from tenant_private.members where store_id=s and role='owner' and active)<>1 or exists(select 1 from tenant_private.members where store_id=s and user_id=r.new_owner) or exists(select 1 from public.saas_memberships where store_id=s and user_id=r.new_owner) or exists(select 1 from tenant_private.admin_member_holds where store_id=s and user_id in (r.old_owner,r.new_owner) and blocked) or not exists(select 1 from auth.mfa_factors where user_id=r.new_owner and factor_type::text='totp' and status::text='verified') then raise exception 'Transfer prerequisites changed';end if;
  update tenant_private.members set active=false where store_id=s and user_id=r.old_owner;
  update public.saas_memberships set active=false where store_id=s and user_id=r.old_owner;
  insert into tenant_private.members(store_id,user_id,role,active) values(s,r.new_owner,'owner',true);
  insert into public.saas_memberships(store_id,user_id,role,active) values(s,r.new_owner,'owner',true);
 end if;
 update tenant_private.owner_transfers set state=case when complete then 'completed' else 'cancelled' end,finished_at=now(),finished_by=auth.uid() where id=req;
 return true;
end $$;
create function public.mt_transfer_admin_list(s uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.transfer_admin_list(s)$$;
create function public.mt_transfer_propose(s uuid,req uuid,old_u uuid,new_u uuid,proof text) returns uuid language sql set search_path='' as $$select tenant_private.transfer_propose(s,req,old_u,new_u,proof)$$;
create function public.mt_transfer_self_review(req uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.transfer_self_review(req)$$;
create function public.mt_transfer_self_decide(req uuid,accept boolean) returns boolean language sql set search_path='' as $$select tenant_private.transfer_self_decide(req,accept)$$;
create function public.mt_transfer_finalize(s uuid,req uuid,complete boolean) returns boolean language sql set search_path='' as $$select tenant_private.transfer_finalize(s,req,complete)$$;
revoke all on function tenant_private.transfer_admin_list(uuid),public.mt_transfer_admin_list(uuid) from public,anon,authenticated;
grant execute on function tenant_private.transfer_admin_list(uuid),public.mt_transfer_admin_list(uuid) to authenticated;
revoke all on function tenant_private.transfer_propose(uuid,uuid,uuid,uuid,text),public.mt_transfer_propose(uuid,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function tenant_private.transfer_propose(uuid,uuid,uuid,uuid,text),public.mt_transfer_propose(uuid,uuid,uuid,uuid,text) to authenticated;
revoke all on function tenant_private.transfer_self_review(uuid),public.mt_transfer_self_review(uuid) from public,anon,authenticated;
grant execute on function tenant_private.transfer_self_review(uuid),public.mt_transfer_self_review(uuid) to authenticated;
revoke all on function tenant_private.transfer_self_decide(uuid,boolean),public.mt_transfer_self_decide(uuid,boolean) from public,anon,authenticated;
grant execute on function tenant_private.transfer_self_decide(uuid,boolean),public.mt_transfer_self_decide(uuid,boolean) to authenticated;
revoke all on function tenant_private.transfer_finalize(uuid,uuid,boolean),public.mt_transfer_finalize(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function tenant_private.transfer_finalize(uuid,uuid,boolean),public.mt_transfer_finalize(uuid,uuid,boolean) to authenticated;

create function tenant_private.self_verified_identity() returns uuid language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Verified account required' using errcode='42501';end if;
 return auth.uid();
end $$;
create function public.mt_self_verified_identity() returns uuid language sql stable set search_path='' as $$select tenant_private.self_verified_identity()$$;
revoke all on function tenant_private.self_verified_identity(),public.mt_self_verified_identity() from public,anon,authenticated;
grant execute on function tenant_private.self_verified_identity(),public.mt_self_verified_identity() to authenticated;

commit;
