-- Phase 5 production security hardening
-- This change was already applied to the Supabase project as migration
-- phase5_revoke_anonymous_staff_owner_rpc_execution on 2026-11-11.
-- Stored here for review and reproducibility. All statements are idempotent.
-- These six RPCs require authenticated staff/owner logic or are trigger-only;
-- anonymous clients never need EXECUTE. Do not change public token-based RPCs.
BEGIN;

REVOKE EXECUTE ON FUNCTION public.apex_claim_job(text,text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apex_employee_get_jobs() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apex_employee_update_job(text,text,text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apex_log_job_activity() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apex_owner_policy(text,text,text,bigint) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apex_record_employee_login(text) FROM anon, PUBLIC;

-- Explicitly preserve existing signed-in staff/owner entrypoints.
GRANT EXECUTE ON FUNCTION public.apex_claim_job(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apex_employee_get_jobs() TO authenticated;
GRANT EXECUTE ON FUNCTION public.apex_employee_update_job(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apex_owner_policy(text,text,text,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apex_record_employee_login(text) TO authenticated;
-- The trigger-only apex_log_job_activity() does not require a client EXECUTE grant.
COMMIT;
