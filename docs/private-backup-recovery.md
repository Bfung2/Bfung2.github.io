# Apex private database backup and recovery

## Verified coverage

On November 16, 2026 (Pacific time), the connected Supabase dashboard showed **Free Plan does not include project backups**. No paid upgrade was purchased. GitHub stores public source and migrations; it does not back up private database rows. There is currently no verified scheduled private backup or successful restore drill.

## Two supported choices

1. Upgrade Supabase through its dashboard, then verify the scheduled backups list includes a successful snapshot. This incurs charges and requires the owner's decision. Confirm current retention in the dashboard.
2. Run `scripts/private-db-backup.sh` from a trusted machine with PostgreSQL 17-compatible pg_dump, GPG, the owner's imported GPG public key, and database connection details. Keep credentials in the local process environment or a private password manager. Never add credentials, database dumps, or private keys to GitHub, Actions logs, public Pages assets, or issue attachments.

The script requires PGHOST, PGDATABASE, PGUSER, PGPASSWORD, APEX_BACKUP_RECIPIENT (recipient public-key fingerprint), and APEX_BACKUP_DIRECTORY (outside the repository). Use the connection details shown by Supabase's Connect dialog. It streams a custom-format database dump directly into encryption, writes a checksum, and removes partial files on failure. It does not generate or publish a decryption key. The owner must already control the recipient's private key, stored separately from the encrypted backups.

Run the backup daily using the trusted machine's scheduler after one manual success. Copy the encrypted dump and checksum to a private off-machine destination. Keep seven daily and four weekly copies; check timestamps and checksums weekly. No scheduler was configured during this update because database credentials and an owner-controlled backup key were unavailable.

## Restore drill without touching production

1. Create a disposable, isolated PostgreSQL 17 environment. Do not connect restore tools to the Apex production host. Block outbound network access to email, payments and webhooks.
2. Verify the encrypted file with its SHA-256 checksum. Decrypt it locally using the separately stored private key. Treat decrypted files as confidential and delete them after the drill.
3. Run `pg_restore --list` first. Confirm public business tables and the required Auth schemas are present. A Supabase-to-Supabase restore has managed schemas and platform objects; follow Supabase's current migration/restore guide and use a clean target. Do not blindly overwrite managed Auth or Storage schemas.
4. Restore using pg_restore into the disposable target. A local PostgreSQL restore can require Supabase extension and role stubs; record those preparation steps. Never treat a partially restored database as a successful backup.
5. Compare table counts and a small sample of order assignments, employee roles, notes, sales credits, settlements and customer links with the recorded source snapshot. Confirm MFA owner policies and anonymous/customer access restrictions still work.
6. Record backup time, checksum, restored table counts, errors, elapsed restore time and outcome in a private operations log. The target is recovery to the last daily backup with a rehearsed restore procedure.
7. Shut down the isolated target and remove decrypted copies. Retain encrypted backups and their checksums privately.

## Items a database dump does not fully recover

Back up Storage object files separately if used. Database rows alone do not restore object bytes. Edge Function code is in GitHub; redeploy it from the matching source. Re-enter Edge secrets from a private password manager. Restore Auth configuration, email/OAuth settings, allowed URLs, PayPal settings, DNS and platform integrations separately. Service tokens and provider keys are not recoverable from the public repository.

During an actual incident, pause writes, identify the last known good snapshot, restore to an isolated replacement first, verify permissions and data, and obtain the owner's decision before replacing production or changing its endpoint. Never run a destructive restore as a backup test.

## Manual encrypted business-record download

The owner workspace now has **Private backup**. A verified owner can select a new encryption password (at least 16 characters), download an encrypted business-record snapshot, and verify that saved file locally using the same password. The password stays in browser memory, is cleared from the form afterward, and is never stored in the catalog or sent to Supabase. The file uses AES-256-GCM with a random nonce and salt and PBKDF2-SHA256 (600,000 iterations). Store the file privately and keep its encryption password separately.

The server checks owner MFA on every export and captures included tables using the calling statement's stable database snapshot. It exports every row in its allowlist without API pagination truncation, with per-table counts. The archive reports missing tables and public tables outside the allowlist. Exports over 16 MiB of table JSON fail rather than silently omit rows; use the pg_dump procedure for larger databases.

**This is a manual business-record backup, not full database recovery.** It excludes Auth user accounts, password hashes, MFA and sessions; schema, roles and RLS policies; Storage file bytes; Edge secrets and provider configuration; and the public catalog held in GitHub. No downloaded copy exists until the owner chooses a password and actually saves the file. Scheduled backups remain disabled.

To check a saved copy, select it under Check a saved copy and enter its encryption password. Verification authenticates the encrypted content, validates the archive format, and checks each table's row count. It displays counts and coverage only; it never restores or modifies production. Successful file verification is not a successful disaster recovery drill.

For recovery, decrypt only in a private, isolated environment; review the schema/migration version, recreate/map missing Auth identities, and stage the records into a disposable database using the matching repository migrations. Validate foreign keys, table counts, assignments, commissions, notes and access controls. Expired checkout links, notification queues and old tracking tokens require review before any real replay. Do not bulk-import this archive into production or automatically replay jobs. Full restoration remains a reviewed database migration requiring an owner decision.
