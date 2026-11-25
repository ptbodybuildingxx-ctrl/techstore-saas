begin;
create table tenant_private.design_versions(
 store_id uuid not null references tenant_private.workspaces(store_id),
 revision bigint not null check(revision>0), theme jsonb not null,
 actor uuid not null, created_at timestamptz not null default now(),primary key(store_id,revision)
);
create table tenant_private.design_heads(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 draft_revision bigint not null,published_revision bigint,
 foreign key(store_id,draft_revision) references tenant_private.design_versions(store_id,revision),
 foreign key(store_id,published_revision) references tenant_private.design_versions(store_id,revision)
);
alter table tenant_private.design_versions enable row level security;
alter table tenant_private.design_heads enable row level security;
revoke all on tenant_private.design_versions,tenant_private.design_heads from public,anon,authenticated,service_role;
create function tenant_private.valid_theme(v jsonb) returns boolean language sql immutable set search_path='' as $$
 select case when jsonb_typeof(v)='object' then
 (select count(*) from jsonb_object_keys(v))=12
 and v ?& array['brand','mark','tagline','mode','accent','background','surface','text','font','radius','density','layout']
 and not exists(select 1 from jsonb_each(v) x where jsonb_typeof(x.value)<>'string')
 and length(btrim(v->>'brand')) between 1 and 80
 and length(v->>'mark') between 0 and 8 and length(v->>'tagline')<=160
 and (v->>'mode') in ('dark','light')
 and (v->>'accent') ~ '^#[0-9A-Fa-f]{6}$' and (v->>'background') ~ '^#[0-9A-Fa-f]{6}$'
 and (v->>'surface') ~ '^#[0-9A-Fa-f]{6}$' and (v->>'text') ~ '^#[0-9A-Fa-f]{6}$'
 and (v->>'font') in ('system','sans','serif')
 and (v->>'radius') in ('square','soft','round')
 and (v->>'density') in ('compact','normal','spacious')
 and (v->>'layout') in ('list','cards')
 else false end
$$;
alter table tenant_private.design_versions add check(tenant_private.valid_theme(theme));
create function tenant_private.design_read(p_store uuid,p_editor boolean) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if p_editor is null or (p_editor and not coalesce(saas_private.is_operator(),false)) or (not p_editor and not coalesce(saas_private.is_operator(),false) and tenant_private.member_role(p_store) is null) then raise exception 'Design access denied' using errcode='42501';end if;
 if not exists(select 1 from tenant_private.workspaces where store_id=p_store) then raise exception 'Unknown shared store' using errcode='22023';end if;
 select jsonb_build_object('revision',case when p_editor then coalesce(h.draft_revision,0) else coalesce(h.published_revision,0) end,'published_revision',coalesce(h.published_revision,0),'theme',case when p_editor then d.theme else v.theme end,'published',v.theme)
 into r from tenant_private.workspaces w left join tenant_private.design_heads h on h.store_id=w.store_id left join tenant_private.design_versions d on d.store_id=h.store_id and d.revision=h.draft_revision left join tenant_private.design_versions v on v.store_id=h.store_id and v.revision=h.published_revision where w.store_id=p_store;
 return r;
end $$;
create function tenant_private.design_change(p_store uuid,p_expected bigint,p_expected_published bigint,p_action text,p_theme jsonb,p_restore bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare h tenant_private.design_heads%rowtype;n bigint;v jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_expected is null or p_expected_published is null or p_expected<0 or p_expected_published<0 or p_action is null or p_action not in ('save','publish','restore') then raise exception 'Invalid design operation' using errcode='22023';end if;
 perform 1 from tenant_private.workspaces where store_id=p_store for update;
 if not found then raise exception 'Unknown shared store' using errcode='22023';end if;
 select * into h from tenant_private.design_heads where store_id=p_store;
 if coalesce(h.draft_revision,0)<>p_expected or coalesce(h.published_revision,0)<>p_expected_published then raise exception 'Design changed; reload' using errcode='40001';end if;
 if p_action='publish' then
  if p_expected=0 or p_theme is not null or p_restore is not null then raise exception 'Save draft first' using errcode='22023';end if;
  update tenant_private.design_heads set published_revision=draft_revision where store_id=p_store;
 else
  if p_action='save' then
   if p_restore is not null or not coalesce(tenant_private.valid_theme(p_theme),false) then raise exception 'Invalid design' using errcode='22023';end if;
   v:=p_theme;
  else
   if p_theme is not null or p_restore is null then raise exception 'Invalid restore' using errcode='22023';end if;
   select theme into v from tenant_private.design_versions where store_id=p_store and revision=p_restore;
   if not found then raise exception 'Unknown revision' using errcode='22023';end if;
  end if;
  n:=p_expected+1;
  insert into tenant_private.design_versions(store_id,revision,theme,actor) values(p_store,n,v,auth.uid());
  insert into tenant_private.design_heads(store_id,draft_revision) values(p_store,n) on conflict(store_id) do update set draft_revision=excluded.draft_revision;
 end if;
 return tenant_private.design_read(p_store,true);
end $$;
create function tenant_private.design_history(p_store uuid,p_before bigint,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid page' using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by revision desc),'[]'::jsonb) into r from (select revision,created_at from tenant_private.design_versions where store_id=p_store and (p_before is null or revision<p_before) order by revision desc limit p_limit) x;return r;
end $$;
create function tenant_private.public_design(p_slug text) returns jsonb
language sql stable security definer set search_path='' as $$
 select v.theme from public.saas_stores s join tenant_private.design_heads h on h.store_id=s.id join tenant_private.design_versions v on v.store_id=h.store_id and v.revision=h.published_revision where s.slug=p_slug and tenant_private.storefront_active(s.id)
$$;
create function public.mt_design_read(p_store uuid,p_editor boolean default false) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.design_read(p_store,p_editor)$$;
create function public.mt_design_change(p_store uuid,p_expected bigint,p_expected_published bigint,p_action text,p_theme jsonb default null,p_restore bigint default null) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.design_change(p_store,p_expected,p_expected_published,p_action,p_theme,p_restore)$$;
create function public.mt_design_history(p_store uuid,p_before bigint default null,p_limit integer default 20) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.design_history(p_store,p_before,p_limit)$$;
create function public.mt_public_design(p_slug text) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.public_design(p_slug)$$;
revoke all on function tenant_private.valid_theme(jsonb),tenant_private.design_read(uuid,boolean),tenant_private.design_change(uuid,bigint,bigint,text,jsonb,bigint),tenant_private.design_history(uuid,bigint,integer),tenant_private.public_design(text),public.mt_design_read(uuid,boolean),public.mt_design_change(uuid,bigint,bigint,text,jsonb,bigint),public.mt_design_history(uuid,bigint,integer),public.mt_public_design(text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.design_read(uuid,boolean),tenant_private.design_change(uuid,bigint,bigint,text,jsonb,bigint),tenant_private.design_history(uuid,bigint,integer),public.mt_design_read(uuid,boolean),public.mt_design_change(uuid,bigint,bigint,text,jsonb,bigint),public.mt_design_history(uuid,bigint,integer) to authenticated;
grant execute on function tenant_private.public_design(text),public.mt_public_design(text) to anon,authenticated;
commit;