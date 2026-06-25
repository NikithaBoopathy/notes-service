#!/usr/bin/env bash
#
# bootstrap.sh
#
# Run this ONCE, as root, on a brand-new Ubuntu VPS, right after first boot.
# It takes the server from "fresh Ubuntu" to "running notes-service stack".
#
# WHAT IT DOES, IN ORDER:
#   1. Creates a non-root 'deploy' user with sudo + your SSH key
#   2. Installs Docker + Docker Compose
#   3. Sets up UFW firewall (22, 80, 443 only)
#   4. Installs fail2ban
#   5. Clones your repo into /opt/notes-service
#   6. Creates .env from .env.example with a random generated DB password
#   7. Builds and starts the stack
#   8. Hits /health to confirm it's actually up
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   - It does NOT disable SSH password auth / root login automatically.
#     That's a separate, manual step at the end (see printed instructions)
#     because doing it inside an unattended script is how people lock
#     themselves out of their own server. Do it yourself, deliberately,
#     AFTER you've confirmed the 'deploy' user can SSH in.
#
# USAGE:
#   1. Edit the CONFIG section below (repo URL, your public SSH key)
#   2. Copy this file onto the fresh VPS (scp it, or paste it into a file
#      with `nano bootstrap.sh`)
#   3. chmod +x bootstrap.sh && ./bootstrap.sh
#
set -euo pipefail

# ============================ CONFIG - EDIT ME ============================
REPO_URL="https://github.com/nikithaboopathy/notes-service.git"
DEPLOY_USER="deploy"
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDTotLfvceiF21YOum9N0hHif7uRuniH4jJOB7u2H1EOFzHqv893sN3y6TKCwvqivBxJA+IeoJBz7vh/9f3OvQKD91YoBpsgnSYXGrQE2aAV423u31MPbeHiaM9GDcup/G/E0NUYfDPZ2wqptrYJI5RRoOYedn8PCPkg4V9Z6SNQ0uUX72OSdVnQGfxsKbuNPXrts2SUJQMB2edZECrswGAqNig9/CXzXsQnJXjNkqqtnUtuv6qLX1P3v1iu/BLtZi5v/OdWb8qplio8PH9yvmYNZ63rRVWp8tSUlxgaE+vs1qHWaCyRkounqMvQkJETxgNljUwCfB2hcSUGP4YmdT/"
PROJECT_DIR="/opt/notes-service"
# ===========================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Run this as root (or with sudo)." >&2
  exit 1
fi

if [[ "$REPO_URL" == *"nikithaboopathy"* ]]; then
  echo "Edit REPO_URL at the top of this script before running it." >&2
  exit 1
fi
if [[ "$SSH_PUBLIC_KEY" == *"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDTotLfvceiF21YOum9N0hHif7uRuniH4jJOB7u2H1EOFzHqv893sN3y6TKCwvqivBxJA+IeoJBz7vh/9f3OvQKD91YoBpsgnSYXGrQE2aAV423u31MPbeHiaM9GDcup/G/E0NUYfDPZ2wqptrYJI5RRoOYedn8PCPkg4V9Z6SNQ0uUX72OSdVnQGfxsKbuNPXrts2SUJQMB2edZECrswGAqNig9/CXzXsQnJXjNkqqtnUtuv6qLX1P3v1iu/BLtZi5v/OdWb8qplio8PH9yvmYNZ63rRVWp8tSUlxgaE+vs1qHWaCyRkounqMvQkJETxgNljUwCfB2hcSUGP4YmdT/"* ]]; then
  echo "Edit SSH_PUBLIC_KEY at the top of this script before running it." >&2
  exit 1
fi

echo "=== [1/8] Creating user '$DEPLOY_USER' ==="
if id "$DEPLOY_USER" &>/dev/null; then
  echo "user $DEPLOY_USER already exists, skipping creation"
else
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
  usermod -aG sudo "$DEPLOY_USER"
fi

mkdir -p /home/"$DEPLOY_USER"/.ssh
echo "$SSH_PUBLIC_KEY" >> /home/"$DEPLOY_USER"/.ssh/authorized_keys
sort -u -o /home/"$DEPLOY_USER"/.ssh/authorized_keys /home/"$DEPLOY_USER"/.ssh/authorized_keys
chmod 700 /home/"$DEPLOY_USER"/.ssh
chmod 600 /home/"$DEPLOY_USER"/.ssh/authorized_keys
chown -R "$DEPLOY_USER":"$DEPLOY_USER" /home/"$DEPLOY_USER"/.ssh
echo "added your key to /home/$DEPLOY_USER/.ssh/authorized_keys"

echo "=== [2/8] Installing Docker ==="
if command -v docker &>/dev/null; then
  echo "docker already installed, skipping"
else
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$DEPLOY_USER"

echo "=== [3/8] Configuring UFW firewall ==="
apt-get update -qq
apt-get install -y -qq ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "ufw status:"
ufw status verbose

echo "=== [4/8] Installing fail2ban ==="
apt-get install -y -qq fail2ban
systemctl enable --now fail2ban
echo "fail2ban active: $(systemctl is-active fail2ban)"

echo "=== [5/8] Cloning repo into $PROJECT_DIR ==="
if [ -d "$PROJECT_DIR/.git" ]; then
  echo "repo already exists at $PROJECT_DIR, pulling latest instead"
  cd "$PROJECT_DIR"
  git pull
else
  git clone "$REPO_URL" "$PROJECT_DIR"
fi
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$PROJECT_DIR"

echo "=== [6/8] Generating .env ==="
cd "$PROJECT_DIR"
if [ -f .env ]; then
  echo ".env already exists, leaving it alone"
else
  RANDOM_PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)
  cp .env.example .env
  sed -i "s|change_me_to_something_long_and_random|${RANDOM_PW}|g" .env
  chown "$DEPLOY_USER":"$DEPLOY_USER" .env
  chmod 600 .env
  echo "generated .env with a random Postgres password (not printed to terminal)"
fi

echo "=== [7/8] Building and starting the stack ==="
# Run as the deploy user via su, since they're the one in the docker group.
# (root can also run docker, but staying consistent with how CI will do it later)
su - "$DEPLOY_USER" -c "cd $PROJECT_DIR && docker compose up -d --build"

echo "=== [8/8] Waiting for health check ==="
for i in $(seq 1 15); do
  if curl -sf http://localhost/health > /dev/null; then
    echo ""
    echo "SUCCESS: app is healthy."
    curl -s http://localhost/health
    echo ""
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "App did not become healthy in time. Check logs with:"
    echo "  cd $PROJECT_DIR && docker compose logs --tail=80"
    exit 1
  fi
  sleep 2
done

cat <<EOF

=========================================================================
Bootstrap complete. The stack is running on this server.

IMPORTANT - finish these manually, do NOT skip:

1. From your laptop, confirm you can SSH in as the deploy user BEFORE
   you do anything else:
     ssh ${DEPLOY_USER}@<this-server-ip>

2. Only once step 1 works, harden SSH by editing /etc/ssh/sshd_config
   on the server and setting:
     PermitRootLogin no
     PasswordAuthentication no
   then: sudo systemctl restart sshd

   Do this in a SEPARATE terminal window from your existing root session,
   and don't close that root session until you've confirmed the deploy
   user can still SSH in after the restart. This is the step where people
   lock themselves out - keep a fallback session open.

3. Add these GitHub repo secrets (Settings -> Secrets and variables ->
   Actions) so CI/CD deploys work:
     VPS_HOST = <this server's IP>
     VPS_USER = ${DEPLOY_USER}
     VPS_SSH_KEY = <the PRIVATE key matching the public key you set above>

4. curl http://<this-server-ip>/health from your own machine to confirm
   it's reachable from outside, not just on localhost.
=========================================================================
EOF
