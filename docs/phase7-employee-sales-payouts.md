# Apex Computers: Phase 6 acceptance review and Phase 7 employee sales

## Phase 6, already merged (#111)

The customer address book, verified-account checkout autofill, private receipt-linking form, order filters, and tech-service autofill are on `main`.

- The `customer_saved_addresses` table uses RLS, denies direct API reads, and exposes an authenticated-only owner-scoped RPC.
- The two-confirmed-identity SQL test in Phase 6 passed: each account sees only its own addresses, and another account cannot remove those addresses. That test rolled back its temporary rows.
- GitHub Actions ran the Phase 6 customer experience regression successfully before merge.
- **Still required:** live UI testing of different saved addresses at checkout, manual checkout override, two customers with *actual* linked test orders, and login/logout across devices. No live payment should be made solely to run the test.

## Phase 7, employee sales and payout reconciliation

### Already working before this PR

- Owner can attribute real sales or customer leads to employees.
- Employee-prepared checkout links and owner-generated TEST checkouts work through existing backend flows.
- Owner can set an employee commission amount, record Paid after paying externally, or Void an outstanding contribution.
- Settled rows are preserved in the audit history. Paid does not transfer money. TEST payments are distinct from real revenue.
- Owner can manage employee roles and per-person permission overrides.

### Changes introduced

1. **Least-privilege employee sales results:** The existing scoped `apex_sales_credits` RPC now strips customer contact details and free-form commission notes unless the employee has `own_sales_receipts` permission. Owner result sets are unchanged. No stored sales, settlements, or employee permissions were changed.
2. **Better employee-card totals:** Paid real contributions, paid TEST contributions, voided records, outstanding amounts, and missing commission amounts are shown together. Existing settlements remain counted.
3. **Owner reconciliation export:** On the Sales contributions page, the owner can export the **currently filtered** rows to a UTF-8 CSV. It includes reference, employee, status, amount, TEST marker, and dates, but not customer contact fields. Strings that might be interpreted as spreadsheet formulas are escaped.
4. **Date range and usable search:** Filter contributions by credited date without losing keyboard focus on each search keystroke. Existing status, employee, and real/TEST filters remain available.
5. **Duplicate-settlement messaging:** If a paid/void action returns 'already processed' rather than creating a new entry, the UI avoids claiming it recorded another payment.
6. **Regression tests:** Node tests cover counts, date filters, CSV spreadsheet safety, owner-only export controls, runtime wiring, and privacy SQL. GitHub Actions invokes them.

### Live production backend review

- Migration `phase7_sales_receipt_privacy` was applied to the connected Supabase project. A source-controlled copy is in `supabase/migrations/20261112053000_phase7_sales_receipt_privacy.sql`.
- A transaction-scoped security test used an existing active employee with a temporary `own_sales_receipts=false` override and confirmed customer/commission details were hidden.
- The same test confirmed employee-only ledger scoping and denied employee attempts to settle contributions.
- **The test transaction was rolled back.** Existing employee settings and contribution records were not changed.
- No test checkout, commission payment, bank transfer, sale deletion, or paid notification was executed.

### After the PR is merged

1. Sign in as owner, open Employees, and verify the real paid, TEST paid, voided, and outstanding metrics against known records.
2. Open Sales contributions and filter by status, employee, type, and date. Export the displayed CSV, inspect that TEST rows are explicitly labeled, and confirm the report has no customer contact data.
3. Sign in as an employee lacking `own_sales_receipts` and confirm their own contribution history still loads but does not reveal customer names or notes. An employee with that permission can see appropriate own-sale receipt details.
4. Create one clearly marked no-payment owner test order from an employee link. Record its commission and mark it Paid or Void only as a simulation. Verify that lifetime counts and history remain accurate.
5. For a **real** paid order, record Paid only when the owner has actually sent the employee's money. The website does not execute transfers.
6. Verify GitHub Actions regression passes after merging. No browser access to the live UI was available from this chat, so the UI checks above remain human acceptance tests.

## Operational safeguards

- Never conflate a customer paying PayPal with the owner paying an employee.
- Never count TEST commission values toward real outstanding or paid balances.
- Do not delete historical settlement snapshots to simplify the dashboard.
- Keep real vs TEST, Paid vs Void, and employee attribution auditable.
- Do not store bearer tokens, payment credentials or customer billing records in GitHub.
