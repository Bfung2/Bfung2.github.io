# Phase 6: Customer account experience

## Delivered

- **Saved shipping addresses:** A verified customer can create, edit, remove, and choose a default among up to five addresses. Address content is stored in a private Supabase table, not `data.json` or localStorage.
- **Checkout:** The default saved shipping address pre-fills the existing checkout fields. A dropdown lets the customer select another saved address or enter an address for this purchase only. The user can still edit the fields; existing price, promo, PayPal, and guest-checkout logic are untouched.
- **Tech requests:** Signed-in customers get their saved contact information and preferred address pre-filled, but can change all fields before submitting.
- **Account history:** Search by order reference or item name and filter linked orders (all, paid, awaiting payment, test, archived).
- **Cross-device receipts:** A signed-in customer can paste the private receipt link or token on the Account page to link it. The existing `apex_customer_link_order` server-side rule requires the receipt's checkout email to equal the customer's verified email. It does not accept arbitrary customer ID overrides.
- **Backward compatibility:** Existing single-profile addresses still work if the customer has not added an address-book entry. Guest checkout and private receipt-link tracking remain available.

## Production database changes

Migration `phase6_customer_saved_addresses_20261111` was applied to Supabase before this PR. The repository source is `supabase/migrations/20261112051000_phase6_customer_saved_addresses.sql`.

- New `customer_saved_addresses` table has RLS enabled and direct client access revoked.
- Only `authenticated` may call `apex_customer_addresses`. Every call validates a confirmed customer identity via `apex_customer_identity()`.
- Each operation uses `auth.uid()` for row scoping. Up to five addresses per verified user are allowed.
- A single default is enforced with a partial unique index.
- Verified in a transaction with two distinct confirmed accounts: each saw its own address; one could not delete the other's. **All test writes were rolled back.** No orders or payment records were changed.

## Review and acceptance tests after deployment

1. Sign into customer A and save two addresses, edit the second, make it default, verify the first is unchanged and appears on another device.
2. Open Checkout with a cart, confirm the default address is prefilled, switch addresses, then choose manual and enter a different address. Do not make a live purchase solely for testing.
3. Verify a guest sees ordinary blank Checkout without the private address selector.
4. Verify the tech-request form pre-fills only for signed-in customers and still allows edits.
5. Search and filter customer order history, including test orders. Test the manual receipt-link form with an owner-controlled test order, and verify a different customer cannot link that receipt.
6. Confirm account sign-out hides addresses and returning to the same browser under another customer does not display the previous account's data.
7. Review GitHub Actions Phase 6 regression, `node tests/phase6-customer.mjs`, and existing customer/storefront regressions.

## Security notes

- Do not save tracking tokens or passwords in this repository.
- Private receipt links are bearer secrets. The account editor validates their basic shape and origin, while the actual link decision is made by the scoped Supabase RPC.
- Database SQL-level identity simulation is useful verification but **does not replace** a two-browser, two-customer acceptance test against the live UI.
- No live paid transaction or customer email change was performed by this phase.
