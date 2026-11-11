begin;
create or replace function public.apex_permission_keys() returns text[] language sql immutable set search_path='' as $$
select array['orders','requests','customer_details','claim_jobs','update_status','view_schedule','edit_schedule','view_reports','view_notes','edit_notes','manage_notes','prepare_sales','manage_promos','own_sales_receipts'];
$$;
update public.staff_roles set permissions=permissions||'{"own_sales_receipts":true}' where lower(name) in ('market','manager');
create or replace function public.apex_prepare_customer_draft(p_kind text,p_payload jsonb,p_employee uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.staff_customer_drafts; v_items jsonb:='[]'; v_item jsonb;v_part jsonb;v_parts jsonb;
begin
 if not coalesce(public.apex_staff_can('prepare_sales'),false) then raise exception 'Sales preparation permission required' using errcode='42501';end if;
 if p_kind not in ('order','request') or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Invalid draft';end if;
 if p_kind='order' and (jsonb_typeof(p_payload->'items') is distinct from 'array' or jsonb_array_length(p_payload->'items') not between 1 and 50) then raise exception 'Choose products for the customer';end if;
 if p_kind='order' then
  for v_item in select value from jsonb_array_elements(p_payload->'items') loop
   if v_item->>'kind'='build' then
    if jsonb_typeof(v_item->'parts') is distinct from 'array' or jsonb_array_length(v_item->'parts') not between 1 and 9 then raise exception 'Choose 1 to 9 build parts';end if;
    v_parts:='[]';
    for v_part in select value from jsonb_array_elements(v_item->'parts') loop
     if length(coalesce(v_part->>'id','')) not between 1 and 200 then raise exception 'Invalid build part';end if;
     v_parts:=v_parts||jsonb_build_array(jsonb_build_object('id',v_part->>'id'));
    end loop;
    v_items:=v_items||jsonb_build_array(jsonb_build_object('id','custom-build','kind','build','qty',1,'assembly',v_item->'assembly'='true'::jsonb,'parts',v_parts));
   else
    if length(coalesce(v_item->>'id','')) not between 1 and 200 or coalesce(v_item->>'qty','') !~ '^[0-9]{1,2}$' then raise exception 'Invalid product selection';end if;
    if (v_item->>'qty')::integer not between 1 and 10 then raise exception 'Quantity must be 1 to 10';end if;
    v_items:=v_items||jsonb_build_array(jsonb_build_object('id',v_item->>'id','qty',(v_item->>'qty')::integer,'kind','product'));
   end if;
  end loop;
 end if;
 if p_kind='request' and (length(coalesce(p_payload->>'reason','')) not between 1 and 120 or length(coalesce(p_payload->>'details','')) not between 1 and 5000) then raise exception 'Enter a service and description';end if;
 if public.apex_is_owner() and not exists(select 1 from public.employee_profiles where user_id=p_employee and active) then raise exception 'Choose the contributing employee';end if;
 -- Store only the selected public products or service description, never customer identity or payment information.
 insert into public.staff_customer_drafts(employee_id,kind,payload) values(case when public.apex_is_owner() then p_employee else auth.uid() end,p_kind,
 case when p_kind='order' then jsonb_build_object('items',v_items) else jsonb_build_object('reason',p_payload->>'reason','details',p_payload->>'details','device',left(coalesce(p_payload->>'device',''),200)) end) returning * into d;
 perform public.apex_staff_audit('customer_draft_created',auth.uid(),jsonb_build_object('draft_id',d.id,'kind',p_kind));
 return jsonb_build_object('token',d.token,'expires_at',d.expires_at);
end;
$$;
create index if not exists staff_drafts_employee_created_idx on public.staff_customer_drafts(employee_id,created_at desc);

-- This is a sales reference only. Never expose the profile username (the login passcode).
alter table public.employee_profiles add column if not exists sales_code text;
update public.employee_profiles set sales_code='APX-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,16)) where sales_code is null;
alter table public.employee_profiles alter column sales_code set default ('APX-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,16)));
create unique index if not exists staff_sales_code_unique on public.employee_profiles(sales_code);
alter table public.apex_orders add column if not exists sales_employee_id uuid;
alter table public.apex_orders add column if not exists sales_employee_name text;
alter table public.apex_orders add column if not exists sales_employee_code text;
alter table public.apex_orders add column if not exists paypal_capture_id text;
create or replace function public.apex_stamp_sales_identity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 NEW.sales_employee_id:=null;NEW.sales_employee_name:=null;NEW.sales_employee_code:=null;
 if NEW.sales_origin='employee' then
  select p.user_id,p.display_name,p.sales_code into NEW.sales_employee_id,NEW.sales_employee_name,NEW.sales_employee_code
  from public.staff_sales_credits c join public.employee_profiles p on p.user_id=c.employee_id where c.job_kind='order' and c.job_id=NEW.id;
 end if;
 return NEW;
end;
$$;
drop trigger if exists z_apex_sales_identity on public.apex_orders;
create trigger z_apex_sales_identity before insert on public.apex_orders for each row execute function public.apex_stamp_sales_identity();

create table if not exists public.apex_paid_notifications(
 id uuid primary key default gen_random_uuid(),
 order_id text not null,
 recipient_kind text not null check(recipient_kind in ('owner','employee')),
 employee_id uuid references public.employee_profiles(user_id) on delete set null,
 recipient text not null default '',
 payload jsonb not null,
 state text not null default 'pending' check(state in ('pending','sending','sent','failed')),
 attempts integer not null default 0,
 lease_token uuid,
 lease_until timestamptz,
 sent_at timestamptz,
 error text,
 unique(order_id,recipient_kind)
);
alter table public.apex_paid_notifications enable row level security;
revoke all on public.apex_paid_notifications from public,anon,authenticated;
grant all on public.apex_paid_notifications to service_role;
create or replace function public.apex_enqueue_paid_notifications() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if NEW.status<>'paid' then return NEW;end if;
 insert into public.apex_paid_notifications(order_id,recipient_kind,recipient,payload)
 values(NEW.id,'owner','apexcomputers039@gmail.com',to_jsonb(NEW)-'handoff_token') on conflict do nothing;
 if NEW.sales_employee_id is not null and public.apex_effective_permissions(NEW.sales_employee_id)->'own_sales_receipts'='true'::jsonb then
  insert into public.apex_paid_notifications(order_id,recipient_kind,employee_id,recipient,payload)
  values(NEW.id,'employee',NEW.sales_employee_id,coalesce((select email from public.employee_profiles where user_id=NEW.sales_employee_id and active),''),to_jsonb(NEW)-'handoff_token') on conflict do nothing;
 end if;
 return NEW;
end;
$$;
drop trigger if exists apex_queue_paid_emails on public.apex_orders;
create trigger apex_queue_paid_emails after update of status on public.apex_orders
for each row execute function public.apex_enqueue_paid_notifications();
create or replace function public.apex_claim_paid_notifications(p_order text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ids uuid[];lease uuid:=gen_random_uuid();
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Notification server required' using errcode='42501';end if;
 -- Use the latest owner-maintained employee email, never a browser-provided recipient.
 update public.apex_paid_notifications n set recipient=coalesce(p.email,'') from public.employee_profiles p
 where n.order_id=p_order and n.employee_id=p.user_id and n.recipient_kind='employee' and n.state in ('pending','failed') and p.active;
 select array_agg(id) into ids from (select n.id from public.apex_paid_notifications n where n.order_id=p_order and
 (n.state in ('pending','failed') or (n.state='sending' and n.lease_until<now())) and
 (n.recipient_kind='owner' or exists(select 1 from public.employee_profiles p where p.user_id=n.employee_id and p.active and public.apex_effective_permissions(p.user_id)->'own_sales_receipts'='true'::jsonb))
 for update skip locked) q;
 update public.apex_paid_notifications set state='sending',lease_token=lease,lease_until=now()+interval '5 minutes',attempts=attempts+1,error=null where id=any(ids);
 return coalesce((select jsonb_agg(to_jsonb(n)) from public.apex_paid_notifications n where id=any(ids)),'[]');
end;
$$;
create or replace function public.apex_finish_paid_notification(p_id uuid,p_lease uuid,p_success boolean,p_error text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Notification server required' using errcode='42501';end if;
 update public.apex_paid_notifications set state=case when p_success then 'sent' else 'failed' end,sent_at=case when p_success then now() else null end,error=left(p_error,300),lease_until=null
 where id=p_id and lease_token=p_lease and state='sending';
end;
$$;
create or replace function public.apex_market_order_progress() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(public.apex_staff_can('prepare_sales'),false) then raise exception 'Sales permission required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('draft_id',d.id,'job_id',d.submitted_job_id,'kind',d.kind,'submitted_at',d.submitted_at,
 'payment_status',case when d.kind='request' then 'service_request' when o.status='paid' or exists(select 1 from public.apex_paid_notifications n where n.order_id=d.submitted_job_id) then 'paid' when d.submitted_at is not null then 'awaiting_payment' else 'waiting_customer' end,
 'order',case when o.status='paid' or exists(select 1 from public.apex_paid_notifications n where n.order_id=d.submitted_job_id) then
 jsonb_build_object('ref',snap.data->'ref','customer_name',case when public.apex_is_owner() or public.apex_staff_can('own_sales_receipts') then snap.data->'customer_name' else null end,'customer_email',case when public.apex_is_owner() or public.apex_staff_can('own_sales_receipts') then snap.data->'customer_email' else null end,'customer_phone',case when public.apex_is_owner() or public.apex_staff_can('own_sales_receipts') then snap.data->'customer_phone' else null end,'shipping_address',case when public.apex_is_owner() or public.apex_staff_can('own_sales_receipts') then snap.data->'shipping_address' else null end,'items',snap.data->'items','total',snap.data->'total','sales_employee_name',snap.data->'sales_employee_name','sales_employee_code',snap.data->'sales_employee_code') else null end,
 'notifications',coalesce((select jsonb_agg(jsonb_build_object('recipient_kind',n.recipient_kind,'state',n.state,'error',case when public.apex_is_owner() then n.error else null end)) from public.apex_paid_notifications n where n.order_id=d.submitted_job_id),'[]')) order by d.created_at desc)
 from public.staff_customer_drafts d left join public.apex_orders o on d.kind='order' and o.id=d.submitted_job_id
 left join lateral (select coalesce((select n.payload from public.apex_paid_notifications n where n.order_id=d.submitted_job_id limit 1),to_jsonb(o)) as data) snap on true
 where public.apex_is_owner() or d.employee_id=auth.uid()),'[]');
end;
$$;
revoke all on function public.apex_stamp_sales_identity(),public.apex_enqueue_paid_notifications(),public.apex_claim_paid_notifications(text),public.apex_finish_paid_notification(uuid,uuid,boolean,text),public.apex_market_order_progress() from public,anon,authenticated;
grant execute on function public.apex_claim_paid_notifications(text),public.apex_finish_paid_notification(uuid,uuid,boolean,text) to service_role;
grant execute on function public.apex_market_order_progress() to authenticated;
create or replace function public.apex_customer_draft(p_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.staff_customer_drafts;
begin
 select * into d from public.staff_customer_drafts where token=p_token and submitted_at is null and expires_at>now();
 if not found then raise exception 'This customer link has expired or was already submitted';end if;
 if not exists(select 1 from public.employee_profiles where user_id=d.employee_id and active) then raise exception 'This employee link is no longer active';end if;
 return jsonb_build_object('kind',d.kind,'payload',d.payload,'expires_at',d.expires_at,'sales_employee_name',(select display_name from public.employee_profiles where user_id=d.employee_id),'sales_employee_code',(select sales_code from public.employee_profiles where user_id=d.employee_id));
end;
$$;

notify pgrst,'reload schema';
commit;
