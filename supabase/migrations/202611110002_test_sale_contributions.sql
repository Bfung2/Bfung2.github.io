begin;
-- Show simulations for troubleshooting without inserting them into real sales credit.
create or replace function public.apex_sales_credits(p_employee uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_owner boolean:=public.apex_is_owner();
begin
 if not v_owner and not exists(select 1 from public.employee_profiles where user_id=v_user and active) then raise exception 'Active staff account required' using errcode='42501'; end if;
 if not v_owner and p_employee is not null and p_employee<>v_user then raise exception 'Only your own sales credits are available' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(x.data order by x.credited_at desc) from (
  select to_jsonb(c)||jsonb_build_object('is_test',false) as data,c.credited_at
  from public.staff_sales_credits c
  where ((v_owner and (p_employee is null or c.employee_id=p_employee)) or (not v_owner and c.employee_id=v_user))
    and not exists(select 1 from public.apex_orders o where c.job_kind='order' and o.id=c.job_id and o.is_test)
  union all
  select jsonb_build_object('id',o.id,'job_kind','order','job_id',o.id,'employee_id',o.sales_employee_id,
    'employee_name',o.sales_employee_name,'customer_name',o.customer_name,'reference',o.ref,
    'credited_at',o.created_at,'is_test',true,'status','test_completed','total',0),o.created_at
  from public.apex_orders o where o.is_test and o.status='test_completed' and o.sales_employee_id is not null
    and ((v_owner and (p_employee is null or o.sales_employee_id=p_employee)) or (not v_owner and o.sales_employee_id=v_user))
 ) x),'[]');
end;
$$;
revoke all on function public.apex_sales_credits(uuid) from public,anon;
grant execute on function public.apex_sales_credits(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
