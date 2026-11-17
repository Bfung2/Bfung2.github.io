# Staff security completion

## Implemented

- Canonical, confirmed owner identity plus an existing Auth session, an active verified MFA factor and AAL2 are required by `apex_is_owner`. Legacy owner/admin RLS policies use the same check.
- Existing authenticated staff RPC entrypoints receive a server guard. Owner policy publishing also explicitly requires the MFA owner check. Public customer, private-link tracking and payment-server APIs remain separate.
- Owner-only employee administration, Gmail sending and manual notification retries verify `apex_is_owner` before privileged work. Payment-server notification calls preserve service-role authentication.
- A staff security status endpoint exposes only enrollment/verification state so the owner can enroll while normal owner access is locked. Enrollment and challenge use Supabase Auth, never a browser-only permission flag.
- Employees use the existing ID plus a separate generated 52-character password. New accounts have default-deny job permissions. Existing roles, notes, assignments, names and commission history remain intact.
- Legacy employee credentials have version 0 and cannot access staff RPCs. After the owner issues a password, only Auth sessions created after that issuance have staff access. Password resets and account disabling block old staff sessions at the database boundary.
- Owner/employee screens wait for server-confirmed security status. Session changes discard stale responses. The early authentication event listener is installed after staff scripts load.
- Current catalog, pricing, checkout, compatibility, settings and responsive tests support the intentionally empty catalog, current rates and retired builder. Synthetic fixtures still exercise pricing and compatibility behavior. Older private-note and staff-state fixtures are repaired too.

## Owner actions after deployment

1. Sign in as owner and choose Set up authenticator. Scan the code using your own authenticator app and enter its code. Owner tools remain locked until this succeeds. Keep the authenticator backed up privately.
2. Open Employees and choose Issue password for each existing employee. Give the ID and password privately to that employee. The old code-only login and previous sessions no longer grant staff access.
3. Sign in as an employee to complete the real-browser acceptance check. Do not record a real commission payment or submit a real PayPal payment for testing.

MFA enrollment and password entry are owner/user steps. No owner authenticator secret was generated or retained by the agent. Existing employee passwords were not rotated automatically during implementation.

## Backups

The current Supabase Free plan has no scheduled backups. The encrypted dump script and isolated restore procedure are in `scripts/private-db-backup.sh` and `docs/private-backup-recovery.md`. No paid plan, scheduler, production export or restore was initiated. Database credentials and an owner-controlled backup key must be configured privately before the first encrypted backup and restore drill. Source code alone does not provide private-data recovery coverage.

## Verification

The isolated PostgreSQL suite checks owner AAL1 denial, AAL2 access, canonical identity, revoked sessions, legacy employee denial, password/session cutoffs, assigned private notes, edit permission, customer/anonymous isolation and migration reruns. Edge tests reject unverified owner user creation and verify independent strong passwords without logging them. Browser checks exercised the existing signed-in owner overview, empty order workflow and activity page. The local browser viewport override did not produce phone dimensions; mobile interaction/layout remains covered by automated drawer/CSS tests rather than a completed visual phone acceptance test. A signed-in employee walkthrough and real authenticator verification still require the owner/employee steps above.
