begin;
create table public.ts_public_reviews(
 id uuid primary key references public.ts_pro_entries(id) on delete cascade,
 product_id text not null check(char_length(product_id) between 1 and 200),
 rating smallint not null check(rating between 1 and 5),
 body text not null check(char_length(body) between 1 and 1000),
 published_at timestamptz not null default now()
);
create index ts_public_reviews_product_date_idx on public.ts_public_reviews(product_id,published_at desc);
alter table public.ts_public_reviews enable row level security;
revoke all on public.ts_public_reviews from public,anon,authenticated;
grant select on public.ts_public_reviews to anon,authenticated;
create policy ts_public_review_read on public.ts_public_reviews for select to anon,authenticated using(true);
create function techstore_private.moderate_review(p_review uuid,p_publish boolean) returns boolean
language plpgsql security definer set search_path='' as $$
declare r public.ts_pro_entries%rowtype; rating_value integer;
begin
 if not techstore_private.live_session() or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501'; end if;
 if not p_publish then delete from public.ts_public_reviews where id=p_review; return true; end if;
 select * into r from public.ts_pro_entries where id=p_review and kind='reviews' and not archived;
 if not found or r.details->'publishConsent' is distinct from 'true'::jsonb or r.details->>'status' not in ('1','2','3','4','5') or r.details->>'status' is null or char_length(btrim(r.notes)) not between 1 and 1000 or r.reference='' then raise exception 'Review lacks consent or valid content'; end if;
 rating_value:=(r.details->>'status')::integer;
 if not exists(select 1 from public.ts_workspace w cross join lateral jsonb_array_elements(coalesce(w.payload->'data'->'products','[]'::jsonb)) p where p->>'id'=r.reference and not coalesce((p->>'hidden')::boolean,false)) then raise exception 'Product is not available'; end if;
 insert into public.ts_public_reviews(id,product_id,rating,body) values(r.id,r.reference,rating_value,btrim(r.notes)) on conflict(id) do update set rating=excluded.rating,body=excluded.body,published_at=now();
 insert into public.ts_audit(actor,action) values(auth.uid(),'review publish '||p_review::text);
 return true;
end $$;
revoke all on function techstore_private.moderate_review(uuid,boolean) from public,anon;
grant execute on function techstore_private.moderate_review(uuid,boolean) to authenticated;
create function public.ts_moderate_review(p_review uuid,p_publish boolean) returns boolean
language sql security invoker set search_path='' as $$ select techstore_private.moderate_review(p_review,p_publish); $$;
revoke all on function public.ts_moderate_review(uuid,boolean) from public,anon;
grant execute on function public.ts_moderate_review(uuid,boolean) to authenticated;
create function techstore_private.unpublish_archived_review() returns trigger language plpgsql security definer set search_path='' as $$
begin if new.kind='reviews' and new.archived then delete from public.ts_public_reviews where id=new.id; end if; return new; end $$;
revoke all on function techstore_private.unpublish_archived_review() from public,anon,authenticated;
create trigger ts_unpublish_archived after update of archived on public.ts_pro_entries for each row execute function techstore_private.unpublish_archived_review();
create function techstore_private.my_sessions() returns table(current_session boolean,device text,created_at timestamptz,last_seen timestamptz)
language sql stable security definer set search_path='' as $$
 select s.id::text=auth.jwt()->>'session_id',left(coalesce(s.user_agent,'Unknown device'),200),s.created_at,coalesce(s.refreshed_at at time zone 'UTC',s.updated_at,s.created_at)
 from auth.sessions s where techstore_private.live_session() and s.user_id=auth.uid() and (s.not_after is null or s.not_after>now()) order by s.updated_at desc nulls last limit 50;
$$;
revoke all on function techstore_private.my_sessions() from public,anon;
grant execute on function techstore_private.my_sessions() to authenticated;
create function public.ts_my_sessions() returns table(current_session boolean,device text,created_at timestamptz,last_seen timestamptz)
language sql stable security invoker set search_path='' as $$ select * from techstore_private.my_sessions(); $$;
revoke all on function public.ts_my_sessions() from public,anon;
grant execute on function public.ts_my_sessions() to authenticated;
commit;