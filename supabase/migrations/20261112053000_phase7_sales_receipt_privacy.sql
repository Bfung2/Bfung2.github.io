-- Phase 7: reduce customer data disclosure in the employee sales ledger.
-- Keep existing owner/employee scoping, settlement history, and grants unchanged.
CREATE OR REPLACE FUNCTION public.apex_sales_credits(p_employee uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid:=auth.uid();v_owner boolean:=public.apex_is_owner();v_result jsonb;
begin
 if not v_owner and not exists(select 1 from public.employee_profiles where user_id=v_user and active) then raise exception 'Active staff account required' using errcode='42501'; end if;
 if not v_owner and p_employee is not null and p_employee<>v_user then raise exception 'Only your own sales credits are available' using errcode='42501'; end if;
 v_result := coalesce((select jsonb_agg(x.data order by x.credited_at desc) from (select pending.data||jsonb_build_object('commission_cents',m.amount_cents,'commission_note',m.note,'commission_revision',coalesce(m.revision,0)) as data,pending.credited_at from (
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
 ) pending left join public.staff_contribution_amounts m on m.job_kind=pending.data->>'job_kind' and m.job_id=pending.data->>'job_id' where not exists(select 1 from public.staff_sales_settlements a where a.job_kind=pending.data->>'job_kind' and a.job_id=pending.data->>'job_id')
 union all
 select a.snapshot||jsonb_build_object('settlement_status',a.status,'settled_at',a.settled_at),a.settled_at
 from public.staff_sales_settlements a
 where (v_owner and (p_employee is null or a.employee_id=p_employee)) or (not v_owner and a.employee_id=v_user)
 ) x),'[]');
 if v_owner or coalesce(public.apex_staff_can('own_sales_receipts'),false) then
  return v_result;
 end if;
 -- Employees without customer-receipt permission get their own credit ledger,
 -- but not customer names or free-form commission notes.
 select coalesce(jsonb_agg(item - 'customer_name' - 'customer_email' - 'customer_phone' - 'shipping_address' - 'commission_note'), '[]'::jsonb)
 into v_result from jsonb_array_elements(v_result) as t(item);
 return v_result;
end;
$function$

