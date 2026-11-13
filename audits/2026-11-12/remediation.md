# November 12 catalog and checkout remediation

The full live catalog review is **unfinished**. Chrome access ended after source observations for 181 catalog IDs. The remaining 540 IDs are explicitly listed in `pending-live-verification.json`; 85 still need exact product-link discovery. No blocked, rate-limited, CAPTCHA, or inaccessible page was used as price or stock evidence.

## Completed changes

- Checkout rejects unknown IDs, invalid quantities, explicitly unavailable products and conflicting mirrors. Saved carts rebuild current product/build prices and assembly fees. PayPal canonical server pricing already existed; its missing eligibility guards are deployed as ACTIVE version 22 and were re-fetched and smoke-tested with an invalid-order request (HTTP 400). No paid order was placed.
- Source observations cover 181 IDs: 37 CPUs, 96 coolers, 23 graphics cards, 15 PSUs, 8 motherboards, 1 case, 1 mouse. Current product HTML and Chrome DOM observations are recorded in `verified-public-offers.json`; this is evidence for inspected offers, not a claim that all catalog entries were checked.
- 203 catalog records (192 distinct IDs) changed, including 23 price corrections. Eligible verified offers are Newegg + $15. Historical prices remain on disabled listings when an eligible direct offer could not be verified.
- The GIGABYTE WindForce RTX 5070 has a verified Newegg-direct in-stock offer again and is re-enabled at $934.99 ($919.99 + $15). The MSI Ventus RTX 5060 Ti remains disabled because the inspected offer is from TELeasy. Both mirror pairs stay synchronized.
- Verified backordered or sold-out offers are disabled, including Ryzen 9 7900X, ASRock Challenger 360 Digital, ASRock Pro White 240, Hyper 212 PRO ARGB, Corsair Nautilus II 360 RS LCD, Fractal Radius 360, and the Newegg offer of the B860M Eagle Plus WIFI6E. The Ryzen 9 5900XT remains disabled/backordered. Previously documented ineligible stored inventory also stays disabled.
- Recovered the exact ASRock B650M PRO RS source and seller/stock/baseline evidence.
- Manufacturer specifications add cooler/PSU clearance evidence for eight case records. Conditional installation limits stay explicit: North XL mesh uses a conservative 155 mm cooler limit with the side fan bracket; removing it permits 185 mm. Partial radiator support lists were not treated as exhaustive lists.
- Audit tooling now rejects search-result URLs as exact listing evidence and recognizes “Not available” stock wording.

## Current static audit

734 entries, 721 IDs. No stored markup mismatches or same-ID price conflicts. Remaining entry gaps: 87 baselines; 85 source links; 85 seller, stock and verification-date fields each. Two baseline gaps belong to disabled marketplace GPUs. The separate 205-SKU static/compatibility review queue includes missing fit evidence and is not the same as the 540-ID unfinished live-review queue.

## Verification and blockers

21 Node regression files and three Python audit tests pass locally. Two unrelated non-CI staff harnesses retain existing limitations: missing PGlite dependency and an undefined harness helper. Source captures were reduced to public product facts; account, cart and delivery information from Chrome was excluded.

Bulk public requests hit Newegg HTTP 429 / error 1015. Requests stopped and the supplied cooldown was honored; a later public request required human verification. The user's authorized Chrome session continued loading normal product pages, until the Browser tool reported that the originating browser context was unavailable. No verification challenge was solved or bypassed. Resume from `pending-live-verification.json` in the connected Chrome context; verify exact variants, direct seller, stock and current price before changing records.
