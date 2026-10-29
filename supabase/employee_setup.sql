-- Apex Computers employee accounts, shared service requests, and job assignments
-- Run this entire script in Supabase SQL Editor as the project owner.

create table if not exists public.employee_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.employee_profiles enable row level security;

drop policy if exists "Owner manages employee profiles" on public.employee_profiles;
create policy "Owner manages employee profiles"
on public.employee_profiles for all to authenticated
using ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com')
with check ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com');

drop policy if exists "Employees read own profile" on public.employee_profiles;
create policy "Employees read own profile"
on public.employee_profiles for select to authenticated
using (user_id = auth.uid() and active = true);

alter table public.apex_orders
  add column if not exists assigned_to uuid references public.employee_profiles(user_id) on delete set null;

create table if not exists public.apex_service_requests (
  id text primary key,
  created_at timestamptz not null default now(),
  customer_name text not null,
  customer_email text not null,
  customer_phone text not null default '',
  customer_address text not null default '',
  availability text not null default '',
  reason text not null,
  device text not null default '',
  details text not null,
  status text not null default 'requested',
  assigned_to uuid references public.employee_profiles(user_id) on delete set null
);

alter table public.apex_service_requests enable row level security;

drop policy if exists "Customers can submit service requests" on public.apex_service_requests;
create policy "Customers can submit service requests"
on public.apex_service_requests for insert to anon, authenticated
with check (
  length(customer_name) between 1 and 120
  and length(customer_email) between 3 and 254
  and length(customer_phone) <= 40
  and length(customer_address) <= 500
  and length(reason) between 1 and 120
  and length(details) between 1 and 5000
);

drop policy if exists "Owner manages service requests" on public.apex_service_requests;
create policy "Owner manages service requests"
on public.apex_service_requests for all to authenticated
using ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com')
with check ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com');

-- Employees can only read work that is unassigned or assigned to themselves.
drop policy if exists "Employees read available or assigned orders" on public.apex_orders;
create policy "Employees read available or assigned orders"
on public.apex_orders for select to authenticated
using (
  exists (
    select 1 from public.employee_profiles ep
    where ep.user_id = auth.uid() and ep.active = true
  )
  and (assigned_to is null or assigned_to = auth.uid())
);

drop policy if exists "Employees read available or assigned requests" on public.apex_service_requests;
create policy "Employees read available or assigned requests"
on public.apex_service_requests for select to authenticated
using (
  exists (
    select 1 from public.employee_profiles ep
    where ep.user_id = auth.uid() and ep.active = true
  )
  and (assigned_to is null or assigned_to = auth.uid())
);

-- Claiming is atomic: two employees cannot claim the same job.
create or replace function public.apex_claim_job(job_kind text, job_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare changed integer;
begin
  if not exists (
    select 1 from public.employee_profiles
    where user_id = auth.uid() and active = true
  ) then
    raise exception 'Active employee account required';
  end if;
  if job_kind = 'order' then
    update public.apex_orders set assigned_to = auth.uid()
    where id = job_id and assigned_to is null;
  elsif job_kind = 'request' then
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
declare changed integer;
begin
  if not exists (
    select 1 from public.employee_profiles
    where user_id = auth.uid() and active = true
  ) then
    raise exception 'Active employee account required';
  end if;
  if new_status not in ('requested','working','waiting','completed','invoiced','shipped','delivered') then
    raise exception 'Invalid status';
  end if;
  if job_kind = 'order' then
    update public.apex_orders set status = new_status
    where id = job_id and assigned_to = auth.uid();
  elsif job_kind = 'request' then
    update public.apex_service_requests set status = new_status
    where id = job_id and assigned_to = auth.uid();
  else
    raise exception 'Invalid job type';
  end if;
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;

revoke all on function public.apex_claim_job(text,text) from public;
revoke all on function public.apex_employee_update_job(text,text,text) from public;
grant execute on function public.apex_claim_job(text,text) to authenticated;
grant execute on function public.apex_employee_update_job(text,text,text) to authenticated;

-- Do not allow employee browser sessions to directly edit assignment or order rows.
-- Owner policies already in place continue to provide owner management access.
