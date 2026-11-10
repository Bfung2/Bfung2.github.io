begin;
create table if not exists public.staff_sales_credits (
 id uuid primary key default gen_random_uuid(),
 job_kind text not null check(job_kind in ('order','request')),
 job_id text not null,
 employee_id uuid references public.employee_profiles(user_id) on delete set null,
 employee_name text not null,
 customer_name text not null,
 reference text not null,
 credited_at timestamptz not null default now(),
 unique(job_kind,job_id)
);
alter table public.staff_sales_credits enable row level security;
revoke all on public.staff_sales_credits from public,anon,authenticated;
grant all on public.staff_sales_credits to service_role;
create index if not exists staff_sales_employee_idx on public.staff_sales_credits(employee_id,credited_at desc);
create or replace function public.apex_credit_sale(p_kind text,p_job text,p_employee uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_name text;v_customer text;v_ref text;
begin
 if not public.apex_is_owner() then raise exception 'Only the owner can assign sales credit' using errcode='42501'; end if;
 if p_kind='order' then select customer_name,ref into v_customer,v_ref from public.apex_orders where id=p_job;
 elsif p_kind='request' then select customer_name,reason into v_customer,v_ref from public.apex_service_requests where id=p_job;
 else raise exception 'Invalid sale type'; end if;
 if not found then raise exception 'Order or request no longer exists'; end if;
 if p_employee is null then
  delete from public.staff_sales_credits where job_kind=p_kind and job_id=p_job;
 else
  select display_name into v_name from public.employee_profiles where user_id=p_employee and active;
  if not found then raise exception 'Choose an active employee'; end if;
  insert into public.staff_sales_credits(job_kind,job_id,employee_id,employee_name,customer_name,reference)
  values(p_kind,p_job,p_employee,v_name,coalesce(v_customer,''),coalesce(v_ref,p_job))
  on conflict(job_kind,job_id) do update set employee_id=excluded.employee_id,employee_name=excluded.employee_name,
   customer_name=excluded.customer_name,reference=excluded.reference,credited_at=now();
 end if;
 perform public.apex_staff_audit('sales_credit_updated',p_employee,jsonb_build_object('job_kind',p_kind,'job_id',p_job));
end;
$$;
create or replace function public.apex_sales_credits(p_employee uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_owner boolean:=public.apex_is_owner();
begin
 if not v_owner and not exists(select 1 from public.employee_profiles where user_id=v_user and active) then raise exception 'Active staff account required' using errcode='42501'; end if;
 if not v_owner and p_employee is not null and p_employee<>v_user then raise exception 'Only your own sales credits are available' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(to_jsonb(c) order by c.credited_at desc) from public.staff_sales_credits c
  where (v_owner and (p_employee is null or c.employee_id=p_employee)) or (not v_owner and c.employee_id=v_user)),'[]');
end;
$$;
revoke all on function public.apex_credit_sale(text,text,uuid),public.apex_sales_credits(uuid) from public,anon;
grant execute on function public.apex_credit_sale(text,text,uuid),public.apex_sales_credits(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
