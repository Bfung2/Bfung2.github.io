# Apex Computers employee system setup

The website code and Supabase Edge Function are in this repository. **The employee system will not be active until you run the SQL and deploy the function in your Supabase project.**

## 1. Run the database setup

1. Open the Supabase project for Apex Computers: https://supabase.com/dashboard/project/arvdrrrbobjpmmygojfm
2. Open **SQL Editor** and create a new query.
3. Open `supabase/employee_setup.sql` in this repository.
4. Copy the entire file into the SQL Editor and run it.

This creates employee profiles, cloud service requests, assignment fields, row-level security policies, and the secure claim/status functions. Employees can read only unassigned work and work assigned to their own account. The owner retains full access.

## 2. Deploy the employee account function

The function source is `supabase/functions/manage-employee/index.ts`.

You need the Supabase CLI installed and authenticated. From a terminal, in a local clone of this repository, run:

```sh
supabase login
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY --project-ref arvdrrrbobjpmmygojfm
supabase functions deploy manage-employee --project-ref arvdrrrbobjpmmygojfm
```

Get the service-role key from **Supabase Dashboard → Project Settings → API Keys** (the secret/service_role key). Paste it only into the terminal command or Supabase secrets. Never put it in `index.html`, GitHub, or a public message. Do not use the anon/public key here.

Keep the function's JWT verification enabled. It verifies that the caller is signed in as the owner email `apexcomputers039@gmail.com` before it can create or disable employee accounts.

## 3. Create the first employee

1. Open the live Apex Computers website.
2. Choose **Owner sign-in** and sign in with the existing owner Supabase account.
3. Open **Manage employees**.
4. Enter the employee's display name, username, and a temporary password of at least 10 characters.
5. Give the employee the username and password privately.

Employee usernames are converted internally to synthetic Supabase Auth email addresses. Employees still sign in using only the username and password. Passwords are managed by Supabase Auth and are not stored in the site's data file.

## 4. Employee workflow

- Employees use **Owner sign-in → Employee sign in** (or the direct Employee Login option) and receive a separate dashboard.
- They see customer name, email, phone, address, order/request details, assigned jobs, and unassigned jobs available to claim.
- Claiming is atomic in the database, so two employees cannot claim the same unassigned job.
- Employees can update the status of their own assigned jobs.
- The owner can assign, unassign, and reassign jobs in **Orders & requests** and can disable employee accounts in **Manage employees**.

## Notes

- New service requests are now submitted to Supabase so they are available across devices. Existing requests saved in `data.json` can be imported from the owner dashboard using the **Import older local requests into shared inbox** button in Orders & requests. Importing is safe to repeat because existing request IDs are skipped.
- Existing orders remain in `apex_orders`; the SQL adds the assignment column without deleting order data.
- The Edge Function creates accounts and disables/enables them. Employee password resets are not yet included in this first version; disabling and re-enabling an account is supported.
