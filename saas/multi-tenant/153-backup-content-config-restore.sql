-- 153: content comparison; allowlisted setting restoration; restrictive staff
-- restoration; design draft proposals approved by the existing design operator.
begin;
set local lock_timeout='5s';
alter table tenant_private.tenant_backup_archives
 add column table_digests jsonb check(table_digests is null or jsonb_typeof(table_digests)='object'),
 add column document_digests jsonb check(document_digests is null or jsonb_typeof(document_digests)='object');

create function tenant_private.tenant_backup_documents(t jsonb) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object(
 'storefront', (select jsonb_build_object('enabled',(x->>'enabled')::boolean,'delivery_enabled',(x->>'delivery_enabled')::boolean) from jsonb_array_elements(coalesce(t->'tenant_private.storefronts','[]')) x limit 1),
 'guest', (select jsonb_build_object('enabled',(x->>'enabled')::boolean) from jsonb_array_elements(coalesce(t->'tenant_private.guest_settings','[]')) x limit 1),
 'loyalty', (select jsonb_build_object('enabled',(x->>'enabled')::boolean,'points_required',(x->>'points_required')::integer,'basis_points',(x->>'basis_points')::integer) from jsonb_array_elements(coalesce(t->'tenant_private.loyalty_settings','[]')) x limit 1),
 'spend_loyalty', (select jsonb_build_object('enabled',(x->>'enabled')::boolean,'points_per_usd',(x->>'points_per_usd')::integer,'max_redeem_bps',(x->>'max_redeem_bps')::integer,'syp_per_usd_minor',(x->>'syp_per_usd_minor')::bigint,'eur_per_usd_minor',(x->>'eur_per_usd_minor')::bigint) from jsonb_array_elements(coalesce(t->'tenant_private.spend_loyalty_policy','[]')) x limit 1),
 'staff_restrictions', (select coalesce(jsonb_agg(jsonb_build_object('user_id',x->>'user_id','action',x->>'action') order by x->>'user_id',x->>'action'),'[]') from jsonb_array_elements(coalesce(t->'tenant_private.staff_denials','[]')) x),
 'design_draft', (select jsonb_build_object('theme',v->'theme') from jsonb_array_elements(coalesce(t->'tenant_private.design_heads','[]')) h join lateral jsonb_array_elements(coalesce(t->'tenant_private.design_versions','[]')) v on v->>'revision'=h->>'draft_revision' limit 1)
 )
$$;
create function tenant_private.tenant_backup_document_digests(doc jsonb) returns jsonb
language sql stable set search_path='' as $$
 select coalesce(jsonb_object_agg(k,tenant_private.finance_review_digest(v)),'{}') from jsonb_each(doc) x(k,v) where v<>'null'::jsonb
$$;
create function tenant_private.tenant_backup_live_documents(s uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select tenant_private.tenant_backup_documents(jsonb_build_object(
 'tenant_private.storefronts',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from tenant_private.storefronts r where store_id=s),
 'tenant_private.guest_settings',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from tenant_private.guest_settings r where store_id=s),
 'tenant_private.loyalty_settings',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from tenant_private.loyalty_settings r where store_id=s),
 'tenant_private.spend_loyalty_policy',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from tenant_private.spend_loyalty_policy r where store_id=s),
 'tenant_private.staff_denials',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from tenant_private.staff_denials r where store_id=s),
 'tenant_private.design_heads',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from tenant_private.design_heads r where store_id=s),
 'tenant_private.design_versions',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from tenant_private.design_versions r join tenant_private.design_heads h on h.store_id=r.store_id and h.draft_revision=r.revision where r.store_id=s)
 ))
$$;
revoke all on function tenant_private.tenant_backup_documents(jsonb),tenant_private.tenant_backup_document_digests(jsonb),tenant_private.tenant_backup_live_documents(uuid) from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_snapshot(s uuid, u uuid, bid uuid, fp text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rel text;data jsonb:='{}';part jsonb;n bigint;size_bytes bigint;total_bytes bigint:=0;total_rows bigint:=0;counts jsonb:='{}';digests jsonb:='{}';receipt jsonb;projection text;
begin
 if not tenant_private.tenant_backup_eligible(s,u) then raise exception 'Backup permission changed' using errcode='42501';end if;
 foreach rel in array tenant_private.tenant_backup_relations(2) loop
  projection:=case when rel='tenant_private.design_originals' then '(to_jsonb(r)-''public_fingerprint'')' else 'to_jsonb(r)' end;
  execute format('select count(*),coalesce(sum(octet_length((%s)::text)::bigint+2),0) from %I.%I r where r.store_id=$1',projection,split_part(rel,'.',1),split_part(rel,'.',2)) into n,size_bytes using s;
  if total_bytes+size_bytes>8000000 or total_rows+n>100000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  execute format('select coalesce(jsonb_agg(%s order by (%s)::text),''[]''::jsonb) from %I.%I r where r.store_id=$1',projection,projection,split_part(rel,'.',1),split_part(rel,'.',2)) into part using s;
  counts:=counts||jsonb_build_object(rel,n);digests:=digests||jsonb_build_object(rel,tenant_private.finance_review_digest(part));
  data:=data||jsonb_build_object(rel,part);total_bytes:=total_bytes+size_bytes;total_rows:=total_rows+n;
 end loop;
 receipt:=tenant_private.effective_receipt_settings(s);
 return jsonb_build_object('version',2,'scope','tenant_operational_archive','id',bid,'store',s,'captured_at',statement_timestamp(),'key_fingerprint',fp,'rows',total_rows,'relation_count',140,'table_counts',counts,'table_digests',digests,'restore_documents',tenant_private.tenant_backup_documents(data),'effective_receipt_settings',receipt,'configuration_evidence_only',to_jsonb(array['tenant_private.design_heads','tenant_private.design_versions','tenant_private.design_originals','tenant_private.storefronts','tenant_private.guest_settings','tenant_private.loyalty_settings','tenant_private.sales_settings','tenant_private.members','tenant_private.staff_profiles','tenant_private.staff_denials','tenant_private.staff_branch_scope','tenant_private.cashier_branch_scope','tenant_private.procurement_grants','tenant_private.receivable_grants','tenant_private.branch_fifo_enabled','tenant_private.branch_treasury_enabled']),'excluded_relations',to_jsonb(array['tenant_private.pos_loyalty_sales','tenant_private.spend_pos_redemptions']),'tables',data);
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '2s'
AS $function$
declare cfg tenant_private.tenant_backup_settings%rowtype;bid uuid:=gen_random_uuid();snapshot jsonb;plain text;encrypted bytea;retained bigint;status text:='error';
begin
 if not pg_try_advisory_xact_lock(894313,151) then return;end if;
 select * into cfg from tenant_private.tenant_backup_settings where enabled and next_due<=now() order by next_due,store_id limit 1 for update skip locked;
 if not found then return;end if;
 begin
  if not tenant_private.tenant_backup_eligible(cfg.store_id,cfg.configured_by) then raise exception 'Backup permission changed' using errcode='42501';end if;
  snapshot:=tenant_private.tenant_backup_snapshot(cfg.store_id,cfg.configured_by,bid,cfg.fingerprint);
  plain:=snapshot::text;
  if octet_length(plain)>8000000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  encrypted:=extensions.pgp_pub_encrypt(plain,cfg.public_key,'cipher-algo=aes256,compress-algo=0');
  if octet_length(encrypted)>9000000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  if not tenant_private.tenant_backup_eligible(cfg.store_id,cfg.configured_by) then raise exception 'Backup permission changed' using errcode='42501';end if;
  -- Keep the previous two snapshots plus the new one. Check global budget
  -- before committing; failed capture never prunes a previously saved archive.
  select coalesce(sum(a.bytes),0) into retained from tenant_private.tenant_backup_archives a
  where a.store_id<>cfg.store_id or a.id in (select b.id from tenant_private.tenant_backup_archives b where b.store_id=cfg.store_id order by b.captured_at desc,b.id limit 2);
  if retained+octet_length(encrypted)>64000000 then raise exception 'Archive quota exceeded' using errcode='54000';end if;
  insert into tenant_private.tenant_backup_archives(store_id,id,captured_at,key_fingerprint,relation_count,row_count,bytes,ciphertext,sha256,archive_version,plaintext_sha256,table_counts,receipt_digest,table_digests,document_digests)
  values(cfg.store_id,bid,(snapshot->>'captured_at')::timestamptz,cfg.fingerprint,(snapshot->>'relation_count')::int,(snapshot->>'rows')::bigint,octet_length(encrypted),encrypted,encode(sha256(encrypted),'hex'),2,encode(sha256(convert_to(plain,'UTF8')),'hex'),snapshot->'table_counts',tenant_private.finance_review_digest(snapshot->'effective_receipt_settings'),snapshot->'table_digests',tenant_private.tenant_backup_document_digests(snapshot->'restore_documents'));
  delete from tenant_private.tenant_backup_archives a where a.store_id=cfg.store_id and a.id not in (select b.id from tenant_private.tenant_backup_archives b where b.store_id=cfg.store_id order by b.captured_at desc,b.id limit 3);
  update tenant_private.tenant_backup_settings set last_attempt=clock_timestamp(),last_success=clock_timestamp(),last_status='saved',next_due=clock_timestamp()+interval '24 hours' where store_id=cfg.store_id;
 exception when others then
  status:=case sqlstate when '42501' then 'permission' when '54000' then 'capacity' else 'error' end;
  update tenant_private.tenant_backup_settings set last_attempt=clock_timestamp(),last_status=status,next_due=clock_timestamp()+case when status='error' then interval '1 hour' else interval '24 hours' end where store_id=cfg.store_id;
 end;
end $function$;
CREATE OR REPLACE FUNCTION tenant_private.tenant_backup_compare(s uuid, d uuid, secret uuid, bid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a tenant_private.tenant_backup_archives%rowtype;rel text;n bigint;counts jsonb:='{}';current_receipt jsonb;current_digest text;live_docs jsonb;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 select * into a from tenant_private.tenant_backup_archives where store_id=s and id=bid;
 if not found then raise exception 'Archive missing' using errcode='22023';end if;
 foreach rel in array tenant_private.tenant_backup_relations(a.archive_version) loop
  execute format('select count(*) from %I.%I r where r.store_id=$1',split_part(rel,'.',1),split_part(rel,'.',2)) into n using s;
  counts:=counts||jsonb_build_object(rel,n);
 end loop;
 live_docs:=tenant_private.tenant_backup_live_documents(s);
 current_receipt:=tenant_private.effective_receipt_settings(s);
 current_digest:=tenant_private.finance_review_digest(current_receipt);
 return jsonb_build_object('id',a.id,'store',s,'archive_version',a.archive_version,'captured_at',a.captured_at,'plaintext_sha256',a.plaintext_sha256,'saved_counts',a.table_counts,'current_counts',counts,'receipt_current_digest',current_digest,'receipt_saved_digest',a.receipt_digest,'receipt_restore_available',a.archive_version=2 and a.receipt_digest is not null and coalesce(tenant_private.can_write(s),false),'count_comparison_only',true,'saved_document_digests',a.document_digests,'current_document_digests',tenant_private.tenant_backup_document_digests(live_docs),'content_comparison_available',a.table_digests is not null);
end $function$;

-- Compare contents in a bounded consistent snapshot. Counts alone never prove equality.
create function tenant_private.tenant_backup_content_compare(s uuid,d uuid,secret uuid,bid uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare a tenant_private.tenant_backup_archives%rowtype;v jsonb;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 select * into a from tenant_private.tenant_backup_archives where store_id=s and id=bid;
 if not found or a.table_digests is null then raise exception 'New archive required' using errcode='22023';end if;
 v:=tenant_private.tenant_backup_snapshot(s,auth.uid(),bid,a.key_fingerprint);
 return jsonb_build_object('store',s,'id',bid,'relations',(select coalesce(jsonb_object_agg(k,jsonb_build_object('saved',a.table_counts->k,'current',v->'table_counts'->k,'same',a.table_digests->>k=v->'table_digests'->>k)),'{}') from jsonb_object_keys(a.table_digests) k));
end $$;

-- Existing owner writes are serialized on the store row; design edits also
-- lock the workspace. Restore grants never recreate accounts or lift denials.
create table tenant_private.tenant_backup_config_requests(
 store_id uuid not null references public.saas_stores(id),
 request_id uuid not null,archive_id uuid not null,actor uuid not null,device_id uuid not null,
 kind text not null check(kind in ('storefront','guest','loyalty','spend_loyalty','staff_restrictions','design_draft')),
 expected_digest text not null check(expected_digest ~ '^[0-9a-f]{64}$'),
 desired_digest text not null check(desired_digest ~ '^[0-9a-f]{64}$'),
 reason text not null check(length(btrim(reason)) between 5 and 500),
 state text not null check(state in ('confirmed','queued','cancelled','conflict')),
 created_at timestamptz not null default clock_timestamp(),
 finished_at timestamptz,finished_by uuid,
 design_theme jsonb,
 expected_draft bigint,expected_published bigint,
 primary key(store_id,request_id),
 check((state='queued')=(design_theme is not null))
);
alter table tenant_private.tenant_backup_config_requests enable row level security;
revoke all on tenant_private.tenant_backup_config_requests from public,anon,authenticated,service_role;
create unique index mt_backup_one_design_request on tenant_private.tenant_backup_config_requests(store_id) where state='queued';
create index mt_backup_config_history on tenant_private.tenant_backup_config_requests(store_id,created_at desc,request_id);

create function tenant_private.tenant_backup_config_restore(s uuid,d uuid,secret uuid,bid uuid,req uuid,k text,expected text,document jsonb,reason text) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $$
declare a tenant_private.tenant_backup_archives%rowtype;prev tenant_private.tenant_backup_config_requests%rowtype;live jsonb;before_hash text;desired text;h tenant_private.design_heads%rowtype;v jsonb;state_value text:='confirmed';n int:=0;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 if k is null or k not in ('storefront','guest','loyalty','spend_loyalty','staff_restrictions','design_draft') or bid is null or req is null or expected is null or expected !~ '^[a-f0-9]{64}$' or document is null or document='null'::jsonb or octet_length(document::text)>1000000 or reason is null or length(btrim(reason)) not between 5 and 500 then raise exception 'Invalid restore request' using errcode='22023';end if;
 perform tenant_private.owner_write(s);
 perform tenant_private.tenant_backup_require(s,d,secret);
 desired:=tenant_private.finance_review_digest(document);
 select * into prev from tenant_private.tenant_backup_config_requests where store_id=s and request_id=req;
 if found then
  if prev.actor<>auth.uid() or prev.device_id<>d or prev.archive_id<>bid or prev.kind<>k or prev.expected_digest<>expected or prev.desired_digest<>desired or prev.reason<>btrim(reason) then raise exception 'Request identity conflict' using errcode='22023';end if;
  return jsonb_build_object('requestId',req,'status',prev.state,'replayed',true);
 end if;
 select * into a from tenant_private.tenant_backup_archives where store_id=s and id=bid for share;
 if not found or a.document_digests->>k is distinct from desired then raise exception 'Document does not match archive' using errcode='22023';end if;
 if k='design_draft' then perform 1 from tenant_private.workspaces where store_id=s for update;end if;
 live:=tenant_private.tenant_backup_live_documents(s);
 before_hash:=tenant_private.finance_review_digest(coalesce(live->k,'null'::jsonb));
 if before_hash is distinct from expected then return jsonb_build_object('requestId',req,'status','conflict');end if;
 case k
 when 'storefront' then
  if tenant_private.central_action_denied(s,'storefront_enable') or tenant_private.central_action_denied(s,'delivery_enable') then raise exception 'Setting denied' using errcode='42501';end if;
  perform public.mt_storefront_enable(s,(document->>'enabled')::boolean);perform public.mt_delivery_enable(s,(document->>'delivery_enabled')::boolean);
 when 'guest' then
  if tenant_private.central_action_denied(s,'guest_enable') then raise exception 'Setting denied' using errcode='42501';end if;
  perform public.mt_guest_enable(s,(document->>'enabled')::boolean);
 when 'loyalty' then
  if tenant_private.central_action_denied(s,'loyalty_edit') then raise exception 'Setting denied' using errcode='42501';end if;
  perform public.mt_set_loyalty(s,(document->>'enabled')::boolean,(document->>'points_required')::integer,(document->>'basis_points')::integer);
 when 'spend_loyalty' then
  if tenant_private.central_action_denied(s,'loyalty_edit') then raise exception 'Setting denied' using errcode='42501';end if;
  perform public.mt_spend_loyalty_set(s,(document->>'enabled')::boolean,(document->>'points_per_usd')::integer,(document->>'max_redeem_bps')::integer,(document->>'syp_per_usd_minor')::bigint,(document->>'eur_per_usd_minor')::bigint);
 when 'staff_restrictions' then
  if jsonb_typeof(document)<>'array' or jsonb_array_length(document)>2000 then raise exception 'Restriction capacity' using errcode='22023';end if;
  -- Skip inactive, removed, promoted or centrally blocked accounts. Only add
  -- denials through the existing validator; never remove a current denial.
  for v in select value from jsonb_array_elements(document) loop
   if exists(select 1 from tenant_private.members m where m.store_id=s and m.user_id=(v->>'user_id')::uuid and m.active and m.role<>'owner') and not exists(select 1 from tenant_private.admin_member_holds b where b.store_id=s and b.user_id=(v->>'user_id')::uuid and b.blocked) then
    perform public.mt_staff_permission_set(s,(v->>'user_id')::uuid,v->>'action',false);n:=n+1;
   end if;
  end loop;
 when 'design_draft' then
  if not coalesce(tenant_private.valid_theme(document->'theme'),false) then raise exception 'Invalid archived theme' using errcode='22023';end if;
  select * into h from tenant_private.design_heads where store_id=s;
  state_value:='queued';
 end case;
 if k in ('storefront','guest','loyalty','spend_loyalty') and tenant_private.finance_review_digest(tenant_private.tenant_backup_live_documents(s)->k) is distinct from desired then raise exception 'Restoration not confirmed' using errcode='22023';end if;
 insert into tenant_private.tenant_backup_config_requests(store_id,request_id,archive_id,actor,device_id,kind,expected_digest,desired_digest,reason,state,finished_at,finished_by,design_theme,expected_draft,expected_published)
 values(s,req,bid,auth.uid(),d,k,expected,desired,btrim(reason),state_value,case when state_value='confirmed' then clock_timestamp() end,case when state_value='confirmed' then auth.uid() end,case when k='design_draft' then document->'theme' end,case when k='design_draft' then coalesce(h.draft_revision,0) end,case when k='design_draft' then coalesce(h.published_revision,0) end);
 return jsonb_build_object('requestId',req,'status',state_value,'restrictions_reviewed',n);
end $$;

create function tenant_private.tenant_backup_config_history(s uuid,d uuid,secret uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id) from (select request_id,archive_id,kind,state,reason,created_at,finished_at from tenant_private.tenant_backup_config_requests where store_id=s order by created_at desc,request_id limit 50) x),'[]');
end $$;

create function tenant_private.admin_backup_design_queue() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at,x.request_id) from (select r.store_id,s.name,r.request_id,r.archive_id,r.reason,r.created_at,r.expected_draft,r.expected_published from tenant_private.tenant_backup_config_requests r join public.saas_stores s on s.id=r.store_id where r.state='queued' order by r.created_at,r.request_id limit 50) x),'[]');
end $$;
create function tenant_private.admin_backup_design_decide(s uuid,req uuid,action text) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='1500ms' as $$
declare r tenant_private.tenant_backup_config_requests%rowtype;h tenant_private.design_heads%rowtype;outcome text;
begin
 if not coalesce(saas_private.is_operator(),false) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Operator AAL2 required' using errcode='42501';end if;
 if action is null or action not in ('approve','cancel') then raise exception 'Invalid decision' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=s for update;
 perform 1 from tenant_private.workspaces where store_id=s for update;
 select * into r from tenant_private.tenant_backup_config_requests where store_id=s and request_id=req and kind='design_draft' for update;
 if not found then raise exception 'Request missing' using errcode='22023';end if;
 if r.state<>'queued' then return jsonb_build_object('requestId',req,'status',r.state);end if;
 outcome:='cancelled';
 if action='approve' then
  select * into h from tenant_private.design_heads where store_id=s;
  if not tenant_private.tenant_backup_eligible(s,r.actor) or not exists(select 1 from tenant_private.offline_devices d where d.store_id=s and d.id=r.device_id and d.actor=r.actor and d.state='approved') or coalesce(h.draft_revision,0)<>r.expected_draft or coalesce(h.published_revision,0)<>r.expected_published or not exists(select 1 from tenant_private.tenant_backup_archives a where a.store_id=s and a.id=r.archive_id and a.document_digests->>'design_draft'=r.desired_digest) then outcome:='conflict';
  else perform tenant_private.design_change(s,r.expected_draft,r.expected_published,'save',r.design_theme,null);outcome:='confirmed';end if;
 end if;
 update tenant_private.tenant_backup_config_requests set state=outcome,design_theme=null,finished_at=clock_timestamp(),finished_by=auth.uid() where store_id=s and request_id=req;
 return jsonb_build_object('requestId',req,'status',outcome);
end $$;

-- Central intervention can queue an already consented encrypted backup or
-- pause it. Never enroll, replace keys, delete archives or decrypt.
create table tenant_private.admin_backup_actions(
 id uuid primary key default gen_random_uuid(),store_id uuid not null references public.saas_stores(id),actor uuid not null,action text not null check(action in ('pause','request')),reason text not null check(length(btrim(reason)) between 5 and 500),created_at timestamptz not null default now()
);
alter table tenant_private.admin_backup_actions enable row level security;
revoke all on tenant_private.admin_backup_actions from public,anon,authenticated,service_role;
create function tenant_private.admin_backup_control(s uuid,action text,reason text) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Operator AAL2 required' using errcode='42501';end if;
 if action is null or action not in ('pause','request') or reason is null or length(btrim(reason)) not between 5 and 500 then raise exception 'Explicit reason required' using errcode='22023';end if;
 if action='pause' then update tenant_private.tenant_backup_settings set enabled=false,last_status='paused',changed_at=now() where store_id=s and enabled;
 else update tenant_private.tenant_backup_settings set next_due=least(next_due,now()),last_status='queued' where store_id=s and enabled and tenant_private.tenant_backup_eligible(s,configured_by) and (last_attempt is null or last_attempt<=now()-interval '1 hour');end if;
 if not found then return false;end if;
 insert into tenant_private.admin_backup_actions(store_id,actor,action,reason) values(s,auth.uid(),action,btrim(reason));return true;
end $$;

create function public.mt_tenant_backup_content_compare(s uuid,d uuid,secret uuid,bid uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_content_compare(s,d,secret,bid)$$;
revoke all on function tenant_private.tenant_backup_content_compare(uuid,uuid,uuid,uuid),public.mt_tenant_backup_content_compare(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_content_compare(uuid,uuid,uuid,uuid),public.mt_tenant_backup_content_compare(uuid,uuid,uuid,uuid) to authenticated;
create function public.mt_tenant_backup_config_restore(s uuid,d uuid,secret uuid,bid uuid,req uuid,k text,expected text,document jsonb,reason text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_config_restore(s,d,secret,bid,req,k,expected,document,reason)$$;
revoke all on function tenant_private.tenant_backup_config_restore(uuid,uuid,uuid,uuid,uuid,text,text,jsonb,text),public.mt_tenant_backup_config_restore(uuid,uuid,uuid,uuid,uuid,text,text,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_config_restore(uuid,uuid,uuid,uuid,uuid,text,text,jsonb,text),public.mt_tenant_backup_config_restore(uuid,uuid,uuid,uuid,uuid,text,text,jsonb,text) to authenticated;
create function public.mt_tenant_backup_config_history(s uuid,d uuid,secret uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_config_history(s,d,secret)$$;
revoke all on function tenant_private.tenant_backup_config_history(uuid,uuid,uuid),public.mt_tenant_backup_config_history(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_config_history(uuid,uuid,uuid),public.mt_tenant_backup_config_history(uuid,uuid,uuid) to authenticated;
create function public.mt_admin_backup_design_queue() returns jsonb language sql security invoker set search_path='' as $$select tenant_private.admin_backup_design_queue()$$;
revoke all on function tenant_private.admin_backup_design_queue(),public.mt_admin_backup_design_queue() from public,anon,authenticated,service_role;
grant execute on function tenant_private.admin_backup_design_queue(),public.mt_admin_backup_design_queue() to authenticated;
create function public.mt_admin_backup_design_decide(s uuid,req uuid,action text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.admin_backup_design_decide(s,req,action)$$;
revoke all on function tenant_private.admin_backup_design_decide(uuid,uuid,text),public.mt_admin_backup_design_decide(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.admin_backup_design_decide(uuid,uuid,text),public.mt_admin_backup_design_decide(uuid,uuid,text) to authenticated;
create function public.mt_admin_backup_control(s uuid,action text,reason text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.admin_backup_control(s,action,reason)$$;
revoke all on function tenant_private.admin_backup_control(uuid,text,text),public.mt_admin_backup_control(uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.admin_backup_control(uuid,text,text),public.mt_admin_backup_control(uuid,text,text) to authenticated;
commit;
