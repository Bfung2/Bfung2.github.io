# Staff roles, schedule, reports, and internal notes

## Activate this update

The storefront remains on GitHub Pages. Private staff data is stored only in Supabase; it is never written to `data.json`, exports, or browser storage.

1. In the existing Apex Supabase project (`arvdrrrbobjpmmygojfm`), open **SQL Editor → New query**.
2. Run [the staff workspace migration](migrations/202611100001_staff_roles_schedule_notes.sql) in full. It runs as one transaction and preserves existing employees, orders, requests, and activity logs.
3. Merge this pull request to publish `index.html`, `staff-workspace.js`, and `staff-workspace.css` through the existing GitHub Pages workflow.
4. Sign in as the owner. Open **Staff workspace → Roles & permissions**, then **Employees → Roles / permissions**.

This update requires the existing employee schema plus the three `20261106` migrations (contact email, permissions/audit, and performance). Apply any missing prerequisites in that order before the new migration. Do not rerun `employee_setup.sql` after the migrations: the original bootstrap contains older job functions and read policies. No new secrets or Edge Function deployment are needed for this update; the existing `manage-employee` function continues to create/disable/delete accounts and reset sign-in codes.

If the new database functions are missing, the staff workspace shows a setup message instead of pretending to save. This PR does not itself apply SQL to the production Supabase project.

## Roles and individual permissions

- Starter roles: **Manager**, **Tech**, and **Market**. Edit, rename, add, or remove them. No employees are assigned a role automatically.
- A person can have several roles. Their allowed permissions combine across those roles.
- For each employee, **Inherit** uses roles, **Allow** grants an individual permission, and **Deny** blocks it even if a role grants it.
- Existing employees retain their existing job access until first configured. When editing them for the first time, their old permissions appear as explicit overrides. Use **Use role defaults for all** to move them fully to role-based access.
- Removing a role removes inherited access immediately in database checks. Individual Allow/Deny overrides remain. Removing the last role does not restore the employee's old access.
- Only the owner can manage employee access and role definitions. A Manager does not become an owner and cannot change anyone's roles.
- The owner retains access to every staff feature. Disabled employees cannot use any staff RPC, even with an existing session.

Available permissions: orders, service requests, customer contact details, claiming jobs, updating assigned job statuses, viewing schedules, editing shifts, viewing employee reports, viewing permitted notes, editing permitted notes, and managing permitted notes.

Schedule editing also needs schedule viewing. Note editing needs notes viewing. Note management needs notes viewing and editing, plus a role in the note's editing list. These dependencies let an explicit individual Deny remain authoritative.

## Schedule

**Staff workspace → Schedule** shows a weekly staff schedule, with an employee filter, previous/next week buttons, and a current-week shortcut. Existing employees can view it by default; starter roles also include schedule viewing. Customers cannot read schedule data or see staff navigation.

Only the owner or staff with viewing and editing permission can create, edit, reassign, or delete shifts. Choose an active employee, title, start/end, optional location, and staff details. Times are entered and displayed in the viewer's device timezone and stored as timezone-aware timestamps. Overnight shifts appear on every day they span. Overlapping shifts for the same person are rejected, including concurrent edits. A revision check prevents overwriting someone else's newer edit.

## Individual employee reports

Click an employee's name or **View report**. Delegated report viewers use **Reports** to select an active employee. The owner can also report on disabled employees.

Reports show currently assigned jobs, distinct jobs completed by that employee, recent activity count, last activity, and paginated activity history. **By employee** identifies the employee as actor; **About employee** identifies administrative changes someone else made. Completion totals require the employee to have recorded the status change, so owner-completed work is not credited as their action. Historical work before audit tracking cannot be reconstructed.

New role/access, schedule, and note actions are logged alongside existing login and job activity. Audit entries record IDs and action metadata, never note bodies. Staff cannot write, modify, or erase audit history through the API. Non-owner report viewers do not receive contact emails or login user agents in event metadata.

## Internal notes

Open **Internal notes**, the **Notes** button on an employee card, **Employee notes** on their report, or **Staff notes** in a product/part details dialog.

A note can reference a product/part, employee, general topic, or another reference. Its access settings are independent of the public product description:

- No audience selected: owner-only.
- **All staff**: readable by active staff who also have global notes-viewing permission.
- Viewing roles: readable by employees in those roles with notes-viewing permission.
- Editing roles: also readable, and editable when the employee has global notes-viewing and notes-editing permission.
- Content editors can edit the title/body only. They cannot change the audience or reference by crafting an API request.
- Note managers can create/delete and change access to notes they may edit. Non-owner managers must keep one of their own roles in the editing list; they cannot move a note outside their own access.
- The owner can always view, edit, or delete a note.

Role removal immediately removes corresponding note access. Notes store role IDs, so creating a new role with a previously used name does not grant access to old notes. Note and shift edits use revision checks to prevent lost updates.

## Validation

Run database integration tests against a disposable embedded PostgreSQL instance:

```sh
npm install --prefix /tmp/apex-staff-test --no-audit --no-fund @electric-sql/pglite@0.5.16
PGLITE_MODULE=/tmp/apex-staff-test/node_modules/@electric-sql/pglite/dist/index.js node tests/staff-permissions.mjs
node tests/staff-workspace-state.mjs
node --check staff-workspace.js
```

Tests run the existing schema, all prior employee migrations, and the new migration twice, then exercise customers, anonymous sessions, owner, tech, market, disabled staff, role changes, individual denies, job access, note audiences/content editors, conflicting schedules, stale writes, and employee reports. They never connect to production.

Browser checks use disposable sample staff and a mocked Supabase client for UI behavior. Production SQL activation and real-account end-to-end testing remain a separate deployment step.
