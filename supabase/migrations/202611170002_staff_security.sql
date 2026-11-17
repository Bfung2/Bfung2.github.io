begin;
alter table public.employee_profiles add column if not exists credential_version integer not null default 0;
alter table public.employee_profiles add column if not exists credentials_changed_at timestamptz;
-- Owner identity is canonical; user-editable metadata never grants owner access.
create or replace function public.apex_owner_identity() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users u where u.id=auth.uid()
 and lower(u.email)='apexcomputers039@gmail.com' and u.email_confirmed_at is not null)
 and exists(select 1 from auth.sessions s where s.user_id=auth.uid() and s.id::text=auth.jwt()->>'session_id');
$$;
create or replace function public.apex_is_owner() returns boolean
language sql stable security definer set search_path='' as $$
 select public.apex_owner_identity() and coalesce(auth.jwt()->>'aal','')='aal2'
 and exists(select 1 from auth.mfa_factors where user_id=auth.uid() and status='verified');
$$;
create or replace function public.apex_employee_secure_session() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.employee_profiles ep join auth.sessions s on s.user_id=ep.user_id
 where ep.user_id=auth.uid() and ep.active and ep.credential_version>=1
 and s.id::text=auth.jwt()->>'session_id' and s.created_at>=ep.credentials_changed_at);
$$;
create or replace function public.apex_require_staff_security() returns void
language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(public.apex_is_owner() or public.apex_employee_secure_session(),false) then
 raise exception 'Verify owner authenticator or use an active employee account with a separate password' using errcode='42501'; end if;
end;
$$;
create or replace function public.apex_staff_security_status() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if public.apex_owner_identity() then return jsonb_build_object('owner',true,'verified',public.apex_is_owner(),'enrolled',exists(select 1 from auth.mfa_factors where user_id=auth.uid() and status='verified'));
 end if;
 return jsonb_build_object('owner',false,'verified',public.apex_employee_secure_session());
end;
$$;
-- Policies need canonical owner identity AND AAL2, including legacy admin policies.
do $migration$
declare p record; u text; c text;
begin
 for p in select * from pg_policies where schemaname='public' and (coalesce(qual,'')||coalesce(with_check,'')) ~ 'apexcomputers039|app_metadata' loop
  u:=case when p.qual is not null then ' using (public.apex_is_owner())' else '' end;
  c:=case when p.with_check is not null then ' with check (public.apex_is_owner())' else '' end;
  execute format('alter policy %I on %I.%I%s%s',p.policyname,p.schemaname,p.tablename,u,c);
 end loop;
end;
$migration$;
-- Apply one server guard to each existing authenticated staff entrypoint. Keep public
-- customer/token endpoints, payment-server helpers and internal triggers unchanged.
do $migration$
declare p record; definition text;
begin
 for p in select proc.oid,proc.proname from pg_proc proc join pg_namespace n on n.oid=proc.pronamespace
 where n.nspname='public' and proc.proname=any(array[
 'apex_manage_promos','apex_record_employee_login','apex_employee_update_job','apex_owner_employee_performance',
 'apex_employee_get_jobs','apex_staff_context','apex_staff_admin','apex_staff_schedule','apex_staff_save_shift',
 'apex_staff_get_notes','apex_employee_report','apex_staff_save_note','apex_credit_sale','apex_owner_test_code',
 'apex_owner_test_checkout','apex_my_customer_drafts','apex_prepare_customer_draft','apex_employee_contact',
 'apex_market_order_progress','apex_save_contribution_amount','apex_sync_product_notes','apex_pay_contribution',
 'apex_owner_dashboard','apex_sales_credits','apex_settle_sales_contribution','apex_update_order_tracking',
 'apex_staff_order_tracking','apex_update_order_delivery','apex_owner_policy','apex_claim_job','apex_owner_ops_health',
 'apex_private_order_note','apex_team_activity']) loop
 definition:=pg_get_functiondef(p.oid);
 if position('perform public.apex_require_staff_security();' in lower(definition))=0 then
 definition:=regexp_replace(definition,'\mbegin\M',E'begin\n perform public.apex_require_staff_security();','i');
 if p.proname='apex_owner_policy' then definition:=replace(definition,'perform public.apex_require_staff_security();',E'perform public.apex_require_staff_security();\n if not public.apex_is_owner() then raise exception ''Owner authenticator verification required'' using errcode=''42501''; end if;'); end if;
 execute definition;
 end if;
 end loop;
end;
$migration$;
create or replace function public.apex_staff_can(p_key text) returns boolean
language sql volatile security definer set search_path='' as $$
 select public.apex_is_owner() or (public.apex_employee_secure_session() and public.apex_effective_permissions(auth.uid())->p_key='true'::jsonb);
$$;
revoke all on function public.apex_owner_identity(),public.apex_employee_secure_session(),public.apex_require_staff_security() from public,anon,authenticated;
revoke all on function public.apex_staff_security_status(),public.apex_is_owner() from public,anon;
grant execute on function public.apex_staff_security_status(),public.apex_is_owner() to authenticated;
notify pgrst,'reload schema';
commit;
