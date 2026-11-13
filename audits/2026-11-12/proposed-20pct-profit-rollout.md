# Apex Computers: proposed 11.5% checkout tax and profit-based product rules

**Status: PR REVIEW / NOT LIVE. The requested 11.5% uniform sales tax requires legal destination and shipping-taxability verification before merging or accepting live orders.** Prepared November 12, 2026 Pacific (revised after the 14.5% proposal).

## Requested settings

| Setting | Proposed behavior |
| --- | --- |
| Customer shipping | 18% of pre-tax item subtotal |
| Customer sales tax | 11.5% of discounted item subtotal in this draft; not yet proven appropriate for every destination |
| Supplier eligibility | Direct Newegg seller only; exact item link; in stock; verified date within seven days for new owner edits |
| Target catalog contribution | At least 20% of item selling price after modeled PayPal Pay Later processing, assuming collected shipping entirely pays for shipping |
| Card/PayPal modeling | Pay Later 4.99% + $0.49 estimated processing fee on product + shipping + tax |

**This is a contribution estimate, not guaranteed net profit.** Newegg costs, inventory, seller claims and source links are stored historical data; most are not newly rechecked against live Newegg pages.

## Updated catalog

- **704 distinct SKUs** with stored Newegg cost baselines were repriced. These span **716 records** across Products and Build a PC. Both copies of a shared SKU use the identical price.
- All **17 distinct SKUs without stored supplier cost baselines** (18 records) remain inactive and unchanged. Do not assume they are eligible or price them from guesses.
- Existing images, IDs, source links, compatibility information and verification dates are preserved.
- Itemized estimates and previous prices are in `proposed-20pct-profit-prices.csv` (721 distinct SKU rows; `proposed_tax_11_5pct_usd` column).
- Example: a stored Newegg cost of **$99.00** becomes a modeled minimum selling price of **$135.29** under 11.5% tax.

## Price calculation

For an item purchased at `C` and listed at `P`:

- Customer shipping `S = round(P × 18%, $0.01)`.
- Modeled tax `T = round(P × 11.5%, $0.01)` (actual lawful buyer tax may differ).
- Estimated Pay Later fee `F = round((P + S + T) × 4.99% + $0.49, $0.01)`.
- Shipping expense assumed equal to `S`. Sales tax is assumed fully remitted.
- Under those assumptions, modeled item contribution is `P - C - F`; the minimum price passes `P - C - F ≥ P × 20%`.
- The pricing engine rounds the needed selling price **up to cents** and simulates each cent until the target passes. It never rounds downward below the target.

A lower tax estimate makes processing fees slightly smaller, so the minimum price may decrease. An address-specific lawful tax or a different payment/fulfillment cost changes the real outcome.

## Future new catalog items

The owner **Add product** and **Add part** dialogs now include Newegg cost, exact item URL, seller, stock, verification date, live minimum price preview, and an enabled-for-sale checkbox. A cost baseline triggers `catalog-pricing.js` to enforce the minimum price. Price edits below the minimum are raised before saving. Direct Newegg seller, in-stock status, valid direct item link and a recent (less than seven days old) date are all required for a *newly edited* supplied item to stay active; unverifiable and missing-cost physical merchandise is saved inactive. The site does not independently check those entered claims in real time.

Changing shipping or tax in Site settings also updates the pricing assumptions and raises any stored product or part prices that fall under the current target, with rollback on a failed GitHub write. Profit model tests and catalog-wide checks run in GitHub Actions.

## Tax and shipping compliance warning

11.5% is the **requested proposed number, not a verified tax rate for all customers**. California's current CDTFA guidance requires looking up applicable district tax by address. Some separately stated delivery charges can be partially taxable depending on the circumstances. A flat 11.5% rate across buyers and excluding all shipping from the taxable base may be incorrect. See:

- https://cdtfa.ca.gov/taxes-and-fees/sales-use-tax-rates.htm
- https://cdtfa.ca.gov/taxes-and-fees/tax-rate-faq.htm
- https://cdtfa.ca.gov/formspubs/pub100/applying-sales-tax.htm

**Do not make this PR ready for live checkout until destination-specific lawful sales tax (and taxability of shipping/handling) has been verified or implemented.** If a fixed 11.5% amount is intended as a business surcharge, do not present it as a government tax.

## Deployment and other risks

- Changes to the GitHub Pages storefront alone do not update the existing PayPal checkout Supabase Edge Function. After validating tax treatment, deploy the branch's `supabase/functions/paypal-checkout/index.ts` along with the frontend so the server and browser use the same shipping/tax formula.
- Unmodeled costs include Newegg checkout sales/use tax, supplier shipping, packaging, loss, labor, employee commissions, promos, refunds, PayPal international surcharges and variable payment rates. Multiple-product orders share fixed fees; discounts can reduce margins.
- Customers with already-created or locked orders may still be governed by previous figures. Validate old pending and discounted orders before accepting payment.

**No live Supabase function, tax engine, payment credentials, or existing order was modified by this proposal.**
