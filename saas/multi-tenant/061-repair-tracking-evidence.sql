-- Repair evidence, versioned estimates and unguessable customer tracking codes.
begin;
create table tenant_private.repair_tracking(store_id uuid not null,repair_id uuid not null,code uuid not null default gen_random_uuid(),identity jsonb not null,created_at timestamptz not null default now(),primary key(store_id,repair_id),unique(code),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id));
create table tenant_private.repair_estimates(store_id uuid not null,repair_id uuid not null,id uuid not null default gen_random_uuid(),currency text not null,amount_minor bigint not null check(amount_minor between 0 and 100000000000000),description text not null check(length(btrim(description)) between 1 and 300),state text not null default 'offered' check(state in ('offered','approved','rejected','superseded')),created_at timestamptz not null default now(),decided_at timestamptz,actor uuid not null,primary key(store_id,id),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency));
create unique index mt_repair_current_estimate on tenant_private.repair_estimates(store_id,repair_id) where state='offered';
create table tenant_private.repair_evidence(store_id uuid not null,repair_id uuid not null,id uuid not null,kind text not null check(kind in ('before','after','task')),note text not null check(length(btrim(note)) between 1 and 300),photo text,actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),foreign key(store_id,repair_id) references public.mt_repairs(store_id,id),check((kind='task' and photo is null) or (kind in ('before','after') and photo is not null and length(photo) between 8 and 32000 and photo ~ '^/9j/[A-Za-z0-9+/]*={0,2}$')));
do $$declare t text;begin foreach t in array array['repair_tracking','repair_estimates','repair_evidence'] loop execute format('alter table tenant_private.%I enable row level security',t);execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create function tenant_private.require_repair(p_store uuid,p_repair uuid,p_write boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(tenant_private.repair_scope_allowed(p_store,p_repair),false) or (p_write and not tenant_private.shared_licensed(p_store)) then raise exception 'Repair access denied' using errcode='42501';end if;
 if not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair) then raise exception 'Unknown repair' using errcode='22023';end if;
end $$;
create function tenant_private.capture_repair_tracking() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into tenant_private.repair_tracking(store_id,repair_id,identity) values(new.store_id,new.id,tenant_private.effective_receipt_settings(new.store_id));return new;end $$;
create trigger mt_repair_tracking after insert on public.mt_repairs for each row execute function tenant_private.capture_repair_tracking();
create function tenant_private.repair_tracking(p_store uuid,p_repair uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;
begin
 perform tenant_private.require_repair(p_store,p_repair,false);
 select jsonb_build_object('code',t.code,'identity',t.identity,'device',r0.device,'fault',r0.fault,'state',r0.state,'created_at',r0.created_at,'repair_id',r0.id) into r from tenant_private.repair_tracking t join public.mt_repairs r0 on r0.store_id=t.store_id and r0.id=t.repair_id where t.store_id=p_store and t.repair_id=p_repair;
 return r;
end
$$;
create function public.mt_repair_tracking(p_store uuid,p_repair uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.repair_tracking(p_store,p_repair)$$;
create function tenant_private.repair_offer(p_store uuid,p_repair uuid,p_id uuid,p_currency text,p_amount bigint,p_description text) returns uuid language plpgsql security definer set search_path='' as $$
declare e tenant_private.repair_estimates%rowtype;begin
 perform tenant_private.owner_write(p_store);perform tenant_private.require_repair(p_store,p_repair,true);
 if p_id is null or p_amount is null or p_amount not between 0 and 100000000000000 or p_description is null or length(btrim(p_description)) not between 1 and 300 then raise exception 'Invalid estimate' using errcode='22023';end if;
 select * into e from tenant_private.repair_estimates where store_id=p_store and id=p_id;
 if found then if e.actor<>auth.uid() or e.repair_id<>p_repair or e.currency<>p_currency or e.amount_minor<>p_amount or e.description<>btrim(p_description) then raise exception 'Conflicting estimate' using errcode='22023';end if;return p_id;end if;
 if not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state in ('received','diagnosing','repairing')) then raise exception 'Repair closed' using errcode='22023';end if;
 if not exists(select 1 from tenant_private.repair_tracking where store_id=p_store and repair_id=p_repair) then raise exception 'Tracking unavailable for historical ticket' using errcode='22023';end if;
 update tenant_private.repair_estimates set state='superseded' where store_id=p_store and repair_id=p_repair and state='offered';
 insert into tenant_private.repair_estimates(store_id,repair_id,id,currency,amount_minor,description,actor) values(p_store,p_repair,p_id,p_currency,p_amount,btrim(p_description),auth.uid());return p_id;
end
$$;
create function public.mt_repair_offer(p_store uuid,p_repair uuid,p_id uuid,p_currency text,p_amount bigint,p_description text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.repair_offer(p_store,p_repair,p_id,p_currency,p_amount,p_description)$$;
create function tenant_private.repair_evidence_add(p_store uuid,p_repair uuid,p_id uuid,p_kind text,p_note text,p_photo text) returns uuid language plpgsql security definer set search_path='' as $$
declare old tenant_private.repair_evidence%rowtype;begin
 perform 1 from public.saas_stores where id=p_store for update;perform tenant_private.require_repair(p_store,p_repair,true);
 if p_id is null or p_kind is null or p_kind not in ('before','after','task') or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid evidence' using errcode='22023';end if;
 select * into old from tenant_private.repair_evidence where store_id=p_store and id=p_id;
 if found then if old.actor<>auth.uid() or old.repair_id<>p_repair or old.kind<>p_kind or old.note<>btrim(p_note) or old.photo is distinct from p_photo then raise exception 'Conflicting evidence' using errcode='22023';end if;return p_id;end if;
 if (select count(*) from tenant_private.repair_evidence where store_id=p_store and repair_id=p_repair)>=50 then raise exception 'Evidence limit' using errcode='22023';end if;
 if not exists(select 1 from public.mt_repairs where store_id=p_store and id=p_repair and state not in ('delivered','cancelled')) then raise exception 'Repair closed' using errcode='22023';end if;
 insert into tenant_private.repair_evidence(store_id,repair_id,id,kind,note,photo,actor) values(p_store,p_repair,p_id,p_kind,btrim(p_note),p_photo,auth.uid());return p_id;
end
$$;
create function public.mt_repair_evidence_add(p_store uuid,p_repair uuid,p_id uuid,p_kind text,p_note text,p_photo text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.repair_evidence_add(p_store,p_repair,p_id,p_kind,p_note,p_photo)$$;
create function tenant_private.repair_evidence_list(p_store uuid,p_repair uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin perform tenant_private.require_repair(p_store,p_repair,false);return jsonb_build_object('evidence',coalesce((select jsonb_agg(jsonb_build_object('kind',kind,'note',note,'photo',photo,'created_at',created_at) order by created_at) from tenant_private.repair_evidence where store_id=p_store and repair_id=p_repair),'[]'::jsonb),'estimates',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc) from (select id,currency,amount_minor,description,state,created_at,decided_at from tenant_private.repair_estimates where store_id=p_store and repair_id=p_repair order by created_at desc limit 50)x),'[]'::jsonb));end
$$;
create function public.mt_repair_evidence_list(p_store uuid,p_repair uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.repair_evidence_list(p_store,p_repair)$$;
create function tenant_private.repair_status(p_slug text,p_code uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid;r uuid;v jsonb;
begin
 select tr.store_id,tr.repair_id into t,r from tenant_private.repair_tracking tr join public.saas_stores s on s.id=tr.store_id where s.slug=p_slug and tr.code=p_code and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 select jsonb_build_object('device',p.device,'state',p.state,'created_at',p.created_at,'estimate',(select jsonb_build_object('id',id,'currency',currency,'amount_minor',amount_minor,'description',description,'state',state) from tenant_private.repair_estimates where store_id=t and repair_id=r order by created_at desc,id desc limit 1)) into v from public.mt_repairs p where p.store_id=t and p.id=r;return v;
end
$$;
create function public.mt_repair_status(p_slug text,p_code uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.repair_status(p_slug,p_code)$$;
create function tenant_private.repair_decide(p_slug text,p_code uuid,p_estimate uuid,p_accept boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid;r uuid;st text;
begin
 if p_accept is null then raise exception 'Invalid decision' using errcode='22023';end if;
 select tr.store_id,tr.repair_id into t,r from tenant_private.repair_tracking tr join public.saas_stores s on s.id=tr.store_id where s.slug=p_slug and tr.code=p_code and tenant_private.storefront_active(s.id);
 if not found then return false;end if;
 perform 1 from public.saas_stores where id=t for update;
 if not exists(select 1 from public.mt_repairs where store_id=t and id=r and state in ('received','diagnosing','repairing')) then return false;end if;
 select state into st from tenant_private.repair_estimates where store_id=t and repair_id=r and id=p_estimate;
 if not found then return false;end if;
 if st=(case when p_accept then 'approved' else 'rejected' end) then return true;end if;
 update tenant_private.repair_estimates set state=case when p_accept then 'approved' else 'rejected' end,decided_at=now() where store_id=t and repair_id=r and id=p_estimate and state='offered';return found;
end
$$;
create function public.mt_repair_decide(p_slug text,p_code uuid,p_estimate uuid,p_accept boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.repair_decide(p_slug,p_code,p_estimate,p_accept)$$;
revoke all on function tenant_private.require_repair(uuid,uuid,boolean),tenant_private.capture_repair_tracking(),tenant_private.repair_tracking(uuid,uuid),public.mt_repair_tracking(uuid,uuid),tenant_private.repair_offer(uuid,uuid,uuid,text,bigint,text),public.mt_repair_offer(uuid,uuid,uuid,text,bigint,text),tenant_private.repair_evidence_add(uuid,uuid,uuid,text,text,text),public.mt_repair_evidence_add(uuid,uuid,uuid,text,text,text),tenant_private.repair_evidence_list(uuid,uuid),public.mt_repair_evidence_list(uuid,uuid),tenant_private.repair_status(text,uuid),public.mt_repair_status(text,uuid),tenant_private.repair_decide(text,uuid,uuid,boolean),public.mt_repair_decide(text,uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.repair_tracking(uuid,uuid),public.mt_repair_tracking(uuid,uuid),tenant_private.repair_offer(uuid,uuid,uuid,text,bigint,text),public.mt_repair_offer(uuid,uuid,uuid,text,bigint,text),tenant_private.repair_evidence_add(uuid,uuid,uuid,text,text,text),public.mt_repair_evidence_add(uuid,uuid,uuid,text,text,text),tenant_private.repair_evidence_list(uuid,uuid),public.mt_repair_evidence_list(uuid,uuid),tenant_private.repair_status(text,uuid),public.mt_repair_status(text,uuid),tenant_private.repair_decide(text,uuid,uuid,boolean),public.mt_repair_decide(text,uuid,uuid,boolean) to authenticated;
grant execute on function tenant_private.repair_status(text,uuid),public.mt_repair_status(text,uuid),tenant_private.repair_decide(text,uuid,uuid,boolean),public.mt_repair_decide(text,uuid,uuid,boolean) to anon;
commit;
