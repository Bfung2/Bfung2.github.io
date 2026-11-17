# Apex follow-up: November 17, 2026

## Completed implementation and verification

- PR #136 is merged. Repaired obsolete tests that still allowed empty seller/stock evidence and updated notification mocks to enforce owner MFA and support current encoding.
- Ran all 36 JavaScript test files plus all three Python unit tests. Includes commission amount/settlement concurrency, real/TEST separation, role and product-note permissions, MFA/revoked sessions, customer tracking/delivery isolation, owner operations and encrypted-record backup integrity.
- Added tests for guest receipt authorization, provider order binding, verification before capture, recovery from ambiguous provider responses, duplicate/concurrent callbacks and preservation of shipped/delivered status.
- Added an immutable, unique `paypal_order_id` binding, controlled by the payment server and permitted only after pricing is locked. Database tests verify reruns, anonymous/customer denial and uniqueness.
- Checkout now requires the existing 256-bit receipt token for create/capture, verifies provider identity/currency/amount before money movement, reuses a completed capture during recovery and conditionally records payment once. It blocks new payments for cancelled/refunded orders and refuses captures whose provider status is refunded. This does not implement a refund service.
- Reconciled GitHub's checkout source with deployed v23's strict seller/stock checks while retaining the repository's cost-recovery guard and carrier-quote support. Fixed the discount cost-recovery calculation to subtract the locked promo discount and added a regression rejecting an under-cost promotion. The currently active shipping mode remains unchanged.
- Wired previously omitted suites into GitHub Actions and updated its Node version to 24 for built-in TypeScript stripping.
- Inspected the live desktop Home and Products pages. Products remains available with the intentionally empty catalog. Mobile interaction behavior and responsive CSS pass automated regressions; a real phone/viewport walkthrough is still pending.

## Rollout

1. **Done:** Applied `supabase/migrations/20261117200001_checkout_payment_binding.sql` and verified the column, unique index and guard in production.
2. **Done:** Deployed `paypal-checkout` version **25**, status **ACTIVE**, including its shared carrier module and discounted cost-recovery fix. Missing-token create/capture requests returned 403; unsupported actions returned 400. These read-only probes used a nonexistent order and caused no payment action.
3. **Pending:** Merge PR #137 so the storefront sends `checkoutToken`. The catalog is currently intentionally empty; before adding saleable products, merge and refresh cached tabs. The backend now requires the receipt token. Legacy unpaid checkouts without a stored provider binding must start a new checkout. A legacy payment that already captured needs PayPal reconciliation rather than an unverified automatic backfill.
4. When an eligible product exists, complete a controlled approval/capture and retry acceptance. Mock tests do not constitute a live financial transaction test.

## Remaining work and actual dependencies

| Area | Status / dependency |
| --- | --- |
| Refunds | Owner-only recording of completed external refunds is implemented with duplicate and amount/tax limits. No in-site refund initiation, provider webhook synchronization or refund-to-commission reconciliation implemented. New capture checks reject refunded provider captures. Reconcile existing payments in PayPal before any refund is performed. |
| Actual profit | Modeled cost recovery is implemented/tested. Owner-entered actual supplier/postage/processor/packing/commission/other costs and contribution after recorded refunds are now implemented, with incomplete-cost handling and private edit history. Automatic invoice/provider import is not implemented. Do not label modeled break-even as actual profit. |
| Commissions | Existing settlement, amount history, permissions and TEST separation pass database and UI regressions. Marking paid records an external transfer; it does not send money. Refund clawback is not implemented. |
| Notifications | Service/verified-owner authorization, configured recipients and success/failure handling pass mocks. No real emails sent during these checks; historical unmatched jobs remain untouched. |
| Security advisories | Public policy/promo/draft/tracking RPCs intentionally support guests. Staff RPCs must remain callable by authenticated users but enforce internal authorization. No blanket privilege revocation was applied. Leaked-password protection remains disabled and needs an eligible Supabase setting/plan. |
| Backup / recovery | Encrypted owner record download and verification are implemented/tested. A first owner-created private backup, activation of the provided private-backup schedule templates, credentials/key destination and a full isolated restore drill remain outstanding. |
| Live carrier shipping | Requires the merchant EasyPost key, private origin address, actual packed dimensions/weights and a real rate test before enabling carrier mode. |
| Mobile | Automated responsive/navigation regressions pass. No real mobile viewport walkthrough completed in this session. |
| Catalog | Intentionally zero products and parts following PR #130. Do not restore the old catalog or retired builder to satisfy historical audit queues. |
| Store policies / tax | Approved warranty/returns/cancellation wording and jurisdiction-correct tax configuration require business decisions/verification; existing values were not changed. |

No customer records, employee payouts, supplier orders, PayPal charges/refunds or email sends were created by verification.

Follow-up implementation: see docs/order-finances.md. New financial tables are included in owner encrypted exports. No actual costs or refunds were entered for production orders.
