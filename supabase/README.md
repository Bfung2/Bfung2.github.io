# Apex Computers private backend

The storefront remains hosted on GitHub Pages and keeps its existing visual design. Supabase is being used for private customer records and server-side operations.

## Current setup

- Supabase project: `https://arvdrrrbobjpmmygojfm.supabase.co`
- The database schema in `schema.sql` has been run in the Supabase SQL Editor.
- An owner Auth user has been created and its server-controlled `app_metadata.role` is set to `admin`.
- The `create-service-request` Edge Function has been deployed and tested directly. A test request was confirmed in `public.service_requests`.
- The feature branch connects the public service form to that function using the publishable key. The browser-side key is designed to be public; never put a Supabase service-role/secret key in HTML, JSON, or Git.
- Draft PR #3 contains the frontend integration. It is not merged and has not yet been verified end-to-end from the website.

## Important security blockers

**Do not treat the current production site as secure yet.**

1. The current `main/index.html` contains hardcoded owner login credentials. Treat them as exposed and replace the owner login with Supabase Auth before enabling management pages.
2. The existing frontend stores a GitHub write token in browser local storage and uses it to write `data.json`. This should be replaced with an authenticated server-side function. Never paste a GitHub token into public source or chat.
3. The current `main/data.json` contains customer order and service-request records. PR #1 proposes clearing these records from the current public file, but it is not merged. If they must be retained, transfer them to private storage first.
4. Clearing the current JSON file does not remove previous commits, forks, or cached copies. If secrets were ever committed, revoke/rotate them. Historical customer data may require repository-history cleanup.
5. Customer sign-in is currently only a local profile keyed by email, not real authentication. Customer account and order history must be migrated before they are trusted.
6. Checkout still writes order details into the public JSON data model. Do not accept real orders until checkout writes to private storage and the owner inbox reads from it.
7. The in-site private service-request list/reply workflow is not complete. For now, requests can be reviewed in the private Supabase Table Editor by the project owner.

## Function secrets

Configure secrets in Supabase Function Secrets, not in this repository. The deployed service-request function uses server-side values such as `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. The service-role key bypasses row-level security and must remain server-side.

The Edge Function should validate request bodies, limit payload sizes, and allow only the intended website origin. If the site uses a custom domain, update the CORS allowlist accordingly.

## Database access model

- Public visitors submit service requests through the Edge Function.
- The Edge Function uses server-side credentials to insert records.
- The database's Row Level Security policies restrict reading/updating private records to an authenticated user whose server-controlled app metadata role is `admin`.
- Do not rely on frontend checks alone; database grants and RLS policies must enforce access.

After any schema/policy changes, rerun the relevant SQL and test both allowed and denied operations. See the official [Supabase Row Level Security guide](https://supabase.com/docs/guides/database/postgres/row-level-security).

## Planned migration order

1. Remove public customer records from the current JSON file and address historical exposure.
2. Replace hardcoded owner credentials with Supabase Auth.
3. Replace browser-held GitHub write-token access with a server-side, admin-authenticated update function for public catalog/settings only.
4. Migrate checkout/orders and customer account features to private storage with explicit access policies.
5. Connect the owner inbox to private orders and service requests.
6. Test the full site on a preview before merging anything into `main`.

## Payment handling

Do not collect card numbers or CVVs directly in this website. If online card payments are added, use a reputable payment provider's hosted checkout. Never store card numbers, CVVs, passwords, or secret API keys in these tables.
