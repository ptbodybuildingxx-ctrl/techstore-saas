begin;
-- Custom host routing registry. Never activates a domain merely on browser assertion.
create table tenant_private.custom_domains(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null unique,
 hostname text not null unique check(length(hostname) between 4 and 253 and hostname ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$'),
 proof_token uuid not null default gen_random_uuid(),state text not null default 'pending' check(state in ('pending','active','disabled')),
 actor uuid not null,created_at timestamptz not null default now(),verified_at timestamptz,evidence_sha256 text,
 primary key(store_id,id),
 check(state<>'active' or (verified_at is not null and evidence_sha256 is not null and evidence_sha256 ~ '^[0-9a-f]{64}$'))
);
create unique index mt_one_current_custom_domain on tenant_private.custom_domains(store_id) where state in ('pending','active');
alter table tenant_private.custom_domains enable row level security;
revoke all on tenant_private.custom_domains from public,anon,authenticated,service_role;
create function tenant_private.valid_hostname(v text) returns boolean language plpgsql immutable set search_path='' as $$
declare x text;parts text[];
begin
 if v is null or length(v) not between 4 and 253 or v<>lower(v) or v !~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$' then return false;end if;
 parts:=string_to_array(v,'.');
 if parts[cardinality(parts)] !~ '^[a-z][a-z0-9-]{1,62}$' or v ~ '(^|\.)(localhost|local|internal|test|invalid|example|onion|github\.io|supabase\.co|supabase\.in)$' then return false;end if;
 foreach x in array parts loop if length(x)>63 or x ~ '^-|-$' then return false;end if;end loop;
 return true;
end $$;
create function tenant_private.domain_request(p_store uuid,p_request uuid,p_host text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r tenant_private.custom_domains%rowtype;h text:=lower(btrim(p_host));
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 if p_request is null or not tenant_private.valid_hostname(h) then raise exception 'Invalid host' using errcode='22023';end if;
 perform 1 from tenant_private.workspaces where store_id=p_store for update;if not found then raise exception 'Unknown store' using errcode='22023';end if;
 select * into r from tenant_private.custom_domains where request_id=p_request;
 if found then if r.actor<>auth.uid() or r.store_id<>p_store or r.hostname<>h then raise exception 'Conflicting domain request' using errcode='22023';end if;
 else insert into tenant_private.custom_domains(store_id,request_id,hostname,actor) values(p_store,p_request,h,auth.uid()) returning * into r;end if;
 return jsonb_build_object('id',r.id,'hostname',r.hostname,'state',r.state,'dns_name','_techstore.'||r.hostname,'dns_value','techstore-verification='||r.proof_token::text,'verified_at',r.verified_at);
end $$;
create function tenant_private.domain_list(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'hostname',x.hostname,'state',x.state,'dns_name','_techstore.'||x.hostname,'dns_value','techstore-verification='||x.proof_token::text,'verified_at',x.verified_at) order by x.created_at desc) from (select * from tenant_private.custom_domains where store_id=p_store order by created_at desc limit 20)x),'[]'::jsonb);
end $$;
create function tenant_private.domain_disable(p_store uuid,p_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(saas_private.is_operator(),false) then raise exception 'Operator required' using errcode='42501';end if;
 perform 1 from tenant_private.workspaces where store_id=p_store for update;
 update tenant_private.custom_domains set state='disabled' where store_id=p_store and id=p_id and state<>'disabled';return found;
end $$;
-- Trusted hosting verifier only. Must independently prove DNS TXT, routing, and valid TLS.
-- No trusted verifier is deployed by this migration. No active domains are created.
create function tenant_private.domain_activate(p_store uuid,p_id uuid,p_host text,p_proof uuid,p_evidence text) returns boolean language plpgsql security definer set search_path='' as $$
declare r tenant_private.custom_domains%rowtype;
begin
 if p_evidence is null or p_evidence !~ '^[0-9a-f]{64}$' or p_proof is null then raise exception 'Invalid evidence' using errcode='22023';end if;
 perform 1 from tenant_private.workspaces where store_id=p_store for update;
 select * into r from tenant_private.custom_domains where store_id=p_store and id=p_id for update;
 if not found or r.state<>'pending' or r.hostname is distinct from p_host or r.proof_token is distinct from p_proof then raise exception 'Domain evidence mismatch' using errcode='22023';end if;
 update tenant_private.custom_domains set state='active',verified_at=now(),evidence_sha256=p_evidence where store_id=p_store and id=p_id;return true;
end $$;
create function tenant_private.resolve_domain(p_host text) returns text language sql stable security definer set search_path='' as $$
 select s.slug from tenant_private.custom_domains d join public.saas_stores s on s.id=d.store_id where d.hostname=p_host and d.state='active' and tenant_private.storefront_active(s.id)
$$;
create function public.mt_domain_request(p_store uuid,p_request uuid,p_host text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.domain_request(p_store,p_request,p_host)$$;
create function public.mt_domain_list(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.domain_list(p_store)$$;
create function public.mt_domain_disable(p_store uuid,p_id uuid) returns boolean language sql security invoker set search_path='' as $$select tenant_private.domain_disable(p_store,p_id)$$;
create function public.mt_service_domain_activate(p_store uuid,p_id uuid,p_host text,p_proof uuid,p_evidence text) returns boolean language sql security invoker set search_path='' as $$select tenant_private.domain_activate(p_store,p_id,p_host,p_proof,p_evidence)$$;
create function public.mt_resolve_domain(p_host text) returns text language sql stable security invoker set search_path='' as $$select tenant_private.resolve_domain(p_host)$$;
revoke all on function tenant_private.valid_hostname(text),tenant_private.domain_request(uuid,uuid,text),tenant_private.domain_list(uuid),tenant_private.domain_disable(uuid,uuid),tenant_private.domain_activate(uuid,uuid,text,uuid,text),tenant_private.resolve_domain(text),public.mt_domain_request(uuid,uuid,text),public.mt_domain_list(uuid),public.mt_domain_disable(uuid,uuid),public.mt_service_domain_activate(uuid,uuid,text,uuid,text),public.mt_resolve_domain(text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.domain_request(uuid,uuid,text),tenant_private.domain_list(uuid),tenant_private.domain_disable(uuid,uuid),public.mt_domain_request(uuid,uuid,text),public.mt_domain_list(uuid),public.mt_domain_disable(uuid,uuid) to authenticated;
grant execute on function tenant_private.domain_activate(uuid,uuid,text,uuid,text),public.mt_service_domain_activate(uuid,uuid,text,uuid,text) to service_role;
grant execute on function tenant_private.resolve_domain(text),public.mt_resolve_domain(text) to anon,authenticated;
commit;