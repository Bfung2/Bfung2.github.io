# Owner catalog health dashboard

Open **Site settings → Catalog health** after merging this PR. The owner view is read-only and uses the currently loaded data.json catalog, with the existing GitHub synchronization mechanism.

- Groups products and PC-builder parts by SKU ID. A SKU that appears in both lists is counted once.
- Highlights stored price mismatches, price conflicts between sections, missing Newegg baseline, missing seller/stock/source details, invalid source domains, and verification dates seven days or more old.
- Filters 25 items per page, searches by SKU/name/category/issue, and exports the current filtered queue as CSV.
- Links only to HTTPS Newegg URLs and escapes catalog names in HTML; CSV fields are quoted and spreadsheet-formula-like values prefixed.

## Interpretation and limitations

**A healthy row is not evidence of current Newegg stock or pricing.** This tool performs a local static-data audit only. It cannot verify live Newegg product page, current seller or availability, the exact variant, or today's price. Stored stock labels are historical. It also does not track physical inventory quantities. Never auto-update prices, remove products or suppress catalog listings based solely on this page.

## Testing

Run:
```
node tests/catalog-health.mjs
```

Verify owner navigation and search/pagination on phone and desktop; confirm non-owner accounts cannot access the dashboard. No new Supabase schema or customer data is required.
