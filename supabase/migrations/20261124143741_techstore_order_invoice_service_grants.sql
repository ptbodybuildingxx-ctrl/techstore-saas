begin;
grant select on public.ts_invoice_settings to service_role;
grant insert (id,request_id,actor,customer_id,kind,document,request_args) on public.ts_invoices to service_role;
grant usage on sequence public.ts_invoices_number_seq to service_role;
commit;