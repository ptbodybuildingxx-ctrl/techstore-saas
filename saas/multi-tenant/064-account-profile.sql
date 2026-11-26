-- Private per-shop staff identity; never used to grant permissions.
begin;
create table tenant_private.staff_profiles(store_id uuid not null,user_id uuid not null,display_name text not null check(length(btrim(display_name)) between 1 and 120),photo text not null default '' check(photo='' or (length(photo) between 8 and 32000 and photo ~ '^/9j/[A-Za-z0-9+/]*={0,2}$')),updated_at timestamptz not null default now(),primary key(store_id,user_id),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id));
alter table tenant_private.staff_profiles enable row level security;revoke all on tenant_private.staff_profiles from public,anon,authenticated,service_role;
create function tenant_private.staff_self(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);v jsonb;
begin
 if role_now is null then raise exception 'Membership required' using errcode='42501';end if;
 select jsonb_build_object('id',auth.uid(),'role',role_now,'display_name',coalesce(p.display_name,''),'photo',coalesce(p.photo,'')) into v from tenant_private.members m left join tenant_private.staff_profiles p on p.store_id=m.store_id and p.user_id=m.user_id where m.store_id=p_store and m.user_id=auth.uid();return v;
end $$;
create function tenant_private.staff_profile_set(p_store uuid,p_name text,p_photo text) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is null or not tenant_private.shared_licensed(p_store) then raise exception 'Membership required' using errcode='42501';end if;
 if p_name is null or length(btrim(p_name)) not between 1 and 120 or p_photo is null or length(p_photo)>32000 then raise exception 'Invalid profile' using errcode='22023';end if;
 insert into tenant_private.staff_profiles(store_id,user_id,display_name,photo) values(p_store,auth.uid(),btrim(p_name),p_photo) on conflict(store_id,user_id) do update set display_name=excluded.display_name,photo=excluded.photo,updated_at=now();return tenant_private.staff_self(p_store);
end $$;
create function public.mt_staff_self(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.staff_self(p_store)$$;
create function public.mt_staff_profile_set(p_store uuid,p_name text,p_photo text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.staff_profile_set(p_store,p_name,p_photo)$$;
revoke all on function tenant_private.staff_self(uuid),tenant_private.staff_profile_set(uuid,text,text),public.mt_staff_self(uuid),public.mt_staff_profile_set(uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.staff_self(uuid),tenant_private.staff_profile_set(uuid,text,text),public.mt_staff_self(uuid),public.mt_staff_profile_set(uuid,text,text) to authenticated;
commit;
