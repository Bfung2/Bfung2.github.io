-- Phase 11: private, read-only owner operations metrics.
-- No personal details, bearer tokens, receipts, emails, or customer order payloads are returned.
CREATE OR REPLACE FUNCTION public.apex_owner_ops_health()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
 v_pending integer := 0;
 v_orphan integer := 0;
 v_pending_matched integer := 0;
 v_pending_stale integer := 0;
 v_notification_failures integer := 0;
 v_expired_leases integer := 0;
 v_sent integer := 0;
 v_order_open integer := 0;
 v_order_unassigned integer := 0;
 v_order_stale integer := 0;
 v_order_tests integer := 0;
 v_request_open integer := 0;
 v_request_unassigned integer := 0;
 v_request_stale integer := 0;
 v_credits_unsettled integer := 0;
 v_settlements_paid integer := 0;
 v_settlements_void integer := 0;
BEGIN
 -- Validate a confirmed owner from the authoritative Auth user table.
 IF auth.uid() IS NULL OR NOT EXISTS (
   SELECT 1 FROM auth.users u WHERE u.id=auth.uid()
     AND lower(u.email)='apexcomputers039@gmail.com'
     AND u.email_confirmed_at IS NOT NULL
 ) THEN
   RAISE EXCEPTION 'Owner authentication required' USING errcode='42501';
 END IF;

 SELECT
  count(*) FILTER (WHERE n.state='pending'),
  count(*) FILTER (WHERE n.state='pending' AND o.id IS NULL),
  count(*) FILTER (WHERE n.state='pending' AND o.id IS NOT NULL),
  count(*) FILTER (WHERE n.state='pending' AND o.id IS NOT NULL AND o.created_at < now()-interval '30 minutes'),
  count(*) FILTER (WHERE n.error IS NOT NULL AND btrim(n.error)<>'' AND n.state<>'sent'),
  count(*) FILTER (WHERE n.lease_until IS NOT NULL AND n.lease_until < now() AND n.state<>'sent'),
  count(*) FILTER (WHERE n.state='sent')
 INTO v_pending,v_orphan,v_pending_matched,v_pending_stale,v_notification_failures,v_expired_leases,v_sent
 FROM public.apex_paid_notifications n
 LEFT JOIN public.apex_orders o ON o.id=n.order_id;

 SELECT
  count(*) FILTER (WHERE NOT coalesce(is_test,false)
    AND coalesce(status,'requested') NOT IN ('completed','delivered','cancelled','canceled','void','test_completed')),
  count(*) FILTER (WHERE NOT coalesce(is_test,false) AND assigned_to IS NULL
    AND coalesce(status,'requested') NOT IN ('completed','delivered','cancelled','canceled','void','test_completed')),
  count(*) FILTER (WHERE NOT coalesce(is_test,false) AND created_at < now()-interval '48 hours'
    AND coalesce(status,'requested') NOT IN ('completed','delivered','cancelled','canceled','void','test_completed')),
  count(*) FILTER (WHERE coalesce(is_test,false))
 INTO v_order_open,v_order_unassigned,v_order_stale,v_order_tests
 FROM public.apex_orders;

 SELECT
  count(*) FILTER (WHERE coalesce(status,'requested') NOT IN ('completed','delivered','cancelled','canceled','void')),
  count(*) FILTER (WHERE assigned_to IS NULL
    AND coalesce(status,'requested') NOT IN ('completed','delivered','cancelled','canceled','void')),
  count(*) FILTER (WHERE created_at < now()-interval '48 hours'
    AND coalesce(status,'requested') NOT IN ('completed','delivered','cancelled','canceled','void'))
 INTO v_request_open,v_request_unassigned,v_request_stale
 FROM public.apex_service_requests;

 SELECT count(*) INTO v_credits_unsettled
 FROM public.staff_sales_credits c
 WHERE NOT EXISTS (
   SELECT 1 FROM public.staff_sales_settlements s
   WHERE s.job_kind=c.job_kind AND s.job_id=c.job_id
 );
 SELECT
  count(*) FILTER (WHERE status='paid'),
  count(*) FILTER (WHERE status='void')
 INTO v_settlements_paid,v_settlements_void
 FROM public.staff_sales_settlements;

 RETURN jsonb_build_object(
  'generated_at',now(),
  'notifications',jsonb_build_object(
    'pending',v_pending,'orphaned',v_orphan,
    'pending_with_order',v_pending_matched,'pending_over_30m',v_pending_stale,
    'failed_or_retry',v_notification_failures,'expired_leases',v_expired_leases,
    'sent',v_sent),
  'orders',jsonb_build_object('open',v_order_open,'unassigned',v_order_unassigned,
    'older_than_48h',v_order_stale,'test',v_order_tests),
  'requests',jsonb_build_object('open',v_request_open,'unassigned',v_request_unassigned,
    'older_than_48h',v_request_stale),
  'sales',jsonb_build_object('unsettled',v_credits_unsettled,
    'paid_records',v_settlements_paid,'void_records',v_settlements_void)
 );
END;
$function$;

REVOKE ALL ON FUNCTION public.apex_owner_ops_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.apex_owner_ops_health() TO authenticated;
