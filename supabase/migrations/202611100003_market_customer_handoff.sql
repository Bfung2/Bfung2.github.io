begin;
create or replace function public.apex_permission_keys() returns text[] language sql immutable set search_path='' as $$
select array['orders','requests','customer_details','claim_jobs','update_status','view_schedule','edit_schedule','view_reports','view_notes','edit_notes','manage_notes','prepare_sales'];
$$;
update public.staff_roles set permissions=permissions||'{"prepare_sales":true}' where lower(name) in ('market','manager');
create table if not exists public.staff_customer_drafts(
 id uuid primary key default gen_random_uuid(),
 token uuid not null unique default gen_random_uuid(),
 employee_id uuid references public.employee_profiles(user_id) on delete set null,
 kind text not null check(kind in ('order','request')),
 payload jsonb not null check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=30000),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '7 days',
 submitted_at timestamptz,
 submitted_job_id text
);
create table if not exists public.staff_employee_contacts(
 employee_id uuid primary key references public.employee_profiles(user_id) on delete cascade,
 phone text not null default '' check(length(phone)<=40),
 address text not null default '' check(length(address)<=500)
);
alter table public.staff_customer_drafts enable row level security;
alter table public.staff_employee_contacts enable row level security;
revoke all on public.staff_customer_drafts,public.staff_employee_contacts from public,anon,authenticated;
grant all on public.staff_customer_drafts,public.staff_employee_contacts to service_role;
alter table public.apex_orders add column if not exists handoff_token uuid;
alter table public.apex_orders add column if not exists sales_origin text not null default 'website';
alter table public.apex_service_requests add column if not exists handoff_token uuid;
alter table public.apex_service_requests add column if not exists sales_origin text not null default 'website';
grant insert(handoff_token) on public.apex_orders to anon,authenticated;
grant insert(handoff_token) on public.apex_service_requests to anon,authenticated;

create or replace function public.apex_prepare_customer_draft(p_kind text,p_payload jsonb,p_employee uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.staff_customer_drafts; v_items jsonb:='[]'; v_item jsonb;
begin
 if not coalesce(public.apex_staff_can('prepare_sales'),false) then raise exception 'Sales preparation permission required' using errcode='42501';end if;
 if p_kind not in ('order','request') or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Invalid draft';end if;
 if p_kind='order' and (jsonb_typeof(p_payload->'items') is distinct from 'array' or jsonb_array_length(p_payload->'items') not between 1 and 50) then raise exception 'Choose products for the customer';end if;
 if p_kind='order' then
  for v_item in select value from jsonb_array_elements(p_payload->'items') loop
   if length(coalesce(v_item->>'id','')) not between 1 and 200 or coalesce(v_item->>'qty','') !~ '^[0-9]{1,2}$' then raise exception 'Invalid product selection';end if;
   if (v_item->>'qty')::integer not between 1 and 10 then raise exception 'Quantity must be 1 to 10';end if;
   v_items:=v_items||jsonb_build_array(jsonb_build_object('id',v_item->>'id','qty',(v_item->>'qty')::integer,'kind','product'));
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
create or replace function public.apex_customer_draft(p_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.staff_customer_drafts;
begin
 select * into d from public.staff_customer_drafts where token=p_token and submitted_at is null and expires_at>now();
 if not found then raise exception 'This customer link has expired or was already submitted';end if;
 if not exists(select 1 from public.employee_profiles where user_id=d.employee_id and active) then raise exception 'This employee link is no longer active';end if;
 return jsonb_build_object('kind',d.kind,'payload',d.payload,'expires_at',d.expires_at);
end;
$$;
create or replace function public.apex_my_customer_drafts() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(public.apex_staff_can('prepare_sales'),false) then raise exception 'Sales preparation permission required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(d) order by created_at desc) from public.staff_customer_drafts d where public.apex_is_owner() or employee_id=auth.uid()),'[]');
end;
$$;
create or replace function public.apex_attach_customer_draft() returns trigger
language plpgsql security definer set search_path='' as $$
declare d public.staff_customer_drafts;v_kind text:=TG_ARGV[0];v_employee text;
begin
 NEW.sales_origin:='website';
 if NEW.handoff_token is null then return NEW;end if;
 select * into d from public.staff_customer_drafts where token=NEW.handoff_token for update;
 if not found or d.kind<>v_kind or d.submitted_at is not null or d.expires_at<=now() then raise exception 'Customer link is expired, invalid or already submitted';end if;
 select display_name into v_employee from public.employee_profiles where user_id=d.employee_id and active;
 if not found then raise exception 'This employee link is no longer active';end if;
 update public.staff_customer_drafts set submitted_at=now(),submitted_job_id=NEW.id where id=d.id;
 NEW.sales_origin:='employee';
 insert into public.staff_sales_credits(job_kind,job_id,employee_id,employee_name,customer_name,reference)
 values(v_kind,NEW.id,d.employee_id,v_employee,NEW.customer_name,case when v_kind='order' then to_jsonb(NEW)->>'ref' else to_jsonb(NEW)->>'reason' end);
 return NEW;
end;
$$;
drop trigger if exists apex_order_handoff on public.apex_orders;
create trigger apex_order_handoff before insert on public.apex_orders for each row execute function public.apex_attach_customer_draft('order');
drop trigger if exists apex_request_handoff on public.apex_service_requests;
create trigger apex_request_handoff before insert on public.apex_service_requests for each row execute function public.apex_attach_customer_draft('request');
create or replace function public.apex_employee_contact(p_employee uuid,p_save boolean default false,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501';end if;
 if not exists(select 1 from public.employee_profiles where user_id=p_employee) then raise exception 'Employee not found';end if;
 if p_save then
  if length(trim(coalesce(p_data->>'name',''))) not between 1 and 100 or (coalesce(p_data->>'email','')<>'' and p_data->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') or length(coalesce(p_data->>'email',''))>254 then raise exception 'Enter a name and valid contact email';end if;
  update public.employee_profiles set display_name=trim(p_data->>'name'),email=nullif(trim(p_data->>'email'),'') where user_id=p_employee;
  insert into public.staff_employee_contacts(employee_id,phone,address) values(p_employee,coalesce(p_data->>'phone',''),coalesce(p_data->>'address','')) on conflict(employee_id) do update set phone=excluded.phone,address=excluded.address;
  perform public.apex_staff_audit('employee_contact_updated',p_employee,'{}');
 end if;
 return (select jsonb_build_object('name',p.display_name,'email',p.email,'phone',coalesce(c.phone,''),'address',coalesce(c.address,'')) from public.employee_profiles p left join public.staff_employee_contacts c on c.employee_id=p.user_id where p.user_id=p_employee);
end;
$$;
revoke all on function public.apex_prepare_customer_draft(text,jsonb,uuid),public.apex_customer_draft(uuid),public.apex_my_customer_drafts(),public.apex_attach_customer_draft(),public.apex_employee_contact(uuid,boolean,jsonb) from public,anon,authenticated;
grant execute on function public.apex_prepare_customer_draft(text,jsonb,uuid),public.apex_my_customer_drafts(),public.apex_employee_contact(uuid,boolean,jsonb) to authenticated;
grant execute on function public.apex_customer_draft(uuid) to anon,authenticated;
notify pgrst,'reload schema';
commit;
