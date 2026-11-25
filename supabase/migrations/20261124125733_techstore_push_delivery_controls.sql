begin;
create function public.ts_push_register(p_user uuid,p_session uuid,p_endpoint text,p_p256dh text,p_auth text,p_remove boolean default false) returns boolean
language plpgsql security invoker set search_path='' as $$
declare existing public.ts_push_subscriptions%rowtype;
begin
 if not public.ts_session_valid(p_user,p_session) or not exists(select 1 from public.ts_profiles where user_id=p_user and active) then raise exception 'Access denied' using errcode='42501';end if;
 if p_endpoint !~ '^https://' or length(p_endpoint)>2048 then raise exception 'Invalid endpoint';end if;
 perform pg_catalog.pg_advisory_xact_lock(593227504);
 if p_remove then delete from public.ts_push_subscriptions where user_id=p_user and endpoint=p_endpoint;return true;end if;
 select * into existing from public.ts_push_subscriptions where endpoint=p_endpoint;
 if found and existing.user_id<>p_user then
 if public.ts_session_valid(existing.user_id,existing.session_id) then raise exception 'Subscription belongs to another active account';end if;
 delete from public.ts_push_subscriptions where id=existing.id;
 end if;
 delete from public.ts_push_subscriptions s where s.user_id=p_user and not public.ts_session_valid(s.user_id,s.session_id);
 if not exists(select 1 from public.ts_push_subscriptions where endpoint=p_endpoint and user_id=p_user) and (select count(*) from public.ts_push_subscriptions where user_id=p_user)>=5 then raise exception 'Maximum 5 active subscriptions';end if;
 insert into public.ts_push_subscriptions(user_id,session_id,endpoint,p256dh,auth_key) values(p_user,p_session,p_endpoint,p_p256dh,p_auth)
 on conflict(endpoint) do update set session_id=excluded.session_id,p256dh=excluded.p256dh,auth_key=excluded.auth_key where public.ts_push_subscriptions.user_id=p_user;
 return found;
end $$;
revoke all on function public.ts_push_register(uuid,uuid,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.ts_push_register(uuid,uuid,text,text,text,boolean) to service_role;
create function public.ts_push_test(p_user uuid,p_session uuid,p_endpoint text) returns boolean language plpgsql security invoker set search_path='' as $$
declare sub_id uuid;
begin
 if not public.ts_session_valid(p_user,p_session) then raise exception 'Access denied' using errcode='42501';end if;
 select id into sub_id from public.ts_push_subscriptions where user_id=p_user and session_id=p_session and endpoint=p_endpoint;
 if not found then raise exception 'Subscribe first';end if;
 perform pg_catalog.pg_advisory_xact_lock(593227505);
 if (select count(*) from public.ts_push_outbox where subscription_id=sub_id and event_key like 'test:%' and created_at>now()-interval '1 hour')>=3 then raise exception 'Test limit reached';end if;
 insert into public.ts_push_outbox(subscription_id,event_key) values(sub_id,'test:'||gen_random_uuid());return true;
end $$;
revoke all on function public.ts_push_test(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.ts_push_test(uuid,uuid,text) to service_role;
create function public.ts_push_finish(p_lease uuid,p_job uuid,p_status integer) returns boolean language plpgsql security invoker set search_path='' as $$
declare sid uuid;
begin
 select subscription_id into sid from public.ts_push_outbox where id=p_job and lease_id=p_lease and sent_at is null and not failed for update;
 if not found then return false;end if;
 if p_status in (404,410) then delete from public.ts_push_subscriptions where id=sid;
 elsif p_status between 200 and 299 then update public.ts_push_outbox set sent_at=now(),lease_id=null where id=p_job;
 else update public.ts_push_outbox set failed=attempts>=5 or p_status in (400,401,403),lease_id=null,next_attempt=now()+make_interval(mins=>least(30,attempts*3)) where id=p_job;end if;
 return true;
end $$;
revoke all on function public.ts_push_finish(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.ts_push_finish(uuid,uuid,integer) to service_role;
commit;