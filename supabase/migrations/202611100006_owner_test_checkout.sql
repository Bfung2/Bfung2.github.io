begin;
alter table public.apex_orders add column if not exists is_test boolean not null default false;
create table if not exists public.apex_test_checkout_settings(
 singleton boolean primary key default true check(singleton),
 code text not null check(code ~ '^[A-Z0-9_-]{3,40}$'),
 enabled boolean not null default false
);
insert into public.apex_test_checkout_settings(singleton,code,enabled) values(true,'APX-TEST',false) on conflict do nothing;
alter table public.apex_test_checkout_settings enable row level security;
revoke all on public.apex_test_checkout_settings from public,anon,authenticated;
grant all on public.apex_test_checkout_settings to service_role;
create or replace function public.apex_owner_test_code(p_save boolean default false,p_code text default null,p_enabled boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501';end if;
 if p_save then
  if exists(select 1 from public.apex_promo_codes where code=upper(trim(p_code))) then raise exception 'Use a code different from ordinary discount codes';end if;
  update public.apex_test_checkout_settings set code=upper(trim(p_code)),enabled=p_enabled where singleton;
  perform public.apex_staff_audit('test_checkout_settings_updated',null,jsonb_build_object('enabled',p_enabled));
 end if;
 return (select jsonb_build_object('code',code,'enabled',enabled) from public.apex_test_checkout_settings where singleton);
end;
$$;
create or replace function public.apex_owner_test_checkout(p_code text,p_order jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare settings public.apex_test_checkout_settings;o public.apex_orders;v_address public.apex_orders.shipping_address%type;
begin
 if not public.apex_is_owner() then raise exception 'Only the owner can simulate a checkout' using errcode='42501';end if;
 select * into settings from public.apex_test_checkout_settings where singleton for update;
 if not settings.enabled or settings.code is distinct from upper(trim(p_code)) then raise exception 'Test code is disabled or invalid';end if;
 if length(trim(coalesce(p_order->>'name',''))) not between 1 and 120 or coalesce(p_order->>'email','') !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or length(coalesce(p_order->>'email',''))>254 or length(coalesce(p_order->>'address','')) not between 5 and 500 or length(coalesce(p_order->>'phone',''))>40 then raise exception 'Enter valid customer details';end if;
 if jsonb_typeof(p_order->'items') is distinct from 'array' or jsonb_array_length(p_order->'items') not between 1 and 50 then raise exception 'Choose test items';end if;
 if nullif(p_order->>'handoff_token','') is null then raise exception 'Open an employee customer link to test this workflow';end if;
 select shipping_address into v_address from jsonb_populate_record(null::public.apex_orders,jsonb_build_object('shipping_address',p_order->>'address'));
 insert into public.apex_orders(id,ref,customer_name,customer_email,customer_phone,shipping_address,notes,items,subtotal,shipping,tax,total,status,handoff_token,is_test,pricing_locked)
 values('test-'||gen_random_uuid()::text,'TEST-'||upper(substr(gen_random_uuid()::text,1,8)),trim(p_order->>'name'),trim(p_order->>'email'),coalesce(p_order->>'phone',''),v_address,'OWNER TEST — NO PAYMENT TAKEN',p_order->'items',0,0,0,0,'requested',(p_order->>'handoff_token')::uuid,true,true) returning * into o;
 -- Keep the original employee identity on the test order, but exclude simulated sales from attribution totals.
 delete from public.staff_sales_credits where job_kind='order' and job_id=o.id;
 update public.apex_orders set status='test_completed' where id=o.id returning * into o;
 perform public.apex_staff_audit('test_checkout_completed',o.sales_employee_id,jsonb_build_object('order_id',o.id,'is_test',true));
 return jsonb_build_object('id',o.id,'ref',o.ref,'status',o.status);
end;
$$;
revoke all on function public.apex_owner_test_code(boolean,text,boolean),public.apex_owner_test_checkout(text,jsonb) from public,anon,authenticated;
grant execute on function public.apex_owner_test_code(boolean,text,boolean),public.apex_owner_test_checkout(text,jsonb) to authenticated;

create or replace function public.apex_enqueue_paid_notifications() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if NEW.status<>'paid' and not (NEW.is_test and NEW.status='test_completed') then return NEW;end if;
 insert into public.apex_paid_notifications(order_id,recipient_kind,recipient,payload)
 values(NEW.id,'owner','apexcomputers039@gmail.com',to_jsonb(NEW)-'handoff_token') on conflict do nothing;
 if NEW.sales_employee_id is not null and public.apex_effective_permissions(NEW.sales_employee_id)->'own_sales_receipts'='true'::jsonb then
  insert into public.apex_paid_notifications(order_id,recipient_kind,employee_id,recipient,payload)
  values(NEW.id,'employee',NEW.sales_employee_id,coalesce((select email from public.employee_profiles where user_id=NEW.sales_employee_id and active),''),to_jsonb(NEW)-'handoff_token') on conflict do nothing;
 end if;
 return NEW;
end;
$$;

create or replace function public.apex_market_order_progress() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(public.apex_staff_can('prepare_sales'),false) then raise exception 'Sales permission required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('draft_id',d.id,'job_id',d.submitted_job_id,'kind',d.kind,'submitted_at',d.submitted_at,
 'payment_status',case when coalesce((snap.data->>'is_test')::boolean,false) then 'test_completed' when d.kind='request' then 'service_request' when o.status='paid' or exists(select 1 from public.apex_paid_notifications n where n.order_id=d.submitted_job_id) then 'paid' when d.submitted_at is not null then 'awaiting_payment' else 'waiting_customer' end,
 'order',case when o.status='paid' or exists(select 1 from public.apex_paid_notifications n where n.order_id=d.submitted_job_id) then
 jsonb_build_object('ref',snap.data->'ref','customer_name',case when public.apex_is_owner() or public.apex_staff_can('own_sales_receipts') then snap.data->'customer_name' else null end,'customer_email',case when public.apex_is_owner() or public.apex_staff_can('own_sales_receipts') then snap.data->'customer_email' else null end,'customer_phone',case when public.apex_is_owner() or public.apex_staff_can('own_sales_receipts') then snap.data->'customer_phone' else null end,'shipping_address',case when public.apex_is_owner() or public.apex_staff_can('own_sales_receipts') then snap.data->'shipping_address' else null end,'items',snap.data->'items','total',snap.data->'total','sales_employee_name',snap.data->'sales_employee_name','sales_employee_code',snap.data->'sales_employee_code') else null end,
 'notifications',coalesce((select jsonb_agg(jsonb_build_object('recipient_kind',n.recipient_kind,'state',n.state,'error',case when public.apex_is_owner() then n.error else null end)) from public.apex_paid_notifications n where n.order_id=d.submitted_job_id),'[]')) order by d.created_at desc)
 from public.staff_customer_drafts d left join public.apex_orders o on d.kind='order' and o.id=d.submitted_job_id
 left join lateral (select coalesce((select n.payload from public.apex_paid_notifications n where n.order_id=d.submitted_job_id limit 1),to_jsonb(o)) as data) snap on true
 where public.apex_is_owner() or d.employee_id=auth.uid()),'[]');
end;
$$;

create or replace function public.apex_manage_promos(p_action text default 'list',p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_code text:=upper(trim(p_data->>'code'));
begin
 if not coalesce(public.apex_staff_can('manage_promos'),false) then raise exception 'Promo management permission required' using errcode='42501';end if;
 if p_action='save' then
  if exists(select 1 from public.apex_test_checkout_settings where code=v_code) then raise exception 'This code is reserved for owner test checkout';end if;
  insert into public.apex_promo_codes(code,kind,amount,minimum_subtotal,enabled,expires_at)
  values(v_code,p_data->>'kind',(p_data->>'amount')::numeric,coalesce((p_data->>'minimum_subtotal')::numeric,0),coalesce((p_data->>'enabled')::boolean,true),nullif(p_data->>'expires_at','')::timestamptz)
  on conflict(code) do update set kind=excluded.kind,amount=excluded.amount,minimum_subtotal=excluded.minimum_subtotal,enabled=excluded.enabled,expires_at=excluded.expires_at,updated_at=now();
 elsif p_action='delete' then delete from public.apex_promo_codes where code=v_code;
 elsif p_action<>'list' then raise exception 'Invalid promo action';end if;
 if p_action<>'list' then perform public.apex_staff_audit('promo_'||p_action,null,jsonb_build_object('code',v_code));end if;
 return coalesce((select jsonb_agg(to_jsonb(p) order by code) from public.apex_promo_codes p),'[]');
end;
$$;

create or replace function public.apex_employee_get_jobs()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_orders_enabled boolean;
  v_requests_enabled boolean;
  v_customer_details boolean;
  v_claim_enabled boolean;
  v_orders jsonb := '[]'::jsonb;
  v_requests jsonb := '[]'::jsonb;
begin
  select coalesce((public.apex_effective_permissions(v_user) ->> 'orders')::boolean, false),
         coalesce((public.apex_effective_permissions(v_user) ->> 'requests')::boolean, false),
         coalesce((public.apex_effective_permissions(v_user) ->> 'customer_details')::boolean, false),
         coalesce((public.apex_effective_permissions(v_user) ->> 'claim_jobs')::boolean, false)
    into v_orders_enabled, v_requests_enabled, v_customer_details, v_claim_enabled
  from public.employee_profiles
  where user_id = v_user and active = true;

  if not found then
    raise exception 'Active employee account required';
  end if;

  if v_orders_enabled then
    select coalesce(jsonb_agg(
      case when v_customer_details then to_jsonb(o)
      else to_jsonb(o) - array['customer_name','customer_email','customer_phone','shipping_address']::text[]
      end
      order by o.created_at desc
    ), '[]'::jsonb)
    into v_orders
    from public.apex_orders o
    where not o.is_test and (o.assigned_to = v_user or (v_claim_enabled and o.assigned_to is null));
  end if;

  if v_requests_enabled then
    select coalesce(jsonb_agg(
      case when v_customer_details then to_jsonb(r)
      else to_jsonb(r) - array['customer_name','customer_email','customer_phone','customer_address']::text[]
      end
      order by r.created_at desc
    ), '[]'::jsonb)
    into v_requests
    from public.apex_service_requests r
    where r.assigned_to = v_user or (v_claim_enabled and r.assigned_to is null);
  end if;

  return jsonb_build_object('orders', v_orders, 'requests', v_requests);
end;
$$;
create or replace function public.apex_claim_job(job_kind text, job_id text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
  v_permissions jsonb;
begin
  select public.apex_effective_permissions(auth.uid()) into v_permissions
  from public.employee_profiles
  where user_id = auth.uid() and active = true;

  if not found then raise exception 'Active employee account required'; end if;
  if coalesce((v_permissions ->> 'claim_jobs')::boolean, false) is not true then
    raise exception 'Your account does not have permission to claim jobs';
  end if;

  if job_kind = 'order' then
    if coalesce((v_permissions ->> 'orders')::boolean, false) is not true then
      raise exception 'Order access is not enabled for your account';
    end if;
    update public.apex_orders set assigned_to = auth.uid()
    where id = job_id and assigned_to is null and not is_test;
  elsif job_kind = 'request' then
    if coalesce((v_permissions ->> 'requests')::boolean, false) is not true then
      raise exception 'Service-request access is not enabled for your account';
    end if;
    update public.apex_service_requests set assigned_to = auth.uid()
    where id = job_id and assigned_to is null;
  else
    raise exception 'Invalid job type';
  end if;
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;
create or replace function public.apex_employee_update_job(job_kind text, job_id text, new_status text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
  v_permissions jsonb;
begin
  select public.apex_effective_permissions(auth.uid()) into v_permissions
  from public.employee_profiles
  where user_id = auth.uid() and active = true;

  if not found then raise exception 'Active employee account required'; end if;
  if coalesce((v_permissions ->> 'update_status')::boolean, false) is not true then
    raise exception 'Your account does not have permission to update job status';
  end if;
  if new_status not in ('requested','working','waiting','completed','invoiced','shipped','delivered') then
    raise exception 'Invalid status';
  end if;

  if job_kind = 'order' then
    if coalesce((v_permissions ->> 'orders')::boolean, false) is not true then
      raise exception 'Order access is not enabled for your account';
    end if;
    update public.apex_orders set status = new_status
    where id = job_id and assigned_to = auth.uid() and not is_test;
  elsif job_kind = 'request' then
    if coalesce((v_permissions ->> 'requests')::boolean, false) is not true then
      raise exception 'Service-request access is not enabled for your account';
    end if;
    update public.apex_service_requests set status = new_status
    where id = job_id and assigned_to = auth.uid();
  else
    raise exception 'Invalid job type';
  end if;
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;
notify pgrst,'reload schema';
commit;
