begin;
create function techstore_private.protect_branch_stock() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='ts_workspace' then
 if exists(select 1 from public.ts_branch_stock s where s.qty>0 and not exists(select 1 from jsonb_array_elements(coalesce(new.payload->'data'->'products','[]'::jsonb)) p where p->>'id'=s.product_id)) then raise exception 'Product still has branch stock';end if;
 elsif new.archived and not old.archived and old.kind='branches' and exists(select 1 from public.ts_branch_stock where branch_id=old.id and qty>0) then raise exception 'Branch still has stock';
 end if;
 return new;
end $$;
revoke all on function techstore_private.protect_branch_stock() from public,anon,authenticated;
create trigger ts_workspace_branch_guard before update of payload on public.ts_workspace for each row execute function techstore_private.protect_branch_stock();
create trigger ts_branch_archive_guard before update of archived on public.ts_pro_entries for each row execute function techstore_private.protect_branch_stock();
create table public.ts_repair_evidence(
 id uuid primary key default gen_random_uuid(),
 repair_id text not null check(length(repair_id) between 1 and 100),
 actor uuid not null references public.ts_profiles(user_id),
 kind text not null check(kind in ('before','after','approval','part')),
 image text not null default '' check(image='' or (octet_length(image)<=180000 and image ~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$')),
 notes text not null default '' check(length(notes)<=500),
 product_id text, qty integer check(qty is null or qty between 1 and 1000000),
 unit_cost numeric(18,4) check(unit_cost is null or unit_cost>=0),
 created_at timestamptz not null default now()
);
create index ts_repair_evidence_ticket_idx on public.ts_repair_evidence(repair_id,created_at);
alter table public.ts_repair_evidence enable row level security;
revoke all on public.ts_repair_evidence from public,anon,authenticated;
create unique index ts_repair_approval_unique on public.ts_repair_evidence(repair_id,actor) where kind='approval';
create function techstore_private.repair_evidence(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; ticket jsonb; rid text; k text; image_value text; note_value text; prod jsonb; pid text; ix int; q int; cost numeric; data jsonb; item public.ts_repair_evidence%rowtype; is_staff boolean;
begin
 if not techstore_private.live_session() then raise exception 'Access denied' using errcode='42501';end if;
 select * into u from public.ts_profiles where user_id=auth.uid() and active;
 if not found then raise exception 'Access denied' using errcode='42501';end if;
 is_staff:=u.role in ('admin','tech','cashier');
 select * into w from public.ts_workspace where id=1 for update;
 rid:=p_args->>'repair_id';
 if p_action='tickets' then return coalesce((select jsonb_agg(jsonb_build_object('id',r->>'id','device',r->>'device','status',r->>'status','estimate',r->>'estimate')) from jsonb_array_elements(coalesce(w.payload->'records'->'repairs','[]'::jsonb)) r where is_staff or r->>'customerId'=u.user_id::text),'[]'::jsonb);end if;
 select r into ticket from jsonb_array_elements(coalesce(w.payload->'records'->'repairs','[]'::jsonb)) r where r->>'id'=rid;
 if ticket is null or (not is_staff and ticket->>'customerId' is distinct from u.user_id::text) then raise exception 'Ticket unavailable' using errcode='42501';end if;
 if p_action='list' then return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'kind',e.kind,'image',e.image,'notes',e.notes,'product_id',e.product_id,'qty',e.qty,'created_at',e.created_at)||case when u.role='admin' then jsonb_build_object('unit_cost',e.unit_cost) else '{}'::jsonb end order by e.created_at) from public.ts_repair_evidence e where e.repair_id=rid and (is_staff or e.kind in ('before','after','approval'))),'[]'::jsonb);end if;
 k:=p_args->>'kind';note_value:=left(coalesce(p_args->>'notes',''),500);image_value:=coalesce(p_args->>'image','');
 if p_action<>'add' then raise exception 'Invalid action';end if;
 if k='approval' then
 if u.role<>'customer' or ticket->>'customerId' is distinct from u.user_id::text or ticket->>'status' is distinct from 'approval' then raise exception 'Approval unavailable' using errcode='42501';end if;
 note_value:='Customer approved estimate USD '||coalesce(ticket->>'estimate','0');image_value:='';
 elsif k in ('before','after') then
 if u.role not in ('admin','tech') or image_value='' then raise exception 'Photo not allowed' using errcode='42501';end if;
 if (select count(*) from public.ts_repair_evidence where repair_id=rid and kind in ('before','after'))>=12 then raise exception 'Maximum 12 photos';end if;
 elsif k='part' then
 if u.role not in ('admin','tech') then raise exception 'Access denied' using errcode='42501';end if;
 pid:=p_args->>'product_id';q:=(p_args->>'qty')::int;
 data:=w.payload->'data';select p,ord::int-1 into prod,ix from jsonb_array_elements(coalesce(data->'products','[]'::jsonb)) with ordinality a(p,ord) where p->>'id'=pid;
 if prod is null or q is null or q<1 or q>1000000 or (prod->>'qty')::int<q then raise exception 'Insufficient stock';end if;
 if ticket->>'status' in ('delivered','cancelled') then raise exception 'Closed ticket';end if;
 cost:=(prod->>'cost')::numeric;note_value:=left(coalesce(prod->>'name','')||' — '||note_value,500);image_value:='';
 data:=jsonb_set(data,array['products',ix::text,'qty'],to_jsonb((prod->>'qty')::int-q));
 update public.ts_workspace set payload=jsonb_set(w.payload,'{data}',data),revision=revision+1,updated_at=now() where id=1;
 else raise exception 'Invalid evidence type';end if;
 insert into public.ts_repair_evidence(repair_id,actor,kind,image,notes,product_id,qty,unit_cost) values(rid,u.user_id,k,image_value,note_value,pid,q,cost) returning * into item;
 insert into public.ts_audit(actor,action) values(u.user_id,'repair evidence '||k||' '||rid);
 return jsonb_build_object('id',item.id,'kind',item.kind);
end $$;
revoke all on function techstore_private.repair_evidence(text,jsonb) from public,anon;
grant execute on function techstore_private.repair_evidence(text,jsonb) to authenticated;
create function public.ts_repair_evidence_action(p_action text,p_args jsonb) returns jsonb language sql security invoker set search_path='' as $$ select techstore_private.repair_evidence(p_action,p_args); $$;
revoke all on function public.ts_repair_evidence_action(text,jsonb) from public,anon;
grant execute on function public.ts_repair_evidence_action(text,jsonb) to authenticated;
commit;