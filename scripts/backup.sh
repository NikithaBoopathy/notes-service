#!/usr/bin/env bash
# Dumps the Postgres DB to a timestamped, gzipped file and prunes anything
# older than 7 days. Meant to run from the HOST via cron, not inside the
# container, so it survives a container being recreated.
#
# Example crontab entry (runs nightly at 2:10am):
#   10 2 * * * /opt/notes-service/scripts/backup.sh >> /var/log/notes-backup.log 2>&1

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$PROJECT_DIR/scripts/backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7

mkdir -p "$BACKUP_DIR"
cd "$PROJECT_DIR"

# read DB creds out of .env so this script doesn't need its own copy
source .env

echo "[$(date)] starting backup"

docker compose exec -T db pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
  | gzip > "$BACKUP_DIR/backup_${TIMESTAMP}.sql.gz"

echo "[$(date)] wrote $BACKUP_DIR/backup_${TIMESTAMP}.sql.gz"

# prune old backups
find "$BACKUP_DIR" -name "backup_*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "[$(date)] backup done, pruned anything older than ${RETENTION_DAYS} days"

# Optional: rsync/scp this directory off-box to S3 or another host.
# Keeping backups on the same disk as the DB they back up is better than
# nothing but doesn't protect against disk/VPS failure - if this matters
# for your use case, add an off-box sync step here.
