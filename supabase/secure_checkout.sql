-- Apex Computers: harden public order submission before enabling Live PayPal.
-- Run this entire script in Supabase SQL Editor as the project owner.
-- Anonymous visitors receive INSERT only. They cannot read or update orders.

alter table public.apex_orders enable row level security;

revoke all on table public.apex_orders from anon;
grant insert (
  id, ref, created_at, customer_name, customer_email, customer_phone,
  shipping_address, notes, items, subtotal, shipping, tax, total, status
) on public.apex_orders to anon;

drop policy if exists "Customers can submit orders" on public.apex_orders;
create policy "Customers can submit orders"
on public.apex_orders
for insert
to anon
with check (
  status = 'requested'
  and length(id) between 1 and 160
  and length(ref) between 1 and 80
  and length(customer_name) between 1 and 120
  and length(customer_email) between 3 and 254
  and length(customer_phone) <= 40
  and length(shipping_address) between 5 and 500
  and length(coalesce(notes, '')) <= 2000
  and jsonb_typeof(items) = 'array'
  and jsonb_array_length(items) between 1 and 50
  and subtotal >= 0
  and shipping >= 0
  and tax >= 0
  and total > 0
);

grant select, update on public.apex_orders to authenticated;
drop policy if exists "Owner manages orders" on public.apex_orders;
create policy "Owner manages orders"
on public.apex_orders
for all
to authenticated
using ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com')
with check ((auth.jwt() ->> 'email') = 'apexcomputers039@gmail.com');

-- Anonymous visitors must not be able to read or edit private service requests.
revoke select, update, delete on table public.apex_service_requests from anon;

-- Let the authenticated owner permanently remove completed inbox items.
-- Existing owner-only "Owner manages orders" and "Owner manages service requests"
-- RLS policies still restrict which rows can be deleted.
grant delete on public.apex_orders, public.apex_service_requests to authenticated;
