#!/usr/bin/env bash
# AIRL workshop page (airl-workshop.web.app) -> own VPS. Install or update.
#
#   bash install.sh                              site on http://<server IP>
#   bash install.sh --domain server.airl.kz      site on https://<domain> (A record must point here)
#
# Web server: if nginx already runs on this machine, the page is added to it as
# one more site (own config file, checked with nginx -t, other sites untouched,
# certificate from Let's Encrypt via certbot). Otherwise Caddy is installed.
#
# Options
#   --domain NAME     domain for HTTPS (free Let's Encrypt certificate)
#   --force-domain    skip the check that the domain already points to this server
#   --refresh-site    download the page again (after it was changed on Firebase)
#   --source URL      page to copy (default https://airl-workshop.web.app)
#   --from-dir PATH   use a local build folder (dist/) instead of downloading
#   --no-forward      stop sending a copy of each lead to the Google Sheet
#   --forward         send copies again
#   --whatsapp NUM    after the form, open WhatsApp chat with this number (lead prefilled)
#   --no-whatsapp     turn that WhatsApp step off
#   --telegram        connect a Telegram channel for leads (asks for the bot token here)
#   --no-telegram     stop posting leads to Telegram
#   --page-url URL    the page itself lives elsewhere (e.g. https://airl.kz/ai-for-work/workshop/):
#                     visitors of this server are sent there; /api and /admin keep working here
#   --serve-page      serve the page from this server again (undo --page-url)
#
# Safe to run again: leads, admin password and settings are kept.
set -Eeuo pipefail

BASE=/opt/airl-workshop
ENV_FILE=/etc/airl-workshop.env
SVC_USER=airl-workshop
SOURCE="https://airl-workshop.web.app"
DOMAIN=""
FORCE_DOMAIN=0
FROM_DIR=""
REFRESH=0
FORWARD_FLAG=""
WA_FLAG=""
PAGE_FLAG=""
TG_FLAG=""

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36m→\033[0m %s\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
trap '[ "$BASH_SUBSHELL" -gt 0 ] && exit 1; die "Stopped at line $LINENO. Nothing was deleted; fix the problem above and run the script again."' ERR

need_value() { [ -n "${2:-}" ] && [ "${2#--}" = "$2" ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)       need_value "$1" "${2:-}"; DOMAIN="$2"; shift 2 ;;
    --force-domain) FORCE_DOMAIN=1; shift ;;
    --refresh-site) REFRESH=1; shift ;;
    --source)       need_value "$1" "${2:-}"; SOURCE="$2"; shift 2 ;;
    --from-dir)     need_value "$1" "${2:-}"; FROM_DIR="$2"; shift 2 ;;
    --no-forward)   FORWARD_FLAG=0; shift ;;
    --forward)      FORWARD_FLAG=1; shift ;;
    --whatsapp)     need_value "$1" "${2:-}"; WA_FLAG="$2"; shift 2 ;;
    --no-whatsapp)  WA_FLAG="off"; shift ;;
    --telegram)     TG_FLAG=setup; shift ;;
    --no-telegram)  TG_FLAG=off; shift ;;
    --page-url)     need_value "$1" "${2:-}"; PAGE_FLAG="$2"; shift 2 ;;
    --serve-page)   PAGE_FLAG=off; shift ;;
    -h|--help)      sed -n '2,29p' "$0"; exit 0 ;;
    *)              die "Unknown option: $1 (see --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root (or with sudo)."

get_env() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

# ------------------------------------------------------------ packages ----
if command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf >/dev/null 2>&1; then PM=dnf
else die "Supported systems: Ubuntu / Debian (apt) or RHEL / Alma / Rocky (dnf)."
fi

info "Installing base packages"
if [ "$PM" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3 curl ca-certificates gnupg >/dev/null
  apt-get install -y -qq sqlite3 >/dev/null 2>&1 || true
else
  dnf install -y -q python3 curl ca-certificates gnupg2 >/dev/null
  dnf install -y -q sqlite >/dev/null 2>&1 || true
fi
PY="$(command -v python3)"
"$PY" -c 'import sys, sqlite3; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
  || die "Python 3.8+ with sqlite3 is required (found $("$PY" -V 2>&1))."
ok "Python $("$PY" -c 'import platform; print(platform.python_version())')"

# ------------------------------------------------------ user and files ----
if ! id -u "$SVC_USER" >/dev/null 2>&1; then
  NOLOGIN="$(command -v nologin || echo /bin/false)"
  useradd --system --home-dir "$BASE" --no-create-home --shell "$NOLOGIN" "$SVC_USER"
fi
install -d -m 755 "$BASE" "$BASE/app"
install -d -m 700 -o "$SVC_USER" -g "$SVC_USER" "$BASE/data" "$BASE/backups"

cat > "$BASE/app/app.py" <<'AIRL_APP_PY_EOF'
@@APP_PY@@
AIRL_APP_PY_EOF

cat > "$BASE/app/sitetool.py" <<'AIRL_SITETOOL_PY_EOF'
@@SITETOOL_PY@@
AIRL_SITETOOL_PY_EOF
chmod 755 "$BASE/app/app.py" "$BASE/app/sitetool.py"

cat > /usr/local/bin/airl-workshop <<EOF
#!/bin/sh
# Run backend commands as the service user: airl-workshop stats | backup | import FILE.csv
set -a; . $ENV_FILE; set +a
if [ "\${1:-}" = import ] && [ -n "\${2:-}" ]; then
  tmp=\$(mktemp); cp "\$2" "\$tmp"; chmod 644 "\$tmp"
  runuser -u $SVC_USER -- $PY $BASE/app/app.py import "\$tmp"; rc=\$?; rm -f "\$tmp"; exit \$rc
fi
exec runuser -u $SVC_USER -- $PY $BASE/app/app.py "\$@"
EOF
chmod 755 /usr/local/bin/airl-workshop
ok "Backend code in $BASE/app"

# ------------------------------------------------------- copy the page ----
MIRROR="$BASE/mirror"
swap_dir() {  # swap_dir NEW TARGET  (keeps TARGET.old as the previous version)
  rm -rf "$2.old"
  if [ -d "$2" ]; then mv "$2" "$2.old"; fi
  mv "$1" "$2"
}
if [ -n "$FROM_DIR" ]; then
  [ -f "$FROM_DIR/index.html" ] || die "$FROM_DIR has no index.html"
  rm -rf "$MIRROR.new"
  cp -a "$FROM_DIR" "$MIRROR.new"
  swap_dir "$MIRROR.new" "$MIRROR"
  ok "Page taken from $FROM_DIR"
elif [ ! -f "$MIRROR/index.html" ] || [ "$REFRESH" = 1 ]; then
  info "Copying the page from $SOURCE"
  rm -rf "$MIRROR.new"
  STATS="$("$PY" "$BASE/app/sitetool.py" mirror --source "$SOURCE" --out "$MIRROR.new")"
  swap_dir "$MIRROR.new" "$MIRROR"
  ok "Page copied: $STATS"
else
  ok "Page already copied earlier (use --refresh-site to download it again)"
fi
REWRITE_SRC="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' \
  "$MIRROR/.mirror.json" 2>/dev/null || echo "$SOURCE")"

# ------------------------------------------------------- address / DNS ----
PUBLIC_IP="$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
fi
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[ -n "$PUBLIC_IP" ] || die "Could not detect this server's IP address."

[ -n "$DOMAIN" ] || DOMAIN="$(get_env SITE_DOMAIN)"
DOMAIN="$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##')"
if [ -n "$DOMAIN" ]; then
  printf '%s' "$DOMAIN" | grep -Eq '^([a-z0-9-]+\.)+[a-z]{2,}$' || die "Not a valid domain: $DOMAIN"
  if [ "$FORCE_DOMAIN" != 1 ]; then
    # system resolver + two public resolvers (a fresh record may still be cached as missing locally)
    RESOLVED="$({ getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}';
      "$PY" - "$DOMAIN" 2>/dev/null <<'PYDNS'
import json, sys, urllib.request
for url in ("https://cloudflare-dns.com/dns-query?name=%s&type=A", "https://dns.google/resolve?name=%s&type=A"):
    try:
        req = urllib.request.Request(url % sys.argv[1], headers={"accept": "application/dns-json"})
        for a in json.load(urllib.request.urlopen(req, timeout=6)).get("Answer", []):
            if a.get("type") == 1:
                print(a["data"])
    except Exception:
        pass
PYDNS
    } | sort -u | tr '\n' ' ' || true)"
    if ! printf ' %s ' "$RESOLVED" | grep -q " $PUBLIC_IP "; then
      warn "$DOMAIN points to '${RESOLVED:-nothing}', but this server is $PUBLIC_IP."
      warn "Setting the site up on the IP for now. Add a DNS A record: $DOMAIN -> $PUBLIC_IP,"
      warn "wait 5-30 minutes and run:  bash install.sh --domain $DOMAIN"
      DOMAIN=""
    fi
  fi
fi
if [ -n "$DOMAIN" ]; then BASE_URL="https://$DOMAIN"; else BASE_URL="http://$PUBLIC_IP"; fi

# ------------------------------------------------- build the served page ----
info "Pointing the form at this server"
if [ "$WA_FLAG" = off ]; then WA_NUM=""
elif [ -n "$WA_FLAG" ]; then WA_NUM="$WA_FLAG"
else WA_NUM="$(get_env SITE_WHATSAPP)"; fi
BUILD_JSON="$("$PY" "$BASE/app/sitetool.py" build --mirror "$MIRROR" --out "$BASE/site.new" \
  --base-url "$BASE_URL" --source "$REWRITE_SRC" --whatsapp "$WA_NUM")"
WA_NUM="$(printf '%s' "$BUILD_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("whatsapp") or "")')"
FOUND_FORWARD="$(printf '%s' "$BUILD_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["forward_url"])')"
chmod -R a+rX "$BASE/site.new"
swap_dir "$BASE/site.new" "$BASE/site"
ok "Form now sends leads to $BASE_URL/api/lead"
if [ -n "$WA_NUM" ]; then ok "After the form, the page opens WhatsApp chat with +$WA_NUM"; fi
if [ "$PAGE_FLAG" = off ]; then PAGE_URL=""
elif [ -n "$PAGE_FLAG" ]; then PAGE_URL="$PAGE_FLAG"
else PAGE_URL="$(get_env SITE_PAGE_URL)"; fi
if [ -n "$PAGE_URL" ]; then
  printf '%s' "$PAGE_URL" | grep -Eq '^https?://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$' || die "Not a valid page address: $PAGE_URL"
  case "$PAGE_URL" in */) ;; *) PAGE_URL="$PAGE_URL/" ;; esac
  ok "Visitors of this server will be sent to $PAGE_URL (form and admin stay here)"
fi

# ------------------------------------------------------------ Telegram ----
TG_TOKEN="$(get_env TELEGRAM_BOT_TOKEN)"
TG_CHAT="$(get_env TELEGRAM_CHAT_ID)"
if [ "$TG_FLAG" = off ]; then
  TG_TOKEN=""; TG_CHAT=""
elif [ "$TG_FLAG" = setup ]; then
  info "Connecting the Telegram channel"
  TG_TMP="$(mktemp)"
  if "$PY" "$BASE/app/app.py" telegram-setup "$TG_TMP"; then
    TG_TOKEN="$(sed -n 1p "$TG_TMP")"; TG_CHAT="$(sed -n 2p "$TG_TMP")"
    ok "Telegram channel connected"
  else
    warn "Telegram was not connected; everything else continues. Run again with --telegram to retry."
  fi
  rm -f "$TG_TMP"
fi

# --------------------------------------------------------- backend port ----
# Other apps may already listen on local ports, so take the first free one.
systemctl stop airl-workshop.service >/dev/null 2>&1 || true
PORT="$(get_env PORT)"; PORT="${PORT:-8787}"
if command -v ss >/dev/null 2>&1; then
  for p in "$PORT" $(seq 8787 8899); do
    if [ -z "$(ss -ltnH "( sport = :$p )" 2>/dev/null)" ]; then PORT="$p"; break; fi
  done
fi

# ------------------------------------------------------------ settings ----
ADMIN_PW="$(get_env ADMIN_PASSWORD)"
NEW_PW=0
if [ -z "$ADMIN_PW" ]; then
  ADMIN_PW="$("$PY" -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(20)))')"
  NEW_PW=1
fi
ADMIN_USER="$(get_env ADMIN_USER)"; ADMIN_USER="${ADMIN_USER:-admin}"
FWD_ENABLED="${FORWARD_FLAG:-$(get_env FORWARD_ENABLED)}"; FWD_ENABLED="${FWD_ENABLED:-1}"
OTHER_LINES=""
if [ -f "$ENV_FILE" ]; then
  OTHER_LINES="$(grep -vE '^(#|$|ADMIN_USER=|ADMIN_PASSWORD=|FORWARD_URL=|FORWARD_ENABLED=|SITE_DOMAIN=|SITE_WHATSAPP=|SITE_PAGE_URL=|TELEGRAM_BOT_TOKEN=|TELEGRAM_CHAT_ID=|HOST=|PORT=|DATA_DIR=|BACKUP_DIR=)' "$ENV_FILE" || true)"
fi
umask 077
cat > "$ENV_FILE" <<EOF
# AIRL workshop backend settings. After editing: systemctl restart airl-workshop
ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PW
# Copy of every lead to the Google Sheet (the old Apps Script). 1 = on, 0 = off
FORWARD_ENABLED=$FWD_ENABLED
FORWARD_URL=$FOUND_FORWARD
# Telegram channel for leads (set up with: bash install.sh --telegram)
TELEGRAM_BOT_TOKEN=$TG_TOKEN
TELEGRAM_CHAT_ID=$TG_CHAT
# Page settings
SITE_DOMAIN=$DOMAIN
SITE_WHATSAPP=$WA_NUM
# Where the page itself lives; empty = served by this server
SITE_PAGE_URL=$PAGE_URL
HOST=127.0.0.1
PORT=$PORT
DATA_DIR=$BASE/data
BACKUP_DIR=$BASE/backups
EOF
[ -z "$OTHER_LINES" ] || printf '%s\n' "$OTHER_LINES" >> "$ENV_FILE"
umask 022
chmod 600 "$ENV_FILE"

# ------------------------------------------------------------- services ----
cat > /etc/systemd/system/airl-workshop.service <<EOF
[Unit]
Description=AIRL workshop page backend (lead form and admin)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$ENV_FILE
Environment=PYTHONUNBUFFERED=1
ExecStart=$PY $BASE/app/app.py serve
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$BASE/data $BASE/backups
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/airl-workshop-backup.service <<EOF
[Unit]
Description=Backup of AIRL workshop leads

[Service]
Type=oneshot
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$ENV_FILE
ExecStart=$PY $BASE/app/app.py backup
EOF

cat > /etc/systemd/system/airl-workshop-backup.timer <<EOF
[Unit]
Description=Daily backup of AIRL workshop leads

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
if [ -f "$BASE/data/leads.db" ]; then
  systemctl start airl-workshop-backup.service && ok "Backup taken before the update"
fi
systemctl enable --quiet airl-workshop.service airl-workshop-backup.timer
systemctl restart airl-workshop.service
systemctl start airl-workshop-backup.timer
for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -fsS --max-time 3 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 \
  || die "Backend did not start. See: journalctl -u airl-workshop -n 50"
ok "Backend running (systemd: airl-workshop)"

# ----------------------------------------------------------- nginx path ----
# Used when nginx already serves other sites here. Everything for this page
# lives in ONE file; it is checked with nginx -t and rolled back on any error,
# so the other sites are never affected.
NGINX_ACME=/var/lib/airl-workshop-acme
HDRS='add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header X-Frame-Options SAMEORIGIN always;'

nginx_site_body() {
  cat <<EOF
    root $BASE/site;
    index index.html;
    client_max_body_size 64k;
    server_tokens off;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    $HDRS

    location /.well-known/acme-challenge/ { root $NGINX_ACME; }

    location /api/ {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location ~ ^/admin(/|\$) {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
  if [ -n "$PAGE_URL" ]; then
    cat <<EOF
    location / { return 301 $PAGE_URL\$is_args\$args; }
EOF
  else
    cat <<EOF
    location /assets/ {
        $HDRS
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        try_files \$uri =404;
    }
    location = / {
        $HDRS
        add_header Cache-Control "no-cache" always;
        try_files /index.html =404;
    }
    location / { try_files \$uri =404; }
    error_page 404 /404.html;
    location = /404.html { internal; }
EOF
  fi
}

nginx_listen() {  # nginx_listen PORT [ssl]
  echo "    listen $1${2:+ $2};"
  if [ "$NGINX_V6" = 1 ]; then echo "    listen [::]:$1${2:+ $2};"; fi
}

nginx_write_conf() {  # nginx_write_conf http|https NAME
  {
    echo "# AIRL workshop page. Generated by install.sh; rerun the script instead of editing."
    if [ "$1" = https ]; then
      cat <<EOF
server {
$(nginx_listen 80)
    server_name $2;
    location /.well-known/acme-challenge/ { root $NGINX_ACME; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
$(nginx_listen 443 ssl)
    server_name $2;
    ssl_certificate     /etc/letsencrypt/live/$2/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$2/privkey.pem;
EOF
      if [ -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
        echo "    include /etc/letsencrypt/options-ssl-nginx.conf;"
      else
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
      fi
      nginx_site_body
      echo "}"
    else
      cat <<EOF
server {
$(nginx_listen 80)
    server_name $2;
EOF
      nginx_site_body
      echo "}"
    fi
  } > "$NGINX_CONF.new"

  [ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "$NGINX_CONF.prev"
  mv "$NGINX_CONF.new" "$NGINX_CONF"
  [ -z "$NGINX_LINK" ] || ln -sf "$NGINX_CONF" "$NGINX_LINK"
  if ! nginx -t >/tmp/airl-nginx-test.log 2>&1; then
    local what
    if [ -f "$NGINX_CONF.prev" ]; then
      mv "$NGINX_CONF.prev" "$NGINX_CONF"; what="its previous config was restored"
    else
      rm -f "$NGINX_CONF"; [ -z "$NGINX_LINK" ] || rm -f "$NGINX_LINK"; what="its config was removed again"
    fi
    cat /tmp/airl-nginx-test.log >&2
    die "nginx config check failed (see above), so nothing was reloaded: $what and the other sites were not touched."
  fi
  rm -f "$NGINX_CONF.prev" /tmp/airl-nginx-test.log
  systemctl reload nginx
}

setup_nginx() {
  ok "nginx $(nginx -v 2>&1 | sed 's#.*/##') already runs here; adding the page as one more site"
  local dump
  dump="$(nginx -T 2>/dev/null || true)"
  if [ -d /etc/nginx/sites-enabled ] && printf '%s' "$dump" | grep -q 'include /etc/nginx/sites-enabled/'; then
    NGINX_CONF=/etc/nginx/sites-available/airl-workshop.conf
    NGINX_LINK=/etc/nginx/sites-enabled/airl-workshop.conf
  else
    NGINX_CONF=/etc/nginx/conf.d/airl-workshop.conf
    NGINX_LINK=""
  fi
  NGINX_V6=0
  if printf '%s' "$dump" | grep -Eq '^[[:space:]]*listen[[:space:]]+\[::\]'; then NGINX_V6=1; fi
  install -d -m 755 "$NGINX_ACME"

  if [ -z "$DOMAIN" ]; then
    nginx_write_conf http "$PUBLIC_IP"
    SCHEME=http
    ok "nginx site added for http://$PUBLIC_IP ($NGINX_CONF)"
    return 0
  fi

  local cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  if [ ! -f "$cert" ]; then
    nginx_write_conf http "$DOMAIN"          # serve the ACME challenge over plain HTTP first
    if ! command -v certbot >/dev/null 2>&1; then
      info "Installing certbot (Let's Encrypt)"
      if [ "$PM" = apt ]; then apt-get install -y -qq certbot >/dev/null; else dnf install -y -q certbot >/dev/null; fi
    fi
    info "Getting an HTTPS certificate for $DOMAIN"
    if certbot certonly --webroot -w "$NGINX_ACME" -d "$DOMAIN" --cert-name "$DOMAIN" \
         --non-interactive --agree-tos --register-unsafely-without-email \
         --deploy-hook "systemctl reload nginx" >/tmp/airl-certbot.log 2>&1; then
      ok "Certificate issued (renews automatically)"
    else
      tail -n 15 /tmp/airl-certbot.log >&2
      warn "Could not get a certificate yet; the page works on http://$DOMAIN. Run the script again later."
    fi
  fi
  if [ -f "$cert" ]; then
    nginx_write_conf https "$DOMAIN"
    SCHEME=https
  else
    SCHEME=http
  fi
  ok "nginx site added for $SCHEME://$DOMAIN ($NGINX_CONF)"
}

# ----------------------------------------------------------- Caddy path ----
# Used on a server without nginx.
setup_caddy() {
if ! command -v caddy >/dev/null 2>&1; then
  info "Installing Caddy (web server with automatic HTTPS)"
  if [ "$PM" = apt ]; then
    if curl -fsSL --max-time 30 https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
         | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
       && curl -fsSL --max-time 30 https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
         -o /etc/apt/sources.list.d/caddy-stable.list \
       && chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list \
       && apt-get update -qq && apt-get install -y -qq caddy >/dev/null; then
      :
    else
      warn "Official Caddy repository not reachable, using the system package"
      rm -f /etc/apt/sources.list.d/caddy-stable.list
      apt-get update -qq || true
      apt-get install -y -qq caddy >/dev/null || die "Could not install Caddy."
    fi
  else
    if ! { dnf install -y -q 'dnf-command(copr)' && dnf copr enable -y @caddy/caddy && dnf install -y -q caddy; } >/dev/null; then
      die "Could not install Caddy."
    fi
  fi
fi
ok "Caddy $(caddy version 2>/dev/null | awk '{print $1}')"

if command -v ss >/dev/null 2>&1; then
  BUSY="$(ss -ltnpH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v '"caddy"' \
          | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | tr '\n' ' ' || true)"
  [ -z "$BUSY" ] || die "Ports 80/443 are used by: $BUSY. Stop it (for example: systemctl disable --now nginx) and run the script again."
fi

install -d -m 755 /etc/caddy/sites
MAIN_CADDY=/etc/caddy/Caddyfile
IMPORT_LINE='import /etc/caddy/sites/*.caddy'
if ! grep -qF "$IMPORT_LINE" "$MAIN_CADDY" 2>/dev/null; then
  if [ -f "$MAIN_CADDY" ]; then cp "$MAIN_CADDY" "$MAIN_CADDY.bak.$(date +%Y%m%d%H%M%S)"; fi
  if [ ! -f "$MAIN_CADDY" ] || grep -q '/usr/share/caddy' "$MAIN_CADDY"; then
    printf '# Every site has its own file in /etc/caddy/sites/\n%s\n' "$IMPORT_LINE" > "$MAIN_CADDY"
  else
    warn "Keeping your existing $MAIN_CADDY and adding an import line to it"
    printf '\n%s\n' "$IMPORT_LINE" >> "$MAIN_CADDY"
  fi
fi

SITE_CADDY=/etc/caddy/sites/airl-workshop.caddy
[ -f "$SITE_CADDY" ] && cp "$SITE_CADDY" "$SITE_CADDY.prev"
{
  cat <<EOF
# AIRL workshop page. Generated by install.sh; rerun the script instead of editing.
(airl_workshop) {
	encode zstd gzip
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		X-Frame-Options SAMEORIGIN
		-Server
	}
	@backend path /api/* /admin /admin/*
	handle @backend {
		reverse_proxy 127.0.0.1:$PORT
	}
EOF
  if [ -n "$PAGE_URL" ]; then
    cat <<EOF
	handle {
		redir ${PAGE_URL}?{query} 301
	}
EOF
  else
    cat <<EOF
	handle {
		root * $BASE/site
		@assets path /assets/*
		header @assets Cache-Control "public, max-age=31536000, immutable"
		@page path / /index.html
		header @page Cache-Control "no-cache"
		file_server
	}
EOF
  fi
  cat <<EOF
	handle_errors {
		@notfound expression {err.status_code} == 404
		handle @notfound {
			root * $BASE/site
			rewrite * /404.html
			file_server
		}
	}
	log
}

EOF
  if [ -n "$DOMAIN" ]; then
    cat <<EOF
$DOMAIN {
	import airl_workshop
}

http://$PUBLIC_IP {
	redir https://$DOMAIN{uri} 302
}
EOF
  else
    cat <<EOF
:80 {
	import airl_workshop
}
EOF
  fi
} > "$SITE_CADDY"

if ! caddy validate --config "$MAIN_CADDY" --adapter caddyfile >/tmp/airl-caddy-validate.log 2>&1; then
  if [ -f "$SITE_CADDY.prev" ]; then mv "$SITE_CADDY.prev" "$SITE_CADDY"; else rm -f "$SITE_CADDY"; fi
  cat /tmp/airl-caddy-validate.log >&2
  die "Caddy config check failed; previous config restored."
fi
rm -f "$SITE_CADDY.prev" /tmp/airl-caddy-validate.log
systemctl enable --quiet caddy
if ! { systemctl is-active --quiet caddy && systemctl reload caddy; }; then
  systemctl restart caddy || die "Caddy did not start. See: journalctl -u caddy -n 50 --no-pager"
fi
ok "Caddy configured ($SITE_CADDY)"
if [ -n "$DOMAIN" ]; then SCHEME=https; else SCHEME=http; fi
}

# ----------------------------------------------------------- web server ----
SCHEME=http
if command -v nginx >/dev/null 2>&1 && { systemctl is-active --quiet nginx || systemctl is-enabled --quiet nginx; }; then
  WEB=nginx
  WEB_LOG="tail -n 50 /var/log/nginx/error.log"
  setup_nginx
else
  WEB=caddy
  WEB_LOG="journalctl -u caddy -n 50 --no-pager"
  setup_caddy
fi
[ -z "$DOMAIN" ] || BASE_URL="$SCHEME://$DOMAIN"

# ------------------------------------------------------------- firewall ----
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  { ufw allow 80/tcp && ufw allow 443/tcp; } >/dev/null || warn "Could not open ports 80/443 in ufw"
  ok "Ports 80 and 443 open in ufw"
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
  { firewall-cmd -q --permanent --add-service=http --add-service=https && firewall-cmd -q --reload; } \
    || warn "Could not open ports 80/443 in firewalld"
  ok "Ports 80 and 443 open in firewalld"
fi

# ------------------------------------------------------------ self-test ----
info "Checking the site"
TEST_BODY='name=Test&phone=%2B7+(700)+000-00-00&city=Test&website=selftest&page=selftest'
if [ -n "$DOMAIN" ]; then
  CURL=(curl -fsS --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" --resolve "$DOMAIN:80:127.0.0.1")
  URL="$SCHEME://$DOMAIN"
else
  CURL=(curl -fsS --max-time 10 -H "Host: $PUBLIC_IP")
  URL="http://127.0.0.1"
fi
PAGE_OK=0
for _ in $(seq 1 30); do
  if [ -n "$PAGE_URL" ]; then
    LOC="$("${CURL[@]}" -o /dev/null -w '%{redirect_url}' "$URL/?utm_source=selftest" 2>/dev/null || true)"
    if [ "$LOC" = "${PAGE_URL}?utm_source=selftest" ]; then PAGE_OK=1; break; fi
  elif "${CURL[@]}" "$URL/" 2>/dev/null | grep -q '<title>'; then PAGE_OK=1; break; fi
  sleep 3
done
if [ "$PAGE_OK" = 1 ]; then
  if [ -n "$PAGE_URL" ]; then ok "$BASE_URL sends visitors to $PAGE_URL (with their utm tags)"
  else ok "Page opens at $BASE_URL"; fi
  if "${CURL[@]}" -X POST -H 'Content-Type: application/x-www-form-urlencoded;charset=UTF-8' \
       --data "$TEST_BODY" "$URL/api/lead" 2>/dev/null | grep -q '"ok": true'; then
    ok "Form endpoint answers (test request, nothing saved)"
  else
    warn "Form endpoint did not answer as expected. See: journalctl -u airl-workshop -n 50"
  fi
else
  warn "The page did not open yet. If you just added the domain, the certificate may still be issuing:"
  warn "  $WEB_LOG"
fi
grep -lq '/api/lead' "$BASE"/site/assets/*.js 2>/dev/null || warn "Could not confirm the form was repointed"

# -------------------------------------------------------------- summary ----
FWD_STATE="on"; [ "$FWD_ENABLED" = 1 ] || FWD_STATE="off"
echo
printf '\033[1m%s\033[0m\n' "AIRL workshop page is on this server"
echo "  Site:            $BASE_URL"
echo "  Leads (admin):   $BASE_URL/admin"
echo "  Login:           $ADMIN_USER"
if [ "$NEW_PW" = 1 ]; then
  echo "  Password:        $ADMIN_PW   (save it; also stored in $ENV_FILE)"
else
  echo "  Password:        unchanged, see $ENV_FILE"
fi
echo "  Web server:      $WEB"
echo "  Google Sheet:    copy of each lead $FWD_STATE"
if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then TG_STATE="on (channel $TG_CHAT)"; else TG_STATE="off (connect with: bash install.sh --telegram)"; fi
echo "  Telegram:        $TG_STATE"
if [ -n "$WA_NUM" ]; then WA_STATE="after the form the page opens WhatsApp chat with +$WA_NUM"; else WA_STATE="off"; fi
echo "  WhatsApp:        $WA_STATE"
if [ -n "$PAGE_URL" ]; then echo "  Page:            $PAGE_URL (this server redirects there)"; fi
echo "  Database:        $BASE/data/leads.db, daily backups in $BASE/backups"
echo "  Logs:            journalctl -u airl-workshop -f"
echo "  Commands:        airl-workshop stats | backup | telegram-test | import old-leads.csv"
if [ -z "$DOMAIN" ]; then
  echo
  warn "No domain yet, so the admin page works over plain HTTP. Point a domain here and run:"
  warn "  bash install.sh --domain <your-domain>"
fi
