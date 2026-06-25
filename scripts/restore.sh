#!/usr/bin/env bash
# Restores a backup created by backup.sh. Usage:
#   ./scripts/restore.sh scripts/backup/backup_20260601_021000.sql.gz
#
# WARNING: this drops and recreates data in the target DB. Don't run this
# against a live DB without thinking about it first.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <path-to-backup.sql.gz>"
  exit 1
fi

BACKUP_FILE="$1"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
source .env

echo "About to restore $BACKUP_FILE into $POSTGRES_DB. This will overwrite existing data."
read -p "Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "aborted"
  exit 1
fi

gunzip -c "$BACKUP_FILE" | docker compose exec -T db psql -U "$POSTGRES_USER" "$POSTGRES_DB"

echo "restore complete"
