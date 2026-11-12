begin;
-- Verified Auth identity, never an email supplied by the browser.
create or replace function public.apex_customer_identity() returns text
language plpgsql stable security definer set search_path='' as $$
declare v_email text;
begin
 select lower(trim(email)) into v_email from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if v_email is null or v_email='' then raise exception 'Confirm your email and sign in first' using errcode='42501'; end if;
 return v_email;
end;
$$;
create table if not exists public.customer_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 details jsonb not null default '{}'::jsonb,
 updated_at timestamptz not null default now()
);
-- Keep account history when staff archive/delete the operational order.
create table if not exists public.customer_order_links (
 order_id text primary key references public.customer_order_tracking(order_id),
 user_id uuid not null references auth.users(id) on delete cascade,
 linked_at timestamptz not null default now()
);
create index if not exists customer_order_links_user on public.customer_order_links(user_id,linked_at desc);
alter table public.customer_profiles enable row level security;
alter table public.customer_order_links enable row level security;
revoke all on public.customer_profiles,public.customer_order_links from public,anon,authenticated;
grant all on public.customer_profiles,public.customer_order_links to service_role;
create or replace function public.apex_customer_profile(p_details jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_email text:=public.apex_customer_identity();v_details jsonb;v_key text;v_address jsonb;
begin
 if p_details is not null then
  if jsonb_typeof(p_details)<>'object' then raise exception 'Invalid contact details'; end if;
  v_address:=coalesce(p_details->'address','{}'::jsonb);
  if jsonb_typeof(v_address)<>'object' then raise exception 'Invalid address'; end if;
  v_details:=jsonb_build_object('name',trim(coalesce(p_details->>'name','')),'phone',trim(coalesce(p_details->>'phone','')),'address',jsonb_build_object('street',trim(coalesce(v_address->>'street','')),'city',trim(coalesce(v_address->>'city','')),'state',trim(coalesce(v_address->>'state','')),'zip',trim(coalesce(v_address->>'zip',''))));
  if length(v_details->>'name')>120 or length(v_details->>'phone')>40 then raise exception 'Contact details are too long'; end if;
  foreach v_key in array array['street','city','state','zip'] loop
   if length(v_details->'address'->>v_key)>200 then raise exception 'Address is too long'; end if;
  end loop;
  insert into public.customer_profiles(user_id,details) values(auth.uid(),v_details) on conflict(user_id) do update set details=excluded.details,updated_at=now();
 end if;
 select details into v_details from public.customer_profiles where user_id=auth.uid();
 return coalesce(v_details,'{"name":"","phone":"","address":{}}'::jsonb)||jsonb_build_object('email',v_email);
end;
$$;
create or replace function public.apex_customer_link_order(p_token text) returns boolean
language plpgsql security definer set search_path='' as $$
declare v_email text:=public.apex_customer_identity();v_order text;
begin
 -- Both the private receipt and the verified checkout email are required.
 select id into v_order from public.apex_orders where tracking_token=p_token and lower(trim(customer_email))=v_email;
 if v_order is null then return false; end if;
 insert into public.customer_order_links(order_id,user_id) values(v_order,auth.uid()) on conflict(order_id) do nothing;
 return exists(select 1 from public.customer_order_links where order_id=v_order and user_id=auth.uid());
end;
$$;
create or replace function public.apex_customer_orders() returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_email text:=public.apex_customer_identity();v_result jsonb;
begin
 select coalesce(jsonb_agg(x.payload order by x.linked_at desc),'[]'::jsonb) into v_result from
 (select t.snapshot||jsonb_build_object('token',t.token,'updated_at',t.updated_at) as payload,l.linked_at
 from public.customer_order_links l join public.customer_order_tracking t on t.order_id=l.order_id
 where l.user_id=auth.uid() order by l.linked_at desc limit 100) x;
 return v_result;
end;
$$;
revoke all on function public.apex_customer_identity(),public.apex_customer_profile(jsonb),public.apex_customer_link_order(text),public.apex_customer_orders() from public,anon;
grant execute on function public.apex_customer_profile(jsonb),public.apex_customer_link_order(text),public.apex_customer_orders() to authenticated;
commit;
