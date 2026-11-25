begin;
create or replace function techstore_private.live_session() returns boolean language sql stable security definer set search_path='' as $$
 select techstore_private.base_live_session(auth.uid(),auth.jwt()->>'session_id') and (not techstore_private.mfa_required(auth.uid()) or (coalesce(auth.jwt()->>'aal'='aal2',false) and techstore_private.mfa_session_verified(auth.uid(),auth.jwt()->>'session_id')))
$$;
commit;