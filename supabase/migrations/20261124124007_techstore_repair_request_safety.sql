begin;
alter table public.ts_repair_evidence add column request_id uuid unique;
create or replace function techstore_private.repair_evidence(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u public.ts_profiles%rowtype; w public.ts_workspace%rowtype; ticket jsonb; rid text; k text; image_value text; note_value text; prod jsonb; pid text; ix int; q int; cost numeric; data jsonb; item public.ts_repair_evidence%rowtype; is_staff boolean; request_value uuid;
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
 request_value:=(p_args->>'request_id')::uuid;if request_value is null then raise exception 'Request ID required';end if;
 select * into item from public.ts_repair_evidence where request_id=request_value;
 if found then if item.actor<>u.user_id or item.repair_id<>rid or item.kind is distinct from k then raise exception 'Request ID conflict';end if;return jsonb_build_object('id',item.id,'kind',item.kind,'duplicate',true);end if;
 if k='approval' then
 if u.role<>'customer' or ticket->>'customerId' is distinct from u.user_id::text or ticket->>'status' is distinct from 'approval' then raise exception 'Approval unavailable' using errcode='42501';end if;
 if (p_args->>'expected_estimate')::numeric is distinct from coalesce((ticket->>'estimate')::numeric,0) then raise exception 'Estimate changed; reload the ticket';end if;
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
 insert into public.ts_repair_evidence(repair_id,actor,kind,image,notes,product_id,qty,unit_cost,request_id) values(rid,u.user_id,k,image_value,note_value,pid,q,cost,request_value) returning * into item;
 insert into public.ts_audit(actor,action) values(u.user_id,'repair evidence '||k||' '||rid);
 return jsonb_build_object('id',item.id,'kind',item.kind);
end $$;

commit;