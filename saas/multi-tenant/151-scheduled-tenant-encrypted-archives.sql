-- 151: bounded scheduled tenant operational archives encrypted to owner-held OpenPGP keys.
-- Deliberately separate from whole-shard recovery. No business rows are changed.
begin;
set local lock_timeout='5s';
create extension if not exists pg_cron;

create table tenant_private.tenant_backup_keys(
 store_id uuid primary key references public.saas_stores(id),
 proposal_id uuid not null unique,
 actor uuid not null,
 public_key bytea not null check(octet_length(public_key) between 32 and 16384),
 fingerprint text not null check(fingerprint ~ '^[0-9a-f]{64}$'),
 proof_hash text not null check(proof_hash ~ '^[0-9a-f]{64}$'),
 expires_at timestamptz not null
);
create table tenant_private.tenant_backup_settings(
 store_id uuid primary key references public.saas_stores(id),
 configured_by uuid not null,
 public_key bytea not null check(octet_length(public_key) between 32 and 16384),
 fingerprint text not null check(fingerprint ~ '^[0-9a-f]{64}$'),
 enabled boolean not null default true,
 next_due timestamptz not null,
 changed_at timestamptz not null default now(),
 last_attempt timestamptz,
 last_success timestamptz,
 last_status text not null default 'queued' check(last_status in ('queued','saved','permission','capacity','error','paused'))
);
create index mt_tenant_backup_due on tenant_private.tenant_backup_settings(next_due,store_id) where enabled;
create table tenant_private.tenant_backup_archives(
 store_id uuid not null references public.saas_stores(id),
 id uuid not null,
 captured_at timestamptz not null,
 key_fingerprint text not null check(key_fingerprint ~ '^[0-9a-f]{64}$'),
 relation_count integer not null check(relation_count>0),
 row_count bigint not null check(row_count>=0),
 bytes integer not null check(bytes between 1 and 9000000),
 ciphertext bytea not null check(octet_length(ciphertext)=bytes),
 sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
 primary key(store_id,id)
);
create index mt_tenant_backup_history on tenant_private.tenant_backup_archives(store_id,captured_at desc,id);
alter table tenant_private.tenant_backup_keys enable row level security;
alter table tenant_private.tenant_backup_settings enable row level security;
alter table tenant_private.tenant_backup_archives enable row level security;
revoke all on tenant_private.tenant_backup_keys,tenant_private.tenant_backup_settings,tenant_private.tenant_backup_archives from public,anon,authenticated,service_role;

create function tenant_private.tenant_backup_eligible(s uuid,u uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.shared_licensed(s),false)
 and exists(select 1 from tenant_private.members m join auth.users a on a.id=m.user_id where m.store_id=s and m.user_id=u and m.active and m.role='owner' and not a.is_anonymous and not exists(select 1 from tenant_private.admin_member_holds h where h.store_id=s and h.user_id=u and h.blocked))
 and exists(select 1 from auth.mfa_factors f where f.user_id=u and f.factor_type::text='totp' and f.status::text='verified')
 and not exists(select 1 from unnest(array['all_catalog_read','all_sales_read','all_purchase_read','all_customer_read','all_debt_read','all_repair_read','all_returns_read','all_order_read','all_warranty_read','all_finance_read','all_supplier_read','all_coupon_read']) a(action) where tenant_private.central_action_denied(s,a.action))
$$;
create function tenant_private.tenant_backup_require(s uuid,d uuid,secret uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.offline_records_authorize(s,d,secret);
 if not tenant_private.tenant_backup_eligible(s,auth.uid()) then raise exception 'Authorized MFA owner required' using errcode='42501';end if;
end $$;

-- The server receives only an encryption public key. Possession of the matching
-- private key must be proved by decrypting a random challenge outside the app.
create function tenant_private.tenant_backup_propose(s uuid,d uuid,secret uuid,public_armor text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare k bytea;challenge text;encrypted bytea;proposal uuid:=gen_random_uuid();fp text;until_at timestamptz:=clock_timestamp()+interval '30 minutes';
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 if public_armor is null or octet_length(public_armor)>24000 or left(btrim(public_armor),36) is distinct from '-----BEGIN PGP PUBLIC KEY BLOCK-----' or right(btrim(public_armor),34) is distinct from '-----END PGP PUBLIC KEY BLOCK-----' or public_armor like '%PRIVATE KEY%' then raise exception 'Public encryption key only' using errcode='22023';end if;
 k:=extensions.dearmor(public_armor);
 if octet_length(k) not between 32 and 16384 then raise exception 'Unsupported key size' using errcode='22023';end if;
 fp:=encode(sha256(k),'hex');challenge:=encode(extensions.gen_random_bytes(32),'hex');
 encrypted:=extensions.pgp_pub_encrypt(challenge,k,'cipher-algo=aes256,compress-algo=0');
 insert into tenant_private.tenant_backup_keys(store_id,proposal_id,actor,public_key,fingerprint,proof_hash,expires_at)
 values(s,proposal,auth.uid(),k,fp,encode(sha256(convert_to(challenge,'UTF8')),'hex'),until_at)
 on conflict(store_id) do update set proposal_id=excluded.proposal_id,actor=excluded.actor,public_key=excluded.public_key,fingerprint=excluded.fingerprint,proof_hash=excluded.proof_hash,expires_at=excluded.expires_at;
 return jsonb_build_object('proposal',proposal,'fingerprint',fp,'expires_at',until_at,'challenge',encode(encrypted,'base64'));
end $$;
create function tenant_private.tenant_backup_activate(s uuid,d uuid,secret uuid,proposal uuid,proof text) returns boolean
language plpgsql security definer set search_path='' as $$
declare k tenant_private.tenant_backup_keys%rowtype;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 if proposal is null or proof is null or proof !~ '^[0-9a-f]{64}$' then raise exception 'Invalid challenge proof' using errcode='22023';end if;
 select * into k from tenant_private.tenant_backup_keys where store_id=s and proposal_id=proposal and actor=auth.uid() and expires_at>now() for update;
 if not found or k.proof_hash is distinct from encode(sha256(convert_to(proof,'UTF8')),'hex') then raise exception 'Key possession not confirmed' using errcode='22023';end if;
 perform pg_advisory_xact_lock(894313,151);
 if not exists(select 1 from tenant_private.tenant_backup_settings where store_id=s and enabled) and (select count(*) from tenant_private.tenant_backup_settings where enabled)>=32 then raise exception 'Scheduled backup capacity reached' using errcode='22023';end if;
 insert into tenant_private.tenant_backup_settings(store_id,configured_by,public_key,fingerprint,enabled,next_due)
 values(s,auth.uid(),k.public_key,k.fingerprint,true,clock_timestamp())
 on conflict(store_id) do update set configured_by=excluded.configured_by,public_key=excluded.public_key,fingerprint=excluded.fingerprint,enabled=true,next_due=excluded.next_due,changed_at=clock_timestamp(),last_status='queued';
 delete from tenant_private.tenant_backup_keys where store_id=s and proposal_id=proposal;
 return true;
end $$;
create function tenant_private.tenant_backup_control(s uuid,d uuid,secret uuid,action text) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 if action is null or action not in ('pause','request') then raise exception 'Invalid backup action' using errcode='22023';end if;
 if action='pause' then
  update tenant_private.tenant_backup_settings set enabled=false,last_status='paused',changed_at=now() where store_id=s;
 else
  update tenant_private.tenant_backup_settings set next_due=least(next_due,now()),last_status='queued' where store_id=s and enabled and configured_by=auth.uid() and (last_attempt is null or last_attempt<=now()-interval '1 hour');
 end if;
 return found;
end $$;

-- All reads inside this STABLE function share the calling statement's MVCC
-- snapshot. Fixed relation allowlist, no caller-provided SQL or table names.
-- Exclude credentials, auth sessions, live tokens, central platform tables and
-- storage object bytes. The archive is NOT a complete database restore image.
create function tenant_private.tenant_backup_snapshot(s uuid,u uuid,bid uuid,fp text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rel text;data jsonb:='{}';part jsonb;n bigint;size_bytes bigint;total_bytes bigint:=0;total_rows bigint:=0;
begin
 if not tenant_private.tenant_backup_eligible(s,u) then raise exception 'Backup permission changed' using errcode='42501';end if;
 foreach rel in array array['public.mt_accounting_adjustments','public.mt_cash_movements','public.mt_cash_receipts','public.mt_coupons','public.mt_customers','public.mt_debt_payments','public.mt_debts','public.mt_fx_rates','public.mt_indirect_tax_entries','public.mt_installments','public.mt_mixed_sales','public.mt_mixed_tenders','public.mt_online_orders','public.mt_payment_allocations','public.mt_period_closes','public.mt_product_prices','public.mt_products','public.mt_purchase_batches','public.mt_purchases','public.mt_repair_events','public.mt_repair_invoice_lines','public.mt_repair_invoices','public.mt_repair_refunds','public.mt_repairs','public.mt_return_allocations','public.mt_returns','public.mt_sale_lines','public.mt_sales','public.mt_stock_events','public.mt_supplier_payments','public.mt_supplier_returns','public.mt_suppliers','public.mt_warranty_claims','public.mt_warranty_events','public.mt_warranty_parts','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.branch_batches','tenant_private.branch_cash_accounts','tenant_private.branch_cash_attribution','tenant_private.branch_cash_transfers','tenant_private.branch_expense_allocations','tenant_private.branch_fifo_lots','tenant_private.branch_fifo_moves','tenant_private.branch_opening_anchors','tenant_private.branch_opening_checks','tenant_private.branch_purchases','tenant_private.branch_repairs','tenant_private.branch_result_approvals','tenant_private.branch_sales','tenant_private.branch_stock','tenant_private.branch_transfers','tenant_private.branch_vouchers','tenant_private.branches','tenant_private.buyer_price_terms','tenant_private.buyer_product_prices','tenant_private.cash_balances','tenant_private.cost_intakes','tenant_private.cost_postings','tenant_private.customer_profile_edits','tenant_private.guest_orders','tenant_private.local_customer_prices','tenant_private.local_membership_sales','tenant_private.local_membership_terms','tenant_private.marketing_campaigns','tenant_private.membership_directory','tenant_private.membership_rates','tenant_private.opening_debt_equity','tenant_private.order_discounts','tenant_private.order_reservations','tenant_private.price_quotes','tenant_private.procurement_requests','tenant_private.product_originals','tenant_private.product_tier_prices','tenant_private.receipt_settings','tenant_private.receipt_snapshots','tenant_private.repair_assignments','tenant_private.repair_estimates','tenant_private.repair_paper_decisions','tenant_private.repair_tasks','tenant_private.return_cost_postings','tenant_private.sale_currencies','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.shop_order_confirmations','tenant_private.shop_order_history','tenant_private.shop_order_items','tenant_private.spend_checkout','tenant_private.spend_loyalty_policy','tenant_private.spend_loyalty_sales','tenant_private.staff_advance_offsets','tenant_private.staff_advances','tenant_private.staff_payroll','tenant_private.staff_payroll_adjustments','tenant_private.staff_payroll_disbursements','tenant_private.staff_payroll_finalizations','tenant_private.staff_payroll_reversals','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.standalone_debt_payments','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_payment_allocations','tenant_private.stock_consumptions','tenant_private.stock_count_cancellations','tenant_private.stock_count_lines','tenant_private.stock_counts','tenant_private.stock_layers','tenant_private.storefront_products','tenant_private.sy_tax_credit_allocations','tenant_private.sy_tax_credit_events','tenant_private.sy_tax_filing_evidence','tenant_private.sy_tax_input_events','tenant_private.sy_tax_inventory_moves','tenant_private.sy_tax_inventory_parts','tenant_private.sy_tax_inventory_releases','tenant_private.sy_tax_inventory_returns','tenant_private.sy_tax_mixed_parts','tenant_private.sy_tax_output','tenant_private.sy_tax_profiles','tenant_private.sy_tax_supplier_return_actions','tenant_private.tradein_estimates','tenant_private.tradein_settlements'] loop
  execute format('select count(*),coalesce(sum(octet_length(to_jsonb(r)::text)::bigint+2),0) from %I.%I r where r.store_id=$1',split_part(rel,'.',1),split_part(rel,'.',2)) into n,size_bytes using s;
  if total_bytes+size_bytes>8000000 or total_rows+n>100000 then raise exception 'Archive capacity exceeded' using errcode='54000';end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) from %I.%I r where r.store_id=$1',split_part(rel,'.',1),split_part(rel,'.',2)) into part using s;
  data:=data||jsonb_build_object(rel,part);total_bytes:=total_bytes+size_bytes;total_rows:=total_rows+n;
 end loop;
 return jsonb_build_object('version',1,'scope','tenant_operational_archive','id',bid,'store',s,'captured_at',statement_timestamp(),'key_fingerprint',fp,'rows',total_rows,'relation_count',124,'excluded_relations',to_jsonb(array['tenant_private.pos_loyalty_sales','tenant_private.spend_pos_redemptions']),'tables',data);
end $$;

create function tenant_private.tenant_backup_tick() returns void
language plpgsql security definer set search_path='' set lock_timeout='2s' as $$
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
  insert into tenant_private.tenant_backup_archives(store_id,id,captured_at,key_fingerprint,relation_count,row_count,bytes,ciphertext,sha256)
  values(cfg.store_id,bid,(snapshot->>'captured_at')::timestamptz,cfg.fingerprint,(snapshot->>'relation_count')::int,(snapshot->>'rows')::bigint,octet_length(encrypted),encrypted,encode(sha256(encrypted),'hex'));
  delete from tenant_private.tenant_backup_archives a where a.store_id=cfg.store_id and a.id not in (select b.id from tenant_private.tenant_backup_archives b where b.store_id=cfg.store_id order by b.captured_at desc,b.id limit 3);
  update tenant_private.tenant_backup_settings set last_attempt=clock_timestamp(),last_success=clock_timestamp(),last_status='saved',next_due=clock_timestamp()+interval '24 hours' where store_id=cfg.store_id;
 exception when others then
  status:=case sqlstate when '42501' then 'permission' when '54000' then 'capacity' else 'error' end;
  update tenant_private.tenant_backup_settings set last_attempt=clock_timestamp(),last_status=status,next_due=clock_timestamp()+case when status='error' then interval '1 hour' else interval '24 hours' end where store_id=cfg.store_id;
 end;
end $$;

create function tenant_private.tenant_backup_overview(s uuid,d uuid,secret uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 return jsonb_build_object('store',s,'settings',(select jsonb_build_object('enabled',v.enabled,'fingerprint',v.fingerprint,'configured_by',v.configured_by,'next_due',v.next_due,'last_attempt',v.last_attempt,'last_success',v.last_success,'last_status',v.last_status) from tenant_private.tenant_backup_settings v where v.store_id=s),
 'pending',(select jsonb_build_object('proposal',k.proposal_id,'fingerprint',k.fingerprint,'expires_at',k.expires_at) from tenant_private.tenant_backup_keys k where k.store_id=s and k.actor=auth.uid() and k.expires_at>now()),
 'archives',coalesce((select jsonb_agg(to_jsonb(a) order by a.captured_at desc,a.id) from (select id,captured_at,key_fingerprint,relation_count,row_count,bytes,sha256 from tenant_private.tenant_backup_archives where store_id=s order by captured_at desc,id limit 3) a),'[]'::jsonb));
end $$;
create function tenant_private.tenant_backup_chunk(s uuid,d uuid,secret uuid,bid uuid,start_at integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a tenant_private.tenant_backup_archives%rowtype;part bytea;
begin
 perform tenant_private.tenant_backup_require(s,d,secret);
 if bid is null or start_at is null or start_at<0 or start_at%49152<>0 then raise exception 'Invalid archive offset' using errcode='22023';end if;
 select * into a from tenant_private.tenant_backup_archives where store_id=s and id=bid;
 if not found or start_at>=a.bytes then raise exception 'Archive not found or expired' using errcode='22023';end if;
 part:=substring(a.ciphertext from start_at+1 for 49152);
 return jsonb_build_object('id',bid,'store',s,'offset',start_at,'bytes',a.bytes,'sha256',a.sha256,'data',encode(part,'base64'));
end $$;
revoke all on function tenant_private.tenant_backup_eligible(uuid,uuid),tenant_private.tenant_backup_require(uuid,uuid,uuid),tenant_private.tenant_backup_snapshot(uuid,uuid,uuid,text),tenant_private.tenant_backup_tick() from public,anon,authenticated,service_role;

create function public.mt_tenant_backup_propose(s uuid,d uuid,secret uuid,public_armor text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_propose(s,d,secret,public_armor)$$;
revoke all on function tenant_private.tenant_backup_propose(uuid,uuid,uuid,text),public.mt_tenant_backup_propose(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_propose(uuid,uuid,uuid,text),public.mt_tenant_backup_propose(uuid,uuid,uuid,text) to authenticated;
create function public.mt_tenant_backup_activate(s uuid,d uuid,secret uuid,proposal uuid,proof text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_activate(s,d,secret,proposal,proof)$$;
revoke all on function tenant_private.tenant_backup_activate(uuid,uuid,uuid,uuid,text),public.mt_tenant_backup_activate(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_activate(uuid,uuid,uuid,uuid,text),public.mt_tenant_backup_activate(uuid,uuid,uuid,uuid,text) to authenticated;
create function public.mt_tenant_backup_control(s uuid,d uuid,secret uuid,action text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_control(s,d,secret,action)$$;
revoke all on function tenant_private.tenant_backup_control(uuid,uuid,uuid,text),public.mt_tenant_backup_control(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_control(uuid,uuid,uuid,text),public.mt_tenant_backup_control(uuid,uuid,uuid,text) to authenticated;
create function public.mt_tenant_backup_overview(s uuid,d uuid,secret uuid) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_overview(s,d,secret)$$;
revoke all on function tenant_private.tenant_backup_overview(uuid,uuid,uuid),public.mt_tenant_backup_overview(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_overview(uuid,uuid,uuid),public.mt_tenant_backup_overview(uuid,uuid,uuid) to authenticated;
create function public.mt_tenant_backup_chunk(s uuid,d uuid,secret uuid,bid uuid,start_at integer) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.tenant_backup_chunk(s,d,secret,bid,start_at)$$;
revoke all on function tenant_private.tenant_backup_chunk(uuid,uuid,uuid,uuid,integer),public.mt_tenant_backup_chunk(uuid,uuid,uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.tenant_backup_chunk(uuid,uuid,uuid,uuid,integer),public.mt_tenant_backup_chunk(uuid,uuid,uuid,uuid,integer) to authenticated;
-- No shops are enrolled automatically. The job is dormant until an owner
-- proves possession of a private encryption key. One due shop per invocation.
select cron.schedule('techstore-tenant-encrypted-backup','*/15 * * * *','select tenant_private.tenant_backup_tick()');
commit;
