begin;
create table if not exists public.apex_order_costs(order_id text primary key references public.apex_orders(id),costs jsonb not null,revision integer not null default 1,updated_at timestamptz not null default now());
create table if not exists public.apex_refund_records(reference text primary key,order_id text not null references public.apex_orders(id),amount_cents bigint not null check(amount_cents>0),tax_cents bigint not null check(tax_cents>=0 and tax_cents<=amount_cents),recorded_at timestamptz not null default now());
create table if not exists public.apex_finance_history(id bigint generated always as identity primary key,order_id text not null,old_costs jsonb,new_costs jsonb,recorded_at timestamptz not null default now());
alter table public.apex_order_costs enable row level security;
alter table public.apex_refund_records enable row level security;
alter table public.apex_finance_history enable row level security;
revoke all on public.apex_order_costs,public.apex_refund_records,public.apex_finance_history from public,anon,authenticated;
create or replace function public.apex_owner_finances(p_action text default 'list',p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.apex_orders;c public.apex_order_costs;r public.apex_refund_records;k text;v numeric;amount bigint;tax bigint;v_reference text;
begin
 if not coalesce(public.apex_is_owner(),false) then raise exception 'Verified owner required' using errcode='42501';end if;
 if p_action='list' then
 return coalesce((select jsonb_agg(to_jsonb(t)) from (
 select ord.id,ord.ref,ord.created_at,ord.subtotal,ord.discount_amount,ord.shipping,ord.tax,ord.total,
 (nullif(ord.paypal_capture_id,'') is not null) as paid,ord.is_test,cost.costs,coalesce(cost.revision,0) as revision,
 coalesce((select jsonb_agg(to_jsonb(refund_row)) from public.apex_refund_records refund_row where refund_row.order_id=ord.id),'[]') as refunds
 from public.apex_orders ord left join public.apex_order_costs cost on cost.order_id=ord.id
 where not ord.is_test order by ord.created_at desc,ord.id limit 100) t),'[]');
 end if;
 select * into o from public.apex_orders where id=p_data->>'order_id' for update;
 if not found or o.is_test or nullif(o.paypal_capture_id,'') is null then raise exception 'A real captured order is required';end if;
 if p_action='costs' then
 select * into c from public.apex_order_costs where order_id=o.id;
 if coalesce(c.revision,0) is distinct from (p_data->>'revision')::integer then raise exception 'Costs changed. Refresh before saving';end if;
 if jsonb_typeof(p_data->'costs')<>'object' or p_data->'costs' is null then raise exception 'Enter all actual costs';end if;
 foreach k in array array['supplier','postage','processing','packing','commissions','other'] loop
 if jsonb_typeof(p_data->'costs'->k)<>'number' or p_data->'costs'->k is null then raise exception 'Enter every actual cost in cents';end if;
 v:=(p_data->'costs'->>k)::numeric;
 if v<0 or v>100000000 or v<>trunc(v) then raise exception 'Invalid cost cents';end if;
 end loop;
 insert into public.apex_finance_history(order_id,old_costs,new_costs) values(o.id,c.costs,p_data->'costs');
 insert into public.apex_order_costs(order_id,costs) values(o.id,p_data->'costs') on conflict(order_id) do update set costs=excluded.costs,revision=apex_order_costs.revision+1,updated_at=now();
 return 'true';
 elsif p_action='refund' then
 v_reference:=trim(p_data->>'reference');amount:=(p_data->>'amount_cents')::bigint;tax:=(p_data->>'tax_cents')::bigint;
 if v_reference is null or v_reference !~ '^[A-Za-z0-9-]{8,100}$' or amount is null or amount<=0 or tax is null or tax<0 or tax>amount then raise exception 'Enter the completed provider refund reference and valid amounts';end if;
 select * into r from public.apex_refund_records where apex_refund_records.reference=v_reference;
 if found then
 if r.order_id=o.id and r.amount_cents=amount and r.tax_cents=tax then return 'true';end if;
 raise exception 'Refund reference already recorded with different details';end if;
 if amount+coalesce((select sum(amount_cents) from public.apex_refund_records where order_id=o.id),0)>round(o.total*100) or tax+coalesce((select sum(tax_cents) from public.apex_refund_records where order_id=o.id),0)>round(o.tax*100) then raise exception 'Refund exceeds captured amount or collected tax';end if;
 insert into public.apex_refund_records values(v_reference,o.id,amount,tax,now());return 'true';
 end if;
 raise exception 'Unknown financial action';
end;
$$;
revoke all on function public.apex_owner_finances(text,jsonb) from public,anon;
grant execute on function public.apex_owner_finances(text,jsonb) to authenticated;
notify pgrst,'reload schema';

-- Manual business-record export; auth credentials, Storage objects and schema are excluded.
-- STABLE uses the calling statement's snapshot across all included tables.
create or replace function public.apex_owner_record_backup() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 table_name text; rows_json jsonb; tables_json jsonb:='{}'; counts_json jsonb:='{}';
 missing_json jsonb:='[]'; extra_json jsonb; result_json jsonb;
 allowed_tables text[]:=array[
 'apex_order_costs','apex_refund_records','apex_finance_history','apex_orders','apex_paid_notifications','apex_promo_codes','apex_service_requests',
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
