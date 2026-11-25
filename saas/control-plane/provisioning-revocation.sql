begin;
do $$ begin
 if to_regclass('saas_private.trial_grants') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Dedicated control plane required'; end if;
end $$;
create function saas_private.reconcile_subscription_grant() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state<>'trial' or new.valid_until is null or new.valid_until<=now() or (old.state='trial' and old.valid_until<=now()) or new.plan_code is distinct from old.plan_code then
   update saas_private.trial_grants set revoked_at=now() where store_id=new.store_id and revoked_at is null;
 end if;
 return new;
end $$;
revoke all on function saas_private.reconcile_subscription_grant() from public,anon,authenticated,service_role;
create trigger saas_reconcile_subscription_grant after update of state,valid_until,plan_code on public.saas_subscriptions for each row execute function saas_private.reconcile_subscription_grant();
commit;