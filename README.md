# notes-service

A small FastAPI app, dockerized and productionized with Postgres, Redis, and
an Nginx reverse proxy, deployed to a VPS via GitHub Actions.

This was built as an infra exercise, but it's a real, runnable stack - not a
toy. Every piece here (healthchecks, backups, log rotation, rate limiting)
is something I've actually hit a problem around before and is here on
purpose, not just for show.

## What's actually in here

- **`app/`** - FastAPI service with a tiny "notes" CRUD resource backed by
  Postgres, with Redis as a read-through cache. There's a real `/health`
  endpoint that checks both dependencies instead of just returning 200.
- **`docker-compose.yml`** - app + postgres + redis + nginx, with
  healthchecks gating startup order, log rotation limits, and the db port
  *not* exposed to the host.
- **`nginx/default.conf`** - reverse proxy with rate limiting and the
  Let's Encrypt HTTP-01 challenge path wired up (commented sections show
  how to flip on HTTPS once you have a cert).
- **`scripts/`** - backup, restore, and deploy scripts. These are what
  actually run in cron and in CI, not just described in prose.
- **`.github/workflows/ci-cd.yml`** - builds and smoke-tests the image on
  every push/PR, and deploys to the VPS over SSH on pushes to `main`.

## Quickstart (local)

```bash
git clone <this-repo>
cd notes-service
cp .env.example .env        # edit POSTGRES_PASSWORD at minimum
docker compose up -d --build
curl http://localhost/health
curl -X POST http://localhost/notes -H "Content-Type: application/json" \
  -d '{"title": "first note", "body": "hello"}'
curl http://localhost/notes/1
```

If `/health` comes back `"status": "ok"` with both `postgres` and `redis`
as `"ok"`, the stack is up.

## Docs

- [docs/deployment.md](docs/deployment.md) - full VPS setup walkthrough,
  from a fresh Ubuntu box to a running stack behind Nginx
- [docs/ssl.md](docs/ssl.md) - SSL approach, including what to do with no
  domain
- [docs/security.md](docs/security.md) - server hardening checklist
  (firewall, fail2ban, SSH, non-root containers)
- [docs/logging-and-backups.md](docs/logging-and-backups.md) - logging
  strategy and backup/restore procedure
- [docs/architecture.md](docs/architecture.md) - architecture diagram and
  request flow

## Known limitations / what I'd do next with more time

- Single app replica, so deploys have a few seconds of downtime while the
  container restarts. Documented the path to a 2-replica rolling deploy in
  `docs/deployment.md` but didn't implement it here since one VPS with one
  small app doesn't really need it yet.
- No centralized log shipping (e.g. to Loki/ELK) - logs currently live in
  Docker's json-file driver on the host with rotation caps. Fine at this
  scale, would revisit at higher traffic.
- No automated DB migrations tool (Alembic) - schema is created via
  `Base.metadata.create_all()` on startup, which is fine for this small
  schema but wouldn't scale to real migration history.
