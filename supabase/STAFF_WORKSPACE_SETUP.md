# Staff roles, schedule, reports, and internal notes

## Activate this update

The storefront remains on GitHub Pages. Private staff data is stored only in Supabase; it is never written to `data.json`, exports, or browser storage.

1. In the existing Apex Supabase project (`arvdrrrbobjpmmygojfm`), open **SQL Editor → New query**.
2. Run [the staff workspace migration](migrations/202611100001_staff_roles_schedule_notes.sql) in full. It runs as one transaction and preserves existing employees, orders, requests, and activity logs.
3. Merge this pull request to publish `index.html`, `staff-workspace.js`, and `staff-workspace.css` through the existing GitHub Pages workflow.
4. Sign in as the owner. Open **Staff workspace → Roles & permissions**, then **Employees → Roles / permissions**.

This update requires the existing employee schema plus the three `20261106` migrations (contact email, permissions/audit, and performance). Apply any missing prerequisites in that order before the new migration. Do not rerun `employee_setup.sql` after the migrations: the original bootstrap contains older job functions and read policies. No new secrets or Edge Function deployment are needed for this update; the existing `manage-employee` function continues to create/disable/delete accounts and reset sign-in codes.

If the new database functions are missing, the staff workspace shows a setup message instead of pretending to save. This PR does not itself apply SQL to the production Supabase project.

## Roles and individual permissions

- Starter roles: **Manager**, **Tech**, and **Market**. Edit, rename, add, or remove them. No employees are assigned a role automatically.
- A person can have several roles. Their allowed permissions combine across those roles.
- For each employee, **Inherit** uses roles, **Allow** grants an individual permission, and **Deny** blocks it even if a role grants it.
- Existing employees retain their existing job access until first configured. When editing them for the first time, their old permissions appear as explicit overrides. Use **Use role defaults for all** to move them fully to role-based access.
- Removing a role removes inherited access immediately in database checks. Individual Allow/Deny overrides remain. Removing the last role does not restore the employee's old access.
- Only the owner can manage employee access and role definitions. A Manager does not become an owner and cannot change anyone's roles.
- The owner retains access to every staff feature. Disabled employees cannot use any staff RPC, even with an existing session.

Available permissions: orders, service requests, customer contact details, claiming jobs, updating assigned job statuses, viewing schedules, editing shifts, viewing employee reports, viewing permitted notes, editing permitted notes, and managing permitted notes.

Schedule editing also needs schedule viewing. Note editing needs notes viewing. Note management needs notes viewing and editing, plus a role in the note's editing list. These dependencies let an explicit individual Deny remain authoritative.

## Schedule

**Staff workspace → Schedule** shows a weekly staff schedule, with an employee filter, previous/next week buttons, and a current-week shortcut. Existing employees can view it by default; starter roles also include schedule viewing. Customers cannot read schedule data or see staff navigation.

Only the owner or staff with viewing and editing permission can create, edit, reassign, or delete shifts. Choose an active employee, title, start/end, optional location, and staff details. Times are entered and displayed in the viewer's device timezone and stored as timezone-aware timestamps. Overnight shifts appear on every day they span. Overlapping shifts for the same person are rejected, including concurrent edits. A revision check prevents overwriting someone else's newer edit.

## Individual employee reports

Click an employee's name or **View report**. Delegated report viewers use **Reports** to select an active employee. The owner can also report on disabled employees.

Reports show currently assigned jobs, distinct jobs completed by that employee, recent activity count, last activity, and paginated activity history. **By employee** identifies the employee as actor; **About employee** identifies administrative changes someone else made. Completion totals require the employee to have recorded the status change, so owner-completed work is not credited as their action. Historical work before audit tracking cannot be reconstructed.

New role/access, schedule, and note actions are logged alongside existing login and job activity. Audit entries record IDs and action metadata, never note bodies. Staff cannot write, modify, or erase audit history through the API. Non-owner report viewers do not receive contact emails or login user agents in event metadata.

## Internal notes

Open **Internal notes**, the **Notes** button on an employee card, **Employee notes** on their report, or **Staff notes** in a product/part details dialog.

A note can reference a product/part, employee, general topic, or another reference. Its access settings are independent of the public product description:

- No audience selected: owner-only.
- **All staff**: readable by active staff who also have global notes-viewing permission.
- Viewing roles: readable by employees in those roles with notes-viewing permission.
- Editing roles: also readable, and editable when the employee has global notes-viewing and notes-editing permission.
- Content editors can edit the title/body only. They cannot change the audience or reference by crafting an API request.
- Note managers can create/delete and change access to notes they may edit. Non-owner managers must keep one of their own roles in the editing list; they cannot move a note outside their own access.
- The owner can always view, edit, or delete a note.

Role removal immediately removes corresponding note access. Notes store role IDs, so creating a new role with a previously used name does not grant access to old notes. Note and shift edits use revision checks to prevent lost updates.

## Validation

Run database integration tests against a disposable embedded PostgreSQL instance:

```sh
npm install --prefix /tmp/apex-staff-test --no-audit --no-fund @electric-sql/pglite@0.5.16
PGLITE_MODULE=/tmp/apex-staff-test/node_modules/@electric-sql/pglite/dist/index.js node tests/staff-permissions.mjs
node tests/staff-workspace-state.mjs
node --check staff-workspace.js
```

Tests run the existing schema, all prior employee migrations, and the new migration twice, then exercise customers, anonymous sessions, owner, tech, market, disabled staff, role changes, individual denies, job access, note audiences/content editors, conflicting schedules, stale writes, and employee reports. They never connect to production.

Browser checks use disposable sample staff and a mocked Supabase client for UI behavior. Production SQL activation and real-account end-to-end testing remain a separate deployment step.

## Sales contribution update

After the staff workspace migration, run `migrations/202611100002_sales_attribution.sql` in Supabase SQL Editor, then merge the sales attribution PR. No Edge Function deployment is needed.

In **Orders & requests**, the owner uses **Credit sale / lead** to select the employee who brought in that customer. This is independent of the employee assigned to perform the work. One primary contributor is recorded per order/request; only the owner can assign, change or remove that credit.

Employees, including Market staff, can open **Sales contributions** to see their own credited customer names and order/request references. Other customer contact information is not returned. They cannot claim credit or inspect another employee’s contributions. The owner sees all contributions and an employee’s credits in their individual report. Tech requests are labeled as leads, not paid sales; no commission or paid-revenue calculation is implied. Credits retain a snapshot after a job is removed with Done.

## Market customer handoff and employee contact details

Run `migrations/202611100003_market_customer_handoff.sql` after the sales attribution migration, then merge the Market handoff PR. No Edge Function redeployment is required.

Manager and Market starter roles receive **Prepare customer sales links**. The owner can grant or deny that permission through existing roles/individual overrides. Staff open **Prepare sale**, choose products/quantities or describe a tech service, and create a customer link. The owner can prepare a link credited to a selected employee. Drafts contain selections only: no customer identity or payment data. The link is a private bearer link; share it directly with the intended customer. It expires in seven days, can be submitted once, and stops working if the employee is disabled.

The customer reviews the selection and enters their own name, email (any valid provider), shipping/contact details and payment authorization in the existing checkout. Current catalog prices are used; the existing PayPal Edge Function revalidates prices server-side before taking payment. Staff do not take a card number or authorize payment through this tab. A service draft becomes a quote/service request and does not automatically charge the customer. Staff can track whether their links are waiting, submitted, or expired. A submitted but unpaid order remains subject to the existing PayPal checkout/retry behavior; creating a draft is never a paid sale.

Submitting a valid link atomically consumes it, labels the order/request **Employee-assisted**, and creates employee contribution credit. Direct submissions are labeled **Online / direct**. Customers can explicitly continue without credit. Source labels describe the submission route; manual attribution can still be corrected through existing owner controls.

**Employees → Contact details** lets only the owner view/edit employee name, email, phone and address. Private phone/address fields are in a separate restricted table, never the staff directory, public catalog or audit payload. Auth login codes are unchanged.

## Checkout promo codes

Activation order matters:

1. Run `migrations/202611100004_promo_codes.sql` in Supabase SQL Editor after the prior staff migrations.
2. Deploy the updated payment function with `supabase functions deploy paypal-checkout --project-ref arvdrrrbobjpmmygojfm`. Keep its current PayPal secrets, environment and existing JWT configuration. No secrets need to change.
3. Merge the promo-code PR. Test a low-value checkout before announcing a promotion. No live transaction was performed during development.

The owner opens **Staff workspace → Promo codes** to create/edit a code, disable it or delete it. Codes are case-insensitive and support percent or fixed dollar discounts, minimum subtotals and optional expiry. Only the owner has access initially. Grant **Create, edit and remove promo codes** through a role or an employee Allow override to delegate management; Deny takes precedence. Role names do not automatically grant promo control.

Checkout customers enter a code and press Apply. The preview is an estimate; the payment server re-prices the catalog items and validates the code before calculating a discounted subtotal, tax and total. Discounts exclude shipping, cannot exceed the subtotal and must leave a positive payable total. One code is supported per order. A verified order price is frozen for PayPal retries, so subsequent code edits, deletion or expiry do not change that order’s approved amount. No usage limits or commission rules are implied.

Codes and management actions stay in Supabase. Anonymous customers can validate a known code for a preview but cannot list/manage codes or write verified discounts. The payment pricing RPC is executable only by the service-role payment server. If the old payment function is still deployed, a checkout with a promo refuses to proceed rather than silently charging the undiscounted amount.

## Normal cart sales, builds, paid tracking and email notifications

Activate in this order:

1. Run `migrations/202611100005_cart_sales_notifications.sql` after the previous staff, attribution, handoff and promo migrations.
2. Confirm Gmail OAuth is configured in project Secrets: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN`. These are the same variables used by this repository's `send-gmail` function. If the live project currently uses a different SMTP implementation, these OAuth settings still need to be configured for this new sender. Never paste secrets into GitHub, the storefront or chat.
3. Deploy both functions, retaining the existing PayPal credentials and environment:

   ```sh
   supabase functions deploy paid-order-notify --project-ref arvdrrrbobjpmmygojfm
   supabase functions deploy paypal-checkout --project-ref arvdrrrbobjpmmygojfm
   ```

   The new notification function keeps JWT verification enabled as declared in `config.toml`. The payment function retains its current configuration. No PayPal merchant account or payment destination is changed.
4. Merge the cart-sales PR. Set each sales employee's real contact email through **Employees → Contact details**. Then verify the live customer/payment/email workflow before relying on notifications. No live payment or real email was sent during development.

### Staff workflow

**Prepare sale → Start / continue cart sale** opens the ordinary Products page. Staff use its existing search and filters, add products/parts normally, or add a custom PC from **Build a PC**. Open **Customer cart → Create customer checkout link** to send that exact selection to the customer. The quick product selector remains available and now also has a search field. Service descriptions continue to use the quote-request workflow; they are not automatically paid services unless represented as priced catalog products.

The customer sees a cart review with product names, quantities and a full build parts list, then enters their own name, email, phone, address and PayPal/card authorization in checkout. All product/build prices are resolved from the current catalog and revalidated by the existing payment server. Customer-link and checkout notices explain that paid order/contact/shipping details are shared with Apex and the preparing employee for fulfillment.

A separate random **APX sales reference code** is recorded with the employee's name on the order. This is never the employee's six-digit login code. The owner inbox shows the employee name/reference beside the order, customer details, items and payment status. Payment still goes through the existing Apex PayPal account.

### Tracking and notifications

Prepared sales distinguish **Waiting for customer**, **Customer submitted — awaiting payment**, **Service request submitted (not paid)** and **Paid / successful**. Tracking refreshes every 30 seconds while the Prepare sale page is visible; use Refresh for an immediate update. Only PayPal-verified paid orders expose paid order/contact details to the contributing employee. The owner sees all drafts; employees see their own. A separate **View own paid-sale customer details and receive receipts** permission is enabled for Market/Manager roles by default. Deny it for an employee or role to withhold customer contact/shipping details from their paid-sales page and stop further queued employee receipts. Custom sales roles need this permission for those details/receipts; it never grants access to another employee’s customers.

After the payment capture is verified, the payment function records its PayPal capture ID and marks the order paid. A database trigger snapshots the paid order and queues separate owner/employee emails. The notification worker sends to `apexcomputers039@gmail.com` and the employee contact email maintained by the owner. Browsers cannot supply recipients, subjects or bodies. Messages contain the customer name, email, phone, shipping address, order items, complete build parts/assembly information, totals/discount, PayPal capture reference, employee name and APX sales reference. No card information or employee login codes are included.

Notifications are asynchronous to the payment outcome in the sense that delivery failure never reverses or fails a captured payment. The current capture request waits for a bounded worker attempt, then returns payment success even if delivery needs retry. Queue state is visible in the staff tracking page. Missing employee email, Gmail authorization or delivery errors require correction and an owner retry via **Retry paid-order emails** in the inbox or paid sales tracking entry. Already sent notifications are not resent on ordinary retries. In-progress sends have a five-minute lease; an interrupted attempt becomes retryable after that lease. A crash after Gmail accepts a message but before the sent marker is saved can cause a duplicate on retry, so delivery is at-least-once, not exactly-once. No background scheduled retry service is installed by this update.

Paid snapshots and tracking survive removing the job with Done. The queue contains private customer information and is inaccessible directly to anonymous customers and employee browser sessions. Disabled/deleted employees are not sent further queued customer notifications. New automatic notifications apply to future paid updates after installation; old historical paid orders are not emailed in bulk.

### Additional tests

```sh
node tests/cart-sales.mjs
node tests/paid-notifications.mjs
```

These exercise cart/build reconstruction, stale/unavailable parts, paid-only tracking, build email formatting, login-code exclusion, mocked notification authorization, fixed server-selected recipients and failed-delivery handling. The database suite additionally checks paid queue creation, claim leases, recipient isolation, retries and preservation after job deletion. Browser visual QA, real Gmail delivery and live PayPal capture remain deployment checks.

## Owner-only test checkout code (with TEST emails)

1. Run `migrations/202611100006_owner_test_checkout.sql` after the previous migrations.
2. Deploy the updated `paid-order-notify` (including its `message.ts` helper) and `paypal-checkout` functions, retaining existing Gmail/PayPal secrets and configuration.
3. Merge the owner test checkout PR.
4. Sign in as owner, open **Staff workspace → Promo codes → Owner test checkout code**, and enable the code. The initial code is **APX-TEST** and it starts disabled. You can change the code or disable it at any time. It is separate from normal discounts; delegated promo managers cannot view, edit or use it.
5. While signed in as owner, open a Market employee's customer link, review the cart, enter the test code in the checkout promo field, and press Apply. Fill in name/email/address and other customer fields, then press **Complete owner test (no payment)**. No PayPal SDK, card details or payment authorization is required for this simulated submission.

The database validates the owner session and current enabled code again at submission. It requires an employee handoff link; it is not an anonymous free-order coupon. The code is reserved from ordinary discount-code management. Disabling it blocks future submissions, including a checkout where the code was applied earlier.

The order is recorded as `is_test=true`, `status=test_completed`, and `$0` charged, with a TEST reference and the original employee identity. It does not receive sales credit, cannot use real PayPal processing, and is excluded from the employee job/claim/status RPCs. The owner inbox labels it **TEST — NO PAYMENT TAKEN** and the Market tracking page shows **TEST SUCCESSFUL — NO PAYMENT TAKEN**, separately from paid sales.

Both owner and eligible employee notifications are queued and sent through the existing notification worker, using the same contact email, receipt permission, Gmail configuration and retry controls as ordinary notifications. Their subjects and bodies explicitly state **TEST — NO PAYMENT TAKEN**; no payment capture is claimed. Existing receipt-permission denies or missing employee email still prevent employee delivery. Enabling or disabling the code does not unsend already queued notifications from a completed test.

Test items retain their display prices/parts for email verification, but test order billing totals are zero and no payment is captured. These are simulated item snapshots, not server-verified commercial quotes. No live test emails or real transactions were sent during development.
