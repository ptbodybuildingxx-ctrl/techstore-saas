-- External delivery foundation. No transport is activated by this migration.
begin;
create table tenant_private.buyer_email_preferences(
 store_id uuid not null references tenant_private.workspaces(store_id),
 buyer uuid not null references auth.users(id) on delete cascade,
 enabled boolean not null default false,
 primary key(store_id,buyer)
);
create table tenant_private.email_outbox(
 store_id uuid not null,buyer uuid not null,notification_id uuid not null,
 state text not null default 'pending' check(state in ('pending','leased','sent','failed','cancelled')),
 attempts integer not null default 0, available_at timestamptz not null default now(),lease uuid,
 primary key(store_id,buyer,notification_id),
 foreign key(store_id,buyer,notification_id) references tenant_private.buyer_notifications(store_id,buyer,id) on delete cascade
);
alter table tenant_private.buyer_email_preferences enable row level security;
alter table tenant_private.email_outbox enable row level security;
revoke all on tenant_private.buyer_email_preferences,tenant_private.email_outbox from public,anon,authenticated,service_role;
create index mt_email_ready on tenant_private.email_outbox(available_at) where state in ('pending','leased');
create function tenant_private.email_preference(p_slug text,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);
begin
 if p_enabled is null then raise exception 'Invalid preference' using errcode='22023';end if;
 insert into tenant_private.buyer_email_preferences values(t,auth.uid(),p_enabled) on conflict(store_id,buyer) do update set enabled=excluded.enabled;
 if not p_enabled then update tenant_private.email_outbox set state='cancelled',lease=null where store_id=t and buyer=auth.uid() and state in ('pending','leased');end if;
 return p_enabled;
end $$;
create function public.mt_email_preference(p_slug text,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.email_preference(p_slug,p_enabled)$$;
create function tenant_private.enqueue_email() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from tenant_private.buyer_email_preferences where store_id=new.store_id and buyer=new.buyer and enabled) then
 insert into tenant_private.email_outbox(store_id,buyer,notification_id) values(new.store_id,new.buyer,new.id) on conflict do nothing;
 end if;return new;
end $$;
create trigger mt_enqueue_email after insert on tenant_private.buyer_notifications for each row execute function tenant_private.enqueue_email();
create function public.mt_email_claim(p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;
begin
 if p_lease is null then raise exception 'Lease required' using errcode='22023';end if;
 update tenant_private.email_outbox set state='failed',lease=null where state='leased' and available_at<=now() and attempts>=5;
 with candidates as (
 select o.store_id,o.buyer,o.notification_id from tenant_private.email_outbox o
 join tenant_private.buyer_email_preferences p using(store_id,buyer)
 join auth.users u on u.id=o.buyer
 where p.enabled and u.email_confirmed_at is not null and u.email is not null and o.state in ('pending','leased') and o.available_at<=now() and o.attempts<5 and tenant_private.storefront_active(o.store_id)
 order by o.available_at limit 20 for update of o skip locked
 ), claimed as (
 update tenant_private.email_outbox o set state='leased',lease=p_lease,attempts=attempts+1,available_at=now()+interval '5 minutes' from candidates c where (o.store_id,o.buyer,o.notification_id)=(c.store_id,c.buyer,c.notification_id) returning o.*
 )
 select coalesce(jsonb_agg(jsonb_build_object('store',c.store_id,'buyer',c.buyer,'id',c.notification_id,'email',u.email,'slug',s.slug)),'[]'::jsonb) into r from claimed c join auth.users u on u.id=c.buyer join public.saas_stores s on s.id=c.store_id;
 return r;
end $$;
create function public.mt_email_finish(p_lease uuid,p_store uuid,p_buyer uuid,p_id uuid,p_success boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if p_success is null then raise exception 'Invalid result' using errcode='22023';end if;
 update tenant_private.email_outbox set state=case when p_success then 'sent' when attempts>=5 then 'failed' else 'pending' end,lease=null,available_at=now()+interval '15 minutes' where store_id=p_store and buyer=p_buyer and notification_id=p_id and state='leased' and lease=p_lease;
 return found;
end $$;
revoke all on function tenant_private.email_preference(text,boolean),public.mt_email_preference(text,boolean),tenant_private.enqueue_email(),public.mt_email_claim(uuid),public.mt_email_finish(uuid,uuid,uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.email_preference(text,boolean),public.mt_email_preference(text,boolean) to authenticated;
grant execute on function public.mt_email_claim(uuid),public.mt_email_finish(uuid,uuid,uuid,uuid,boolean) to service_role;
commit;
