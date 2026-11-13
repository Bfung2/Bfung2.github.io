# Compatibility documentation continuation: November 13, 2026

Following merged PR #121, this branch resolves **85 of 93 previously active unique catalog fit metadata gaps**, touching **93 catalog records** including mirrored product/builder GPU entries. Breakdown: 32 RAM heights, 10 cooler heights, 10 case PSU form-factor facts, 15 GPU auxiliary-power requirements, and 18 PSU GPU cable-connector configurations. Remaining active documentation gaps: **8 unique IDs**. The 45 inactive inventory-review IDs remain unchanged.

## Remaining active, not guessed

- 7 cases need exact PSU form-factor documentation: Antec C8 ARGB; Antec C8 Black; DIYPC DIY-ATX08-Wood; DIYPC DIY-G18-WD; Phanteks Enthoo Pro TG; Rosewill Helium NAS; Rosewill Helium NAS Max.
- 1 cooler requires exact height confirmation: SilverStone XE04-SP3 4U / RL-XE04-SP3B.

## Verification safeguards

All manufacturer or exact-item source references are in `manufacturer-fit-batch-2-evidence.json`. `catalog-review-queue.csv` tracks the 8 active unknowns and all 45 inactive items. Only compatibility fields and `specSourceUrl` / `specVerifiedDate` were updated in `data.json`; product IDs, names, inventory, Newegg source links, prices, seller, images, and active states are preserved. No new price or stock verification is claimed.

**Connector caution:** total PCIe plugs may share a daisy-chain cable, and adapters require vendor-specific verification; matching connector-count strings alone cannot certify cable gauge, separate PCIe cable availability, GPU power compatibility, wattage safety, BIOS support, QVL, or cooling clearance. Keep builder warnings and human assembly review in place.
