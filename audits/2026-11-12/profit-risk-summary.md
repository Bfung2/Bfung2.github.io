# Apex Computers: checkout margin risk audit

**Run date:** 2026-11-12 (America/Los_Angeles). **Source:** `data.json` on `main` at blob `ef5ce15dfdced609c2eb23f1963b65a380497b26`, original 212 storefront products + 522 builder parts, deduplicated by shared `id` to **721 unique catalog listings**.

**Critical finding:** The $15 Newegg baseline markup is **not** $15 after payment fees. Under the scenario below, **130 currently eligible catalog listings produce negative estimated single-product PayPal contribution**. **110** are negative through card checkout and **203** are negative through Pay Later. These sets overlap, and 17 disabled items have no verified Newegg cost baseline.

## Standardized scenario, not proven actual net profit

- Apex sale price and Newegg **stored** baseline are from `data.json`. These are **NOT 721 fresh live Newegg price checks**, and no new actual seller/stock proof is claimed.
- Assume an order contains exactly **one product, quantity 1**. Each catalog item's Newegg source points to its product listing ID. Private product notes were confirmed in Supabase in the preceding note-link audit, but this analysis does not expose note text.
- Shop checkout from current `data.json` charges **10% sales tax** and **$7 shipping per order**, so payment processor fees use `(Apex price + 10% tax + $7)`.
- Assume charged sales tax is fully remitted, supplier purchase tax is either recoverable/exempt or excluded, and **$7 collected shipping equals exactly $7 actual delivery cost**. Thus shipping and sales tax yield no income in the model, but processing fees apply to them.
- Standard domestic fees from [PayPal's current US pricing page](https://www.paypal.com/us/business/fees): PayPal **3.49% + $0.49**, credit/debit cards through PayPal Checkout **2.99% + $0.49**, Pay Later **4.99% + $0.49**. Actual merchant agreement or payment method may vary.
- Net contribution = `Apex item price - stored Newegg cost - payment processing fee on checkout total`. Rounded to cents on each transaction. Discounts, employee commissions, returns, Newegg cart taxes/shipping, assembly labor, chargebacks, insurance, etc. are **excluded**, so actual results may be worse.
- Multi-item cart margins differ: the fixed fee is charged once per transaction, shipping once, and total tax/percentage fees apply across the cart. PC builder assembly fees of $250 can offset part losses where actually charged.

## Results

| Metric | Count |
|---|---:|
| Unique catalog items | 721 |
| Eligible, Newegg-direct, recorded in-stock items | 674 |
| Ineligible/disabled catalog items | 47 |
| Unique items with stored Newegg baseline | 704 |
| Eligible items with the exact stored $15 markup | 674 |
| Eligible PayPal negative contribution | **130** |
| Eligible card negative contribution | **110** |
| Eligible Pay Later negative contribution | **203** |
| Missing supplier cost baseline (all disabled) | 17 |

At the present checkout tax/shipping settings, break-even on a single item with $15 gross markup is approximately an **Apex sale price of $371.60** for PayPal and **$434.80** for card. This is *not* a recommended universal price cap, because source cost and per-transaction expenses vary.

## Loss risk by catalog category

| Category | Eligible | PayPal loss risk | Card loss risk | Pay Later loss risk |
|---|---:|---:|---:|---:|
| CPU | 34 | 17 | 8 | 25 |
| CPU cooler | 190 | 4 | 2 | 15 |
| Case | 21 | 0 | 0 | 1 |
| Graphics card | 30 | 27 | 27 | 30 |
| Keyboard | 15 | 1 | 1 | 1 |
| Memory | 32 | 14 | 14 | 23 |
| Monitor | 88 | 45 | 40 | 59 |
| Motherboard | 42 | 0 | 0 | 4 |
| Mouse | 6 | 0 | 0 | 1 |
| Power supply | 179 | 5 | 5 | 18 |
| Storage | 37 | 17 | 13 | 26 |
| **Total** | **674** | **130** | **110** | **203** |

See `profit-risk-all-products.csv` for all **721** entries with product links, cost baselines, seller/status, checkout fees and per-method estimated contributions. See `profit-risk-loss-list.md` for all **130** currently eligible PayPal-negative products.

## Suggested next actions

1. Protect checkout from unprofitable orders with a server-side margin rule **using a validated supplier cost**, accounting for fees, purchased items and shipping. Don't rely on catalog $15 markup alone.
2. Set dynamic margins or minimum fees for expensive standalone items while deciding whether to preserve the flat $15 markup for lower-cost items. Avoid silently changing sales prices.
3. Confirm Newegg seller and actual live exact-SKU price *before every purchase*. Do not use third-party seller offers as eligible direct cost baselines.
4. Account separately for supplier sales tax, delivery expenses, returns, payment disputes, employee commissions and discounts.
5. Audit sales tax configuration against actual tax obligations; a universal 10% setting is not necessarily legally accurate in each customer jurisdiction.

**No storefront prices, live inventory status, notes or permissions are changed in this audit.**
