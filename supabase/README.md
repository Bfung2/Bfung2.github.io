# Apex Computers private orders setup

This folder prepares a private order backend for the existing GitHub Pages website.
The site can remain hosted free on GitHub Pages. Supabase stores private orders and
service requests; server-side Edge Functions will accept customer submissions and
send email notifications. This setup is not live until the Supabase project is
created, the SQL is run, secrets are configured, and the frontend is connected.

## 1. Create a Supabase project

1. Open https://supabase.com and create/sign in to your account.
2. Create a project named `apex-computers`. Save the database password somewhere safe.
3. In Project Settings / API, copy the **Project URL** and the **publishable/anon key**.
   These can be used by the browser client. Never put the **service_role/secret key**
   in `index.html`, `data.json`, a GitHub commit, or any other public file.
4. Open SQL Editor, create a new query, paste all of `supabase/schema.sql`, and run it.

## 2. Create the owner login

1. In Supabase Authentication, enable email/password sign-in.
2. Create an owner user using your own email address.
3. In the user's app metadata, set `role` to `admin` (not user-editable metadata).
   The SQL policies use this server-controlled role to allow the owner to view/update
   orders and service requests. Do not make a customer account an admin.

## 3. Keep secrets server-side

The service-request form now calls `create-service-request` instead of writing customer details into `data.json`. The browser needs the project's publishable key in `SUPABASE_PUBLISHABLE_KEY` near the top of `index.html`. This is the public/publishable key only, never the service-role key. Configure secrets
inside Supabase Function Secrets, such as `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
and (once email is configured) `RESEND_API_KEY`. Do not commit these values to GitHub
or paste secret keys into chat.

## 4. Important migration safety

- Do not merge the new checkout/admin frontend until it has been connected and tested
  against the Supabase project.
- Existing `data.json` customer request data was removed in the separate security PR,
  but deleting it from the latest version does not erase it from Git history.
- The current `index.html` still has legacy logic that writes orders/requests/accounts
  into public `data.json`. That logic must be replaced before collecting real customer
  information again. The public data file should contain catalog/settings only.
- GitHub Pages serves static files only; it cannot execute PHP or protect server secrets.

## 5. Email notifications

Automatic email needs a server-side email provider such as Resend, plus a verified sender
domain/address as required by the provider. The existing `mailto:` buttons only open the
owner's email app and are not automatic notifications.

## Current status

This is setup scaffolding only. No Supabase project has been created and the website is
not yet connected to a private backend.
