# Owner and employee management update

This update extends the existing roles, commissions, reports, account disabling, and customer tracking tools. It does not replace or reset employee access, products, orders, or payouts.

## Included

- Overview for employees with assigned active work, real sale count, commission balances, permitted actions, and links to customer sales progress.
- Owner overview links directly to operations alerts and unassigned work, alongside existing commission totals and employee reconciliation.
- Roles and individual Allow/Deny permissions remain enforced through the existing permission-aware database functions. Employees see their current enabled permissions in Overview. Product publishing remains owner-only.
- Sales contributions retain pending, paid, and voided history, payment timestamps, owner-set amounts, CSV exports and separate TEST records. Paid records an external payment; it does not transfer funds. Pending contributions are already credited sales awaiting owner settlement, not speculative revenue.
- Team activity page with 50-event pagination, search across loaded events, event details, and owner-only database access. Existing permission, order, product-note and commission actions feed the existing audit log.
- Order workflow grouped by existing fulfillment stages: received, sourcing, building, testing, ready, shipped, delivered, on hold, cancelled. Existing payment and fulfillment states remain separate.
- Private order notes with separate view/edit permissions, assigned-order scoping, immediate inactive-profile denial, optimistic revision checks, and audit events. The notes are never included in public tracking snapshots.
- Owner authenticator enrollment and challenge/verification using Supabase MFA. No secrets are saved to the catalog or localStorage. Existing six-digit employee login remains compatible.

## Deployment

The additive migration `202611170001_team_management.sql` was applied to the connected Apex project during implementation. Merge the frontend PR to publish the navigation and tools.

## Validation and limitations

- Isolated PostgreSQL tests cover migration reruns, owner/employee/customer/anonymous access, assignment isolation, editing permissions, disabled employees, concurrent note edits, direct-table denial and activity access.
- JavaScript tests cover employee overview scoping and activity filtering. Existing commission, tracking, storefront syntax and operations regressions pass.
- MFA enrollment must be completed by the owner with their own authenticator after merge. It is optional setup/session verification; existing database policies and Edge Functions do not universally require AAL2. Do not describe this as mandatory MFA enforcement.
- Employee code-only authentication still has the original six-digit credential strength. This update does not silently change existing employee credentials.
- The legacy staff-permissions suite currently fails against the intentionally empty catalog because its seeded-product-note fixture is undefined. The legacy staff-workspace-state suite is missing a staff-sales-ledger fixture dependency. Both failures reproduce before this change; new isolated team permission tests pass.
- No signed-in browser acceptance test or real authenticator enrollment was performed. No real payment, settlement, sale attribution, employee setting change or notification was made for verification.

After merge, check Overview, Order workflow, Team activity and Security as owner. Check Overview and assigned workflow as an employee. Confirm an unassigned or disabled employee cannot open a private order note. For authenticator setup, scan the QR code, verify a code, and retain access to your authenticator and Supabase recovery account.
