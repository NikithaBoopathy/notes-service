# Logging and Backup Strategy

## Logging

- The app logs to stdout in a flat single-line format with timestamp,
  level, module, and message - deliberately not pretty-printed, so it's
  greppable and forwards cleanly to any log driver or aggregator later.
- Docker's `json-file` driver collects it, with rotation capped at
  `max-size: 10m`, `max-file: 3` per service (see `docker-compose.yml`).
  Without this cap, a chatty service can quietly fill the disk over weeks
  - this is a real failure mode worth designing out from the start rather
  than patching after a disk-full incident.
- `/health` is excluded from nginx's access log (`access_log off;` on that
  location) since it gets hit constantly by Docker's own healthcheck and
  would otherwise drown out real traffic in the logs.
- To look at logs: `docker compose logs -f app` (or `db`, `redis`, `nginx`).
  Add `--tail=100` to avoid dumping the whole history.

### If this grew past one VPS
Ship logs to something like Loki + Grafana, or just `journald` +
`vector`/`fluentbit` forwarding to a cheap object-storage-backed log store.
Skipped here because for a single-instance app, `docker compose logs` plus
rotation caps covers the actual need - adding a log pipeline before there's
a reason to is just more moving parts to keep healthy.

## Backups

- `scripts/backup.sh` runs `pg_dump` via `docker compose exec`, gzips the
  output, timestamps the filename, and prunes anything older than 7 days.
  It's meant to run from a host cron job (example crontab line is in the
  script's header comment), not from inside a container, so it survives
  the app container being recreated during deploys.
- `scripts/restore.sh` reverses this, with an explicit confirmation prompt
  since it's a destructive operation.

### Why pg_dump and not just snapshotting the data volume
A `pg_dump` produces a SQL file that's portable across Postgres versions
and doesn't require the target Postgres to match the exact version/page
layout of the source, unlike copying the raw data directory. For a small
DB like this, dump speed is a non-issue, so the portability is worth more
than the slightly faster raw-volume copy would buy.

### What's missing (intentionally, for this exercise's scope)
Backups currently sit on the same disk as the live DB. That protects
against "I dropped a table by accident," not against "the VPS's disk
died." The real fix is a one-line addition to `backup.sh` - `rsync` or
`aws s3 cp` the resulting `.sql.gz` to a second location - left out here
because it needs a destination (another box, or an S3-compatible bucket)
specific to wherever this actually gets deployed, but the hook point is
exactly where that comment sits in the script.

## Restart strategy

Every service in `docker-compose.yml` has `restart: unless-stopped`, so a
container that crashes (OOM, unhandled exception, etc.) comes back up on
its own without needing someone to notice and intervene. Combined with the
Docker healthcheck on the app container (`HEALTHCHECK` in the Dockerfile),
Docker will also flag a container as `unhealthy` if `/health` starts
failing even while the process is still technically running - visible via
`docker compose ps`, which is usually the first thing to check when
something seems off.
