begin;
alter table public.apex_orders add column if not exists tracking_token text not null default replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
alter table public.apex_orders add column if not exists fulfillment_stage text not null default 'received';
alter table public.apex_orders add column if not exists customer_update text not null default '';
alter table public.apex_orders add column if not exists tracking_revision integer not null default 1;
create unique index if not exists apex_order_tracking_token_unique on public.apex_orders(tracking_token);
-- Browser checkout supplies a cryptographically random token it can retain without reading the order table.
grant insert(tracking_token) on public.apex_orders to anon;
create table if not exists public.customer_order_tracking (
 order_id text primary key,
 token text not null unique check(token ~ '^[a-f0-9]{64}$'),
 snapshot jsonb not null,
 updated_at timestamptz not null default now()
);
create table if not exists public.customer_order_tracking_events (
 id uuid primary key default gen_random_uuid(),
 order_id text not null references public.customer_order_tracking(order_id),
 recorded_at timestamptz not null default now(),
 stage text not null,
 message text not null,
 payment_confirmed boolean not null
);
alter table public.customer_order_tracking enable row level security;
alter table public.customer_order_tracking_events enable row level security;
revoke all on public.customer_order_tracking,public.customer_order_tracking_events from public,anon,authenticated;
grant all on public.customer_order_tracking,public.customer_order_tracking_events to service_role;
-- Establish the current known stage only for orders not yet tracked. Reruns preserve later owner edits.
update public.apex_orders o set fulfillment_stage=case o.status when 'working' then 'building' when 'waiting' then 'on_hold' when 'completed' then 'ready' when 'shipped' then 'shipped' when 'delivered' then 'delivered' else 'received' end
where o.fulfillment_stage='received' and o.status in ('working','waiting','completed','shipped','delivered')
and (o.is_test or nullif(o.paypal_capture_id,'') is not null)
and not exists(select 1 from public.customer_order_tracking t where t.order_id=o.id);
create or replace function public.apex_tracking_snapshot(o public.apex_orders) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('ref',o.ref,'created_at',o.created_at,'is_test',o.is_test,'stage',o.fulfillment_stage,
  'public_update',o.customer_update,'revision',o.tracking_revision,'total',o.total,
  'payment_confirmed',not o.is_test and (o.status='paid' or nullif(o.paypal_capture_id,'') is not null),
  'items',coalesce((select jsonb_agg(jsonb_build_object('name',left(i->>'name',300),'qty',coalesce(i->'qty','1'::jsonb))) from jsonb_array_elements(o.items) i),'[]'::jsonb),'archived',false);
$$;
create or replace function public.apex_prepare_order_tracking() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_paid boolean; mapped text;
begin
 if NEW.tracking_token !~ '^[a-f0-9]{64}$' then raise exception 'Invalid tracking token'; end if;
 if NEW.fulfillment_stage not in ('received','sourcing','building','testing','ready','shipped','delivered','on_hold','cancelled') or length(NEW.customer_update)>1000 then raise exception 'Invalid customer progress update'; end if;
 if TG_OP='UPDATE' then
  if NEW.tracking_token<>OLD.tracking_token then raise exception 'Tracking links cannot be changed'; end if;
  v_paid:=NEW.is_test or NEW.status='paid' or nullif(NEW.paypal_capture_id,'') is not null or coalesce((select (snapshot->>'payment_confirmed')::boolean from public.customer_order_tracking where order_id=NEW.id),false);
  if NEW.status is distinct from OLD.status and NEW.fulfillment_stage=OLD.fulfillment_stage and v_paid then
   mapped:=case NEW.status when 'working' then 'building' when 'waiting' then 'on_hold' when 'completed' then 'ready' when 'shipped' then 'shipped' when 'delivered' then 'delivered' else null end;
   if mapped is not null then NEW.fulfillment_stage:=mapped; end if;
  end if;
  NEW.tracking_revision:=OLD.tracking_revision+case when NEW.fulfillment_stage is distinct from OLD.fulfillment_stage or NEW.customer_update is distinct from OLD.customer_update then 1 else 0 end;
 end if;
 return NEW;
end;
$$;
create or replace function public.apex_sync_order_tracking() returns trigger
language plpgsql security definer set search_path='' as $$
declare snap jsonb; prior jsonb;
begin
 if TG_OP='DELETE' then
  update public.customer_order_tracking set snapshot=snapshot||jsonb_build_object('archived',true),updated_at=now() where order_id=OLD.id;
  return OLD;
 end if;
 select snapshot into prior from public.customer_order_tracking where order_id=NEW.id;
 snap:=public.apex_tracking_snapshot(NEW);
 if coalesce((prior->>'payment_confirmed')::boolean,false) then snap:=snap||'{"payment_confirmed":true}'::jsonb; end if;
 insert into public.customer_order_tracking(order_id,token,snapshot) values(NEW.id,NEW.tracking_token,snap)
 on conflict(order_id) do update set snapshot=excluded.snapshot,updated_at=now();
 if prior is null or prior->>'stage' is distinct from snap->>'stage' or prior->>'public_update' is distinct from snap->>'public_update' or prior->>'payment_confirmed' is distinct from snap->>'payment_confirmed' then
  insert into public.customer_order_tracking_events(order_id,stage,message,payment_confirmed)
  values(NEW.id,snap->>'stage',snap->>'public_update',(snap->>'payment_confirmed')::boolean);
 end if;
 return NEW;
end;
$$;
drop trigger if exists apex_prepare_order_tracking on public.apex_orders;
create trigger apex_prepare_order_tracking before insert or update on public.apex_orders for each row execute function public.apex_prepare_order_tracking();
drop trigger if exists apex_sync_order_tracking on public.apex_orders;
create trigger apex_sync_order_tracking after insert or update or delete on public.apex_orders for each row execute function public.apex_sync_order_tracking();
-- Existing orders receive private links; backfill never changes their payment or fulfillment status.
insert into public.customer_order_tracking(order_id,token,snapshot)
select o.id,o.tracking_token,public.apex_tracking_snapshot(o) from public.apex_orders o on conflict(order_id) do nothing;
create or replace function public.apex_customer_order_status(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.customer_order_tracking;
begin
 if p_token is null or p_token !~ '^[a-f0-9]{64}$' then raise exception 'Tracking link is invalid or unavailable'; end if;
 select * into t from public.customer_order_tracking where token=p_token;
 if not found then raise exception 'Tracking link is invalid or unavailable'; end if;
 return t.snapshot||jsonb_build_object('updated_at',t.updated_at,'events',coalesce((select jsonb_agg(to_jsonb(e) order by e.recorded_at desc) from
  (select recorded_at,stage,message,payment_confirmed from public.customer_order_tracking_events where order_id=t.order_id order by recorded_at desc limit 50) e),'[]'::jsonb));
end;
$$;
create or replace function public.apex_staff_order_tracking(p_order text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.apex_orders;
begin
 select * into o from public.apex_orders where id=p_order;
 if not found or not coalesce((public.apex_is_owner() or (coalesce(public.apex_staff_can('orders'),false) and coalesce(public.apex_staff_can('update_status'),false) and o.assigned_to=auth.uid())),false) then raise exception 'Order tracking access required' using errcode='42501'; end if;
 return jsonb_build_object('token',o.tracking_token,'revision',o.tracking_revision,'stage',o.fulfillment_stage,'public_update',o.customer_update,'ref',o.ref,'is_test',o.is_test);
end;
$$;
create or replace function public.apex_update_order_tracking(p_order text,p_stage text,p_message text,p_revision integer) returns boolean
language plpgsql security definer set search_path='' as $$
declare o public.apex_orders;
begin
 select * into o from public.apex_orders where id=p_order for update;
 if not found or not coalesce((public.apex_is_owner() or (coalesce(public.apex_staff_can('orders'),false) and coalesce(public.apex_staff_can('update_status'),false) and o.assigned_to=auth.uid())),false) then raise exception 'Order tracking access required' using errcode='42501'; end if;
 if p_stage is null or p_stage not in ('received','sourcing','building','testing','ready','shipped','delivered','on_hold','cancelled') or p_message is null or length(p_message)>1000 then raise exception 'Choose a valid stage and a message of up to 1000 characters'; end if;
 if o.tracking_revision is distinct from p_revision then raise exception 'Order progress changed. Reopen and try again'; end if;
 if p_stage not in ('received','on_hold','cancelled') and not o.is_test and not coalesce((select (snapshot->>'payment_confirmed')::boolean from public.customer_order_tracking where order_id=o.id),false) then raise exception 'Payment must be confirmed before fulfillment starts'; end if;
 update public.apex_orders set fulfillment_stage=p_stage,customer_update=p_message where id=p_order;
 perform public.apex_staff_audit('customer_tracking_updated',o.assigned_to,jsonb_build_object('order_id',o.id,'stage',p_stage));
 return true;
end;
$$;
revoke all on function public.apex_tracking_snapshot(public.apex_orders),public.apex_prepare_order_tracking(),public.apex_sync_order_tracking() from public,anon,authenticated;
revoke all on function public.apex_customer_order_status(text),public.apex_staff_order_tracking(text),public.apex_update_order_tracking(text,text,text,integer) from public,anon,authenticated;
grant execute on function public.apex_customer_order_status(text) to anon,authenticated;
grant execute on function public.apex_staff_order_tracking(text),public.apex_update_order_tracking(text,text,text,integer) to authenticated;
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
 return jsonb_build_object('id',o.id,'ref',o.ref,'status',o.status,'tracking_token',o.tracking_token);
end;
$$;
-- Private links are retrieved only through the assigned-staff RPC, not the claimable jobs list.
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
      case when v_customer_details then (to_jsonb(o)-'tracking_token')
      else (to_jsonb(o)-'tracking_token') - array['customer_name','customer_email','customer_phone','shipping_address']::text[]
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
notify pgrst,'reload schema';
commit;
