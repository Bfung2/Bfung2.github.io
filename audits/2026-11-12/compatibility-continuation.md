# Remaining case PSU mounting compatibility verification: November 13, 2026

Following the merged catalog audit (#121), the 85-fit-fact continuation (#122), and the SilverStone SP3B follow-up (#123), the active physical-fit documentation queue contained seven cases with unconfirmed PSU form factor. This branch resolves three exact-model standard ATX mounts using positive third-party product documentation, retaining four genuinely unknown mounts.

## Confirmed cases (ATX PSU mounting)

| Catalog ID | Model | Evidence | Notes |
|---|---|---|---|
| `caseAntecC8Black` | Antec C8 Black | https://www.microcenter.com/product/701827/antec-c8-tempered-glass-eatx-full-tower-computer-case-black | Exact Micro Center model C8 specifies PSU mount Bottom (ATX). |
| `caseAntecC8ARGBBlack` | Antec C8 ARGB Black | https://global.channelonline.com/smbi_canada/store/Products/overview/M015606150 | Exact manufacturer-model cabinet data lists Power Device: No power supply (ATX); Antec specs max length 210mm. |
| `casePhanteksEnthooProTG` | Phanteks Enthoo Pro TG PH-ES614PTG_BK | https://www.cclonline.com/ph-es614ptg-bk-phanteks-enthoo-pro-tg-full-tower-gaming-case-black-usb-3-0/ | Exact model listing explicitly lists ATX Power Supply supported. Manufacturer model page confirms identity. |

Only `supportedPSUFormFactors: "ATX"` is being confirmed. PSU maximum length already existed and still applies. No inference is made about SFX/SFX-L adapters, cable routing space, side connectors, or coexistence with drive cages and fans.

## Four remaining open

- `caseDiypcAtx08Wood`: DIYPC DIY-ATX08-Wood, PSU maximum length known (240mm), exact mounting PSU form factor not explicitly listed by inspected sources.
- `caseDiypcG18Wood`: DIYPC DIY-G18-WD, PSU maximum length known (160mm), exact mounting PSU form factor not explicitly listed.
- `caseRosewillHeliumNAS`: Rosewill Helium NAS, PSU maximum length known (200mm); exact PSU form factor not explicit in manufacturer product page or manual.
- `caseRosewillHeliumNASMax`: Rosewill Helium NAS Max, PSU maximum length known (200mm); exact PSU form factor not explicit in manufacturer product page.

These four remain `unverified` in the PC builder until explicit exact-model PSU compatibility or manufacturer confirmation exists. A case's compatibility with an ATX **motherboard** is not proof of ATX **PSU** mounting.

## Guardrails

Changed three cases' `supportedPSUFormFactors`, `specSourceUrl`, and `specVerifiedDate` only. All 734 records, IDs, models, Newegg URLs, images, prices, baselines, seller, stock, and active flags preserved. This check is physical compatibility only, not live price/stock verification. The 45 inactive inventory-review queue entries remain intact. A final full-build inspection remains necessary even for a nominal format match.
