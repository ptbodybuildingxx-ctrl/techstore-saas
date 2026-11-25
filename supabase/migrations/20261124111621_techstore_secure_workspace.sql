create table public.ts_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 role text not null default 'customer' check(role in ('admin','cashier','stock','tech','customer')),
 name text not null default '', active boolean not null default true, created_at timestamptz not null default now()
);
create table public.ts_workspace (
 id integer primary key check(id=1), revision bigint not null default 0,
 payload jsonb not null default '{"data":{},"records":{}}'::jsonb,
 updated_at timestamptz not null default now()
);
create table public.ts_audit (
 id bigint generated always as identity primary key, actor uuid, action text not null,
 revision bigint, created_at timestamptz not null default now()
);
create index ts_audit_created_idx on public.ts_audit(created_at desc);
insert into public.ts_workspace(id) values(1);
alter table public.ts_profiles enable row level security;
alter table public.ts_workspace enable row level security;
alter table public.ts_audit enable row level security;
revoke all on public.ts_profiles, public.ts_workspace, public.ts_audit from public, anon, authenticated;
grant select,insert,update,delete on public.ts_profiles to service_role;
grant select,update on public.ts_workspace to service_role;
grant select,insert on public.ts_audit to service_role;
grant usage,select on sequence public.ts_audit_id_seq to service_role;
create function public.ts_commit(p_revision bigint,p_payload jsonb,p_actor uuid,p_action text)
returns bigint language plpgsql security invoker set search_path='' as $$
declare v bigint;
begin
 if jsonb_typeof(p_payload) <> 'object' then raise exception 'invalid payload'; end if;
 update public.ts_workspace set payload=p_payload,revision=revision+1,updated_at=now()
 where id=1 and revision=p_revision returning revision into v;
 if v is null then return null; end if;
 insert into public.ts_audit(actor,action,revision) values(p_actor,left(p_action,200),v);
 return v;
end; $$;
revoke all on function public.ts_commit(bigint,jsonb,uuid,text) from public,anon,authenticated;
grant execute on function public.ts_commit(bigint,jsonb,uuid,text) to service_role;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('techstore-media','techstore-media',false,5000000,array['image/png','image/jpeg','image/webp']) on conflict(id) do nothing;