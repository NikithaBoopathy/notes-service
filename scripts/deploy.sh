#!/usr/bin/env bash
# Runs ON THE SERVER (triggered remotely by GitHub Actions over SSH).
# Pulls latest code, rebuilds the app image, and restarts only what changed.
#
# Note on "zero downtime": with a single app replica this is "near-zero
# downtime" at best - there's a brief gap while the old container stops and
# the new one's healthcheck passes. True zero-downtime would mean running
# 2+ app replicas behind nginx and doing a rolling swap, which is overkill
# for a small single-VPS deployment but documented in docs/deployment.md
# as the next step if traffic ever justifies it.

set -euo pipefail

PROJECT_DIR="/opt/notes-service"
cd "$PROJECT_DIR"

echo "[$(date)] pulling latest code"
git fetch origin main
git reset --hard origin/main

echo "[$(date)] building new app image"
docker compose build app

echo "[$(date)] recreating app container (db/redis/nginx untouched if unchanged)"
docker compose up -d --no-deps app

echo "[$(date)] waiting for health check"
for i in $(seq 1 15); do
  if curl -sf http://localhost/health > /dev/null; then
    echo "[$(date)] healthy"
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "[$(date)] app did not become healthy in time, check logs:"
    docker compose logs --tail=50 app
    exit 1
  fi
  sleep 2
done

echo "[$(date)] pruning old images to keep disk usage sane"
docker image prune -f

echo "[$(date)] deploy complete"
