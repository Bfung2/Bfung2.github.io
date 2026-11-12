begin;
create table if not exists public.staff_sales_settlements (
 job_kind text not null check(job_kind in ('order','request')),
 job_id text not null,
 employee_id uuid,
 status text not null check(status in ('paid','void')),
 snapshot jsonb not null,
 settled_at timestamptz not null default now(),
 settled_by uuid references auth.users(id) on delete set null,
 primary key(job_kind,job_id)
);
alter table public.staff_sales_settlements enable row level security;
revoke all on public.staff_sales_settlements from public,anon,authenticated;
grant all on public.staff_sales_settlements to service_role;
-- Immutable settlement history keeps employee payout counts without retaining active cards.
create or replace function public.apex_sales_credits(p_employee uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_owner boolean:=public.apex_is_owner();
begin
 if not v_owner and not exists(select 1 from public.employee_profiles where user_id=v_user and active) then raise exception 'Active staff account required' using errcode='42501'; end if;
 if not v_owner and p_employee is not null and p_employee<>v_user then raise exception 'Only your own sales credits are available' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(x.data order by x.credited_at desc) from (select pending.data,pending.credited_at from (
  select to_jsonb(c)||jsonb_build_object('is_test',false,'settlement_status','pending') as data,c.credited_at
  from public.staff_sales_credits c
  where ((v_owner and (p_employee is null or c.employee_id=p_employee)) or (not v_owner and c.employee_id=v_user))
    and not exists(select 1 from public.apex_orders o where c.job_kind='order' and o.id=c.job_id and o.is_test)
  union all
  select jsonb_build_object('id',o.id,'job_kind','order','job_id',o.id,'employee_id',o.sales_employee_id,
    'employee_name',o.sales_employee_name,'customer_name',o.customer_name,'reference',o.ref,
    'credited_at',o.created_at,'is_test',true,'status','test_completed','total',0,'settlement_status','pending'),o.created_at
  from public.apex_orders o where o.is_test and o.status='test_completed' and o.sales_employee_id is not null
    and ((v_owner and (p_employee is null or o.sales_employee_id=p_employee)) or (not v_owner and o.sales_employee_id=v_user))
 ) pending where not exists(select 1 from public.staff_sales_settlements a where a.job_kind=pending.data->>'job_kind' and a.job_id=pending.data->>'job_id')
 union all
 select a.snapshot||jsonb_build_object('settlement_status',a.status,'settled_at',a.settled_at),a.settled_at
 from public.staff_sales_settlements a
 where (v_owner and (p_employee is null or a.employee_id=p_employee)) or (not v_owner and a.employee_id=v_user)
 ) x),'[]');
end;
$$;
revoke all on function public.apex_sales_credits(uuid) from public,anon;
grant execute on function public.apex_sales_credits(uuid) to authenticated;

-- Records an already completed employee payment; never transfers money or changes the customer order.
create or replace function public.apex_settle_sales_contribution(p_kind text,p_job text,p_action text) returns boolean
language plpgsql security definer set search_path='' as $$
declare c jsonb; prior text;
begin
 if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501'; end if;
 if p_action is null or p_action not in ('paid','void') then raise exception 'Choose paid or void'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_kind||':'||p_job,0));
 select status into prior from public.staff_sales_settlements where job_kind=p_kind and job_id=p_job;
 if found then
  if prior=p_action then return false; end if;
  raise exception 'This contribution was already settled. Refresh the page';
 end if;
 select value into c from jsonb_array_elements(public.apex_sales_credits())
 where value->>'job_kind'=p_kind and value->>'job_id'=p_job and value->>'settlement_status'='pending';
 if c is null then raise exception 'Contribution no longer exists. Refresh the page'; end if;
 insert into public.staff_sales_settlements(job_kind,job_id,employee_id,status,snapshot,settled_by)
 values(p_kind,p_job,(c->>'employee_id')::uuid,p_action,c,auth.uid());
 perform public.apex_staff_audit('sales_contribution_'||p_action,(c->>'employee_id')::uuid,jsonb_build_object('job_kind',p_kind,'job_id',p_job,'is_test',coalesce((c->>'is_test')::boolean,false)));
 return true;
end;
$$;
revoke all on function public.apex_settle_sales_contribution(text,text,text) from public,anon;
grant execute on function public.apex_settle_sales_contribution(text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
