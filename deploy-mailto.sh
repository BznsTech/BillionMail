#!/usr/bin/env bash
# =============================================================================
# BillionMail — one-shot deploy for  https://mailto.run.place
#
# This server ALREADY runs three other projects behind a shared Nginx:
#   - twreed.online       (Next.js, systemd 'marketplace', port 3000)
#   - rkan.run.place      (Next.js, systemd 'rkan', port 3001)
#   - whatsadd.io         (Laravel + PHP-FPM + a Node/PM2 bridge on 3001)
# …plus a shared MariaDB (3306), Redis (6379), Nginx (80/443) and certbot.
#
# BillionMail is a Docker-Compose mail stack (Postfix, Dovecot, Rspamd,
# Roundcube, its OWN Postgres + Redis, and a Go admin panel). This script wires
# it onto mailto.run.place WITHOUT touching any of the above:
#
#   * The admin panel container is bound to 127.0.0.1 only (compose override),
#     so it NEVER competes with the host Nginx for 80/443.
#   * The existing host Nginx reverse-proxies mailto.run.place -> the panel.
#   * A Let's Encrypt cert is issued in webroot mode (certbot never rewrites the
#     other sites) and reused for mail TLS (Postfix/Dovecot).
#   * BillionMail's Postgres/Redis stay on loopback high-ports (25432/26379),
#     so the shared MariaDB/Redis are untouched.
#   * Only the standard mail ports (25/465/587/143/993/110/995) are opened
#     publicly — nothing else on the box uses them.
#
# USAGE (run from inside this project directory, as root):
#   sudo bash deploy-mailto.sh
#
# RE-RUNNABLE: every step is idempotent. Secrets are generated once (first run)
# and preserved on re-runs.
#
# PREREQUISITE you must do yourself first — point DNS at THIS server's IP:
#   A     mailto.run.place        -> <server IP>
#   A     mail.mailto.run.place   -> <server IP>
#   MX    mailto.run.place        -> mail.mailto.run.place  (priority 10)
# HTTPS issuance falls back gracefully if DNS is not ready yet.
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
DOMAIN="mailto.run.place"
WWW_DOMAIN="www.${DOMAIN}"
MAIL_HOSTNAME="mail.${DOMAIN}"        # MX / SMTP / IMAP TLS hostname
LE_EMAIL="rxeze.ca@gmail.com"         # Let's Encrypt expiry notices

# Desired loopback ports for the panel (auto-bumped if already taken). These are
# NEVER exposed publicly — the host Nginx proxies to them over 127.0.0.1.
WANT_HTTP_PORT="8080"
WANT_HTTPS_PORT="8443"

# Project directory = the directory this script lives in.
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${APP_DIR}/.env"
WEBROOT="/var/www/certbot"
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

# Mail ports that MUST be free & public for a working mail server.
MAIL_PORTS=(25 465 587 143 993 110 995)

# --- Helpers -----------------------------------------------------------------
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

gen()  { LC_ALL=C </dev/urandom tr -dc 'A-Za-z0-9' 2>/dev/null | head -c "${1:-32}"; }

# True if anything is LISTENing on the given TCP port (any interface).
port_in_use() { ss -ltnH 2>/dev/null | grep -qE "[:.]${1}[[:space:]]"; }

# Read KEY's value from .env (empty if absent).
get_env() { [ -f "$ENV_FILE" ] && sed -nE "s/^${1}=//p" "$ENV_FILE" | head -1 || true; }

# Set or replace KEY=VALUE in .env (idempotent, value written verbatim/unquoted
# to match BillionMail's env format).
set_env() {
  local key="$1" val="$2"
  [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    grep -vE "^${key}=" "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
}

# Echo the first free TCP port at/after $1 (used for the loopback panel ports).
free_port_from() { local p="$1"; while port_in_use "$p"; do p=$((p + 1)); done; echo "$p"; }

# --- Preflight ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Please run with sudo:  sudo bash deploy-mailto.sh"
command -v apt-get >/dev/null 2>&1 || die "This script targets Ubuntu/Debian (apt-get not found)."
[ -f "${APP_DIR}/docker-compose.yml" ] || die "docker-compose.yml not found in ${APP_DIR} — run from the project folder."
[ -f "${APP_DIR}/env_init" ]            || die "env_init not found in ${APP_DIR} — is this the BillionMail repo?"

log "Deploying '${DOMAIN}' from ${APP_DIR}"

# --- 1. Base host packages (idempotent; these are mostly already present) -----
log "Ensuring base packages (nginx, certbot, openssl, ufw, curl)"
export DEBIAN_FRONTEND=noninteractive
# --allow-releaseinfo-change: a pre-existing 3rd-party repo on this box (the
# ondrej/php PPA from the whatsadd deploy) changed its Label, which otherwise
# makes apt refuse to update. Non-fatal: the packages below are likely already
# installed, so a flaky index refresh must not abort the whole deploy.
apt-get update -y -qq --allow-releaseinfo-change || warn "apt-get update reported issues — continuing"
# Installing already-present packages is a no-op and does NOT restart nginx.
apt-get install -y -qq ca-certificates curl openssl nginx ufw certbot python3-certbot-nginx >/dev/null \
  || die "Failed to install base packages. Run 'apt-get update' manually to see the underlying error, then re-run."

# --- 2. Docker (install only if missing; never disturb an existing engine) ----
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  log "Docker already installed and running — leaving it untouched"
else
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker via the official convenience script"
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
  docker info >/dev/null 2>&1 || die "Docker installed but the daemon is not running. Check: systemctl status docker"
fi

# Resolve the compose command (plugin preferred).
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "Docker Compose not found. The get.docker.com script normally installs the plugin — re-run, or install docker-compose-plugin."
fi
log "Using compose command: ${DC}"

# --- 3. Mail-port preflight (skip if our stack is already up) ----------------
# Mail ports must be the standard ones to be useful, so we refuse to remap them.
# On a re-run our own containers already hold them via docker-proxy — that's
# fine, so only enforce this on a first install.
BM_RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^billionmail-' || true)"
if [ "${BM_RUNNING}" = "0" ]; then
  busy=()
  for p in "${MAIL_PORTS[@]}"; do port_in_use "$p" && busy+=("$p"); done
  if [ "${#busy[@]}" -gt 0 ]; then
    warn "These required mail ports are already in use: ${busy[*]}"
    ss -ltnp 2>/dev/null | grep -E "[:.]($(IFS='|'; echo "${busy[*]}"))[[:space:]]" || true
    die "Free the port(s) above (no other mail server should run here) and re-run."
  fi
  log "All mail ports (${MAIL_PORTS[*]}) are free."
else
  log "BillionMail containers already running — skipping mail-port preflight (re-run)."
fi

# --- 4. .env: config + secrets ----------------------------------------------
FIRST_RUN=0
if [ ! -f "${ENV_FILE}" ]; then
  log "Creating .env from env_init"
  cp "${APP_DIR}/env_init" "${ENV_FILE}"
  FIRST_RUN=1
else
  log ".env already exists — preserving existing secrets"
fi

# Pick loopback panel ports: reuse what's already in .env if valid, else choose
# the first free ports at/after the desired ones. (Never moves on a re-run.)
CUR_HTTP="$(get_env HTTP_PORT)"
CUR_HTTPS="$(get_env HTTPS_PORT)"
case "${CUR_HTTP}" in ''|80|443) HTTP_PORT="$(free_port_from "${WANT_HTTP_PORT}")";; *) HTTP_PORT="${CUR_HTTP}";; esac
case "${CUR_HTTPS}" in ''|80|443) HTTPS_PORT="$(free_port_from "${WANT_HTTPS_PORT}")";; *) HTTPS_PORT="${CUR_HTTPS}";; esac
[ "${HTTPS_PORT}" = "${HTTP_PORT}" ] && HTTPS_PORT="$(free_port_from "$((HTTP_PORT + 1))")"

# Secrets: generate ONCE, on first run only (they get baked into the DB/redis
# volumes on first boot — regenerating later would break auth).
if [ "${FIRST_RUN}" = "1" ]; then
  log "Generating first-run secrets (admin password, DB/Redis passwords, safe path)"
  set_env DBNAME          "billionmail"
  set_env DBUSER          "billionmail"
  set_env DBPASS          "$(gen 32)"
  set_env REDISPASS       "$(gen 32)"
  set_env ADMIN_USERNAME  "admin"
  set_env ADMIN_PASSWORD  "$(gen 16)"
  set_env SafePath        "$(gen 10)"
fi

# Always-enforced settings (safe to rewrite on every run).
set_env BILLIONMAIL_HOSTNAME "${MAIL_HOSTNAME}"
set_env HTTP_PORT            "${HTTP_PORT}"
set_env HTTPS_PORT           "${HTTPS_PORT}"
set_env WEB_BASE_PATH        ""
# Keep BillionMail's own Postgres/Redis on loopback high-ports (no clash with
# the host's shared MariaDB:3306 / Redis:6379).
set_env SQL_PORT             "127.0.0.1:25432"
set_env REDIS_PORT           "127.0.0.1:26379"

SAFE_PATH="$(get_env SafePath)"
ADMIN_USER="$(get_env ADMIN_USERNAME)"
ADMIN_PASS="$(get_env ADMIN_PASSWORD)"

# --- 5. Compose override: bind the panel to loopback only --------------------
# Without this the 'core' container would publish HTTP_PORT/HTTPS_PORT on ALL
# interfaces (Docker bypasses ufw), exposing the panel and clashing with the
# host Nginx. `!override` replaces the base 'ports' list rather than appending.
log "Writing docker-compose.override.yml (panel bound to 127.0.0.1)"
cat > "${APP_DIR}/docker-compose.override.yml" <<YAML
# Managed by deploy-mailto.sh — do not edit by hand.
# Confines the BillionMail admin panel to loopback so the host Nginx can
# reverse-proxy ${DOMAIN} to it without competing for ports 80/443.
name: billionmail
services:
  core-billionmail:
    ports: !override
      - "127.0.0.1:${HTTP_PORT}:${HTTP_PORT}"
      - "127.0.0.1:${HTTPS_PORT}:${HTTPS_PORT}"
YAML

# --- 6. Self-signed fallback certs (so mail daemons can boot pre-LE) ----------
mkdir -p "${APP_DIR}/ssl" "${APP_DIR}/ssl-self-signed"
if [ ! -f "${APP_DIR}/ssl/cert.pem" ] || [ ! -f "${APP_DIR}/ssl/key.pem" ]; then
  log "Generating a temporary self-signed cert for the mail daemons"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "${APP_DIR}/ssl-self-signed/key.pem" \
    -out    "${APP_DIR}/ssl-self-signed/cert.pem" \
    -subj "/CN=${MAIL_HOSTNAME}" >/dev/null 2>&1
  cp "${APP_DIR}/ssl-self-signed/cert.pem" "${APP_DIR}/ssl/cert.pem"
  cp "${APP_DIR}/ssl-self-signed/key.pem"  "${APP_DIR}/ssl/key.pem"
fi

# --- 7. Bring up the stack ---------------------------------------------------
log "Pulling images and starting the stack (${DC} up -d)"
( cd "${APP_DIR}" && ${DC} pull && ${DC} up -d )

# SAFETY NET: verify the panel ports did NOT end up bound to a public interface.
sleep 2
if ss -ltnH 2>/dev/null | grep -qE "(0\.0\.0\.0|\*|\[::\]):(${HTTP_PORT}|${HTTPS_PORT})[[:space:]]"; then
  ( cd "${APP_DIR}" && ${DC} down ) || true
  die "Panel ports ${HTTP_PORT}/${HTTPS_PORT} were exposed publicly — aborted and took the stack down.
  Your Docker Compose may be too old for the '!override' tag. Upgrade docker-compose-plugin and re-run."
fi
log "Panel confirmed bound to 127.0.0.1 only."

# Smoke test: wait for the panel to answer on the loopback HTTP port.
log "Waiting for the panel on 127.0.0.1:${HTTP_PORT}"
panel_up=0
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${HTTP_PORT}/" || true)"
  [ -n "${code}" ] && [ "${code}" != "000" ] && { panel_up=1; break; }
  sleep 1
done
if [ "${panel_up}" = "1" ]; then
  log "Panel is serving on 127.0.0.1:${HTTP_PORT}."
else
  warn "Panel did not answer yet. Recent core logs:"
  ( cd "${APP_DIR}" && ${DC} logs --tail 40 core-billionmail ) || true
  warn "Continuing to configure Nginx — check '${DC} logs core-billionmail' if the site 502s."
fi

# --- 8. Nginx reverse proxy (HTTP first, so ACME + site work immediately) ----
log "Configuring Nginx for ${DOMAIN} (other sites left untouched)"
mkdir -p "${WEBROOT}"

write_nginx_http_only() {
  cat > "${NGINX_SITE}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${WWW_DOMAIN} ${MAIL_HOSTNAME};

    client_max_body_size 128m;

    location /.well-known/acme-challenge/ { root ${WEBROOT}; }

    location / {
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
    }
}
NGINX
}

write_nginx_https() {
  cat > "${NGINX_SITE}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${WWW_DOMAIN} ${MAIL_HOSTNAME};
    location /.well-known/acme-challenge/ { root ${WEBROOT}; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN} ${WWW_DOMAIN} ${MAIL_HOSTNAME};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff"    always;

    client_max_body_size 128m;

    location /.well-known/acme-challenge/ { root ${WEBROOT}; }

    location / {
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300;
    }
}
NGINX
}

# If a cert already exists (re-run), go straight to HTTPS; else HTTP-only first.
if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
  write_nginx_https
else
  write_nginx_http_only
fi
ln -sf "${NGINX_SITE}" "${NGINX_LINK}"
# Validate the WHOLE config (incl. the other sites) before reloading gracefully.
nginx -t || die "nginx -t failed — NOT reloading (other sites protected). Fix the error above."
systemctl reload nginx
log "Nginx reverse proxy is live over HTTP."

# --- 9. HTTPS via Let's Encrypt (webroot; never rewrites the other sites) ----
if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
  log "Requesting a Let's Encrypt certificate (webroot mode)"
  got_cert=0
  if certbot certonly --webroot -w "${WEBROOT}" \
       -d "${DOMAIN}" -d "${WWW_DOMAIN}" -d "${MAIL_HOSTNAME}" \
       --non-interactive --agree-tos -m "${LE_EMAIL}"; then
    got_cert=1
  else
    warn "Cert for all three names failed (usually DNS not ready) — retrying with ${DOMAIN} only"
    if certbot certonly --webroot -w "${WEBROOT}" \
         -d "${DOMAIN}" \
         --non-interactive --agree-tos -m "${LE_EMAIL}"; then
      got_cert=1
    fi
  fi

  if [ "${got_cert}" = "1" ]; then
    write_nginx_https
    nginx -t && systemctl reload nginx
    log "HTTPS is live for ${DOMAIN}."
  else
    warn "Could not obtain an HTTPS certificate yet. The site works over HTTP."
    warn "Once DNS for ${DOMAIN} / ${MAIL_HOSTNAME} points here, re-run this script."
  fi
fi

# --- 10. Reuse the LE cert for mail TLS + auto-renew hook ---------------------
LIVE="/etc/letsencrypt/live/${DOMAIN}"
if [ -f "${LIVE}/fullchain.pem" ]; then
  log "Installing the LE cert for mail TLS (Postfix/Dovecot) + renewal hook"
  install -m 644 "${LIVE}/fullchain.pem" "${APP_DIR}/ssl/cert.pem"
  install -m 600 "${LIVE}/privkey.pem"   "${APP_DIR}/ssl/key.pem"
  ( cd "${APP_DIR}" && ${DC} restart postfix-billionmail dovecot-billionmail ) >/dev/null 2>&1 || true

  HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
  mkdir -p "${HOOK_DIR}"
  cat > "${HOOK_DIR}/billionmail-${DOMAIN}.sh" <<HOOK
#!/usr/bin/env bash
# Auto-generated by deploy-mailto.sh — refresh mail TLS after cert renewal.
set -e
DOMAIN="${DOMAIN}"
APP_DIR="${APP_DIR}"
# Only act when it is OUR lineage that renewed.
case "\${RENEWED_LINEAGE:-}" in */\${DOMAIN}) ;; *) exit 0 ;; esac
install -m 644 "\${RENEWED_LINEAGE}/fullchain.pem" "\${APP_DIR}/ssl/cert.pem"
install -m 600 "\${RENEWED_LINEAGE}/privkey.pem"   "\${APP_DIR}/ssl/key.pem"
cd "\${APP_DIR}" && ${DC} restart postfix-billionmail dovecot-billionmail >/dev/null 2>&1 || true
systemctl reload nginx >/dev/null 2>&1 || true
HOOK
  chmod +x "${HOOK_DIR}/billionmail-${DOMAIN}.sh"
fi

# --- 11. Firewall (only if ufw is active) ------------------------------------
if ufw status 2>/dev/null | grep -q "Status: active"; then
  log "Opening firewall for mail + web + SSH"
  ufw allow OpenSSH        >/dev/null 2>&1 || true
  ufw allow 'Nginx Full'   >/dev/null 2>&1 || true
  for p in "${MAIL_PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
fi

# --- 12. Convenience: bm CLI symlink -----------------------------------------
if [ -f "${APP_DIR}/bm.sh" ]; then
  chmod +x "${APP_DIR}/bm.sh"
  ln -sf "${APP_DIR}/bm.sh" /usr/bin/bm
fi

# --- Done --------------------------------------------------------------------
SERVER_IP="$(curl -s4 --max-time 8 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
SCHEME="https"; [ -f "${LIVE}/fullchain.pem" ] || SCHEME="http"

log "Deployment complete!"
cat <<SUMMARY

  ┌─────────────────────────────────────────────────────────────────┐
   BillionMail is deployed on ${DOMAIN}
  └─────────────────────────────────────────────────────────────────┘

  Admin panel : ${SCHEME}://${DOMAIN}/${SAFE_PATH}
                (the /${SAFE_PATH} "safe entrance" must be visited first)
  Username    : ${ADMIN_USER}
  Password    : ${ADMIN_PASS}

  Mail host   : ${MAIL_HOSTNAME}
  Manage      : bm status   |   bm help          (BillionMail CLI)
  Logs        : cd ${APP_DIR} && ${DC} logs -f core-billionmail

  DNS records to set (at your DNS provider), pointing at ${SERVER_IP}:
    A     ${DOMAIN}          ${SERVER_IP}
    A     ${MAIL_HOSTNAME}   ${SERVER_IP}
    MX    ${DOMAIN}          ${MAIL_HOSTNAME}  (priority 10)
    TXT   ${DOMAIN}          "v=spf1 mx ~all"
  Then add the domain in the panel to generate DKIM + DMARC records.

  Coexistence: twreed.online, rkan.run.place and whatsadd.io — plus the
  shared Nginx, MariaDB and Redis — were left completely untouched.

SUMMARY
[ "${SCHEME}" = "http" ] && warn "HTTPS not yet issued — set DNS, then re-run: sudo bash deploy-mailto.sh"
echo
