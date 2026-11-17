# PayPal refund tools

PR #137 is merged. This follow-up adds verified-owner refund tools to Order finances. No refunds were issued during implementation.

## Existing refunds

Enter a PayPal refund ID and the tax portion you actually refunded. The server fetches that refund using the merchant's PayPal credentials, verifies COMPLETED status, USD currency and its parent capture against the order's stored capture. Gross amount comes from PayPal; refunded tax remains owner-entered. Only then does the payment server record/verify the refund, with total/tax limits and duplicate protection. Existing manual records must match; conflicting data stops for review. The owner can repeat verification to check a pending refund later. No arbitrary URLs returned by a provider or supplied by a browser are fetched.

## Full refunds from Apex

Choose Issue full refund and type the exact order ID shown by the confirmation. This authorizes a real refund of the full captured order total, including its collected tax. The server verifies current owner MFA, rejects TEST/uncaptured orders and checks the canonical PayPal capture amount/currency/status before submitting. Orders with prior recorded refunds must be reconciled in PayPal; partial refunds are handled in PayPal and can then be verified here.

Each order has one durable refund attempt and provider idempotency key. A saved pending refund ID is queried on retry rather than creating another refund. If an ambiguous attempt lacks a saved provider ID, retries use the original request ID for at most one hour, and only while the capture remains COMPLETED. Older or changed captures require PayPal reconciliation. This intentionally stops instead of risking another refund. Failed database persistence after a provider success is reported explicitly for review. Completed references are unique and cannot be counted twice.

Tax in a full refund uses all tax recorded on the captured order. Existing-refund verification uses the owner's entered tax allocation; PayPal verification does not prove this allocation is correct. Retained processor fees and other actual costs still belong in the cost fields. Commission adjustments are a separate owner review; no employee payout is sent or clawed back. Customer tracking and email notifications do not yet publish refund status automatically.

## Deployment and limits

Apply the verified-refund migration and deploy `paypal-refunds` with JWT validation enabled. It uses the existing project-level PayPal credentials/environment. Merge the accompanying frontend/config/workflow files. The refund-attempt table is private and included in encrypted owner record exports. Tests use mocked PayPal responses and isolated PostgreSQL, covering permissions, provider matching, idempotency, retry limits and amount limits. A real financial acceptance test has not been performed.

This is owner-triggered provider reconciliation, not a background webhook subscription. Webhooks require registering and verifying the merchant's endpoint/webhook ID; no webhook configuration or secret was invented. Private backup activation and a full restore drill still require an owner-controlled encryption key, database credentials and private destination. See docs/order-finances.md and docs/private-backup-recovery.md. No paid plan was purchased, and no private data was exported.

## Background refund syncing

The signed paypal-webhook listener validates mandatory headers, a PayPal certificate host/path and the original event with PayPal's signature API. It independently fetches the canonical refund and matches its capture/currency/status/amount to a real Apex order. Replay-safe inbox entries cannot count a refund twice. Full-order refunds reconcile with the full recorded tax. Partial refunds wait for the owner's explicit tax allocation; contribution is suppressed while that order has an unresolved refund.

After merging, a verified owner must select **Enable / repair PayPal refund syncing** once. This registers or reuses the exact listener URL and stores its environment-specific webhook ID privately. No new credentials need pasting. A current owner MFA session was unavailable here, so subscription activation and real event delivery remain unverified. Existing subscriptions without the refund event stop for review. Failed processing returns a non-2xx status so PayPal can retry. Webhook config and inbox are included in encrypted owner exports; full event payloads/customer contact information are not retained.

The owner inbox shows up to 100 unresolved refund records. Each inbox entry includes a tax-allocation and verification form, including orders outside the latest-100 financial list. Broader order pagination remains a future usability improvement.

The cloud browser did not apply mobile-emulation shortcuts. Desktop inspection and automated responsive tests must not be represented as a real phone walkthrough. Private backup activation and full recovery remain blocked on an owner-controlled key, credentials, destination and isolated restore target; no paid plan or private export was created.
