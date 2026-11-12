# Apex Computers: Phase 5 security review
Review date: November 11, 2026 (Pacific). Project: Apex Computers production Supabase and GitHub Pages.

## Verified in production
- The 23 tables in the public database schema have RLS enabled.
- Customer profile, customer order links, tracking and tracking-event tables have no direct SELECT privileges for anonymous or ordinary authenticated API roles; customer access is mediated by scoped RPCs.
- Six privileged staff/owner or trigger-only RPCs no longer grant EXECUTE to the anonymous role. Authenticated employee/owner RPC access was preserved. This was applied in Supabase migration `phase5_revoke_anonymous_staff_owner_rpc_execution` and confirmed via `has_function_privilege` after deployment. The reference SQL is in `docs/sql/phase5_rpc_grants.sql`.
- The anonymous SECURITY DEFINER warning count fell from 10 to 4. The remaining functions are deliberately public-facing: private-token customer draft, 64-character secret-token order status, promo preview, and published policy retrieval. Review them if their access model changes.
- A controlled, non-destructive database test impersonated two existing confirmed user IDs using transaction-local JWT claims. Each customer-profile RPC returned the matching identity; each customer-orders RPC returned an array; invalid receipt linking was rejected. It changed no user, order or profile records.
- There were **zero linked customer-order records** at audit time. This test therefore did not establish isolation between two accounts with actual order history.
- The GitHub Actions storefront regression workflow completed successfully for the customer-account rollout PR, including static privacy and customer account tests.
- Edge Function `auth-email-hook` uses webhook signature verification with the gateway JWT check disabled; signup and recovery delivery were confirmed by live tests. Other actions (e.g. invite or email change) are not currently handled by this hook.

## Advisor triage
- 18 tables with RLS but no policies: intentional deny-by-default/private-table pattern for RPC-only access. Do not add broad policies solely to clear the advisory.
- 4 remaining anonymous SECURITY DEFINER functions: require periodic review of their token/capability constraints.
- Authenticated SECURITY DEFINER functions: review individual body authorization and ownership conditions before changing grants. Blanket revocation could break checkout, customer, staff and owner flows.
- Leaked-password protection is disabled; Supabase currently makes this feature available on Pro and above, while this project is on Free. Revisit this setting upon upgrading: https://supabase.com/docs/guides/auth/password-security

## Outstanding acceptance tests
1. Sign in as **two separate non-owner customers in separate browser sessions**, save a profile for each, and verify that neither profile nor address is visible from the other login.
2. Create an explicitly marked **test order** under customer A using the normal test checkout, link it using the private receipt, confirm it appears only in A's order history, and confirm customer B cannot claim it with the same receipt. Do not place a live paid order for this test.
3. Check employee and owner workflows after the permission tightening (claim jobs, update status, policy editing, login activity).
4. Inspect Auth rate limits and password policy settings before increasing traffic. Do not test by repeatedly submitting login attempts in production.
5. Review `paypal-checkout` and `create-service-request` for spam/abuse monitoring. Public checkout and guest request endpoints intentionally accept unauthenticated requests and need rate-limiting/operational monitoring.

## Tests and limitations
`node tests/phase5-security.mjs` is a **static source regression test**, not a replacement for authenticated live testing or Supabase database advisors. The live SQL audit is documented here separately. Avoid committing customer emails, credentials, bearer tokens, private order links, or raw production records to this repository.
