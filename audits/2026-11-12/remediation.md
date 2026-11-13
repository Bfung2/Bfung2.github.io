# Full catalog source review — November 12–13, 2026

The live source pass is complete: **721 of 721 catalog IDs**, across 734 storefront/builder records. All 85 previously missing exact product links were recovered. The pending live queue is empty. `verified-public-offers.json` records public source facts and inspected offer eligibility for every ID.

## Catalog corrections

Compared with main after PR #120, this follow-up changes 717 records / 704 IDs and corrects 79 record prices. Every eligible inspected offer is sold directly by Newegg, in stock, and priced at observed Newegg price plus $15. Out-of-stock, backordered, or unverified direct offers are unavailable. Historical prices remain on unavailable records; they are not newly verified baselines.

The 721 IDs include 676 observed in-stock direct offers, 18 out-of-stock offers, 7 backorders, 19 listings whose inspected offer was from a marketplace seller, and 1 direct listing without verified purchasability. Two previously unavailable records were re-enabled after current direct stock verification; separately hidden in-stock items remain hidden. IDs and storefront/builder mirrors are preserved.

Exact variant checks corrected the ASRock H810M-X WIFI source and the CORSAIR 16GB DDR5-5200 CL40 kit source. Memory descriptions use observed kit capacity, speed, latency, color and model. `title-reconciliations.json` records the final naming corrections. Manufacturer sources confirm the NZXT, Phanteks and Sudokoo model aliases.

Documented cooler types, radiator sizes, air-cooler heights, PSU wattages/form factors/lengths, and GPU fit details were added where explicitly available. Existing precise verified GPU dimensions take precedence over rounded retailer dimensions. Numeric price prose was synchronized with the verified baseline.

## Validation

All 21 applicable Node regression files and three Python audit tests pass, including checkout eligibility, saved-cart revalidation, mirror synchronization, catalog search, compatibility, accounts, storefront UX and public-data safety. `validation-results.json` contains results. Two unrelated non-CI staff harnesses retain their previously documented dependency/helper limitations and were not rerun.

The static audit finds no missing source, seller, stock or verification-date fields, no markup mismatches, and no same-ID price conflicts. Eighteen record baselines remain absent only on disabled unavailable inventory; no price was fabricated. All stored ineligible seller/stock records are disabled.

## Compatibility limits

The separate 138-ID fit/documentation queue (93 active) is not unfinished live offer verification. It records facts not established by available pages, including RAM height, complete PSU cable counts and cooler dimensions. Exact CPU/BIOS support, memory QVL, shared storage lanes and conditional radiator/clearance combinations remain unverified where applicable. Matching socket or nominal radiator size does not certify a complete build. Customer compatibility warnings and assembly review requirements remain in force.

## Previously merged checkout work

PR #120 added cart and server eligibility guards. PayPal canonical pricing and eligibility were deployed as ACTIVE version 22 and checked using an invalid-order HTTP 400 response. This follow-up does not redeploy payment code or place an order.

No cart, account or delivery data is included. Failed loads and security/error pages were never used as price/stock evidence; incomplete pages were rechecked. Evidence is a point-in-time observation and should be reverified before fulfillment.
