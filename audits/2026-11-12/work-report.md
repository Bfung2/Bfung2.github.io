# Customer accounts and catalog follow-up

## Implemented

- Replaced the local contact-profile “sign-in” with Supabase customer password authentication. Customer storage is separate from owner/employee sessions; legacy local profiles are not treated as identity.
- Prepared confirmed-email signup and password recovery with PKCE callbacks. Sending stays disabled until business SMTP and exact redirect URLs are configured and delivery tested. No real signup/recovery emails were sent.
- Added private validated contact profiles, token-plus-verified-email order linking, cross-device linked history (latest 100), and retained account history for linked archived orders.
- Applied the additive customer account migration to production. A fresh query confirmed both tables exist, anonymous profile SELECT and history RPC access are false, and authenticated history RPC access is true. RPC identity checks and private tables enforce per-customer access.
- Synchronized same-ID catalog edits across Products/Build a PC and deduplicated same-ID cards even when legacy names differ.
- Added an actionable CSV review queue, grouped by SKU and prioritized by active catalog documentation gaps, then fit metadata gaps.
- Prepared customer policy wording and an account activation checklist. Draft policies are not linked or published on the storefront.

## Verified

The merged live storefront renders 126 product cards and 2,552 DOM elements in the observed desktop layout. Production account-table setup succeeded. Database tests cover reruns, confirmed canonical identity, forged identity, cross-account denial, receipt token plus email requirements and archived history. Client tests cover separate sessions, callback isolation, email rollout gates, recovery events, escaped history and late responses after logout. Existing tracking, compatibility, pagination, staff workspace, sales/filter, notification, settings and targeted catalog checks pass. New account screens were checked through isolated client/state tests and syntax checks; a live signup/reset and new-screen browser test is pending deployment and SMTP setup.

## Still open

- Configure the business SMTP sender, keep email confirmation enabled, correct Site URL and allow the two exact callback URLs, test delivery/recovery, then enable CUSTOMER_EMAIL_READY.
- Complete owner decisions in docs/policy-decisions.md and approve completed wording in docs/customer-policy-draft.md before publication.
- Live source verification for remaining catalog entries. The static queue contains 237 SKUs (233 active) needing catalog evidence or selected fit metadata checks. This is a review queue, not proof of incompatibility. The 734 source records still include 118 missing Newegg baselines, 99 missing source URLs, 150 missing seller/date records and 146 missing stock records. No price/availability was invented or changed in this follow-up.
- Existing price conflicts for two inactive marketplace GPUs remain recorded for source review; this change prevents future same-SKU owner edits from diverging.
