begin;
create table if not exists public.staff_contribution_amounts (
 job_kind text not null check(job_kind in ('order','request')),
 job_id text not null,
 amount_cents integer not null check(amount_cents between 0 and 100000000),
 note text not null default '' check(length(note)<=1000),
 revision integer not null default 1,
 updated_at timestamptz not null default now(),
 primary key(job_kind,job_id)
);
alter table public.staff_contribution_amounts enable row level security;
revoke all on public.staff_contribution_amounts from public,anon,authenticated;
grant all on public.staff_contribution_amounts to service_role;
create or replace function public.apex_sales_credits(p_employee uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_owner boolean:=public.apex_is_owner();
begin
 if not v_owner and not exists(select 1 from public.employee_profiles where user_id=v_user and active) then raise exception 'Active staff account required' using errcode='42501'; end if;
 if not v_owner and p_employee is not null and p_employee<>v_user then raise exception 'Only your own sales credits are available' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(x.data order by x.credited_at desc) from (select pending.data||jsonb_build_object('commission_cents',m.amount_cents,'commission_note',m.note,'commission_revision',coalesce(m.revision,0)) as data,pending.credited_at from (
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
end;
$$;
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
 if p_action='paid' and c->>'commission_cents' is null then raise exception 'Set the employee commission amount before recording payment'; end if;
 insert into public.staff_sales_settlements(job_kind,job_id,employee_id,status,snapshot,settled_by)
 values(p_kind,p_job,(c->>'employee_id')::uuid,p_action,c,auth.uid());
 perform public.apex_staff_audit('sales_contribution_'||p_action,(c->>'employee_id')::uuid,jsonb_build_object('job_kind',p_kind,'job_id',p_job,'is_test',coalesce((c->>'is_test')::boolean,false)));
 return true;
end;
$$;

-- All commission amounts are explicitly set by the owner, never inferred from sale totals.
create or replace function public.apex_save_contribution_amount(p_kind text,p_job text,p_amount_cents integer,p_note text,p_revision integer default 0) returns boolean
language plpgsql security definer set search_path='' as $$
declare c jsonb; current_revision integer;
begin
 if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501'; end if;
 if p_amount_cents is null or p_amount_cents not between 0 and 100000000 or p_note is null or length(p_note)>1000 then raise exception 'Enter a valid amount and a note of up to 1000 characters'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_kind||':'||p_job,0));
 if exists(select 1 from public.staff_sales_settlements where job_kind=p_kind and job_id=p_job) then raise exception 'Settled contributions cannot be changed'; end if;
 select value into c from jsonb_array_elements(public.apex_sales_credits()) where value->>'job_kind'=p_kind and value->>'job_id'=p_job;
 if c is null then raise exception 'Contribution no longer exists'; end if;
 select revision into current_revision from public.staff_contribution_amounts where job_kind=p_kind and job_id=p_job;
 if coalesce(current_revision,0) is distinct from p_revision then raise exception 'The amount changed. Refresh and try again'; end if;
 insert into public.staff_contribution_amounts(job_kind,job_id,amount_cents,note) values(p_kind,p_job,p_amount_cents,p_note)
 on conflict(job_kind,job_id) do update set amount_cents=excluded.amount_cents,note=excluded.note,revision=staff_contribution_amounts.revision+1,updated_at=now();
 perform public.apex_staff_audit('contribution_amount_saved',(c->>'employee_id')::uuid,jsonb_build_object('job_kind',p_kind,'job_id',p_job,'amount_cents',p_amount_cents));
 return true;
end;
$$;
-- Saving the payment amount and archiving the paid contribution is one transaction.
create or replace function public.apex_pay_contribution(p_kind text,p_job text,p_amount_cents integer,p_note text,p_revision integer default 0) returns boolean
language plpgsql security definer set search_path='' as $$
declare prior text;
begin
 if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_kind||':'||p_job,0));
 select status into prior from public.staff_sales_settlements where job_kind=p_kind and job_id=p_job;
 if found then
  if prior='paid' then return false; end if;
  raise exception 'Contribution was voided';
 end if;
 perform public.apex_save_contribution_amount(p_kind,p_job,p_amount_cents,p_note,p_revision);
 return public.apex_settle_sales_contribution(p_kind,p_job,'paid');
end;
$$;
create or replace function public.apex_owner_dashboard() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501'; end if;
 return jsonb_build_object(
  'paid_orders',(select count(*) from public.apex_orders where not is_test and status='paid'),
  'open_orders',(select count(*) from public.apex_orders where not is_test and status in ('paid','working','waiting','invoiced','shipped')),
  'open_requests',(select count(*) from public.apex_service_requests where coalesce(status,'requested') not in ('completed','delivered','done','cancelled')),
  'failed_notifications',(select count(*) from public.apex_paid_notifications where state='failed' and coalesce(payload->>'is_test','false')<>'true'),
  'waiting_links',(select count(*) from public.staff_customer_drafts where submitted_at is null and expires_at>now()));
end;
$$;
revoke all on function public.apex_save_contribution_amount(text,text,integer,text,integer),public.apex_pay_contribution(text,text,integer,text,integer),public.apex_owner_dashboard() from public,anon;
grant execute on function public.apex_save_contribution_amount(text,text,integer,text,integer),public.apex_pay_contribution(text,text,integer,text,integer),public.apex_owner_dashboard() to authenticated;
notify pgrst,'reload schema';
commit;
