begin;
alter table public.apex_refund_records add column if not exists verified_at timestamptz;
alter table public.apex_refund_records add column if not exists capture_id text;
create table if not exists public.apex_refund_attempts(order_id text primary key references public.apex_orders(id),request_id uuid not null default gen_random_uuid(),created_at timestamptz not null default now(),refund_id text);
alter table public.apex_refund_attempts enable row level security;
revoke all on public.apex_refund_attempts from public,anon,authenticated;
grant all on public.apex_refund_attempts,public.apex_refund_records to service_role;
create or replace function public.apex_reserve_full_refund(p_order text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ord public.apex_orders;attempt public.apex_refund_attempts;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Payment server required' using errcode='42501';end if;
 select * into ord from public.apex_orders where id=p_order for update;
 if not found or ord.is_test or nullif(ord.paypal_capture_id,'') is null then raise exception 'Captured real order required';end if;
 select * into attempt from public.apex_refund_attempts where order_id=p_order;
 if found then return to_jsonb(attempt);end if;
 if exists(select 1 from public.apex_refund_records where order_id=p_order) then raise exception 'Prior refund exists; reconcile in PayPal';end if;
 insert into public.apex_refund_attempts(order_id) values(p_order) returning * into attempt;
 return to_jsonb(attempt);
end;
$$;
create or replace function public.apex_record_verified_refund(p_order text,p_reference text,p_capture text,p_amount bigint,p_tax bigint) returns boolean
language plpgsql security definer set search_path='' as $$
declare ord public.apex_orders;prior public.apex_refund_records;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Payment server required' using errcode='42501';end if;
 select * into ord from public.apex_orders where id=p_order for update;
 if not found or ord.is_test or ord.paypal_capture_id is distinct from p_capture or p_reference is null or p_reference !~ '^[A-Za-z0-9-]{8,100}$' or p_amount is null or p_tax is null or p_amount<=0 or p_tax<0 or p_tax>p_amount then raise exception 'Invalid verified refund';end if;
 select * into prior from public.apex_refund_records where reference=p_reference;
 if found then
 if prior.order_id<>p_order or prior.amount_cents<>p_amount or prior.tax_cents<>p_tax then raise exception 'Recorded details conflict; review required';end if;
 else
 if coalesce((select sum(amount_cents) from public.apex_refund_records where order_id=p_order),0)+p_amount>round(ord.total*100) or coalesce((select sum(tax_cents) from public.apex_refund_records where order_id=p_order),0)+p_tax>round(ord.tax*100) then raise exception 'Refund exceeds recorded payment or tax';end if;
 insert into public.apex_refund_records(reference,order_id,amount_cents,tax_cents) values(p_reference,p_order,p_amount,p_tax);
 end if;
 update public.apex_refund_records set verified_at=now(),capture_id=p_capture where reference=p_reference;
 return true;
end;
$$;
revoke all on function public.apex_reserve_full_refund(text),public.apex_record_verified_refund(text,text,text,bigint,bigint) from public,anon,authenticated;
grant execute on function public.apex_reserve_full_refund(text),public.apex_record_verified_refund(text,text,text,bigint,bigint) to service_role;
notify pgrst,'reload schema';
create or replace function public.apex_owner_record_backup() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 table_name text; rows_json jsonb; tables_json jsonb:='{}'; counts_json jsonb:='{}';
 missing_json jsonb:='[]'; extra_json jsonb; result_json jsonb;
 allowed_tables text[]:=array[
 'apex_refund_attempts','apex_order_costs','apex_refund_records','apex_finance_history','apex_orders','apex_paid_notifications','apex_promo_codes','apex_service_requests',
 'apex_shop_policies','apex_shop_policy_history','apex_test_checkout_settings',
 'customer_order_links','customer_order_tracking','customer_order_tracking_events',
 'customer_profiles','customer_saved_addresses','employee_activity_logs','employee_profiles',
 'orders','service_requests','staff_contribution_amounts','staff_customer_drafts',
 'staff_employee_contacts','staff_notes','staff_order_notes','staff_role_assignments',
 'staff_roles','staff_sales_credits','staff_sales_settlements','staff_shifts'];
begin
 if not coalesce(public.apex_is_owner(),false) then
 raise exception 'Verified owner authenticator required for private backup' using errcode='42501'; end if;
 foreach table_name in array allowed_tables loop
  if pg_catalog.to_regclass(pg_catalog.format('public.%I',table_name)) is null then
   missing_json:=missing_json||pg_catalog.jsonb_build_array(table_name);continue;
  end if;
  execute pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(t)),''[]''::jsonb) from public.%I t',table_name) into rows_json;
  tables_json:=tables_json||pg_catalog.jsonb_build_object(table_name,rows_json);
  counts_json:=counts_json||pg_catalog.jsonb_build_object(table_name,pg_catalog.jsonb_array_length(rows_json));
  if pg_catalog.octet_length(tables_json::text)>16777216 then
   raise exception 'Record export exceeds 16 MiB. Use the encrypted pg_dump backup procedure instead';
  end if;
 end loop;
 select coalesce(jsonb_agg(tablename order by tablename),'[]') into extra_json from pg_catalog.pg_tables
 where schemaname='public' and not (tablename=any(allowed_tables));
 result_json:=pg_catalog.jsonb_build_object('format','apex-business-records','version',1,
 'created_at',now(),'tables',tables_json,'counts',counts_json,
 'missing_tables',missing_json,'unlisted_tables',extra_json,
 'excluded',jsonb_build_array('Auth accounts, passwords, MFA and sessions','Database schema, roles and policies','Storage file bytes','Edge secrets and provider configuration','Public catalog stored in GitHub'),
 'automatic_restore',false);
 return result_json;
end;
$$;
revoke all on function public.apex_owner_record_backup() from public,anon;
grant execute on function public.apex_owner_record_backup() to authenticated;
notify pgrst,'reload schema';
commit;
