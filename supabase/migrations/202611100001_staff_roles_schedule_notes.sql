-- Run after the three 20261106 employee migrations. Transactional and safe to rerun.
begin;

create or replace function public.apex_is_owner() returns boolean
language sql volatile security definer set search_path = '' as $$
  select auth.uid() is not null and lower(coalesce(auth.jwt()->>'email','')) = 'apexcomputers039@gmail.com';
$$;
create or replace function public.apex_permission_keys() returns text[]
language sql immutable set search_path = '' as $$
  select array['orders','requests','customer_details','claim_jobs','update_status','view_schedule','edit_schedule','view_reports','view_notes','edit_notes','manage_notes'];
$$;
create or replace function public.apex_validate_permissions(p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(p) = 'object' and not exists (
    select 1 from jsonb_each(case when jsonb_typeof(p)='object' then p else '{}'::jsonb end) e
    where not (e.key = any(public.apex_permission_keys())) or jsonb_typeof(e.value)<>'boolean'
  );
$$;

alter table public.employee_profiles add column if not exists permission_overrides jsonb not null default '{}';
alter table public.employee_profiles add column if not exists access_configured boolean not null default false;
create table if not exists public.staff_roles (
  id uuid primary key default gen_random_uuid(),
  name text not null check(length(trim(name)) between 1 and 60),
  permissions jsonb not null default '{}' check(public.apex_validate_permissions(permissions)),
  created_at timestamptz not null default now()
);
create unique index if not exists staff_roles_name_unique on public.staff_roles(lower(trim(name)));
create table if not exists public.staff_role_assignments (
  user_id uuid not null references public.employee_profiles(user_id) on delete cascade,
  role_id uuid not null references public.staff_roles(id) on delete cascade,
  primary key(user_id,role_id)
);
create index if not exists staff_role_assignments_role_idx on public.staff_role_assignments(role_id);
create table if not exists public.staff_shifts (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employee_profiles(user_id) on delete cascade,
  title text not null check(length(trim(title)) between 1 and 120),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  location text not null default '' check(length(location)<=300),
  details text not null default '' check(length(details)<=2000),
  revision integer not null default 1,
  updated_at timestamptz not null default now(),
  check(ends_at > starts_at and ends_at <= starts_at + interval '7 days')
);
create index if not exists staff_shifts_time_idx on public.staff_shifts(starts_at,ends_at);
create index if not exists staff_shifts_employee_idx on public.staff_shifts(employee_id,starts_at);
create table if not exists public.staff_notes (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check(entity_type in ('general','product','employee','other')),
  entity_id text not null default '' check(length(entity_id)<=200),
  title text not null check(length(trim(title)) between 1 and 160),
  body text not null check(length(body)<=10000),
  all_staff boolean not null default false,
  view_role_ids uuid[] not null default '{}',
  edit_role_ids uuid[] not null default '{}',
  revision integer not null default 1,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists staff_notes_entity_idx on public.staff_notes(entity_type,entity_id,updated_at desc);

-- No direct table grants: every read/write goes through an authenticated, permission-checked RPC.
alter table public.staff_roles enable row level security;
alter table public.staff_role_assignments enable row level security;
alter table public.staff_shifts enable row level security;
alter table public.staff_notes enable row level security;
revoke all on public.staff_roles,public.staff_role_assignments,public.staff_shifts,public.staff_notes from public,anon,authenticated;
grant all on public.staff_roles,public.staff_role_assignments,public.staff_shifts,public.staff_notes to service_role;

-- Existing employees keep their current job permissions until the owner first configures roles/overrides.
-- Once configured, the union of roles is the baseline; explicit individual true/false wins.
create or replace function public.apex_effective_permissions(p_user uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare ep public.employee_profiles; result jsonb := '{}'; k text;
begin
  select * into ep from public.employee_profiles where user_id=p_user and active;
  if not found then return '{}'; end if;
  foreach k in array public.apex_permission_keys() loop
    result := result || jsonb_build_object(k,
      case when ep.permission_overrides ? k then ep.permission_overrides->k = 'true'::jsonb
      when not ep.access_configured then coalesce(ep.permissions->k = 'true'::jsonb,k='view_schedule')
      else exists(select 1 from public.staff_role_assignments a join public.staff_roles r on r.id=a.role_id
        where a.user_id=p_user and r.permissions->k='true'::jsonb) end);
  end loop;
  return result;
end;
$$;
create or replace function public.apex_staff_can(p_key text) returns boolean
language sql volatile security definer set search_path = '' as $$
  select public.apex_is_owner() or (public.apex_effective_permissions(auth.uid())->p_key = 'true'::jsonb);
$$;

create or replace function public.apex_staff_audit(p_event text,p_target uuid default null,p_details jsonb default '{}') returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.employee_activity_logs(actor_user_id,actor_name,target_user_id,event_type,details)
  values(auth.uid(),case when public.apex_is_owner() then 'Owner' else coalesce((select display_name from public.employee_profiles where user_id=auth.uid()),'Staff') end,p_target,p_event,p_details);
end;
$$;

-- Keep legacy job RPCs' permissions snapshot synchronized within the same transaction.
create or replace function public.apex_sync_staff_permissions() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.employee_profiles ep set permissions=public.apex_effective_permissions(ep.user_id)
  where ep.access_configured;
  return null;
end;
$$;
drop trigger if exists staff_role_permissions_sync on public.staff_roles;
create trigger staff_role_permissions_sync after insert or update or delete on public.staff_roles
for each statement execute function public.apex_sync_staff_permissions();
drop trigger if exists staff_assignment_permissions_sync on public.staff_role_assignments;
create trigger staff_assignment_permissions_sync after insert or update or delete on public.staff_role_assignments
for each statement execute function public.apex_sync_staff_permissions();

insert into public.staff_roles(name,permissions) values
('Manager','{"orders":true,"requests":true,"customer_details":true,"claim_jobs":true,"update_status":true,"view_schedule":true,"edit_schedule":true,"view_reports":true,"view_notes":true,"edit_notes":true,"manage_notes":false}'),
('Tech','{"orders":true,"requests":true,"customer_details":true,"claim_jobs":true,"update_status":true,"view_schedule":true,"view_notes":true,"edit_notes":true}'),
('Market','{"view_schedule":true,"view_notes":true,"edit_notes":true}')
on conflict do nothing;

create or replace function public.apex_staff_context() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_owner boolean := public.apex_is_owner(); v_perms jsonb := public.apex_effective_permissions(auth.uid());
begin
  if not v_owner and not exists(select 1 from public.employee_profiles where user_id=auth.uid() and active) then raise exception 'Active staff account required' using errcode='42501'; end if;
  return jsonb_build_object('permissions',v_perms,'roles',coalesce((select jsonb_agg(to_jsonb(r) order by r.name) from public.staff_roles r),'[]'),
    'employees',coalesce((select jsonb_agg(jsonb_build_object('user_id',ep.user_id,'display_name',ep.display_name,'active',ep.active,
      'email',case when v_owner then ep.email else null end,
      'permissions',case when v_owner or ep.user_id=auth.uid() then public.apex_effective_permissions(ep.user_id) else null end,
      'permission_overrides',case when v_owner or ep.user_id=auth.uid() then ep.permission_overrides else null end,
      'access_configured',ep.access_configured,
      'role_ids',case when v_owner or ep.user_id=auth.uid() then coalesce((select jsonb_agg(a.role_id) from public.staff_role_assignments a where a.user_id=ep.user_id),'[]') else '[]'::jsonb end)
      order by ep.display_name) from public.employee_profiles ep where v_owner or ep.active),'[]'));
end;
$$;

-- Role definitions and employee access are owner-only, even for managers.
create or replace function public.apex_staff_admin(p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_user uuid; v_roles uuid[]; v_overrides jsonb; v_permissions jsonb; v_name text;
begin
  if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501'; end if;
  if p_action='role_save' then
    v_name:=trim(p_data->>'name'); v_permissions:=p_data->'permissions';
    if v_name is null or length(v_name) not between 1 and 60 or not coalesce(public.apex_validate_permissions(v_permissions),false) then raise exception 'Invalid role name or permissions'; end if;
    v_id:=nullif(p_data->>'id','')::uuid;
    if v_id is null then insert into public.staff_roles(name,permissions) values(v_name,v_permissions) returning id into v_id;
    else update public.staff_roles set name=v_name,permissions=v_permissions where id=v_id;
      if not found then raise exception 'Role no longer exists'; end if;
    end if;
    perform public.apex_staff_audit('role_saved',null,jsonb_build_object('role_id',v_id,'name',v_name,'permissions',v_permissions));
  elsif p_action='role_delete' then
    v_id:=(p_data->>'id')::uuid;
    delete from public.staff_roles where id=v_id;
    if not found then raise exception 'Role no longer exists'; end if;
    perform public.apex_staff_audit('role_deleted',null,jsonb_build_object('role_id',v_id));
  elsif p_action='employee_access' then
    v_user:=(p_data->>'user_id')::uuid; v_overrides:=p_data->'overrides';
    if not coalesce(public.apex_validate_permissions(v_overrides),false) then raise exception 'Invalid permission overrides'; end if;
    if jsonb_typeof(p_data->'role_ids') is distinct from 'array' then raise exception 'Choose employee roles'; end if;
    select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into v_roles from jsonb_array_elements_text(p_data->'role_ids');
    if exists(select 1 from unnest(v_roles) r where not exists(select 1 from public.staff_roles where id=r)) then raise exception 'A selected role no longer exists'; end if;
    perform 1 from public.employee_profiles where user_id=v_user for update;
    if not found then raise exception 'Employee not found'; end if;
    if length(trim(p_data->>'display_name')) not between 1 and 100 or p_data->>'display_name' is null then raise exception 'Enter an employee name'; end if;
    if coalesce(p_data->>'email','')<>'' and (length(p_data->>'email')>254 or p_data->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception 'Enter a valid contact email'; end if;
    update public.employee_profiles set display_name=trim(p_data->>'display_name'),email=nullif(lower(trim(p_data->>'email')),''),permission_overrides=v_overrides,access_configured=true where user_id=v_user;
    delete from public.staff_role_assignments where user_id=v_user;
    insert into public.staff_role_assignments(user_id,role_id) select v_user,unnest(v_roles);
    update public.employee_profiles set permissions=public.apex_effective_permissions(v_user) where user_id=v_user;
    perform public.apex_staff_audit('employee_access_updated',v_user,jsonb_build_object('role_ids',v_roles,'overrides',v_overrides));
  else raise exception 'Unknown staff administration action'; end if;
  return jsonb_build_object('success',true,'id',v_id);
end;
$$;

-- Prevent the old account endpoint from replacing role-managed permissions accidentally.
-- This also protects the snapshot when an older account-management client sends legacy flags.
create or replace function public.apex_staff_preserve_permissions() returns trigger
language plpgsql security definer set search_path = '' as $$
declare k text; v_result jsonb:='{}';
begin
  if not coalesce(public.apex_validate_permissions(NEW.permission_overrides),false) then raise exception 'Invalid permission overrides'; end if;
  if NEW.access_configured then
    foreach k in array public.apex_permission_keys() loop
      v_result:=v_result||jsonb_build_object(k,NEW.active and case when NEW.permission_overrides ? k then NEW.permission_overrides->k='true'::jsonb
        else exists(select 1 from public.staff_role_assignments a join public.staff_roles r on r.id=a.role_id where a.user_id=NEW.user_id and r.permissions->k='true'::jsonb) end);
    end loop;
    NEW.permissions:=v_result;
  end if;
  return NEW;
end;
$$;
drop trigger if exists staff_profile_validate on public.employee_profiles;
create trigger staff_profile_validate before insert or update on public.employee_profiles
for each row execute function public.apex_staff_preserve_permissions();

-- Existing job routines now read the live effective permissions, never stale client flags.

create or replace function public.apex_employee_get_jobs()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_orders_enabled boolean;
  v_requests_enabled boolean;
  v_customer_details boolean;
  v_claim_enabled boolean;
  v_orders jsonb := '[]'::jsonb;
  v_requests jsonb := '[]'::jsonb;
begin
  select coalesce((public.apex_effective_permissions(v_user) ->> 'orders')::boolean, false),
         coalesce((public.apex_effective_permissions(v_user) ->> 'requests')::boolean, false),
         coalesce((public.apex_effective_permissions(v_user) ->> 'customer_details')::boolean, false),
         coalesce((public.apex_effective_permissions(v_user) ->> 'claim_jobs')::boolean, false)
    into v_orders_enabled, v_requests_enabled, v_customer_details, v_claim_enabled
  from public.employee_profiles
  where user_id = v_user and active = true;

  if not found then
    raise exception 'Active employee account required';
  end if;

  if v_orders_enabled then
    select coalesce(jsonb_agg(
      case when v_customer_details then to_jsonb(o)
      else to_jsonb(o) - array['customer_name','customer_email','customer_phone','shipping_address']::text[]
      end
      order by o.created_at desc
    ), '[]'::jsonb)
    into v_orders
    from public.apex_orders o
    where o.assigned_to = v_user or (v_claim_enabled and o.assigned_to is null);
  end if;

  if v_requests_enabled then
    select coalesce(jsonb_agg(
      case when v_customer_details then to_jsonb(r)
      else to_jsonb(r) - array['customer_name','customer_email','customer_phone','customer_address']::text[]
      end
      order by r.created_at desc
    ), '[]'::jsonb)
    into v_requests
    from public.apex_service_requests r
    where r.assigned_to = v_user or (v_claim_enabled and r.assigned_to is null);
  end if;

  return jsonb_build_object('orders', v_orders, 'requests', v_requests);
end;
$$;

create or replace function public.apex_claim_job(job_kind text, job_id text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
  v_permissions jsonb;
begin
  select public.apex_effective_permissions(auth.uid()) into v_permissions
  from public.employee_profiles
  where user_id = auth.uid() and active = true;

  if not found then raise exception 'Active employee account required'; end if;
  if coalesce((v_permissions ->> 'claim_jobs')::boolean, false) is not true then
    raise exception 'Your account does not have permission to claim jobs';
  end if;

  if job_kind = 'order' then
    if coalesce((v_permissions ->> 'orders')::boolean, false) is not true then
      raise exception 'Order access is not enabled for your account';
    end if;
    update public.apex_orders set assigned_to = auth.uid()
    where id = job_id and assigned_to is null;
  elsif job_kind = 'request' then
    if coalesce((v_permissions ->> 'requests')::boolean, false) is not true then
      raise exception 'Service-request access is not enabled for your account';
    end if;
    update public.apex_service_requests set assigned_to = auth.uid()
    where id = job_id and assigned_to is null;
  else
    raise exception 'Invalid job type';
  end if;
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;

create or replace function public.apex_employee_update_job(job_kind text, job_id text, new_status text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
  v_permissions jsonb;
begin
  select public.apex_effective_permissions(auth.uid()) into v_permissions
  from public.employee_profiles
  where user_id = auth.uid() and active = true;

  if not found then raise exception 'Active employee account required'; end if;
  if coalesce((v_permissions ->> 'update_status')::boolean, false) is not true then
    raise exception 'Your account does not have permission to update job status';
  end if;
  if new_status not in ('requested','working','waiting','completed','invoiced','shipped','delivered') then
    raise exception 'Invalid status';
  end if;

  if job_kind = 'order' then
    if coalesce((v_permissions ->> 'orders')::boolean, false) is not true then
      raise exception 'Order access is not enabled for your account';
    end if;
    update public.apex_orders set status = new_status
    where id = job_id and assigned_to = auth.uid();
  elsif job_kind = 'request' then
    if coalesce((v_permissions ->> 'requests')::boolean, false) is not true then
      raise exception 'Service-request access is not enabled for your account';
    end if;
    update public.apex_service_requests set status = new_status
    where id = job_id and assigned_to = auth.uid();
  else
    raise exception 'Invalid job type';
  end if;
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;

create or replace function public.apex_staff_schedule(p_from timestamptz,p_to timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce(public.apex_staff_can('view_schedule'),false) then raise exception 'Schedule access required' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_to<=p_from or p_to>p_from+interval '100 days' then raise exception 'Choose a schedule range of up to 100 days'; end if;
  return coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at) from public.staff_shifts s
    where s.starts_at<p_to and s.ends_at>p_from),'[]');
end;
$$;
create or replace function public.apex_staff_save_shift(p_data jsonb,p_delete boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid:=nullif(p_data->>'id','')::uuid; v_employee uuid; v_revision integer; v_start timestamptz; v_end timestamptz;
begin
  if not coalesce(public.apex_staff_can('view_schedule') and public.apex_staff_can('edit_schedule'),false) then raise exception 'Schedule editing permission required' using errcode='42501'; end if;
  -- Serialize edits to avoid simultaneous overlapping assignments.
  perform pg_advisory_xact_lock(94268101);
  if v_id is not null then
    select employee_id,revision into v_employee,v_revision from public.staff_shifts where id=v_id for update;
    if not found then raise exception 'Shift no longer exists'; end if;
    if v_revision is distinct from (p_data->>'revision')::integer then raise exception 'This shift changed. Refresh and try again'; end if;
  end if;
  if p_delete then
    if v_id is null then raise exception 'Shift ID required'; end if;
    delete from public.staff_shifts where id=v_id;
  else
    v_employee:=(p_data->>'employee_id')::uuid;
    if not exists(select 1 from public.employee_profiles where user_id=v_employee and active) then raise exception 'Choose an active employee'; end if;
    v_start:=(p_data->>'starts_at')::timestamptz;v_end:=(p_data->>'ends_at')::timestamptz;
    if v_start is null or v_end is null or v_end<=v_start or v_end>v_start+interval '7 days' then raise exception 'End must follow start, with a maximum shift of seven days'; end if;
    if exists(select 1 from public.staff_shifts where employee_id=v_employee and id is distinct from v_id and starts_at<v_end and ends_at>v_start) then raise exception 'This employee already has a shift during that time'; end if;
    if v_id is null then
      insert into public.staff_shifts(employee_id,title,starts_at,ends_at,location,details)
      values(v_employee,trim(p_data->>'title'),v_start,v_end,coalesce(p_data->>'location',''),coalesce(p_data->>'details','')) returning id into v_id;
    else
      update public.staff_shifts set employee_id=v_employee,title=trim(p_data->>'title'),starts_at=v_start,ends_at=v_end,
        location=coalesce(p_data->>'location',''),details=coalesce(p_data->>'details',''),revision=revision+1,updated_at=now() where id=v_id;
    end if;
  end if;
  perform public.apex_staff_audit(case when p_delete then 'shift_deleted' else 'shift_saved' end,v_employee,jsonb_build_object('shift_id',v_id));
  return v_id;
end;
$$;

create or replace function public.apex_note_allowed(p_note uuid,p_edit boolean default false) returns boolean
language sql volatile security definer set search_path = '' as $$
  select public.apex_is_owner() or (coalesce(public.apex_staff_can('view_notes'),false) and exists(
    select 1 from public.staff_notes n where n.id=p_note
      and (n.all_staff or exists(select 1 from public.staff_role_assignments a where a.user_id=auth.uid() and (a.role_id=any(n.view_role_ids) or a.role_id=any(n.edit_role_ids))))
      and (not p_edit or (public.apex_staff_can('edit_notes') and exists(select 1 from public.staff_role_assignments a where a.user_id=auth.uid() and a.role_id=any(n.edit_role_ids))))
  ));
$$;
create or replace function public.apex_staff_get_notes(p_type text default null,p_entity text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce(public.apex_staff_can('view_notes'),false) then raise exception 'Notes access required' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(n)||jsonb_build_object('can_edit',public.apex_note_allowed(n.id,true)) order by n.updated_at desc)
    from public.staff_notes n where public.apex_note_allowed(n.id) and (p_type is null or n.entity_type=p_type) and (p_entity is null or n.entity_id=p_entity)),'[]');
end;
$$;
create or replace function public.apex_staff_save_note(p_data jsonb,p_delete boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid:=nullif(p_data->>'id','')::uuid; v_old public.staff_notes; v_manage boolean:=public.apex_staff_can('manage_notes'); v_view uuid[];v_edit uuid[];v_type text;v_entity text;
begin
  if not coalesce(public.apex_staff_can('view_notes'),false) then raise exception 'Notes access required' using errcode='42501'; end if;
  if v_id is not null then
    select * into v_old from public.staff_notes where id=v_id for update;
    if not found or not coalesce(public.apex_note_allowed(v_id,true),false) then raise exception 'Note editing access required' using errcode='42501'; end if;
    if v_old.revision is distinct from (p_data->>'revision')::integer then raise exception 'This note changed. Refresh and try again'; end if;
  elsif not coalesce(v_manage,false) then raise exception 'Note creation permission required' using errcode='42501'; end if;
  if p_delete then
    if v_id is null or not coalesce(v_manage,false) then raise exception 'Note management permission required' using errcode='42501'; end if;
    delete from public.staff_notes where id=v_id;
  else
    if v_manage then
      if jsonb_typeof(p_data->'view_role_ids') is distinct from 'array' or jsonb_typeof(p_data->'edit_role_ids') is distinct from 'array' then raise exception 'Choose role access'; end if;
      select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into v_view from jsonb_array_elements_text(p_data->'view_role_ids');
      select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into v_edit from jsonb_array_elements_text(p_data->'edit_role_ids');
      if exists(select 1 from unnest(v_view||v_edit) r where not exists(select 1 from public.staff_roles where id=r)) then raise exception 'A selected role no longer exists'; end if;
      v_type:=p_data->>'entity_type';v_entity:=coalesce(p_data->>'entity_id','');
      if v_type='employee' and not exists(select 1 from public.employee_profiles where user_id::text=v_entity) then raise exception 'Choose an existing employee'; end if;
      if v_type='product' and length(trim(v_entity))=0 then raise exception 'Choose a product or part'; end if;
      if v_id is null then
        insert into public.staff_notes(entity_type,entity_id,title,body,all_staff,view_role_ids,edit_role_ids,created_by)
        values(v_type,v_entity,trim(p_data->>'title'),p_data->>'body',coalesce((p_data->>'all_staff')::boolean,false),v_view,v_edit,auth.uid()) returning id into v_id;
      else
        update public.staff_notes set entity_type=v_type,entity_id=v_entity,title=trim(p_data->>'title'),body=p_data->>'body',
          all_staff=coalesce((p_data->>'all_staff')::boolean,false),view_role_ids=v_view,edit_role_ids=v_edit,revision=revision+1,updated_at=now() where id=v_id;
      end if;
      -- Non-owner note managers cannot create or move a note outside their own editing access.
      if not coalesce(public.apex_note_allowed(v_id,true),false) then raise exception 'Include one of your roles in editing access' using errcode='42501'; end if;
    else
      -- Content editors cannot change the target or access lists, even by crafting an API request.
      update public.staff_notes set title=trim(p_data->>'title'),body=p_data->>'body',revision=revision+1,updated_at=now() where id=v_id;
    end if;
  end if;
  perform public.apex_staff_audit(case when p_delete then 'note_deleted' else 'note_saved' end,null,jsonb_build_object('note_id',v_id));
  return v_id;
end;
$$;

create or replace function public.apex_employee_report(p_user_id uuid,p_before timestamptz default null,p_limit integer default 50,p_before_id bigint default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_result jsonb;
begin
  if not coalesce(public.apex_staff_can('view_reports'),false) then raise exception 'Employee reporting permission required' using errcode='42501'; end if;
  if not exists(select 1 from public.employee_profiles where user_id=p_user_id) then raise exception 'Employee not found'; end if;
  select jsonb_build_object(
    'assigned_jobs',(select count(*) from public.apex_orders where assigned_to=p_user_id)+(select count(*) from public.apex_service_requests where assigned_to=p_user_id),
    'completed_by_employee',(select count(distinct job_kind||':'||job_id) from public.employee_activity_logs where actor_user_id=p_user_id and details->>'new_status' in ('completed','delivered') and details->>'old_status' is distinct from details->>'new_status'),
    'activity_30d',(select count(*) from public.employee_activity_logs where actor_user_id=p_user_id and created_at>=now()-interval '30 days'),
    'last_activity',(select max(created_at) from public.employee_activity_logs where actor_user_id=p_user_id),
    'events',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc,e.id desc) from (
      select id,created_at,actor_user_id,actor_name,target_user_id,event_type,job_kind,job_id,
      case when public.apex_is_owner() then details else details-array['email','user_agent']::text[] end as details
      from public.employee_activity_logs where (actor_user_id=p_user_id or target_user_id=p_user_id)
      and (p_before is null or created_at<p_before or (created_at=p_before and p_before_id is not null and id<p_before_id)) order by created_at desc,id desc limit greatest(1,least(p_limit,100))
    ) e),'[]')
  ) into v_result;
  return v_result;
end;
$$;

-- Limit every new function's execution explicitly. Internal audit/sync helpers are never callable by clients.
revoke all on function public.apex_staff_audit(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.apex_sync_staff_permissions() from public,anon,authenticated;
revoke all on function public.apex_staff_preserve_permissions() from public,anon,authenticated;
revoke all on function public.apex_effective_permissions(uuid) from public,anon,authenticated;
revoke all on function public.apex_validate_permissions(jsonb) from public,anon,authenticated;
revoke all on function public.apex_permission_keys() from public,anon,authenticated;
revoke all on function public.apex_is_owner() from public,anon;
revoke all on function public.apex_staff_can(text) from public,anon;
revoke all on function public.apex_note_allowed(uuid,boolean) from public,anon;
revoke all on function public.apex_staff_context() from public,anon;
revoke all on function public.apex_staff_admin(text,jsonb) from public,anon;
revoke all on function public.apex_staff_schedule(timestamptz,timestamptz) from public,anon;
revoke all on function public.apex_staff_save_shift(jsonb,boolean) from public,anon;
revoke all on function public.apex_staff_get_notes(text,text) from public,anon;
revoke all on function public.apex_staff_save_note(jsonb,boolean) from public,anon;
revoke all on function public.apex_employee_report(uuid,timestamptz,integer,bigint) from public,anon;
grant execute on function public.apex_is_owner(),public.apex_staff_can(text),public.apex_note_allowed(uuid,boolean),
  public.apex_staff_context(),public.apex_staff_admin(text,jsonb),public.apex_staff_schedule(timestamptz,timestamptz),
  public.apex_staff_save_shift(jsonb,boolean),public.apex_staff_get_notes(text,text),public.apex_staff_save_note(jsonb,boolean),
  public.apex_employee_report(uuid,timestamptz,integer,bigint) to authenticated;

-- Advance legacy snapshots with the new default staff schedule access.
update public.employee_profiles set permissions=permissions||'{"view_schedule":true}' where not access_configured and not (permissions ? 'view_schedule');
notify pgrst,'reload schema';
commit;
