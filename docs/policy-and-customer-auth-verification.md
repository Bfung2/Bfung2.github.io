# Apex policy deployment and customer authentication acceptance checklist

## Policy editor: existing database
PR #103's SQL migration may already have succeeded. If the live policy editor shows "Owner access required", run **only** `sql/apex-shop-policies-owner-fix.sql` in Supabase SQL Editor once this PR is merged. This replaces the existing security-definer policy function without deleting policy data.

Owner access is granted only to an authenticated user with a trusted admin app-metadata role OR the specifically confirmed owner email stored in `auth.users`. User-editable metadata and the frontend's `isOwner` flag do not grant backend access. If the owner email is unconfirmed, complete confirmation before retrying. Existing private drafts remain private.

### Verify
1. Log out and log back into staff owner mode. Open Site settings > Warranty / Returns editor.
2. Save a short **draft** and check the public Warranty page does not show it.
3. Publish only after reviewing real business policies and confirm the public page shows the saved published version.
4. Make a new private draft and confirm the public policy still shows the previous version.
5. Switch to Returns and repeat. Check the version increments with each publication.
6. Sign out and confirm the private editor cannot be opened. Confirm employee and customer sessions cannot access the `apex_owner_policy` RPC.
7. Confirm public anonymous access through `apex_public_policy` works and direct table reads are denied by RLS/grants.

Do not publish sample legal language. Have the store's warranty, refunds, return shipping, exclusions, and applicable consumer rights reviewed before publication.

## Customer account verification
`CUSTOMER_EMAIL_READY` remains **false** in `customer-accounts.js` until email flows are demonstrated end-to-end. This is intentional; do not claim registration is live.

### Supabase dashboard checks
- Authentication > Providers > Email: enable the Email provider and require confirmation for new accounts.
- Authentication > URL Configuration: set Site URL to `https://bfung2.github.io/` and allow both:
  - `https://bfung2.github.io/?customer_auth=confirm`
  - `https://bfung2.github.io/?customer_auth=recovery`
- Authentication email delivery: set up approved SMTP delivery and verify sender address, templates, rate limits, SPF/DKIM where applicable. Check spam and real inbox delivery.
- Ensure the customer profile/order SQL from PR #102 is applied and access is restricted to authenticated, confirmed users.

### Tests with non-production customer identities
1. Try signup when the gate is **off**. It must be blocked with an honest message.
2. After SMTP is configured, temporarily enable the gate on a testing branch and register a new customer email.
3. Verify a confirmation email arrives, and an unconfirmed account cannot access its profile/order history.
4. Follow the confirmation link **in the same browser** used for signup (PKCE flow), sign in, and confirm profile updates persist across devices.
5. Request a password reset, open the reset link in the same browser, set a new password of at least 12 characters, and confirm the old password no longer works.
6. Test expired/used links and recovery opened in a different browser. Both should fail safely with clear instructions.
7. Sign out and confirm private profile/order history is hidden. Try an employee login and verify no customer account data leaks.
8. Verify cross-account isolation using two separate test identities. Customer B must never see customer A's orders.
9. Only after all checks pass: change `CUSTOMER_EMAIL_READY` to `true` in a separately reviewed PR and deploy.

No password, OTP, JWT, session token, or payment data should be posted in GitHub issues or chat.
