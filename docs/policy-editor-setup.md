# Warranty and Returns editor

This feature does not publish legal terms automatically.

1. In Supabase SQL Editor, run \`sql/apex-shop-policies.sql\` once.
2. Sign in as the owner using an account with JWT app_metadata.role = "admin".
3. Open Site settings -> Warranty / Returns editor.
4. Write a policy, click Save private draft, review it, then click Publish saved draft.
5. Visit the public Warranty and Returns pages to verify.
6. Confirm anonymous visitors cannot read drafts by querying the public tables (RLS and privileges deny direct access).
7. Check authenticated employees and customers cannot call apex_owner_policy.

Policy versions are retained in apex_shop_policy_history. This interface lists timestamps and versions but does not implement reverting to an old version. To restore, manually retrieve text with authorized database access and republish it as a new version.

This feature does not verify actual email delivery for Supabase customer authentication. Separately verify confirmation and password reset delivery and redirect URLs on the live site. No real payment tests were performed.
