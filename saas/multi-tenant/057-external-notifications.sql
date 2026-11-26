-- Explicit device opt-in and service-only delivery, independent of the original store.
begin;
create table tenant_private.push_devices(
 store_id uuid not null references tenant_private.workspaces(store_id),buyer uuid not null references auth.users(id) on delete cascade,id uuid not null default gen_random_uuid(),
 endpoint text not null check(length(endpoint)<=2048),p256dh text not null,auth_key text not null,created_at timestamptz not null default now(),
 primary key(store_id,buyer,id),unique(endpoint)
);
create table tenant_private.push_outbox(
 store_id uuid not null,buyer uuid not null,device_id uuid not null,notification_id uuid not null,
 state text not null default 'pending' check(state in ('pending','leased','sent','failed')),attempts int not null default 0,available_at timestamptz not null default now(),lease uuid,
 primary key(store_id,buyer,device_id,notification_id),foreign key(store_id,buyer,device_id) references tenant_private.push_devices(store_id,buyer,id) on delete cascade,
 foreign key(store_id,buyer,notification_id) references tenant_private.buyer_notifications(store_id,buyer,id) on delete cascade
);
alter table tenant_private.push_devices enable row level security;alter table tenant_private.push_outbox enable row level security;
revoke all on tenant_private.push_devices,tenant_private.push_outbox from public,anon,authenticated,service_role;
create index mt_push_ready on tenant_private.push_outbox(available_at) where state in ('pending','leased');
create function tenant_private.email_enabled(p_slug text) returns boolean language plpgsql stable security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);begin return coalesce((select enabled from tenant_private.buyer_email_preferences where store_id=t and buyer=auth.uid()),false);end $$;
create function public.mt_email_enabled(p_slug text) returns boolean language sql stable security invoker set search_path='' as $$select tenant_private.email_enabled(p_slug)$$;
create function tenant_private.push_register(p_slug text,p_endpoint text,p_key text,p_auth text,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
declare t uuid:=tenant_private.buyer_store(p_slug);
begin
 if p_enabled is null or p_endpoint is null or length(p_endpoint)>2048 or p_endpoint !~ '^https://(fcm[.]googleapis[.]com|updates[.]push[.]services[.]mozilla[.]com|web[.]push[.]apple[.]com)/[^[:space:]#]+$' then raise exception 'Invalid endpoint' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=t for update;
 if not p_enabled then delete from tenant_private.push_devices where store_id=t and buyer=auth.uid() and endpoint=p_endpoint;return false;end if;
 if p_key is null or p_key !~ '^[A-Za-z0-9_-]{87}$' or p_auth is null or p_auth !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'Invalid subscription' using errcode='22023';end if;
 if exists(select 1 from tenant_private.push_devices where endpoint=p_endpoint and (store_id<>t or buyer<>auth.uid())) then raise exception 'Device already registered; unsubscribe locally first' using errcode='22023';end if;
 if not exists(select 1 from tenant_private.push_devices where endpoint=p_endpoint) and (select count(*) from tenant_private.push_devices where store_id=t and buyer=auth.uid())>=5 then raise exception 'Device limit' using errcode='22023';end if;
 insert into tenant_private.push_devices(store_id,buyer,endpoint,p256dh,auth_key) values(t,auth.uid(),p_endpoint,p_key,p_auth) on conflict(endpoint) do update set p256dh=excluded.p256dh,auth_key=excluded.auth_key where push_devices.store_id=t and push_devices.buyer=auth.uid();
 if not found then raise exception 'Device registration conflict' using errcode='22023';end if;return true;
end $$;
create function public.mt_push_register(p_slug text,p_endpoint text,p_key text,p_auth text,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.push_register(p_slug,p_endpoint,p_key,p_auth,p_enabled)$$;
create function tenant_private.enqueue_push() returns trigger language plpgsql security definer set search_path='' as $$begin
 insert into tenant_private.push_outbox(store_id,buyer,device_id,notification_id) select store_id,buyer,id,new.id from tenant_private.push_devices where store_id=new.store_id and buyer=new.buyer on conflict do nothing;return new;
end $$;
create trigger mt_enqueue_push after insert on tenant_private.buyer_notifications for each row execute function tenant_private.enqueue_push();
create function public.mt_push_claim(p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;
begin
 if p_lease is null then raise exception 'Lease required' using errcode='22023';end if;
 update tenant_private.push_outbox set state='failed',lease=null where state='leased' and available_at<=now() and attempts>=5;
 with candidates as (select o.store_id,o.buyer,o.device_id,o.notification_id from tenant_private.push_outbox o join auth.users u on u.id=o.buyer where o.state in ('pending','leased') and o.available_at<=now() and o.attempts<5 and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until<=now()) and tenant_private.storefront_active(o.store_id) order by o.available_at limit 10 for update of o skip locked),
 claimed as (update tenant_private.push_outbox o set state='leased',lease=p_lease,attempts=attempts+1,available_at=now()+interval '5 minutes' from candidates c where (o.store_id,o.buyer,o.device_id,o.notification_id)=(c.store_id,c.buyer,c.device_id,c.notification_id) returning o.*)
 select coalesce(jsonb_agg(jsonb_build_object('store',c.store_id,'buyer',c.buyer,'device',c.device_id,'id',c.notification_id,'endpoint',d.endpoint,'p256dh',d.p256dh,'auth',d.auth_key)),'[]') into r from claimed c join tenant_private.push_devices d on (d.store_id,d.buyer,d.id)=(c.store_id,c.buyer,c.device_id);return r;
end $$;
create function public.mt_push_finish(p_lease uuid,p_store uuid,p_buyer uuid,p_device uuid,p_id uuid,p_status int) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if p_status is null then raise exception 'Status required' using errcode='22023';end if;
 if not exists(select 1 from tenant_private.push_outbox where store_id=p_store and buyer=p_buyer and device_id=p_device and notification_id=p_id and state='leased' and lease=p_lease) then return false;end if;
 if p_status in (404,410) then delete from tenant_private.push_devices where store_id=p_store and buyer=p_buyer and id=p_device;return found;end if;
 update tenant_private.push_outbox set state=case when p_status between 200 and 299 then 'sent' when attempts>=5 or p_status in (400,401,403) then 'failed' else 'pending' end,lease=null,available_at=now()+interval '15 minutes' where store_id=p_store and buyer=p_buyer and device_id=p_device and notification_id=p_id and state='leased' and lease=p_lease;return found;
end $$;
create function public.mt_delivery_still_allowed(p_channel text,p_lease uuid,p_store uuid,p_buyer uuid,p_id uuid,p_device uuid default null) returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if not tenant_private.storefront_active(p_store) or not exists(select 1 from auth.users where id=p_buyer and email_confirmed_at is not null and (banned_until is null or banned_until<=now())) then return false;end if;
 if p_channel='email' then return exists(select 1 from tenant_private.email_outbox o join tenant_private.buyer_email_preferences p using(store_id,buyer) where o.store_id=p_store and o.buyer=p_buyer and o.notification_id=p_id and o.state='leased' and o.lease=p_lease and p.enabled);end if;
 if p_channel='push' then return exists(select 1 from tenant_private.push_outbox where store_id=p_store and buyer=p_buyer and notification_id=p_id and device_id=p_device and state='leased' and lease=p_lease);end if;return false;
end $$;
revoke all on function tenant_private.email_enabled(text),public.mt_email_enabled(text),tenant_private.push_register(text,text,text,text,boolean),public.mt_push_register(text,text,text,text,boolean),tenant_private.enqueue_push(),public.mt_push_claim(uuid),public.mt_push_finish(uuid,uuid,uuid,uuid,uuid,int),public.mt_delivery_still_allowed(text,uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.email_enabled(text),public.mt_email_enabled(text),tenant_private.push_register(text,text,text,text,boolean),public.mt_push_register(text,text,text,text,boolean) to authenticated;
grant execute on function public.mt_push_claim(uuid),public.mt_push_finish(uuid,uuid,uuid,uuid,uuid,int),public.mt_delivery_still_allowed(text,uuid,uuid,uuid,uuid,uuid) to service_role;
commit;
