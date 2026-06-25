# Server Security Checklist

What's actually applied in this setup, and why each piece earns its place:

## Network level
- **UFW**: only 22 (SSH), 80, 443 open. Everything else denied by default.
- **Postgres and Redis are never exposed to the host network** - no `ports:`
  mapping in `docker-compose.yml` for either. They're only reachable from
  other containers on the compose-managed bridge network. This is the
  single biggest thing that prevents "I left my DB open to the internet"
  incidents, which are depressingly common with default docker-compose
  setups that map `5432:5432` out of habit.
- **fail2ban** on sshd, bans repeat-offender IPs automatically.

## SSH
- Password auth disabled, key-only.
- Root login disabled - the `deploy` user has sudo, root itself isn't
  reachable over SSH.
- CI uses a dedicated deploy key, scoped to this purpose, not a personal key.

## Containers
- App container runs as a **non-root user** (`appuser`), set explicitly in
  the Dockerfile. If the app process is compromised, the attacker doesn't
  get root inside the container, let alone on the host.
- Multi-stage Dockerfile - build tools (gcc, headers) don't end up in the
  final image, which shrinks the attack surface and image size both.
- `.env` is gitignored - secrets never touch the repo. `.env.example`
  documents what's needed without containing real values.
- Postgres/Redis images are pinned to specific major versions
  (`postgres:16-alpine`, `redis:7-alpine`), not `latest` - avoids
  surprise breaking changes on a routine `docker compose pull`.

## Application level
- `/health` checks real dependencies (actually queries Postgres, actually
  pings Redis) rather than blindly returning 200 - a load balancer or
  monitoring system that trusts a fake-healthy endpoint won't catch a DB
  that's silently unreachable.
- Nginx rate limiting (`limit_req_zone`, 10 req/s with burst 20) on the
  proxied routes, to blunt basic abuse/scraping before it reaches the app.
- Input validation via Pydantic models (`NoteIn`) - field length caps,
  so there's no unbounded-size payload getting written to the DB.

## What's intentionally NOT here, and why
- No WAF (e.g. ModSecurity) - reasonable for a small API, would add for a
  public-facing service handling sensitive data or under active attack.
- No secrets manager (Vault, etc.) - `.env` on a single VPS is proportional
  to the scale here. Would move to a real secrets manager once there's more
  than one server or more than one person touching prod config.
- No automatic OS patching configured in this writeup, but it's a one-line
  `apt install unattended-upgrades` and worth doing on any real VPS -
  listed here so it's not forgotten, not because it's hard.
