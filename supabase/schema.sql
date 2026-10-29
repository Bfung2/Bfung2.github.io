-- Apex Computers: private order and service-request storage.
-- Run in Supabase SQL Editor. Customer records must never be put in public data.json.
-- The public website must submit orders through a server-side Edge Function using
-- the Supabase service-role key stored only as a Supabase secret.

create extension if not exists pgcrypto;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  customer_name text not null,
  customer_email text not null,
  customer_phone text,
  shipping_address jsonb not null default '{}'::jsonb,
  items jsonb not null default '[]'::jsonb,
  subtotal numeric(12,2) not null default 0 check (subtotal >= 0),
  shipping numeric(12,2) not null default 0 check (shipping >= 0),
  tax numeric(12,2) not null default 0 check (tax >= 0),
  total numeric(12,2) not null default 0 check (total >= 0),
  status text not null default 'pending'
    check (status in ('pending','confirmed','working','invoiced','shipped','delivered','cancelled')),
  customer_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists orders_status_idx on public.orders (status);

create table if not exists public.service_requests (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  customer_email text not null,
  customer_phone text,
  address text,
  device text,
  issue text not null,
  reason text,
  status text not null default 'new'
    check (status in ('new','contacted','scheduled','in_progress','completed','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists service_requests_created_at_idx
  on public.service_requests (created_at desc);

alter table public.orders enable row level security;
alter table public.service_requests enable row level security;

-- Explicit least-privilege grants. RLS policies do not revoke SQL privileges by
-- themselves, so remove all client-role grants before granting only the required
-- operations. Server-side Edge Functions use service_role and must keep that key
-- in Supabase Function Secrets only.
revoke all on table public.orders from anon, authenticated;
revoke all on table public.service_requests from anon, authenticated;
grant select, update on table public.orders to authenticated;
grant select, update on table public.service_requests to authenticated;

-- Only authenticated users whose app_metadata role is admin can read/update records.
-- No public/anon insert policies are created. Edge Functions with the service-role
-- key handle validated customer submissions server-side.
drop policy if exists "Admins can view orders" on public.orders;
create policy "Admins can view orders"
  on public.orders for select to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

drop policy if exists "Admins can update orders" on public.orders;
create policy "Admins can update orders"
  on public.orders for update to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

drop policy if exists "Admins can view service requests" on public.service_requests;
create policy "Admins can view service requests"
  on public.service_requests for select to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

drop policy if exists "Admins can update service requests" on public.service_requests;
create policy "Admins can update service requests"
  on public.service_requests for update to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

-- Never store card numbers, CVVs, passwords, or secret API keys in these tables.
