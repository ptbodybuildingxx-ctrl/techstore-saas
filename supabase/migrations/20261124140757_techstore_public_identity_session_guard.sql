begin;
create or replace function techstore_private.store_identity(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.ts_store_identity%rowtype; i public.ts_invoice_settings%rowtype;
begin
 if p_action='get' then select * into c from public.ts_store_identity where id=1;select * into i from public.ts_invoice_settings where id=1;return jsonb_build_object('name',i.store_name,'logo',i.logo,'tagline_ar',c.tagline_ar,'tagline_en',c.tagline_en,'accent',c.accent);end if;
 if p_action is distinct from 'save' or techstore_private.live_session() is distinct from true or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>200000 then raise exception 'Invalid request';end if;
 update public.ts_invoice_settings set store_name=btrim(p_args->>'name'),logo=coalesce(p_args->>'logo','') where id=1;
 update public.ts_store_identity set tagline_ar=coalesce(p_args->>'tagline_ar',''),tagline_en=coalesce(p_args->>'tagline_en',''),accent=p_args->>'accent' where id=1;
 insert into public.ts_audit(actor,action) values(auth.uid(),'store identity updated');return jsonb_build_object('ok',true);
end $$;

create or replace function techstore_private.product_gallery(p_action text,p_args jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb; prod jsonb; pid text; paths_value text[]; x text;
begin
 select payload->'data' into d from public.ts_workspace where id=1;
 if p_action='public' then
 if d->'owner'->>'maintenance'='true' then return '{}'::jsonb;end if;
 return coalesce((select jsonb_object_agg(g.product_id,to_jsonb(g.paths)) from public.ts_product_gallery g join lateral (select p from jsonb_array_elements(coalesce(d->'products','[]')) p where p->>'id'=g.product_id and p->>'hidden' is distinct from 'true' and not(coalesce(d->'owner'->'hiddenCategories','[]') ? coalesce(p->>'type','')) limit 1) p on true),'{}');
 end if;
 if techstore_private.live_session() is distinct from true or not exists(select 1 from public.ts_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Access denied' using errcode='42501';end if;
 if p_action='list' then return coalesce((select jsonb_object_agg(product_id,to_jsonb(paths)) from public.ts_product_gallery),'{}');end if;
 if p_action<>'save' or jsonb_typeof(p_args->'paths') is distinct from 'array' or jsonb_array_length(p_args->'paths')>4 then raise exception 'Invalid gallery';end if;
 pid:=p_args->>'product_id';
 select p into prod from jsonb_array_elements(coalesce(d->'products','[]')) p where p->>'id'=pid;
 if prod is null then raise exception 'Unknown product';end if;
 select coalesce(array_agg(v),'{}') into paths_value from jsonb_array_elements_text(p_args->'paths') v;
 foreach x in array paths_value loop
 if x !~ '^catalog/[0-9a-f-]{36}\.jpg$' or not exists(select 1 from storage.objects where bucket_id='techstore-products' and name=x) then raise exception 'Invalid picture path';end if;
 end loop;
 insert into public.ts_product_gallery(product_id,paths) values(pid,paths_value) on conflict(product_id) do update set paths=excluded.paths,updated_at=now();
 insert into public.ts_audit(actor,action) values(auth.uid(),'product gallery updated '||pid);return jsonb_build_object('ok',true);
end $$;

commit;