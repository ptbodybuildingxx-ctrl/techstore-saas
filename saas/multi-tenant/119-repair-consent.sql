-- 119: documented repair identity, paper consent, tracking recovery and explicit photo sharing.
-- No passwords, identity document numbers, or tracking codes are copied to audit events.
begin;
create table tenant_private.repair_case_audit(
 store_id uuid not null,repair_id uuid not null,request_id uuid not null,
 kind text not null check(kind in ('account_linked','identity_checked','tracking_activated','tracking_rotated','paper_decision','photo_visibility')),
 actor uuid not null,details jsonb not null,created_at timestamptz not null default now(),
 primary key(store_id,request_id),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id)
);
create index repair_case_audit_ticket on tenant_private.repair_case_audit(store_id,repair_id,created_at desc,request_id);
create table tenant_private.repair_paper_decisions(
 store_id uuid not null,estimate_id uuid not null,repair_id uuid not null,request_id uuid not null,
 accepted boolean not null,currency text not null,amount_minor bigint not null check(amount_minor between 0 and 100000000000000),
 document_ref text not null check(length(btrim(document_ref)) between 1 and 120),
 actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,estimate_id),unique(store_id,request_id),unique(store_id,document_ref),
 foreign key(store_id,estimate_id) references tenant_private.repair_estimates(store_id,id),
 foreign key(store_id,repair_id) references public.mt_repairs(store_id,id)
);
create table tenant_private.repair_photo_visibility(
 store_id uuid not null,evidence_id uuid not null,repair_id uuid not null,buyer uuid not null,
 visible boolean not null,actor uuid not null,updated_at timestamptz not null default now(),
 primary key(store_id,evidence_id),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id)
);
alter table tenant_private.repair_case_audit enable row level security;
alter table tenant_private.repair_paper_decisions enable row level security;
alter table tenant_private.repair_photo_visibility enable row level security;
revoke all on tenant_private.repair_case_audit,tenant_private.repair_paper_decisions,tenant_private.repair_photo_visibility from public,anon,authenticated;

create function tenant_private.repair_case_owner(s uuid,r uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(s);
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live owner required' using errcode='42501';end if;
 perform tenant_private.require_repair(s,r,true);
end $$;
revoke all on function tenant_private.repair_case_owner(uuid,uuid) from public,anon,authenticated;

create function tenant_private.audit_repair_link()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into tenant_private.repair_case_audit(store_id,repair_id,request_id,kind,actor,details)
 values(new.store_id,new.repair_id,gen_random_uuid(),'account_linked',new.actor,jsonb_build_object('buyer',new.buyer,'method','confirmed_account_and_in_person_attestation'));
 return new;
end $$;
revoke all on function tenant_private.audit_repair_link() from public,anon,authenticated;
create trigger mt_audit_repair_link after insert on tenant_private.repair_customer_links for each row execute function tenant_private.audit_repair_link();

CREATE OR REPLACE FUNCTION tenant_private.repair_customer_link(p_store uuid, p_repair uuid, p_code uuid, p_confirm boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid;
begin
 perform tenant_private.owner_write(p_store);if not coalesce(saas_private.live_session(),false) then raise exception 'Live owner session required' using errcode='42501';end if;perform tenant_private.require_repair(p_store,p_repair,true);
 if p_code is null or p_confirm is distinct from true or not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state in ('received','diagnosing','repairing','ready')) then raise exception 'Open ticket and in-person confirmation required' using errcode='22023';end if;
 if exists(select 1 from tenant_private.repair_customer_links where store_id=p_store and repair_id=p_repair) then raise exception 'Ticket already linked' using errcode='22023';end if;
 delete from tenant_private.repair_pairing_codes c where c.store_id=p_store and c.code=p_code and c.expires_at>now() and exists(select 1 from auth.users u where u.id=c.buyer and u.email_confirmed_at is not null and not u.is_anonymous and (u.banned_until is null or u.banned_until<=now())) returning buyer into b;
 if not found then raise exception 'Invalid or expired pairing code' using errcode='22023';end if;
 insert into tenant_private.repair_customer_links(store_id,repair_id,buyer,actor) values(p_store,p_repair,b,auth.uid());
 update tenant_private.repair_estimates e set superseded_at=now() where e.store_id=p_store and e.repair_id=p_repair and e.superseded_at is null and exists(select 1 from tenant_private.repair_paper_decisions p where p.store_id=e.store_id and p.estimate_id=e.id);
 return true;
end $function$
;
CREATE OR REPLACE FUNCTION tenant_private.repair_offer(p_store uuid, p_repair uuid, p_id uuid, p_currency text, p_amount bigint, p_description text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e tenant_private.repair_estimates%rowtype;begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_repair(p_store,p_repair,true);
 if p_id is null or p_amount is null or p_amount not between 0 and 100000000000000 or p_description is null or length(btrim(p_description)) not between 1 and 300 then raise exception 'Invalid estimate' using errcode='22023';end if;
 select * into e from tenant_private.repair_estimates where store_id=p_store and id=p_id;
 if found then if e.actor<>auth.uid() or e.repair_id<>p_repair or e.currency<>p_currency or e.amount_minor<>p_amount or e.description<>btrim(p_description) then raise exception 'Conflicting estimate' using errcode='22023';end if;return p_id;end if;
 if not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state in ('received','diagnosing','repairing','ready')) then raise exception 'Repair closed' using errcode='22023';end if;
 if not exists(select 1 from tenant_private.repair_tracking where store_id=p_store and repair_id=p_repair) then raise exception 'Tracking unavailable for historical ticket' using errcode='22023';end if;
 update tenant_private.repair_estimates set superseded_at=now(),state=case when state='offered' then 'superseded' else state end where store_id=p_store and repair_id=p_repair and superseded_at is null;
 insert into tenant_private.repair_estimates(store_id,repair_id,id,currency,amount_minor,description,actor) values(p_store,p_repair,p_id,p_currency,p_amount,btrim(p_description),auth.uid());return p_id;
end
$function$
;
CREATE OR REPLACE FUNCTION tenant_private.repair_decide(p_slug text, p_code uuid, p_estimate uuid, p_accept boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;r uuid;st text;who uuid;
begin
 if p_accept is null or auth.uid() is null or not coalesce(saas_private.live_session(),false) then raise exception 'Verified live customer required' using errcode='42501';end if;
 select tr.store_id,tr.repair_id into t,r from tenant_private.repair_tracking tr join public.saas_stores s on s.id=tr.store_id where s.slug=p_slug and tr.code=p_code and tenant_private.storefront_active(s.id);
 if not found then return false;end if;
 perform 1 from public.saas_stores where id=t for update;
 if not exists(select 1 from tenant_private.repair_tracking where store_id=t and repair_id=r and code=p_code) or not coalesce(saas_private.live_session(),false) or not exists(select 1 from tenant_private.repair_customer_links where store_id=t and repair_id=r and buyer=auth.uid()) then raise exception 'Linked customer required' using errcode='42501';end if;
 if not exists(select 1 from public.mt_repairs where store_id=t and id=r and state in ('received','diagnosing','repairing','ready')) then return false;end if;
 select state,decided_by into st,who from tenant_private.repair_estimates where store_id=t and repair_id=r and id=p_estimate and superseded_at is null;
 if not found then return false;end if;
 if st=(case when p_accept then 'approved' else 'rejected' end) and who=auth.uid() then return true;end if;
 update tenant_private.repair_estimates set state=case when p_accept then 'approved' else 'rejected' end,decided_at=now(),decided_by=auth.uid(),decision_session=(auth.jwt()->>'session_id')::uuid
 where store_id=t and repair_id=r and id=p_estimate and state='offered';return found;
end $function$
;

create function tenant_private.repair_link_documented(s uuid,r uuid,req uuid,code uuid,method text,proof text)
returns boolean language plpgsql security definer set search_path='' as $$
declare a tenant_private.repair_case_audit%rowtype;b uuid;d jsonb;
begin
 perform tenant_private.repair_case_owner(s,r);
 if req is null or code is null or method is null or method not in ('government_id_seen','intake_receipt_and_confirmed_account') or proof is null or length(btrim(proof)) not between 1 and 120 then raise exception 'Identity check and non-sensitive reference required' using errcode='22023';end if;
 select * into a from tenant_private.repair_case_audit where store_id=s and request_id=req;
 if found then
  if a.repair_id<>r or a.actor<>auth.uid() or a.kind<>'identity_checked' or a.details->>'method' is distinct from method or a.details->>'reference' is distinct from btrim(proof) then raise exception 'Conflicting identity request' using errcode='22023';end if;
  return true;
 end if;
 perform tenant_private.repair_customer_link(s,r,code,true);
 select buyer into strict b from tenant_private.repair_customer_links where store_id=s and repair_id=r;
 insert into tenant_private.repair_case_audit(store_id,repair_id,request_id,kind,actor,details) values(s,r,req,'identity_checked',auth.uid(),jsonb_build_object('buyer',b,'method',method,'reference',btrim(proof)));
 return true;
end $$;

create function tenant_private.repair_manage_tracking(s uuid,r uuid,req uuid,mode text,proof text)
returns boolean language plpgsql security definer set search_path='' as $$
declare a tenant_private.repair_case_audit%rowtype;k text;b uuid;old_est uuid;has_tracking boolean;
begin
 perform tenant_private.repair_case_owner(s,r);
 if req is null or mode is null or mode not in ('activate','rotate') or proof is null or length(btrim(proof)) not between 1 and 120 then raise exception 'Tracking action and verification reference required' using errcode='22023';end if;
 k:=case when mode='activate' then 'tracking_activated' else 'tracking_rotated' end;
 select * into a from tenant_private.repair_case_audit where store_id=s and request_id=req;
 if found then
  if a.repair_id<>r or a.actor<>auth.uid() or a.kind<>k or a.details->>'reference' is distinct from btrim(proof) then raise exception 'Conflicting recovery request' using errcode='22023';end if;
  return true;
 end if;
 if not exists(select 1 from public.mt_repairs where store_id=s and id=r and state in ('received','diagnosing','repairing','ready')) then raise exception 'Only open repairs may be recovered' using errcode='22023';end if;
 select exists(select 1 from tenant_private.repair_tracking where store_id=s and repair_id=r) into has_tracking;
 if mode='activate' then
  if has_tracking then raise exception 'Tracking already active' using errcode='22023';end if;
  insert into tenant_private.repair_tracking(store_id,repair_id,identity) values(s,r,tenant_private.effective_receipt_settings(s));
 else
  if not has_tracking then raise exception 'Activate historical tracking first' using errcode='22023';end if;
  delete from tenant_private.repair_customer_links where store_id=s and repair_id=r returning buyer into b;
  select id into old_est from tenant_private.repair_estimates where store_id=s and repair_id=r and superseded_at is null;
  update tenant_private.repair_estimates set superseded_at=now(),state=case when state='offered' then 'superseded' else state end where store_id=s and repair_id=r and superseded_at is null;
  update tenant_private.repair_photo_visibility set visible=false,actor=auth.uid(),updated_at=now() where store_id=s and repair_id=r and visible;
  update tenant_private.repair_tracking set code=gen_random_uuid() where store_id=s and repair_id=r;
 end if;
 insert into tenant_private.repair_case_audit(store_id,repair_id,request_id,kind,actor,details) values(s,r,req,k,auth.uid(),jsonb_build_object('reference',btrim(proof),'previous_buyer',b,'superseded_estimate',old_est,'method','government_id_and_original_intake_verified'));
 return true;
end $$;

create function tenant_private.repair_record_paper(s uuid,r uuid,req uuid,eid uuid,accept boolean,c text,amount bigint,proof text)
returns boolean language plpgsql security definer set search_path='' as $$
declare old tenant_private.repair_paper_decisions%rowtype;e tenant_private.repair_estimates%rowtype;
begin
 perform tenant_private.repair_case_owner(s,r);
 if req is null or eid is null or accept is null or c is null or amount is null or proof is null or length(btrim(proof)) not between 1 and 120 then raise exception 'Signed paper decision required' using errcode='22023';end if;
 select * into old from tenant_private.repair_paper_decisions where store_id=s and request_id=req;
 if found then
  if old.actor<>auth.uid() or old.repair_id<>r or old.estimate_id<>eid or old.accepted<>accept or old.currency<>c or old.amount_minor<>amount or old.document_ref<>btrim(proof) then raise exception 'Conflicting paper decision' using errcode='22023';end if;
  return true;
 end if;
 if not exists(select 1 from tenant_private.repair_tracking where store_id=s and repair_id=r) or exists(select 1 from tenant_private.repair_customer_links where store_id=s and repair_id=r) or not exists(select 1 from public.mt_repairs where store_id=s and id=r and state in ('received','diagnosing','repairing','ready')) then raise exception 'Unlinked open tracked repair required; linked customers decide in their account' using errcode='22023';end if;
 select * into e from tenant_private.repair_estimates where store_id=s and repair_id=r and id=eid and superseded_at is null and state='offered' for update;
 if not found or e.currency<>c or e.amount_minor<>amount then raise exception 'Estimate changed or already decided' using errcode='22023';end if;
 insert into tenant_private.repair_paper_decisions(store_id,estimate_id,repair_id,request_id,accepted,currency,amount_minor,document_ref,actor) values(s,eid,r,req,accept,c,amount,btrim(proof),auth.uid());
 update tenant_private.repair_estimates set state=case when accept then 'approved' else 'rejected' end,decided_at=now() where store_id=s and id=eid;
 insert into tenant_private.repair_case_audit(store_id,repair_id,request_id,kind,actor,details) values(s,r,req,'paper_decision',auth.uid(),jsonb_build_object('estimate',eid,'accepted',accept,'currency',c,'amount_minor',amount,'reference',btrim(proof),'method','government_id_seen_signed_paper'));
 return true;
end $$;

-- Existing closed tickets are untouched; untracked open historical tickets must be activated.
create or replace function tenant_private.repair_approved(p_store uuid,p_repair uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
 select 1 from tenant_private.repair_estimates e where e.store_id=p_store and e.repair_id=p_repair and e.superseded_at is null and e.state='approved'
 and (exists(select 1 from tenant_private.repair_customer_links l where l.store_id=e.store_id and l.repair_id=e.repair_id and l.buyer=e.decided_by and e.decision_session is not null)
 or (not exists(select 1 from tenant_private.repair_customer_links l where l.store_id=e.store_id and l.repair_id=e.repair_id) and exists(select 1 from tenant_private.repair_paper_decisions p where p.store_id=e.store_id and p.repair_id=e.repair_id and p.estimate_id=e.id and p.accepted and p.currency=e.currency and p.amount_minor=e.amount_minor)))
 )
$$;

create function tenant_private.repair_share_photo(s uuid,r uuid,req uuid,eid uuid,show boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare a tenant_private.repair_case_audit%rowtype;b uuid;
begin
 perform tenant_private.repair_case_owner(s,r);
 if req is null or eid is null or show is null then raise exception 'Invalid photo request' using errcode='22023';end if;
 select * into a from tenant_private.repair_case_audit where store_id=s and request_id=req;
 if found then
  if a.repair_id<>r or a.actor<>auth.uid() or a.kind<>'photo_visibility' or a.details->>'evidence' is distinct from eid::text or a.details->>'visible' is distinct from show::text then raise exception 'Conflicting photo request' using errcode='22023';end if;
  return true;
 end if;
 select buyer into b from tenant_private.repair_customer_links where store_id=s and repair_id=r;
 if b is null or not exists(select 1 from tenant_private.repair_evidence where store_id=s and repair_id=r and id=eid and kind in ('before','after') and photo is not null) then raise exception 'Linked buyer and device photo required' using errcode='22023';end if;
 insert into tenant_private.repair_photo_visibility(store_id,evidence_id,repair_id,buyer,visible,actor) values(s,eid,r,b,show,auth.uid()) on conflict(store_id,evidence_id) do update set buyer=excluded.buyer,visible=excluded.visible,actor=excluded.actor,updated_at=now();
 insert into tenant_private.repair_case_audit(store_id,repair_id,request_id,kind,actor,details) values(s,r,req,'photo_visibility',auth.uid(),jsonb_build_object('evidence',eid,'visible',show,'buyer',b));return true;
end $$;

create function tenant_private.repair_case_review(s uuid,r uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform tenant_private.require_repair(s,r,false);
 select jsonb_build_object('state',state,'device',device,'customer_id',customer_id,'customer_name',(select name from public.mt_customers c0 where c0.store_id=s and c0.id=mt_repairs.customer_id),'tracked',exists(select 1 from tenant_private.repair_tracking where store_id=s and repair_id=r),
 'linked',exists(select 1 from tenant_private.repair_customer_links where store_id=s and repair_id=r),
 'approved',tenant_private.repair_approved(s,r),
 'estimates',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id) from (select e.id,e.currency,e.amount_minor,e.description,e.state,e.created_at,e.decided_at,e.superseded_at,case when p.estimate_id is not null then 'paper' when e.decision_session is not null and e.decided_by is not null then 'account' else null end decision_method,p.document_ref,e.decided_by from tenant_private.repair_estimates e left join tenant_private.repair_paper_decisions p on p.store_id=e.store_id and p.estimate_id=e.id where e.store_id=s and e.repair_id=r order by e.created_at desc,e.id limit 50)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id) from (select request_id,prior_state,next_state,note,actor,created_at from public.mt_repair_events where store_id=s and repair_id=r order by created_at desc,request_id limit 50)x),'[]'::jsonb),
 'audit',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id) from (select request_id,kind,actor,details,created_at from tenant_private.repair_case_audit where store_id=s and repair_id=r order by created_at desc,request_id limit 50)x),'[]'::jsonb),
 'photos',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id) from (select e.id,e.kind,e.note,e.created_at,coalesce(v0.visible and v0.buyer=l.buyer,false) shared from tenant_private.repair_evidence e left join tenant_private.repair_photo_visibility v0 on v0.store_id=e.store_id and v0.evidence_id=e.id left join tenant_private.repair_customer_links l on l.store_id=e.store_id and l.repair_id=e.repair_id where e.store_id=s and e.repair_id=r and e.kind in ('before','after') and e.photo is not null order by e.created_at desc,e.id limit 50)x),'[]'::jsonb))
 into v from public.mt_repairs where store_id=s and id=r;
 return v;
end $$;

-- Public tracking codes provide status only. Quote details and opted-in photos require the current verified linked account.
create or replace function tenant_private.repair_status(p_slug text,p_code uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid;r uuid;v jsonb;linked boolean;
begin
 select tr.store_id,tr.repair_id into t,r from tenant_private.repair_tracking tr join public.saas_stores s on s.id=tr.store_id where s.slug=p_slug and tr.code=p_code and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 linked:=coalesce(saas_private.live_session(),false) and exists(select 1 from tenant_private.repair_customer_links l where l.store_id=t and l.repair_id=r and l.buyer=auth.uid());
 select jsonb_build_object('device',case when linked then p.device else 'طلب صيانة' end,'state',p.state,'created_at',p.created_at,'linked_account',linked,'can_decide',linked and p.state in ('received','diagnosing','repairing','ready'),
 'estimate',case when linked then (select jsonb_build_object('id',id,'currency',currency,'amount_minor',amount_minor,'description',description,'state',state) from tenant_private.repair_estimates where store_id=t and repair_id=r and superseded_at is null order by created_at desc,id desc limit 1) else null end,
 'shared_evidence',case when linked then coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at,x.id) from (select e.id,e.kind,e.photo,e.created_at from tenant_private.repair_evidence e join tenant_private.repair_photo_visibility v0 on v0.store_id=e.store_id and v0.evidence_id=e.id where e.store_id=t and e.repair_id=r and v0.repair_id=r and v0.buyer=auth.uid() and v0.visible and e.kind in ('before','after') and e.photo is not null order by e.created_at desc,e.id limit 50)x),'[]'::jsonb) else '[]'::jsonb end) into v from public.mt_repairs p where p.store_id=t and p.id=r and exists(select 1 from tenant_private.repair_tracking tr where tr.store_id=t and tr.repair_id=r and tr.code=p_code);
 return v;
end $$;

create function public.mt_repair_link_documented(s uuid,r uuid,req uuid,code uuid,method text,proof text) returns boolean language sql set search_path='' as $$select tenant_private.repair_link_documented(s,r,req,code,method,proof)$$;
create function public.mt_repair_manage_tracking(s uuid,r uuid,req uuid,mode text,proof text) returns boolean language sql set search_path='' as $$select tenant_private.repair_manage_tracking(s,r,req,mode,proof)$$;
create function public.mt_repair_record_paper(s uuid,r uuid,req uuid,eid uuid,accept boolean,c text,amount bigint,proof text) returns boolean language sql set search_path='' as $$select tenant_private.repair_record_paper(s,r,req,eid,accept,c,amount,proof)$$;
create function public.mt_repair_share_photo(s uuid,r uuid,req uuid,eid uuid,show boolean) returns boolean language sql set search_path='' as $$select tenant_private.repair_share_photo(s,r,req,eid,show)$$;
create function public.mt_repair_case_review(s uuid,r uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.repair_case_review(s,r)$$;
revoke all on function tenant_private.repair_link_documented(uuid,uuid,uuid,uuid,text,text),public.mt_repair_link_documented(uuid,uuid,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function tenant_private.repair_link_documented(uuid,uuid,uuid,uuid,text,text),public.mt_repair_link_documented(uuid,uuid,uuid,uuid,text,text) to authenticated;
revoke all on function tenant_private.repair_manage_tracking(uuid,uuid,uuid,text,text),public.mt_repair_manage_tracking(uuid,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function tenant_private.repair_manage_tracking(uuid,uuid,uuid,text,text),public.mt_repair_manage_tracking(uuid,uuid,uuid,text,text) to authenticated;
revoke all on function tenant_private.repair_record_paper(uuid,uuid,uuid,uuid,boolean,text,bigint,text),public.mt_repair_record_paper(uuid,uuid,uuid,uuid,boolean,text,bigint,text) from public,anon,authenticated;
grant execute on function tenant_private.repair_record_paper(uuid,uuid,uuid,uuid,boolean,text,bigint,text),public.mt_repair_record_paper(uuid,uuid,uuid,uuid,boolean,text,bigint,text) to authenticated;
revoke all on function tenant_private.repair_share_photo(uuid,uuid,uuid,uuid,boolean),public.mt_repair_share_photo(uuid,uuid,uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function tenant_private.repair_share_photo(uuid,uuid,uuid,uuid,boolean),public.mt_repair_share_photo(uuid,uuid,uuid,uuid,boolean) to authenticated;
revoke all on function tenant_private.repair_case_review(uuid,uuid),public.mt_repair_case_review(uuid,uuid) from public,anon,authenticated;
grant execute on function tenant_private.repair_case_review(uuid,uuid),public.mt_repair_case_review(uuid,uuid) to authenticated;
commit;
