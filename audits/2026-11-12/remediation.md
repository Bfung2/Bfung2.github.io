# November 12 audit remediation

## Fixed
- Unknown IDs, malformed items, invalid quantities and unavailable items are rejected by the browser cart. Saved product/build prices and assembly fees are rebuilt from the current catalog before displaying totals and submitting orders.
- Production PayPal source inspection confirmed that canonical price calculation and unknown-ID rejection already exist. Added the missing server checks for disabled listings, explicit non-Newegg sellers, ineligible stock and conflicting product/part prices.
- Both disabled GPU mirrors now agree on their retained historical price/name. Removed obsolete price claims from descriptions. These prices are not new verified offers; both SKUs remain disabled pending Newegg-direct verification.
- Recovered eight exact same-ID source URLs and one stored baseline from catalog mirrors, without advancing verification dates.
- Opened exact Newegg pages for five Intel CPUs. Recovered five missing source links. Verified primary Newegg seller/Add to cart offers for i7-14700 ($366.24), i5-14600K ($249.97), i5-14600KF ($232.08). Updated all exact-name catalog records to baseline + $15, including legacy parts with different IDs.

## Evidence
Reviewed November 12, 2026. Current seller and Add to cart observed on these underlying product pages:
- https://www.newegg.com/p/N82E16819118476 — i7-14700; Apex $381.24.
- https://www.newegg.com/p/N82E16819118470 — i5-14600K; Apex $264.97.
- https://www.newegg.com/p/N82E16819118472 — i5-14600KF; Apex $247.08.
- https://www.newegg.com/p/N82E16819118468 — i7-14700KF identity/link confirmed; primary seller antonline, alternate Newegg offer not fully confirmed. No new seller/stock/price claim recorded.
- https://www.newegg.com/p/N82E16819118487 — i7-14700F identity/link confirmed; primary seller NothingButSavings, alternate Newegg offer not fully confirmed. No new seller/stock/price claim recorded.

## Still open
734 entries remain. Static audit: 114 missing baselines, 86 missing source URLs, 142 missing seller/stock/date fields each, zero stored markup mismatches and zero same-ID price conflicts. Counts are entries, not unique SKUs. The review queue covers 236 SKUs, including compatibility evidence gaps. Missing evidence remains unverified rather than invented; this is not full live catalog/spec/image verification. No paid checkout was executed.

## Validation
Checkout behavioral regression tests cover products/builds, unknown IDs, invalid eligibility, conflicting mirrors, forged/stale prices and assembly fees. Storefront CI tests and Python audit tests pass locally. Two extra non-CI staff test harnesses have pre-existing limitations: staff-permissions requires an unavailable @electric-sql/pglite dependency; staff-workspace-state references a missing harness helper staffEmployeeLedgerStats. No staff code changed.
