-- Apex Computers: owner-only employee performance reporting.
-- Run after 202611060002_employee_permissions_audit.sql.
-- Captures assignment/status snapshots for new job audit events and exposes aggregate metrics to the owner.

create or replace function public.apex_log_job_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_name text;
  v_old jsonb;
  v_new jsonb;
  v_id text;
  v_changed jsonb := '[]'::jsonb;
  v_event text;
  v_details jsonb;
begin
  if v_actor is null then
    if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
  end if;

  if TG_OP <> 'INSERT' then v_old := to_jsonb(OLD); end if;
  if TG_OP <> 'DELETE' then v_new := to_jsonb(NEW); end if;
  v_id := coalesce(v_new ->> 'id', v_old ->> 'id');

  select display_name into v_name
  from public.employee_profiles where user_id = v_actor;

  if v_name is null then
    if lower(coalesce(auth.jwt() ->> 'email','')) = 'apexcomputers039@gmail.com' then
      v_name := 'Owner';
    else
      v_name := 'Authenticated user';
    end if;
  end if;

  if TG_OP = 'UPDATE' then
    select coalesce(jsonb_agg(k), '[]'::jsonb) into v_changed
    from jsonb_object_keys(v_old) as keys(k)
    where v_old -> k is distinct from v_new -> k;
  end if;

  v_event := lower(TG_ARGV[0]) || '_' || lower(TG_OP);
  v_details := jsonb_build_object(
    'changed_fields', v_changed,
    'old_status', v_old ->> 'status',
    'new_status', v_new ->> 'status',
    'old_assigned_to', v_old ->> 'assigned_to',
    'new_assigned_to', v_new ->> 'assigned_to'
  );

  insert into public.employee_activity_logs
    (actor_user_id, actor_name, event_type, job_kind, job_id, details)
  values
    (v_actor, v_name, v_event, TG_ARGV[0], v_id, v_details);

  if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
end;
$$;

create or replace function public.apex_owner_employee_performance()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if lower(coalesce(auth.jwt() ->> 'email','')) <> 'apexcomputers039@gmail.com' then
    raise exception 'Owner authentication required';
  end if;

  select jsonb_build_object(
    'employees',
    coalesce(jsonb_agg(
      jsonb_build_object(
        'user_id', p.user_id,
        'display_name', p.display_name,
        'active', p.active,
        'assigned_jobs', (
          select count(*) from public.apex_orders o where o.assigned_to = p.user_id
        ) + (
          select count(*) from public.apex_service_requests r where r.assigned_to = p.user_id
        ),
        'active_jobs', (
          select count(*) from public.apex_orders o
          where o.assigned_to = p.user_id and coalesce(o.status, 'requested') not in ('completed','delivered')
        ) + (
          select count(*) from public.apex_service_requests r
          where r.assigned_to = p.user_id and coalesce(r.status, 'requested') not in ('completed','delivered')
        ),
        'completed_jobs', (
          select count(distinct l.job_kind || ':' || l.job_id)
          from public.employee_activity_logs l
          where l.details ->> 'new_status' in ('completed','delivered')
            and l.details ->> 'new_assigned_to' = p.user_id::text
            and l.job_id is not null
        ),
        'claimed_jobs', (
          select count(distinct l.job_kind || ':' || l.job_id)
          from public.employee_activity_logs l
          where l.actor_user_id = p.user_id
            and l.details ->> 'old_assigned_to' is null
            and l.details ->> 'new_assigned_to' = p.user_id::text
            and l.job_id is not null
        ),
        'activity_30d', (
          select count(*) from public.employee_activity_logs l
          where l.actor_user_id = p.user_id
            and l.created_at >= now() - interval '30 days'
        ),
        'last_activity', (
          select max(l.created_at) from public.employee_activity_logs l
          where l.actor_user_id = p.user_id
        )
      )
      order by p.active desc, p.display_name
    ), '[]'::jsonb)
  ) into v_result
  from public.employee_profiles p;

  return v_result;
end;
$$;

revoke all on function public.apex_owner_employee_performance() from public, anon;
grant execute on function public.apex_owner_employee_performance() to authenticated;
