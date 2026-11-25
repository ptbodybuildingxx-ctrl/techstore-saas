-- Development account contact details; no email verification or recovery privileges.
begin;
do $$ begin
 if to_regclass('saas_private.admin_setup') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Dedicated control plane required'; end if;
end $$;
create table saas_private.operator_contacts (
 user_id uuid primary key references saas_private.operators(user_id) on delete cascade,
 contact_email text not null check(length(contact_email) between 3 and 254 and contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'),
 updated_at timestamptz not null default now()
);
alter table saas_private.operator_contacts enable row level security;
revoke all on saas_private.operator_contacts from public,anon,authenticated,service_role;
create function saas_private.operator_contact(p_email text,p_write boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_email text; v_name text;
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator authorization required' using errcode='42501'; end if;
 if p_write is null then raise exception 'Invalid operation' using errcode='22023'; end if;
 if p_write then
   if p_email is null or length(btrim(p_email)) not between 3 and 254 or btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or lower(btrim(p_email)) like '%@%.invalid' then raise exception 'Invalid contact email' using errcode='22023'; end if;
   insert into saas_private.operator_contacts(user_id,contact_email) values(auth.uid(),btrim(p_email))
    on conflict(user_id) do update set contact_email=excluded.contact_email,updated_at=now();
 end if;
 select contact_email into v_email from saas_private.operator_contacts where user_id=auth.uid();
 select preferred_name into v_name from saas_private.admin_setup where singleton;
 return jsonb_build_object('username',v_name,'contact_email',v_email,'verified',false);
end $$;
create function public.saas_admin_contact(p_email text default null,p_write boolean default false) returns jsonb
language sql security invoker set search_path='' as $$ select saas_private.operator_contact(p_email,p_write) $$;
revoke all on function saas_private.operator_contact(text,boolean),public.saas_admin_contact(text,boolean) from public,anon,authenticated,service_role;
grant execute on function saas_private.operator_contact(text,boolean),public.saas_admin_contact(text,boolean) to authenticated;
commit;