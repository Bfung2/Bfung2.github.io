# Apex Computers proposed checkout and catalog repricing

**Status: DRAFT / NOT LIVE. Requires tax-rate and shipping-tax compliance review before merge.**
Prepared November 12, 2026 (US Pacific); repo `Bfung2/Bfung2.github.io`.

## Requested adjustments

- **Shipping:** replace fixed $7/order with **18% of the pre-tax merchandise subtotal**, calculated consistently in customer cart and Supabase PayPal checkout. Owner site settings label changes to a percentage. Existing `shippingFee` is deprecated and set to 0; `shippingRatePercent=18` is authoritative.
- **Sales-tax rate requested:** `taxRate=14.5` in the proposed branch, calculated on discounted merchandise subtotal, excluding shipping. **This is not verified to be a lawful rate for individual buyer destinations. DO NOT MERGE/DEPLOY 14.5% as a universal sales tax until confirmed by qualified tax guidance or a jurisdiction-specific tax service.** The old site uses a single blanket rate (10%) rather than buyer-address tax determination.
- **Item prices:** 704 of 721 unique catalog IDs have numeric stored Newegg cost baselines; all 704 are repriced, covering 716 records across 212 storefront products and 522 PC-builder parts. Includes 30 inactive items with baselines; all 17 unique products without cost baselines remain **inactive and unchanged**.
- Updated outdated product descriptions which claimed an exact $15 markup, without changing brand, SKU, Newegg source URL, seller, stock, images, compatibility fields, or verification dates.
- **Revenue target:** 20% **modeled net contribution margin as a percentage of pre-tax product sale price** under a *single-item-per-order* scenario, **not** 20% markup over supplier cost and not proven accounting net profit.
- Target payment method is the highest published regular domestic PayPal Checkout cost: **Pay Later 4.99% + $0.49 per transaction**. Standard PayPal 3.49% and cards 2.99% normally produce higher contribution. Source: https://www.paypal.com/us/business/fees

## Target-price formula

Let `C` be the stored Newegg product price, `P` Apex item price, `S=round(P*0.18, 2)` proposed shipping charge, `T=round(P*0.145, 2)` proposed tax charge, and `F=round(0.0499*(P+S+T)+0.49,2)` the Pay Later processing fee.

Assume **all customer sales tax is remitted** and the 18% shipping collected is **completely offset by actual fulfillment shipping expense**. A 20% contribution target requires:

`P - C - F >= P*0.20`

`P ~= (C + 0.49) / (1 - 0.20 - 0.0499*(1 + 0.18 + 0.145))`

Each price is rounded *up* to cents, and increased by $0.01 when necessary to pass the actual rounded checkout fee simulation. This target is conservative relative to normal card and PayPal Checkout domestic fees, but **does not guarantee true 20% profit** once seller shipping, supplier sales/use tax, discounts/promotions, employee commissions, returns, chargebacks, packaging, shipping insurance, labor or additional taxes are included.

Price examples under proposed settings:

| Product | Stored Newegg baseline | Old Apex sale | Proposed Apex sale | Estimated one-item Pay Later contribution |
|---|---:|---:|---:|---:|
| AMD Ryzen 5 5500 | $99.00 | $114.00 | $135.57 | $27.12 |
| RTX 3060 MSI Ventus 12GB | $463.99 | $478.99 | $632.92 | $126.59 |
| GIGABYTE AORUS RTX 5090 | $7,189.99 | $7,204.99 | $9,797.87 | $1,959.58 |

These figures are based on historic stored cost baselines. **Current Newegg listing prices, third-party seller status and availability have not been freshly rechecked for all 721 SKUs.**

Review the full list in `proposed-20pct-profit-prices.csv`.

## Sales-tax and shipping warning

According to the California Department of Tax and Fee Administration, sales-tax rates vary with district and transaction; a ZIP code alone is not always sufficient for the correct rate. A 14.5% blanket rate is not a substitute for determining applicable tax. For separately stated delivery, nontaxable treatment can depend on actual third-party shipping cost. A percentage shipping charge above actual delivery cost can be taxable in part. Sources:
- https://cdtfa.ca.gov/taxes-and-fees/sales-use-tax-rates.htm
- https://cdtfa.ca.gov/taxes-and-fees/tax-rate-faq.htm
- https://cdtfa.ca.gov/formspubs/pub100/applying-sales-tax.htm

Before activating checkout, configure a proper rate determination by destination and treatment of shipping. If 14.5% was meant to be a **handling/service fee**, do not mislabel it as tax. If collecting other taxes, confirm the legal basis first.

## Implementation / rollout notes

1. Merge only after reviewing **all proposed prices** and verifying the tax settings and source cost accuracy. This PR is intentionally draft.
2. New customer cart and UI source is in `index.html`; the PayPal *server-side* recalculation is in `supabase/functions/paypal-checkout/index.ts`. **GitHub Pages will not automatically deploy the Supabase Edge Function.** Deploy the matching reviewed Edge Function as part of rollout before accepting real payment under the new shipping model.
3. The existing `apex_lock_checkout_price` database RPC accepts a verified `p_shipping` and `p_tax_rate` and locks taxes after discounts, so promo codes or older locked orders have their own margin effects. No database migration or notes data changes are included.
4. The owner dashboard and daily catalog audits now check the margin policy, rather than wrongly flagging every new product as breaking the old $15 markup.
5. Refunds, old open/unlocked orders, discounts, multiple-item carts and state-specific taxes need operational review before activation.

**Files modified:** `data.json`, `index.html`, `supabase/functions/paypal-checkout/index.ts`, `catalog-health.js`, `scripts/audit_catalog.py` and relevant tests. **No production Supabase data updated.**
