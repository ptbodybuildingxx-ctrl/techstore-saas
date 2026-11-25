begin;
-- Preserve validation of all existing 12-field design versions.
alter function tenant_private.valid_theme(jsonb) rename to valid_theme_v1;
create function tenant_private.valid_theme(v jsonb) returns boolean language plpgsql immutable set search_path='' as $$
declare k text; val text; permitted text[]:=array['tenant_order','store_order','invoice_format','invoice_title','invoice_footer','logo']; base jsonb;
begin
 if jsonb_typeof(v) is distinct from 'object' then return false;end if;
 base:=v-permitted;
 if not coalesce(tenant_private.valid_theme_v1(base),false) then return false;end if;
 foreach k in array permitted loop
  if not v ? k then continue;end if;
  if jsonb_typeof(v->k) is distinct from 'string' then return false;end if;
  val:=v->>k;
  case k
   when 'tenant_order' then
    if cardinality(string_to_array(val,','))<>10 or not (string_to_array(val,',') @> array['settings','inventory','products','cart','debt','cash','sales','cost','returns','operations']) then return false;end if;
   when 'store_order' then
    if cardinality(string_to_array(val,','))<>3 or not (string_to_array(val,',') @> array['catalog','cart','orders']) then return false;end if;
   when 'invoice_format' then if val not in ('a4','thermal') then return false;end if;
   when 'invoice_title' then if length(btrim(val)) not between 1 and 80 then return false;end if;
   when 'invoice_footer' then if length(val)>200 then return false;end if;
   when 'logo' then
    if val<>'' and (length(val)>22000 or val !~ '^iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$' or length(val)%4<>0) then return false;end if;
  end case;
 end loop;
 return true;
end $$;
-- Rebind existing check to the new backward-compatible validator.
do $$ declare c text;begin
 select conname into strict c from pg_constraint where conrelid='tenant_private.design_versions'::regclass and contype='c' and pg_get_constraintdef(oid) like '%valid_theme_v1%';
 execute format('alter table tenant_private.design_versions drop constraint %I',c);
end $$;
alter table tenant_private.design_versions add constraint design_versions_theme_check check(tenant_private.valid_theme(theme));
revoke all on function tenant_private.valid_theme(jsonb),tenant_private.valid_theme_v1(jsonb) from public,anon,authenticated,service_role;
-- Read only original sale lines; existing RLS also restricts cashier to their own sales.
create function public.mt_sale_receipt_lines(p_store uuid,p_sale uuid) returns setof public.mt_sale_lines
language sql stable security invoker set search_path='' as $$
 select * from public.mt_sale_lines where store_id=p_store and sale_id=p_sale order by product_id limit 100
$$;
revoke all on function public.mt_sale_receipt_lines(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.mt_sale_receipt_lines(uuid,uuid) to authenticated;
commit;