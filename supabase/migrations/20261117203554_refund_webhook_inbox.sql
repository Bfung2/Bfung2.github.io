begin;
create table if not exists public.apex_paypal_webhook_config(environment text primary key check(environment in ('live','sandbox')),webhook_id text not null);
create table if not exists public.apex_refund_inbox(reference text primary key,order_id text not null references public.apex_orders(id),capture_id text not null,amount_cents bigint not null check(amount_cents>0),received_at timestamptz not null default now());
alter table public.apex_paypal_webhook_config enable row level security;
alter table public.apex_refund_inbox enable row level security;
revoke all on public.apex_paypal_webhook_config,public.apex_refund_inbox from public,anon,authenticated;
grant all on public.apex_paypal_webhook_config,public.apex_refund_inbox to service_role;
create or replace function public.apex_owner_refund_inbox() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(public.apex_is_owner(),false) then raise exception 'Verified owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(t)) from (select i.reference,i.order_id,i.amount_cents,i.received_at from public.apex_refund_inbox i where not exists(select 1 from public.apex_refund_records r where r.reference=i.reference and r.verified_at is not null) order by i.received_at desc limit 100) t),'[]');
end;
$$;
revoke all on function public.apex_owner_refund_inbox() from public,anon;
grant execute on function public.apex_owner_refund_inbox() to authenticated;
notify pgrst,'reload schema';
create or replace function public.apex_owner_record_backup() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 table_name text; rows_json jsonb; tables_json jsonb:='{}'; counts_json jsonb:='{}';
 missing_json jsonb:='[]'; extra_json jsonb; result_json jsonb;
 allowed_tables text[]:=array[
 'apex_paypal_webhook_config','apex_refund_inbox','apex_refund_attempts','apex_order_costs','apex_refund_records','apex_finance_history','apex_orders','apex_paid_notifications','apex_promo_codes','apex_service_requests',
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
