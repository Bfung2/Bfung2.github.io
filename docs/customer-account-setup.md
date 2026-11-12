# Customer account rollout

Implemented in `customer-accounts.js` and migration `202611120001_customer_accounts.sql`.

## Current state

Customer signup and password-reset sending remain disabled on main until the activation pull request is merged. The activation branch changes `CUSTOMER_EMAIL_READY` to `true`; do not merge until live email delivery and recovery are verified. The existing browser-only contact profile has been replaced with a real password sign-in form; it no longer pretends that entering an email creates an authenticated account. Guest checkout and private tracking links remain available.

Observed on November 11, 2026: Supabase custom SMTP is disabled; Site URL is `http://localhost:3000`; no redirect URLs are configured. No signup or reset emails were sent during implementation. No email-provider credentials are stored in this repository.

## Activation checklist

1. The migration `supabase/migrations/202611120001_customer_accounts.sql` was applied successfully to production on November 12, 2026 UTC. It is additive and rerunnable. No existing orders or staff permissions were changed.
2. Configure a business-controlled SMTP sender in Supabase Authentication → Emails → SMTP Settings. Verify the sender/domain through that provider. Keep its password in Supabase settings only.
3. Keep email confirmations enabled in Authentication → Sign In / Providers → Email. Do not disable confirmation to get around email delivery failures.
4. Set Site URL to `https://bfung2.github.io/` and allow these exact redirect URLs:
   - `https://bfung2.github.io/?customer_auth=confirm`
   - `https://bfung2.github.io/?customer_auth=recovery`
5. Test signup, confirmation, sign-in, password reset and sign-out with an owner-controlled email address. PKCE confirmation/recovery links must be opened in the same browser where the request began.
6. Verify a test order links to its matching verified account, a second account cannot claim it, and linked history loads on another device. Confirm owner/employee sessions stay signed in when the customer signs out.
7. After delivery and recovery pass, mark the customer-auth activation pull request ready and merge/deploy it. Its `CUSTOMER_EMAIL_READY=true` code makes signup and password recovery available.

Existing anonymous receipts link on sign-in or “Refresh / link saved receipts” only when their checkout email matches the account's verified email. A deleted operational order retains account history if linked before deletion. Unlinked archived orders cannot be claimed automatically because tracking snapshots intentionally contain no customer email. Keep the original private receipt link or contact Apex.

The account page shows the latest 100 linked orders. Order progress remains token-based and read-only. Account contact edits do not alter old orders. Account email changes and self-service account deletion are not part of this release.

## Verification

- `node tests/customer-accounts.mjs`: separate storage, callback isolation, rollout gates, recovery state, escaped history and stale sign-out responses.
- `PGLITE_MODULE=/tmp/apex-test/node_modules/@electric-sql/pglite/dist/index.js node tests/staff-permissions.mjs`: migration rerun, canonical confirmed identity, forged identity rejection, private profile validation, receipt claims, cross-account denial, archived history and existing staff/tracking regressions.
- Production email delivery is not verified; account signup is not yet enabled.

## Activation PR caution

This branch intentionally enables signup and password recovery in code. Keep its pull request **draft and unmerged** until production custom SMTP is configured, the live Site URL and redirect allowlist are correct, and successful end-to-end confirmation and reset emails are observed. The website's existing customer sign-in works only for accounts already created and verified; neither a code change nor a successful test-order notification proves authentication email delivery.
