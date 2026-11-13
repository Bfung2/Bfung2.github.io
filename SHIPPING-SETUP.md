# Apex Computers: live actual-carrier-rate shipping (EasyPost)

## What this change does

The storefront can now choose between the existing percentage-based shipping (still the default) and a live carrier quote. In live mode, before an order is saved, the checkout sends **verified catalog item IDs** and the customer's U.S. shipping destination to the server. It obtains real EasyPost rate offers using **measured packed carton dimensions**. The server checks the same destination and cart again immediately before PayPal order creation. The checkout shows the carrier charge, and PayPal uses a server-recomputed final price.

The customer shipping amount = the cheapest available EasyPost label quote across the configured carrier accounts, **plus the processor-percentage fee attributable to that shipping charge**. This is not a flat rate and is not based on the cart value. Existing item prices, the 7% configured sales tax, 0% break-even target, and $250 assembly fee are not changed by this PR.

The feature is **off until the merchant completes setup**. It NEVER invents an origin or package weights/dimensions. If a required measurement or live rate is missing, checkout in carrier mode stops rather than accepting an unprofitable shipping price.

## Required one-time setup

1. Open a carrier-rating account at [EasyPost](https://www.easypost.com/) and connect the carriers you actually want to buy shipping labels from. Obtain a **production** API key. Test keys are accepted only when your Supabase PayPal environment is explicitly sandbox.
2. In the **Supabase Dashboard → Edge Functions → Secrets**, configure:
   - `EASYPOST_API_KEY`: your EasyPost production API key, stored server-side only.
   - `APEX_SHIP_FROM_JSON`: your actual U.S. parcel origin as a JSON string, for example `{"name":"Apex Computers","street1":"YOUR STREET","city":"YOUR CITY","state":"CA","zip":"YOUR ZIP","country":"US","phone":"YOUR PHONE"}`. Replace every placeholder with your real data. **Never commit these secrets to GitHub or put your private origin address in public website settings.**
3. Deploy the updated Supabase Edge Function **paypal-checkout**, including the shared module under `supabase/functions/_shared/carrier-shipping.mjs`, to your project. On a Supabase CLI with remote deployment configured, deploy with `supabase functions deploy paypal-checkout --project-ref arvdrrrbobjpmmygojfm` after verifying the installed CLI's help for its current syntax. Do not switch the site to live carrier quotes before deployment.
4. As owner, go to every physical product/part you intend to sell → Edit → **Packed shipping measurements**. Enter *measured, fully packed outer carton* length/width/height in **inches** and weight in **ounces**, not the bare item's dimensions. For assembled PCs, enter **Completed PC** weight and dimensions on the selected **Case** record to represent its fully packed finished build. A parts-only build is deliberately rated as separately packed components. Repeat for every purchasable part. Existing catalog entries have no verified package measurements; no bulk estimates have been inserted.
5. In Site settings → **Shipping method**, switch from **Legacy percentage** to **Live EasyPost carrier quotes**, then Save. The existing 2% shipping setting remains available for fallback if you switch back.
6. Test a single small part and an assembled PC with a valid U.S. delivery address. Confirm that the quote shown before order placement matches the checkout's verified PayPal amount. Test missing/malformed measurements and rate failure; checkout must fail closed, never silently charge the old 2% rate.

## Operations and limitations

- **Carrier price is a live quotation, not a purchased label.** Quotes may change before you purchase the label. Buy the corresponding label through your carrier/EasyPost account and check the final billed amount. The payment flow currently does not purchase labels automatically.
- The quote currently uses the **cheapest available USD rate** among the carriers enabled in EasyPost. Verify whether its delivery time, signature, tracking and claims protection meet your needs. Consider restricting carrier accounts for valuable/fragile PCs.
- **Packaging, label supplies, pickup charges, insurance, special handling, damage claims, returns, international shipping, and additional surcharges are not included in the carrier rate.** Enter separately known overhead in the owner product's `extraCostUSD` when setting break-even prices, and verify insurance coverage. Do not count the same cost twice.
- Supports U.S. addresses only. A cart can include at most 12 separately rated packages; larger orders need a manual quote/workflow.
- Service-only products such as on-site tech service don't require a package. Other merchandise without packed measurements can't be purchased in live-quote mode.
- The **configured tax setting is unchanged**, but California and destination-specific taxability of shipping and assembly needs separate tax review.
- **Customer-entered rates/amounts are never trusted for payment**. The PayPal function reads current catalog prices and re-quotes shipping from the saved destination. Existing database tables do not require a migration.
- This PR does not populate parcel dimensions because the current 734-listing catalog has no verified packed shipping measurements and the store's public shipping origin is blank.

## Automated checks

Run `node --test tests/carrier-shipping.test.cjs` on a machine with Node 20+; the test uses a fake carrier response and does not need credentials. Before production, run end-to-end tests with a real EasyPost account and a sandbox PayPal integration.
