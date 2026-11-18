begin;

create table public.apex_shipments (
  order_id text primary key references public.apex_orders(id) on delete cascade,
  carrier text not null,
  tracking_number text not null,
  email_state text not null default 'pending' check (email_state in ('pending','sending','sent','failed','test')),
  tracker_id text,
  carrier_checked_at timestamptz,
  carrier_update jsonb
);
alter table public.apex_shipments enable row level security;
revoke all on public.apex_shipments from public, anon, authenticated;
grant select, update on public.apex_shipments to service_role;

create function public.apex_confirm_shipment(
  p_order text, p_revision integer, p_carrier text, p_number text
) returns void
language plpgsql security definer set search_path='' as $$
declare
  o public.apex_orders;
  shipment public.apex_shipments;
begin
  select * into o from public.apex_orders where id=p_order for update;
  if not found or not coalesce(public.apex_is_owner() or (
    o.assigned_to=auth.uid() and public.apex_staff_can('orders') and public.apex_staff_can('update_status')
  ),false) then
    raise exception 'Order tracking access required' using errcode='42501';
  end if;

  if not coalesce(
    (p_carrier='UPS' and p_number ~ '^(1Z[A-Z0-9]{16}|T[0-9]{10}|[0-9]{9,26})$')
    or (p_carrier='USPS' and p_number ~ '^([0-9]{16,34}|[A-Z]{2}[0-9]{9}[A-Z]{2})$'), false
  ) then
    raise exception 'Enter a valid UPS or USPS tracking number';
  end if;

  if o.fulfillment_stage in ('cancelled','delivered') or o.status in ('cancelled','delivered')
      or public.apex_customer_order_status(o.tracking_token)->'refund'->>'status'='full' then
    raise exception 'This order is closed for shipping';
  end if;

  select * into shipment from public.apex_shipments where order_id=o.id;
  if found then
    if shipment.carrier<>p_carrier or shipment.tracking_number<>p_number
        or o.shipping_carrier<>p_carrier or o.shipment_tracking_number<>p_number then
      raise exception 'This order already has a confirmed shipment with different tracking details';
    end if;
    if o.fulfillment_stage='shipped' and o.status='shipped' then return; end if;
  end if;

  perform public.apex_update_order_delivery(o.id,jsonb_build_object(
    'stage','shipped','public_update',o.customer_update,'carrier',p_carrier,
    'tracking_number',p_number,'estimated_completion',o.estimated_completion_date,
    'pickup_instructions',o.pickup_instructions
  ),p_revision);
  update public.apex_orders set status='shipped' where id=o.id and status is distinct from 'shipped';
  insert into public.apex_shipments(order_id,carrier,tracking_number,email_state)
  values(o.id,p_carrier,p_number,case when o.is_test then 'test' else 'pending' end)
  on conflict(order_id) do nothing;
end;
$$;

revoke all on function public.apex_confirm_shipment(text,integer,text,text) from public,anon;
grant execute on function public.apex_confirm_shipment(text,integer,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
