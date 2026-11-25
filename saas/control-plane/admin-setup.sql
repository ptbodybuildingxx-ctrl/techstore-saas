begin;
do $$ begin
 if to_regclass('saas_private.operators') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Dedicated control plane required'; end if;
end $$;
create table saas_private.admin_setup (
 singleton boolean primary key default true check(singleton),
 preferred_name text not null check(preferred_name ~ '^[a-z][a-z0-9_-]{2,39}$'),
 created_at timestamptz not null default now()
);
alter table saas_private.admin_setup enable row level security;
revoke all on saas_private.admin_setup from public,anon,authenticated,service_role;
comment on table saas_private.admin_setup is 'Pending setup preference only; confers no authentication or operator privilege.';
commit;