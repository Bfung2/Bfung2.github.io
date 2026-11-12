# Apex storefront quality batch

## Live browser checks completed

- Reloaded the published site to load PR #100 and previous merged work.
- Tested CPU selection and opening/cancelling final build review; no purchase, checkout submission or payment was made.
- Verified mobile build-review layout at a 390 × 844 viewport: dialog fit within the viewport, with no horizontal overflow. Long content scrolls inside the dialog.
- Removed the temporary CPU selection after testing; cart remained empty. Restored the normal browser viewport.
- Opened/closed the mobile product filter drawer and checked owner overview at phone width. Page scroll width matched viewport width.
- Measured the current all-products view: 707 product cards and 12,452 DOM elements rendered. The new category pagination is prepared in this branch, not yet measured live after merge.

## Implemented in this branch

- Independent 12-card product category pages, numbered/current-page controls, previous/next navigation, bounded page selection and filter/search resets. Full catalog stays searchable.
- Offscreen category rendering containment and reduced phone animations.
- Empty builder no longer reports an unverified partial build before a part is selected.
- Optional carrier, tracking number, estimated-completion date and pickup instructions in customer progress. Only owner/assigned authorized staff can edit; updates retain revision and payment guards. Dates are expressly estimates.
- Targeted catalog corrections and fit specifications documented in targeted-verification.json. Two previously blocked direct-Newegg GPU offers were verified in the current browser, prices synchronized across matching records at +$15, and re-enabled. Two marketplace listings remain disabled.
- Verified GPU lengths/connectors for four existing model IDs and Dark Rock Pro 5 height from the manufacturer. This is not a full compatibility-specification audit.

## Repository cleanup completed

Closed obsolete unmerged PRs #1, #2 and #3 after comparing their purpose with current catalog-only data.json and implemented private Supabase workflows. Their old schema/frontend proposals should not be merged over the current implementation. This did not rewrite repository history or delete branches.

## Still incomplete

- Full live Newegg catalog verification. Static audit covers 734 records; 118 lack recorded Newegg baselines and 99 lack exact source URLs after this batch. Counts include duplicate/inactive records; they are not verified current price errors.
- Remaining CPU/BIOS, radiator, clearance and connector metadata throughout the catalog.
- Secure customer accounts and cross-device order history.
- Owner-approved warranty/returns/shipping/turnaround policies; decision checklist in docs/policy-decisions.md.
- New pagination and delivery UI need published browser verification after merge. Existing live review/filter/dashboard checks above do not imply new branch UI has been tested live.

## Validation

Full PGlite staff integration suite, storefront pagination, build compatibility, order tracking state, staff state and customer-link filter tests. New tests cover delivery ownership/privacy, stale revisions, malformed estimated dates, tracking history, 12-card page bounds, independent categories and empty-builder state.
