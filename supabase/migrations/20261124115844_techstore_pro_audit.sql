begin;
create or replace function techstore_private.pro_audit() returns trigger language plpgsql security definer set search_path='' as $$
declare a uuid; k text; r text;
begin
 a:=auth.uid();
 if tg_table_name='ts_pro_entries' then
   k:=new.kind; r:=new.id::text;
 else
   if tg_op='DELETE' then k:=old.module; r:=old.user_id::text;
   else k:=new.module; r:=new.user_id::text; end if;
 end if;
 insert into public.ts_audit(actor,action) values(a,left('pro:'||tg_table_name||':'||tg_op||':'||k||':'||r,200));
 if tg_op='DELETE' then return old; end if;
 return new;
end; $$;
revoke all on function techstore_private.pro_audit() from public,anon,authenticated;
create trigger ts_pro_entries_audit after insert or update on public.ts_pro_entries for each row execute function techstore_private.pro_audit();
create trigger ts_pro_grants_audit after insert or update or delete on public.ts_pro_grants for each row execute function techstore_private.pro_audit();
commit;