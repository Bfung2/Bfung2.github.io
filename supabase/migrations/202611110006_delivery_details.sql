begin;
alter table public.apex_orders add column if not exists shipping_carrier text not null default '';
alter table public.apex_orders add column if not exists shipment_tracking_number text not null default '';
alter table public.apex_orders add column if not exists estimated_completion_date date;
alter table public.apex_orders add column if not exists pickup_instructions text not null default '';
create or replace function public.apex_tracking_snapshot(o public.apex_orders) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('ref',o.ref,'created_at',o.created_at,'is_test',o.is_test,'stage',o.fulfillment_stage,
  'public_update',o.customer_update,'delivery',jsonb_build_object('carrier',o.shipping_carrier,'tracking_number',o.shipment_tracking_number,'estimated_completion',o.estimated_completion_date,'pickup_instructions',o.pickup_instructions),'revision',o.tracking_revision,'total',o.total,
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
  NEW.tracking_revision:=OLD.tracking_revision+case when NEW.fulfillment_stage is distinct from OLD.fulfillment_stage or NEW.customer_update is distinct from OLD.customer_update or NEW.shipping_carrier is distinct from OLD.shipping_carrier or NEW.shipment_tracking_number is distinct from OLD.shipment_tracking_number or NEW.estimated_completion_date is distinct from OLD.estimated_completion_date or NEW.pickup_instructions is distinct from OLD.pickup_instructions then 1 else 0 end;
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
 if prior is null or prior->>'stage' is distinct from snap->>'stage' or prior->>'public_update' is distinct from snap->>'public_update' or prior->>'payment_confirmed' is distinct from snap->>'payment_confirmed' or prior->'delivery' is distinct from snap->'delivery' then
  insert into public.customer_order_tracking_events(order_id,stage,message,payment_confirmed)
  values(NEW.id,snap->>'stage',case when prior is not null and prior->'delivery' is distinct from snap->'delivery' then 'Delivery details updated. '||coalesce(snap->>'public_update','') else snap->>'public_update' end,(snap->>'payment_confirmed')::boolean);
 end if;
 return NEW;
end;
$$;
create or replace function public.apex_staff_order_tracking(p_order text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.apex_orders;
begin
 select * into o from public.apex_orders where id=p_order;
 if not found or not coalesce((public.apex_is_owner() or (coalesce(public.apex_staff_can('orders'),false) and coalesce(public.apex_staff_can('update_status'),false) and o.assigned_to=auth.uid())),false) then raise exception 'Order tracking access required' using errcode='42501'; end if;
 return jsonb_build_object('token',o.tracking_token,'revision',o.tracking_revision,'stage',o.fulfillment_stage,'public_update',o.customer_update,'ref',o.ref,'is_test',o.is_test,'delivery',jsonb_build_object('carrier',o.shipping_carrier,'tracking_number',o.shipment_tracking_number,'estimated_completion',o.estimated_completion_date,'pickup_instructions',o.pickup_instructions));
end;
$$;

create or replace function public.apex_update_order_delivery(p_order text,p_data jsonb,p_revision integer) returns boolean
language plpgsql security definer set search_path='' as $$
declare o public.apex_orders; v_stage text:=p_data->>'stage';v_message text:=coalesce(p_data->>'public_update','');v_carrier text:=trim(coalesce(p_data->>'carrier',''));v_number text:=trim(coalesce(p_data->>'tracking_number',''));v_pickup text:=coalesce(p_data->>'pickup_instructions','');v_date date;
begin
 select * into o from public.apex_orders where id=p_order for update;
 if not found or not coalesce((public.apex_is_owner() or (coalesce(public.apex_staff_can('orders'),false) and coalesce(public.apex_staff_can('update_status'),false) and o.assigned_to=auth.uid())),false) then raise exception 'Order tracking access required' using errcode='42501'; end if;
 if p_revision is distinct from o.tracking_revision then raise exception 'Order progress changed. Reopen and try again'; end if;
 if v_stage is null or v_stage not in ('received','sourcing','building','testing','ready','shipped','delivered','on_hold','cancelled') or length(v_message)>1000 or length(v_carrier)>80 or length(v_number)>100 or length(v_pickup)>1000 then raise exception 'Choose a valid stage and keep delivery details within the limits'; end if;
 if v_number<>'' and v_carrier='' then raise exception 'Enter the carrier for this tracking number'; end if;
 if coalesce(p_data->>'estimated_completion','')<>'' and p_data->>'estimated_completion' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Enter a valid estimated date'; end if;
 begin v_date:=nullif(p_data->>'estimated_completion','')::date;exception when invalid_datetime_format or datetime_field_overflow then raise exception 'Enter a valid estimated date';end;
 if v_stage not in ('received','on_hold','cancelled') and not o.is_test and not coalesce((select (snapshot->>'payment_confirmed')::boolean from public.customer_order_tracking where order_id=o.id),false) then raise exception 'Payment must be confirmed before fulfillment starts'; end if;
 update public.apex_orders set fulfillment_stage=v_stage,customer_update=v_message,shipping_carrier=v_carrier,shipment_tracking_number=v_number,estimated_completion_date=v_date,pickup_instructions=v_pickup where id=o.id;
 perform public.apex_staff_audit('customer_delivery_updated',o.assigned_to,jsonb_build_object('order_id',o.id,'stage',v_stage));
 return true;
end;
$$;
revoke all on function public.apex_update_order_delivery(text,jsonb,integer) from public,anon;
grant execute on function public.apex_update_order_delivery(text,jsonb,integer) to authenticated;
notify pgrst,'reload schema';
commit;
