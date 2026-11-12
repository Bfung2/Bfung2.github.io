# Staff sales visibility (Phase 3)

Sales contributions now have filters for:
- Outstanding / Employee payment history / Voided.
- Real and test / Real only / Test only.
- Employee (owner only).
- Customer, order reference, job ID and employee-name search.

The owner sees a collapsible employee payout overview showing:
- Recorded outstanding real commission amounts.
- Number of outstanding real contributions with an unset amount.
- Recorded real employee payouts and their count.
- Voided real contributions.
- Test pending / test paid counts in a separate column.

**Important:** Clicking Paid employee records a transfer already completed, not a money transfer. Commission totals are from the returned sales-credit records and should not be treated as verified bank reconciliation. Test contributions never count toward real balances. Historical paid records without a stored amount may understate the paid total.

This PR makes **UI/reporting changes only**. It does not modify the SQL commissions, employee roles, payout RPCs, or actual orders.

Run `node tests/staff-sales-view.mjs`. Verify that an employee sees only the contributions returned by the existing server-side permissioned RPC and never sees owner employee filters. Test with owner data before wider rollout.
