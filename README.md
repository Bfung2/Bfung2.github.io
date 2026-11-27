# Apex Computers

Apex Computers runs a static storefront on GitHub Pages. Supabase stores customer and staff records and runs the checkout backend. PayPal processes payments. The deployment entry point is `index.html`. The repository also contains legacy PHP files from the initial shop prototype.

- [Storefront](https://bfung2.github.io/)
- [Supabase migrations](supabase/migrations/)
- [Edge Functions](supabase/functions/)
- [Operations runbook](docs/phase11-operations-runbook.md)
- [Shipping and carrier setup](SHIPPING-SETUP.md)
- [Refunds](docs/paypal-refunds.md) and [recording actual costs](docs/order-finances.md)
- [Staff security](docs/staff-security-completion.md) and [private backup recovery](docs/private-backup-recovery.md)

## Release and verify

1. Apply pending migrations in version order to the linked Supabase project. For the custom PC quote release, apply `20261127000100_custom_pc_quotes.sql` and `20261127000200_private_catalog_sources.sql` before publishing storefront changes. Use the configured project and confirm the migration status first.
2. Deploy the updated payment function with `supabase functions deploy paypal-checkout --project-ref arvdrrrbobjpmmygojfm`. Use a separate test project with PayPal sandbox credentials for payment testing. The production storefront uses the live merchant configuration.
3. Merge the storefront PR and check the GitHub Pages deployment. Keep Supabase service-role and PayPal secret keys in Supabase secrets. Keep customer records and supplier costs out of public Git commits.
4. Run one test request from quote creation through fulfillment. Verify that a customer can open the private quote, request a change, accept the revised amount, and pay only once. Verify the customer's tracking status and owner actual-profit view. Use PayPal sandbox for test payments and refunds.

## Run locally

Serve the repository from its root with `python3 -m http.server 8000`. The checked-in frontend points to Apex's configured services. A local browser preview still uses those services unless you substitute test configuration or mock requests. Avoid creating test customer records or payments in the live project.

GitHub Actions runs the release checks in [apex-regression.yml](.github/workflows/apex-regression.yml). Run the mocked payment suite with `node tests/payment-checkout.mjs` on Node 24. The quote and supplier SQL regression uses PGlite and checks owner permissions, quote revisions and expiry, pricing, and retry-safe acceptance. See [automated regression checks](docs/automated-regression-checks.md).

## Custom PC quotes

- Customers enter budget, games or apps, resolution, and pickup or shipping preferences from **Custom PCs**. They receive a private link to check progress. A shipping request captures the address so Apex can price the quote.
- Open **Staff workspace → Custom PC quotes** to review requests. Enter the specification, selling price, shipping charge, applicable sales tax, and estimated expenses. Confirm the parts, carrier cost, and tax for the specific quote. The calculator applies processing fees to the total charge and excludes collected tax from contribution. An offer below $350 requires your explicit confirmation.
- Publish the offer and use **Email quote link** or **Copy quote link**. Offers expire after seven days. Customer change requests appear in the quote queue. An accepted quote keeps its agreed price. Coordinate post-acceptance changes with the customer and use the existing cancellation and refund tools as appropriate.
- Accepted quotes become Apex orders. Wait for confirmed PayPal payment before ordering parts or starting fulfillment. Assign the order from **Orders & requests** and post progress from **Order workflow**, and **Actual costs and refunds** from the quote to compare the estimate with recorded contribution. Include actual assembly labor and inbound freight in the relevant expense totals.
- The link grants access to quote review and acceptance. Treat it like a receipt link and send it directly to the intended customer.

## Parts and accessories

Use **Products → Add a product** in verified owner mode. Start with upgrades you can source at a price that leaves room for payment fees and fulfillment costs. Use the exact Newegg listing to confirm seller, availability, and cost. Set a selling price above the modeled minimum when the market supports it. Add useful search terms such as capacity, manufacturer, model, interface, or category synonyms.

The owner product editor stores supplier links, purchase prices, and extra costs in Supabase. GitHub receives the customer-facing listing and an opaque reference. Checkout independently checks the linked cost evidence and blocks orders below estimated costs. Refresh the verified date within seven days to keep an eligible listing available. Public catalog audits can check public fields and verification age. Open the owner editor to review the private cost and listing link.

Existing legacy catalog records can be reopened and saved through the owner editor to move their current supplier fields to Supabase. Data previously published in Git history should be treated as public.
