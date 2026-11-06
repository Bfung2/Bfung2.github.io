-- Apex Computers: employee permissions, login history, activity audit, and server-side access controls.
-- Run after 202611060001_employee_contact_email.sql.

alter table public.employee_profiles
  add column if not exists permissions jsonb not null default
    '{"orders":true,"requests":true,"customer_details":true,"claim_jobs":true,"update_status":true}'::jsonb;

update public.employee_profiles
set permissions = '{"orders":true,"requests":true,"customer_details":true,"claim_jobs":true,"update_status":true}'::jsonb
where permissions is null;

create table if not exists public.employee_activity_logs (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  actor_user_id uuid references auth.users(id) on delete set null,
  actor_name text not null default 'Unknown',
  target_user_id uuid references auth.users(id) on delete set null,
  event_type text not null,
  job_kind text,
  job_id text,
  details jsonb not null default '{}'::jsonb
);

create index if not exists employee_activity_logs_created_at_idx
  on public.employee_activity_logs (created_at desc);
create index if not exists employee_activity_logs_actor_idx
  on public.employee_activity_logs (actor_user_id, created_at desc);
create index if not exists employee_activity_logs_target_idx
  on public.employee_activity_logs (target_user_id, created_at desc);

alter table public.employee_activity_logs enable row level security;
drop policy if exists "Owner reads employee activity logs" on public.employee_activity_logs;
create policy "Owner reads employee activity logs"
on public.employee_activity_logs for select to authenticated
using ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com');

revoke all on public.employee_activity_logs from anon, authenticated;
grant select on public.employee_activity_logs to authenticated;

-- Employees may read their own profile, but may not enumerate or edit other profiles.
drop policy if exists "Owner manages employee profiles" on public.employee_profiles;
create policy "Owner manages employee profiles"
on public.employee_profiles for all to authenticated
using ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com')
with check ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com');
drop policy if exists "Employees read own profile" on public.employee_profiles;
create policy "Employees read own profile"
on public.employee_profiles for select to authenticated
using (user_id = auth.uid() and active = true);

-- Remove direct employee table reads. Employees must use the permission-aware RPC below,
-- which strips customer-identifying fields when customer_details is disabled.
drop policy if exists "Employees read available or assigned orders" on public.apex_orders;
drop policy if exists "Employees read available or assigned requests" on public.apex_service_requests;

create or replace function public.apex_employee_get_jobs()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_orders_enabled boolean;
  v_requests_enabled boolean;
  v_customer_details boolean;
  v_orders jsonb := '[]'::jsonb;
  v_requests jsonb := '[]'::jsonb;
begin
  select coalesce((permissions ->> 'orders')::boolean, false),
         coalesce((permissions ->> 'requests')::boolean, false),
         coalesce((permissions ->> 'customer_details')::boolean, false)
    into v_orders_enabled, v_requests_enabled, v_customer_details
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
    where o.assigned_to is null or o.assigned_to = v_user;
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
    where r.assigned_to is null or r.assigned_to = v_user;
  end if;

  return jsonb_build_object('orders', v_orders, 'requests', v_requests);
end;
$$;

create or replace function public.apex_record_employee_login(p_user_agent text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_name text;
begin
  select display_name into v_name
  from public.employee_profiles
  where user_id = auth.uid() and active = true;

  if not found then
    raise exception 'Active employee account required';
  end if;

  insert into public.employee_activity_logs
    (actor_user_id, actor_name, target_user_id, event_type, details)
  values
    (auth.uid(), v_name, auth.uid(), 'login',
     jsonb_build_object('user_agent', left(coalesce(p_user_agent, ''), 300)));
end;
$$;

create or replace function public.apex_claim_job(job_kind text, job_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  changed integer;
  v_permissions jsonb;
begin
  select permissions into v_permissions
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
    where id = job_id and assigned_to is null;
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
set search_path = public
as $$
declare
  changed integer;
  v_permissions jsonb;
begin
  select permissions into v_permissions
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
    where id = job_id and assigned_to = auth.uid();
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

-- Audit all authenticated owner/employee changes to orders and service requests.
create or replace function public.apex_log_job_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_name text;
  v_old jsonb;
  v_new jsonb;
  v_id text;
  v_changed jsonb := '[]'::jsonb;
  v_event text;
begin
  if v_actor is null then
    if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
  end if;

  if TG_OP <> 'INSERT' then v_old := to_jsonb(OLD); end if;
  if TG_OP <> 'DELETE' then v_new := to_jsonb(NEW); end if;
  v_id := coalesce(v_new ->> 'id', v_old ->> 'id');

  select display_name into v_name
  from public.employee_profiles where user_id = v_actor;

  if v_name is null then
    if lower(coalesce(auth.jwt() ->> 'email','')) = 'apexcomputers039@gmail.com' then
      v_name := 'Owner';
    else
      v_name := 'Authenticated user';
    end if;
  end if;

  if TG_OP = 'UPDATE' then
    select coalesce(jsonb_agg(k), '[]'::jsonb) into v_changed
    from jsonb_object_keys(v_old) as keys(k)
    where v_old -> k is distinct from v_new -> k;
  end if;

  v_event := lower(TG_ARGV[0]) || '_' || lower(TG_OP);
  insert into public.employee_activity_logs
    (actor_user_id, actor_name, event_type, job_kind, job_id, details)
  values
    (v_actor, v_name, v_event, TG_ARGV[0], v_id,
     jsonb_build_object('changed_fields', v_changed));

  if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
end;
$$;

drop trigger if exists apex_orders_activity_audit on public.apex_orders;
create trigger apex_orders_activity_audit
after insert or update or delete on public.apex_orders
for each row execute function public.apex_log_job_activity('order');

drop trigger if exists apex_service_requests_activity_audit on public.apex_service_requests;
create trigger apex_service_requests_activity_audit
after insert or update or delete on public.apex_service_requests
for each row execute function public.apex_log_job_activity('request');

revoke all on function public.apex_employee_get_jobs() from public;
revoke all on function public.apex_record_employee_login(text) from public;
revoke all on function public.apex_claim_job(text,text) from public;
revoke all on function public.apex_employee_update_job(text,text,text) from public;
grant execute on function public.apex_employee_get_jobs() to authenticated;
grant execute on function public.apex_record_employee_login(text) to authenticated;
grant execute on function public.apex_claim_job(text,text) to authenticated;
grant execute on function public.apex_employee_update_job(text,text,text) to authenticated;

-- The audit table is append-only for clients. Only security-definer functions/triggers write to it.
