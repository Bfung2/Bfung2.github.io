# Phase 11: Apex operations and recovery runbook

Phase 11 covers the production static storefront, Supabase customer/order backend, and the existing Gmail paid-order notification sender. All automated checks are non-destructive.

## Installed capabilities

- **Owner operations center:** Sign in as the owner and open https://bfung2.github.io/#/operations. The top owner bar includes an alert count for open operational issues.
- **Aggregate metrics:** A scoped Supabase function returns notification counts, open orders, unassigned/stale service requests, and employee sales settlement counts. It returns no customer contact information.
- **Scheduled public monitor:** GitHub Actions runs the public storefront and critical asset checks twice per day, after relevant deployments, and on manual invocation. A failure opens or updates one GitHub issue; subsequent recovery closes it.
- **Public catalog recovery artifact:** Each monitor run stores a copy of public data.json, its SHA-256 digest, and commit reference for up to 30 days. Git history is also a versioned recovery source.
- **Existing audit remains separate:** Scheduled catalog integrity and live Newegg price audits are not replaced or duplicated by this availability monitor.

## The meaning of notification counts

A pending notification is queued, not proof that sending failed. A pending unmatched notification points to an order ID with no matching current Apex order. Do not automatically retry, relink, or delete these records without checking historical delivery evidence.

During implementation on November 11, 2026 (Pacific), the live database showed **20 pending unmatched notification records** with zero recorded retries/errors and **8 sent records**. We left these entries unchanged. They may be historical; their origin has not been established.

A failure or expired delivery lease requires the owner to inspect Supabase paid-order-notify Edge Function logs and Gmail sent mail before attempting an authorized retry. Paid employee sales entries record transfers already performed externally; the operations center does not send employee payments.

## Monitoring and alerts

1. In GitHub, open Actions > Apex public operations monitor, select a run, and inspect the status report and recovery artifacts.
2. When a public check fails, the workflow creates/reopens an issue titled **[Apex monitor] Public storefront health check failing**. Repeated failures update that issue instead of generating new ones.
3. To receive alerts away from GitHub, enable GitHub notifications for your repository or incident issue. The workflow itself does not send Gmail messages or reveal private credentials.
4. After correcting the deployment, run the monitor manually. A successful check closes the incident issue.
5. For catalog or fit discrepancies, use the existing Newegg audit workflow and issue #116. A successful public page-load check is not a price/stock/seller verification.

## Safe backups

**Public catalog:** Use data.json commit history or the SHA-256-checked GitHub Actions recovery artifact. Review the snapshot, validate its checksum and contents, then restore through a pull request rather than overwriting main without review.

**Private Supabase database:** The public catalog snapshot is **not** a backup of orders, customer accounts, employee commission data, notification history, or Supabase Auth. Check your Supabase project Database > Backups options, as managed backup availability depends on plan. If needed, establish a separate private encrypted database-export process with documented offsite retention and a tested isolated restore. Never upload a private export, service-role credential, OAuth refresh token or payment secret to GitHub.

Before a recovery, confirm which PostgreSQL schemas and authentication records are included, preserve Edge Function configuration securely, and test restoration only in a separate project. Reconcile PayPal captures and customer order links before bringing restored data online.

## Post-merge acceptance

- [ ] GitHub Actions Phase 11 regression passes alongside existing customer, sales, catalog and builder tests.
- [ ] Owner can load and refresh the Operations center. Employee and customer sessions cannot access its metrics.
- [ ] Owner sees notification pending/unmatched counts but no customer personal data in the dashboard.
- [ ] Run the public monitor manually after the PR is deployed, and inspect the downloadable report and catalog checksum.
- [ ] Verify the incident issue workflow and configure notifications. The automated test covers simulated failures without taking the actual store down.
- [ ] Choose and validate a **private database backup/restore** process. This is not done by the public workflow.

## Future operational improvements

An authenticated non-payment synthetic checkout, more detailed payment error reporting, automated *idempotent* notification retries, and privately encrypted offsite database backups are worthwhile follow-ups. None should be enabled without verifying the appropriate service credentials and failure behavior first.
