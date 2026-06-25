# SSL Setup

## If you have a domain

Use certbot in standalone/webroot mode against the nginx container's shared
volume (`certbot-www`, already wired up in `docker-compose.yml`).

```bash
# one-time cert issuance - run on the VPS
docker run --rm \
  -v notes-service_certbot-www:/var/www/certbot \
  -v notes-service_certbot-conf:/etc/letsencrypt \
  certbot/certbot certonly --webroot -w /var/www/certbot \
  -d api.yourdomain.com --email you@yourdomain.com --agree-tos --no-eff-email
```

Then uncomment the HTTPS `server` block in `nginx/default.conf` (and the
redirect line in the HTTP block), and reload:

```bash
docker compose exec nginx nginx -s reload
```

Renewal: certbot certs expire every 90 days. Add a cron entry to renew and
reload nginx:

```cron
0 3 * * 1 docker run --rm -v notes-service_certbot-www:/var/www/certbot -v notes-service_certbot-conf:/etc/letsencrypt certbot/certbot renew --quiet && docker compose -f /opt/notes-service/docker-compose.yml exec nginx nginx -s reload
```

## If you DON'T have a domain (this exercise's actual situation)

Let's Encrypt won't issue a cert for a bare IP address - it requires domain
validation. There are three reasonable options here, and what I'd actually
pick depends on the goal:

1. **Run HTTP only for the demo.** This is what the included
   `nginx/default.conf` does by default (HTTPS block commented out). For a
   grading/demo environment that isn't handling real user data, this is
   honestly fine and is what I did here - the doc explains the real path
   rather than faking a cert that wouldn't actually validate.

2. **Self-signed certificate**, if you want to demonstrate the HTTPS
   config path without a domain:
   ```bash
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout nginx/selfsigned.key -out nginx/selfsigned.crt \
     -subj "/CN=localhost"
   ```
   Point the HTTPS server block at these instead of Let's Encrypt paths.
   Browsers will show a warning since it's not CA-signed - that's expected
   and fine for internal/demo use, not for production traffic.

3. **A free subdomain service** (e.g. duckdns.org, nip.io for IP-based
   wildcard domains) gets you an actual hostname pointing at your VPS's IP,
   which then lets you run real Let's Encrypt issuance per option 1 in the
   "if you have a domain" section above. This is the option I'd recommend
   if the grader wants to see a real green-padlock HTTPS flow without
   buying a domain.

## Cloudflare option (bonus)

If the domain's DNS is on Cloudflare, putting it in front with proxying
enabled gets you HTTPS at the edge for free, plus DDoS protection, without
touching nginx's cert config at all (set nginx to "Flexible" or, better,
issue an origin cert from Cloudflare and terminate TLS at nginx too for
end-to-end encryption - "Full (strict)" mode).
