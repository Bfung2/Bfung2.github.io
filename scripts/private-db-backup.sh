#!/usr/bin/env bash
# Run from a trusted machine with pg_dump, gpg, a recipient public key and PG* env.
set -euo pipefail
umask 077
: "${APEX_BACKUP_RECIPIENT:?Set the GPG recipient fingerprint (public key)}"
: "${APEX_BACKUP_DIRECTORY:?Set a private backup directory outside this repository}"
: "${PGHOST:?Set PGHOST from the Supabase database connection dialog}"
: "${PGDATABASE:?Set PGDATABASE}"
: "${PGUSER:?Set PGUSER}"
: "${PGPASSWORD:?Set PGPASSWORD privately; never commit it}"
export PGSSLMODE="${PGSSLMODE:-require}"
command -v pg_dump >/dev/null
command -v gpg >/dev/null
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
mkdir -p "$APEX_BACKUP_DIRECTORY"
backup_dir="$(cd "$APEX_BACKUP_DIRECTORY" && pwd -P)"
case "$backup_dir/" in "$repo_root/"*) echo 'Backups must be outside the Git repository.' >&2; exit 1;; esac
backup_path="$backup_dir/apex-$(date -u +%Y%m%dT%H%M%SZ).dump.gpg"
trap 'rm -f "$backup_path.partial"' EXIT
pg_dump --format=custom --no-owner --no-acl | gpg --batch --encrypt --recipient "$APEX_BACKUP_RECIPIENT" --output "$backup_path.partial"
mv "$backup_path.partial" "$backup_path"
sha256sum "$backup_path" > "$backup_path.sha256"
echo "Encrypted backup created: $backup_path"
echo 'This backup is not restore-verified. Follow docs/private-backup-recovery.md.'
