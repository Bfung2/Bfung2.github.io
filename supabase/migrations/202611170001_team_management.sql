begin;
-- Private fulfillment notes are separate from customer-visible tracking messages.
create table if not exists public.staff_order_notes (
 order_id text primary key references public.apex_orders(id) on delete cascade,
 body text not null default '' check(length(body)<=5000),
 revision integer not null default 1,
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id) on delete set null
);
alter table public.staff_order_notes enable row level security;
revoke all on public.staff_order_notes from public,anon,authenticated;
grant all on public.staff_order_notes to service_role;
create or replace function public.apex_private_order_note(p_order text,p_body text default null,p_revision integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.apex_orders; n public.staff_order_notes;
begin
 select * into o from public.apex_orders where id=p_order for update;
 if not found or not coalesce(public.apex_is_owner() or (public.apex_staff_can('orders') and public.apex_staff_can('view_notes') and o.assigned_to=auth.uid()),false) then
 raise exception 'Private order note access required' using errcode='42501'; end if;
 select * into n from public.staff_order_notes where order_id=p_order;
 if p_body is not null then
  if not coalesce(public.apex_is_owner() or public.apex_staff_can('edit_notes'),false) then raise exception 'Note editing permission required' using errcode='42501'; end if;
  if length(p_body)>5000 then raise exception 'Note must be 5000 characters or fewer'; end if;
  if p_revision is distinct from coalesce(n.revision,0) then raise exception 'Note changed. Reopen it before saving'; end if;
  insert into public.staff_order_notes(order_id,body,updated_by) values(p_order,p_body,auth.uid())
  on conflict(order_id) do update set body=excluded.body,revision=staff_order_notes.revision+1,updated_at=now(),updated_by=auth.uid() returning * into n;
  perform public.apex_staff_audit('private_order_note_saved',o.assigned_to,jsonb_build_object('order_id',p_order,'revision',n.revision));
 end if;
 return jsonb_build_object('body',coalesce(n.body,''),'revision',coalesce(n.revision,0),'updated_at',n.updated_at);
end;
$$;
create or replace function public.apex_team_activity(p_before bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from
 (select id,created_at,actor_name,event_type,job_kind,job_id,details from public.employee_activity_logs
 where p_before is null or id<p_before order by id desc limit 50) x),'[]'::jsonb);
end;
$$;
revoke all on function public.apex_private_order_note(text,text,integer),public.apex_team_activity(bigint) from public,anon;
grant execute on function public.apex_private_order_note(text,text,integer),public.apex_team_activity(bigint) to authenticated;
notify pgrst,'reload schema';
commit;
