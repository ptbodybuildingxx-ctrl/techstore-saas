-- 118: owner-facing effective access matrix and optimistic, audited batch changes.
begin;
create table tenant_private.staff_access_events(
 id uuid primary key default gen_random_uuid(),store_id uuid not null references tenant_private.workspaces(store_id),
 user_id uuid not null,actor uuid,kind text not null,previous jsonb,current jsonb,created_at timestamptz not null default now()
);
alter table tenant_private.staff_access_events enable row level security;
revoke all on tenant_private.staff_access_events from public,anon,authenticated;
create index staff_access_events_employee on tenant_private.staff_access_events(store_id,user_id,created_at desc,id);
create function tenant_private.audit_staff_access()
returns trigger language plpgsql security definer set search_path='' as $$
declare a jsonb;b jsonb;s uuid;u uuid;
begin
 if tg_op<>'INSERT' then a:=to_jsonb(old);end if;
 if tg_op<>'DELETE' then b:=to_jsonb(new);end if;
 if a is not distinct from b then if tg_op='DELETE' then return old;else return new;end if;end if;
 s:=coalesce(b->>'store_id',a->>'store_id')::uuid;u:=coalesce(b->>'user_id',a->>'user_id')::uuid;
 insert into tenant_private.staff_access_events(store_id,user_id,actor,kind,previous,current) values(s,u,auth.uid(),tg_table_name,a,b);
 if tg_op='DELETE' then return old;else return new;end if;
end $$;
revoke all on function tenant_private.audit_staff_access() from public,anon,authenticated;
create trigger mt_audit_staff_denials after insert or update or delete on tenant_private.staff_denials for each row execute function tenant_private.audit_staff_access();
create trigger mt_audit_procurement_grants after insert or update or delete on tenant_private.procurement_grants for each row execute function tenant_private.audit_staff_access();
create trigger mt_audit_receivable_grants after insert or update or delete on tenant_private.receivable_grants for each row execute function tenant_private.audit_staff_access();
create trigger mt_audit_staff_scope after insert or update or delete on tenant_private.staff_branch_scope for each row execute function tenant_private.audit_staff_access();
create trigger mt_audit_cashier_scope after insert or update or delete on tenant_private.cashier_branch_scope for each row execute function tenant_private.audit_staff_access();

create function tenant_private.staff_access_matrix(s uuid,u uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r text;enabled boolean;b uuid;licensed boolean;d text[];rg text[];pg tenant_private.procurement_grants%rowtype;items jsonb;
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select role,active into r,enabled from tenant_private.members where store_id=s and user_id=u;
 if not found then raise exception 'Unknown employee' using errcode='22023';end if;
 select coalesce((select branch_id from tenant_private.cashier_branch_scope where store_id=s and user_id=u),(select branch_id from tenant_private.staff_branch_scope where store_id=s and user_id=u)) into b;
 licensed:=coalesce(tenant_private.shared_licensed(s),false);
 select coalesce(array_agg(action order by action),'{}'::text[]) into d from tenant_private.staff_denials where store_id=s and user_id=u;
 select coalesce((select actions from tenant_private.receivable_grants where store_id=s and user_id=u and branch_id is not distinct from b),'{}'::text[]) into rg;
 select * into pg from tenant_private.procurement_grants where store_id=s and user_id=u;
 with matrix(action,role_access,grant_access,write_action,depends,editable) as (values
 ('sell',r='cashier',true,true,array[]::text[],true),
 ('stock_adjust',r='stock',true,true,array['catalog_read'],true),
 ('stock_transfer',r='stock',true,true,array[]::text[],true),
 ('product_create',r='stock' and b is null,true,true,array[]::text[],true),
 ('repair_transition',r='tech',true,true,array['repair_read'],true),
 ('repair_evidence',r='tech',true,true,array['repair_read'],true),
 ('attendance',r in ('cashier','stock','tech'),true,true,array[]::text[],true),
 ('catalog_read',r in ('cashier','stock'),true,false,array[]::text[],true),
 ('stock_history_read',r='stock',true,false,array['catalog_read'],true),
 ('sales_read',r='cashier',true,false,array[]::text[],true),
 ('repair_read',r='tech',true,false,array[]::text[],true),
 ('product_edit',r='stock' and b is null,true,true,array[]::text[],true),
 ('repair_task_finish',r='tech',true,true,array['repair_read','repair_transition'],true),
 ('repair_create',false,true,true,array[]::text[],false),
 ('product_price_edit',false,true,true,array[]::text[],false),
 ('customer_create',r='cashier','read'=any(rg) and 'customer_create'=any(rg),true,array['receivable_read'],true),
 ('debt_payment',r='cashier','read'=any(rg) and 'debt_payment'=any(rg),true,array['receivable_read'],true),
 ('quote_create',r='cashier',true,true,array['catalog_read'],true),
 ('quote_read',r='cashier',true,false,array[]::text[],true),
 ('receipt_read',r in ('cashier','tech'),true,false,case when r='tech' then array['repair_read'] else array['sales_read'] end,true),
 ('warranty_read',r='cashier',true,false,array['sales_read'],true),
 ('receivable_read',r='cashier','read'=any(rg),true,array[]::text[],true),
 ('customer_edit',r='cashier','read'=any(rg) and 'customer_edit'=any(rg),true,array['receivable_read'],true),
 ('credit_sale',r='cashier','read'=any(rg) and 'credit_sale'=any(rg),true,array['receivable_read','sell'],true),
 ('standalone_open',r='cashier','read'=any(rg) and 'standalone_open'=any(rg),true,array['receivable_read'],true),
 ('standalone_payment',r='cashier','read'=any(rg) and 'standalone_payment'=any(rg),true,array['receivable_read','debt_payment'],true),
 ('payable_manage',r='cashier','read'=any(rg) and 'payable_manage'=any(rg),true,array['receivable_read'],true),
 ('procurement_read',r='stock',coalesce(pg.read_allowed,false),false,array[]::text[],true),
 ('supplier_write',r='stock',coalesce(pg.read_allowed and pg.manage_suppliers,false),true,array['procurement_read'],true),
 ('purchase_write',r='stock',coalesce(pg.read_allowed and pg.receive_credit,false),true,array['procurement_read','catalog_read','stock_adjust'],true),
 ('notifications_read',r in ('stock','tech'),true,false,array[]::text[],true),
 ('orders_read',false,true,false,array[]::text[],false),('orders_write',false,true,true,array[]::text[],false),
 ('warranty_write',false,true,true,array[]::text[],false),('returns_read',false,true,false,array[]::text[],false),('returns_write',false,true,true,array[]::text[],false),
 ('used_read',false,true,false,array[]::text[],false),('used_write',false,true,true,array[]::text[],false),
 ('loyalty_read',false,true,false,array[]::text[],false),('invoice_repair',false,true,true,array[]::text[],false),('receipt_write',false,true,true,array[]::text[],false),
 ('finance_read',false,true,false,array[]::text[],false),('finance_write',false,true,true,array[]::text[],false),
 ('staff_admin',false,true,true,array[]::text[],false),('store_admin',false,true,true,array[]::text[],false),('backup_admin',false,true,true,array[]::text[],false)
 )
 select jsonb_agg(jsonb_build_object('action',action,'editable',enabled and r<>'owner' and editable and role_access,'denied',action=any(d),'effective',enabled and ((r='owner' and (not write_action or licensed)) or (role_access and grant_access and (not write_action or licensed) and not action=any(d) and not depends&&d)),'reason',case when not enabled then 'inactive' when r='owner' then case when write_action and not licensed then 'license' else 'allowed' end when not role_access then 'role' when not grant_access then 'grant' when write_action and not licensed then 'license' when action=any(d) then 'denied' when depends&&d then 'dependency' else 'allowed' end) order by action) into items from matrix;
 return jsonb_build_object('user',u,'role',r,'active',enabled,'branch',b,'denials',to_jsonb(d),'operations',items);
end $$;
create function public.mt_staff_access_matrix(s uuid,u uuid)
returns jsonb language sql stable set search_path='' as $$select tenant_private.staff_access_matrix(s,u)$$;
revoke all on function tenant_private.staff_access_matrix(uuid,uuid),public.mt_staff_access_matrix(uuid,uuid) from public,anon,authenticated;
grant execute on function tenant_private.staff_access_matrix(uuid,uuid),public.mt_staff_access_matrix(uuid,uuid) to authenticated;
create function tenant_private.staff_access_save(s uuid,u uuid,expected text[],desired text[],expected_role text,expected_branch uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare state jsonb;previous text[];a text;
begin
 perform tenant_private.owner_write(s);
 state:=tenant_private.staff_access_matrix(s,u);
 if state->>'role'='owner' or state->>'active'<>'true' or state->>'role' is distinct from expected_role or (state->>'branch')::uuid is distinct from expected_branch then raise exception 'Employee changed; reload' using errcode='22023';end if;
 select coalesce(array_agg(value order by value),'{}'::text[]) into previous from jsonb_array_elements_text(state->'denials');
 if expected is null or desired is null or cardinality(expected)>64 or cardinality(desired)>64 or array_position(desired,null) is not null or previous is distinct from (select coalesce(array_agg(distinct x order by x),'{}'::text[]) from unnest(expected)x) then raise exception 'Permissions changed; reload' using errcode='22023';end if;
 for a in select distinct x from unnest(previous||desired)x where (x=any(previous)) is distinct from (x=any(desired)) loop
  if not exists(select 1 from jsonb_array_elements(state->'operations') j where j->>'action'=a and j->>'editable'='true') then raise exception 'Operation outside current role' using errcode='22023';end if;
  perform tenant_private.staff_permission_set(s,u,a,not a=any(desired));
 end loop;
 return tenant_private.staff_access_matrix(s,u);
end $$;
create function public.mt_staff_access_save(s uuid,u uuid,expected text[],desired text[],expected_role text,expected_branch uuid)
returns jsonb language sql set search_path='' as $$select tenant_private.staff_access_save(s,u,expected,desired,expected_role,expected_branch)$$;
revoke all on function tenant_private.staff_access_save(uuid,uuid,text[],text[],text,uuid),public.mt_staff_access_save(uuid,uuid,text[],text[],text,uuid) from public,anon,authenticated;
grant execute on function tenant_private.staff_access_save(uuid,uuid,text[],text[],text,uuid),public.mt_staff_access_save(uuid,uuid,text[],text[],text,uuid) to authenticated;
commit;
