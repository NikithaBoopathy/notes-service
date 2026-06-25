# Deployment Walkthrough

This assumes a fresh Ubuntu 22.04/24.04 VPS (tested approach - DigitalOcean,
Hetzner, or similar small box works fine, 1-2GB RAM is enough for this
stack).

## 1. Initial server setup

```bash
# as root, first login
adduser deploy
usermod -aG sudo deploy
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy

# switch to the deploy user from here on - don't run things as root
su - deploy
```

Lock down SSH (`/etc/ssh/sshd_config`):
```
PermitRootLogin no
PasswordAuthentication no
```
Then `sudo systemctl restart sshd`. Password auth off + root login off
stops the bulk of automated SSH scanning traffic dead.

## 2. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker deploy
newgrp docker
docker --version
docker compose version
```

## 3. Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

Only SSH, HTTP, and HTTPS are reachable from outside. Postgres and Redis
are never exposed - in `docker-compose.yml` they're on the internal compose
network only, and there's no `ports:` mapping for them, so even if the
firewall rule was missing, there'd be nothing listening on those ports
externally.

## 4. fail2ban

```bash
sudo apt install -y fail2ban
sudo systemctl enable --now fail2ban
```

The default jail (`sshd`) is enough to start - it bans IPs after repeated
failed SSH attempts. Check status with `sudo fail2ban-client status sshd`.

## 5. Clone the repo and configure

```bash
sudo mkdir -p /opt/notes-service
sudo chown deploy:deploy /opt/notes-service
cd /opt/notes-service
git clone <repo-url> .
cp .env.example .env
nano .env   # set a real POSTGRES_PASSWORD, matching DATABASE_URL
```

## 6. First deploy (manual, before CI is wired up)

```bash
docker compose up -d --build
docker compose ps          # everything should show "healthy" or "running"
curl http://localhost/health
```

## 7. Point a domain at it (if you have one)

Add an A record for your domain to the VPS's IP, then follow
`docs/ssl.md` to get a Let's Encrypt cert via certbot, and uncomment the
HTTPS server block in `nginx/default.conf`.

## 8. Wire up GitHub Actions deploys

In the GitHub repo settings, add these secrets:
- `VPS_HOST` - the server's IP or domain
- `VPS_USER` - `deploy`
- `VPS_SSH_KEY` - a private key whose public half is in
  `/home/deploy/.ssh/authorized_keys` on the server (generate a
  dedicated deploy key, don't reuse your personal one)

From here, every push to `main` runs `scripts/deploy.sh` on the server via
SSH (see `.github/workflows/ci-cd.yml`). The script pulls, rebuilds the app
image, restarts only the app container, and waits on `/health` before
declaring success - if the health check never comes up, the workflow run
fails and the old container's logs print into the Action output.

## Rolling back

If a deploy goes bad:
```bash
cd /opt/notes-service
git log --oneline -5        # find the last good commit
git reset --hard <good-sha>
docker compose build app
docker compose up -d --no-deps app
```

## Path to true zero-downtime (not implemented here, but the next step)

Run two `app` replicas (`docker compose up -d --scale app=2`), and update
nginx's `proxy_pass` to point at both (`upstream` block with both
addresses). Deploy script then restarts one replica at a time, waiting for
its healthcheck before touching the other. With a single VPS and modest
traffic, the few seconds of downtime from a single-replica restart hasn't
been worth the added complexity, but this is the natural next step if that
changes.
