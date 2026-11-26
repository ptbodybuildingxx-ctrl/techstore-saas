-- Immutable receipt identity at issuance. No fabricated historical backfill.
begin;
create table tenant_private.receipt_settings(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 settings jsonb not null,updated_at timestamptz not null default now(),actor uuid not null
);
create table tenant_private.receipt_snapshots(
 store_id uuid not null references tenant_private.workspaces(store_id),
 kind text not null check(kind in ('sale','repair')),document_id uuid not null,
 settings jsonb not null,created_at timestamptz not null default now(),
 primary key(store_id,kind,document_id)
);
alter table tenant_private.receipt_settings enable row level security;
alter table tenant_private.receipt_snapshots enable row level security;
revoke all on tenant_private.receipt_settings,tenant_private.receipt_snapshots from public,anon,authenticated,service_role;
create function tenant_private.valid_receipt_settings(v jsonb) returns boolean language plpgsql immutable set search_path='' as $$
begin
 if v is null or jsonb_typeof(v)<>'object' then return false;end if;
 return (select count(*)=8 and coalesce(bool_and(jsonb_typeof(value)='string' and case key when 'brand' then length(btrim(value#>>'{}')) between 1 and 80 when 'phone' then length(value#>>'{}')<=60 when 'address' then length(value#>>'{}')<=300 when 'sale_title' then length(btrim(value#>>'{}')) between 1 and 80 when 'repair_title' then length(btrim(value#>>'{}')) between 1 and 80 when 'footer' then length(value#>>'{}')<=200 when 'format' then value#>>'{}' in ('a4','thermal') when 'logo' then value#>>'{}'='' or (length(value#>>'{}')<=22000 and length(value#>>'{}')%4=0 and value#>>'{}'~'^iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$') else false end),false) from jsonb_each(v));
end $$;
alter table tenant_private.receipt_settings add check(tenant_private.valid_receipt_settings(settings));
alter table tenant_private.receipt_snapshots add check(tenant_private.valid_receipt_settings(settings));
create function tenant_private.effective_receipt_settings(p_store uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(r.settings,jsonb_build_object('brand',coalesce(v.theme->>'brand',s.name),'phone','','address','','sale_title',coalesce(v.theme->>'invoice_title','إيصال بيع'),'repair_title','إيصال صيانة','footer',coalesce(v.theme->>'invoice_footer','شكراً لتسوقكم معنا'),'format',coalesce(v.theme->>'invoice_format','a4'),'logo',coalesce(v.theme->>'logo','')))
 from public.saas_stores s left join tenant_private.receipt_settings r on r.store_id=s.id left join tenant_private.design_heads h on h.store_id=s.id left join tenant_private.design_versions v on v.store_id=h.store_id and v.revision=h.published_revision where s.id=p_store
$$;
create function tenant_private.receipt_config(p_store uuid,p_settings jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_settings is not null then
  if not coalesce(tenant_private.can_write(p_store),false) then raise exception 'Write denied' using errcode='42501';end if;
  if not tenant_private.valid_receipt_settings(p_settings) then raise exception 'Invalid receipt settings' using errcode='22023';end if;
  perform 1 from public.saas_stores where id=p_store for update;
  insert into tenant_private.receipt_settings(store_id,settings,actor) values(p_store,p_settings,auth.uid()) on conflict(store_id) do update set settings=excluded.settings,actor=excluded.actor,updated_at=now();
 end if;
 return tenant_private.effective_receipt_settings(p_store);
end $$;
create function tenant_private.snapshot_receipt() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into tenant_private.receipt_snapshots(store_id,kind,document_id,settings) values(new.store_id,case when tg_table_name='mt_sales' then 'sale' else 'repair' end,new.id,tenant_private.effective_receipt_settings(new.store_id));
 return new;
end $$;
create trigger mt_sale_receipt_snapshot after insert on public.mt_sales for each row execute function tenant_private.snapshot_receipt();
create trigger mt_repair_receipt_snapshot after insert on public.mt_repair_invoices for each row execute function tenant_private.snapshot_receipt();
create function tenant_private.receipt_snapshot(p_store uuid,p_kind text,p_document uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);v jsonb;
begin
 if p_kind='sale' then
  if not exists(select 1 from public.mt_sales s where s.store_id=p_store and s.id=p_document and (role_now='owner' or (role_now='cashier' and s.actor=auth.uid()))) then raise exception 'Receipt access denied' using errcode='42501';end if;
 elsif p_kind='repair' then
  if role_now is distinct from 'owner' or not exists(select 1 from public.mt_repair_invoices where store_id=p_store and id=p_document) then raise exception 'Receipt access denied' using errcode='42501';end if;
 else raise exception 'Invalid receipt kind' using errcode='22023';end if;
 select settings into v from tenant_private.receipt_snapshots where store_id=p_store and kind=p_kind and document_id=p_document;
 return v;
end $$;
create function public.mt_receipt_config(p_store uuid,p_settings jsonb default null) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.receipt_config(p_store,p_settings)$$;
create function public.mt_receipt_snapshot(p_store uuid,p_kind text,p_document uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.receipt_snapshot(p_store,p_kind,p_document)$$;
revoke all on function tenant_private.valid_receipt_settings(jsonb),tenant_private.effective_receipt_settings(uuid),tenant_private.receipt_config(uuid,jsonb),tenant_private.snapshot_receipt(),tenant_private.receipt_snapshot(uuid,text,uuid),public.mt_receipt_config(uuid,jsonb),public.mt_receipt_snapshot(uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.receipt_config(uuid,jsonb),tenant_private.receipt_snapshot(uuid,text,uuid),public.mt_receipt_config(uuid,jsonb),public.mt_receipt_snapshot(uuid,text,uuid) to authenticated;
commit;
