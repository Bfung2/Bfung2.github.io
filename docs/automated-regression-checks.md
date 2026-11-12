# Automated storefront regression checks (Phase 4)

GitHub Actions workflow: `.github/workflows/apex-regression.yml`. Triggered by pull requests and pushes to main, with read-only repository permissions.

## Automated checks
- Parse critical JavaScript modules and inline storefront scripts.
- Check that local JavaScript assets referenced by index.html exist.
- Guard against orders, service requests, accounts and customer-link records being committed into public `data.json`.
- Run the customer-account regression and catalog synchronization tests.
- Run the newer catalog-health and staff-sales UI tests **when those files are present** (so PRs may merge independently).
- Produce and upload a static catalog audit report and review queue as a temporary build artifact.

The catalog audit intentionally never fails CI for historical missing seller/stock/price evidence. Instead it records a review queue. Do **not** interpret the report as live Newegg verification. No price or inventory changes occur.

### Deliberately not included
- No live payment capture.
- No production customer signup or real emails.
- No automatic Newegg scraping or price adjustment.
- No database writes.
- SQL integration tests needing PGlite are not in this minimal no-dependency workflow yet.

## Operational checks
After merging this PR, visit **GitHub → Actions → Apex storefront regression checks** and inspect the first run. If any assertion fails, review the logs and fix the regression before proceeding with risky changes. For any catalog review output, download the `static-catalog-review-queue` artifact in the run summary.

Locally, run:
```sh
node tests/site-safety.mjs
node tests/customer-accounts.mjs
node tests/catalog-edit-sync.mjs
python3 scripts/audit_catalog.py --data data.json --output catalog-audit-report.json
```
The audit report is a local output file and should not be mistaken for a verified price update.
