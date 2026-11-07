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
    -h|--help)      sed -n '2,26p' "$0"; exit 0 ;;
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
#!/usr/bin/env python3
"""
AIRL workshop landing: backend for the lead form + admin panel.

Python 3.8+ standard library only (no pip installs).

Endpoints
  POST /api/lead          form submission (same payload the page used to send
                          to Google Apps Script: name, phone, city, utm_*, page,
                          website = honeypot)
  GET  /api/health        liveness check
  GET  /admin             lead list (HTTP Basic auth)
  GET  /admin/leads.xlsx  Excel export
  GET  /admin/leads.csv   CSV export

CLI
  app.py serve                     run the HTTP server
  app.py backup                    write a dated copy of the database
  app.py import FILE.csv           import old leads (e.g. exported Google Sheet)
  app.py stats                     print counts
  app.py telegram-test             post a test message to the Telegram channel
  app.py telegram-setup OUTFILE    interactive bot/channel setup (used by install.sh)
"""
import base64
import csv
import hmac
import html
import io
import json
import logging
import os
import queue
import re
import signal
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import deque
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape as xml_escape


# ---------------------------------------------------------------- config ----

def env(name, default=""):
    return os.environ.get(name, default).strip()


def env_flag(name, default="1"):
    return env(name, default).lower() not in ("0", "false", "no", "off", "")


HOST = env("HOST", "127.0.0.1")
PORT = int(env("PORT", "8787"))
DATA_DIR = env("DATA_DIR", "/opt/airl-workshop/data")
BACKUP_DIR = env("BACKUP_DIR", "/opt/airl-workshop/backups")
DB_PATH = os.path.join(DATA_DIR, "leads.db")
ADMIN_USER = env("ADMIN_USER", "admin")
ADMIN_PASSWORD = env("ADMIN_PASSWORD")
FORWARD_URL = env("FORWARD_URL")
FORWARD_ENABLED = env_flag("FORWARD_ENABLED", "1") and bool(FORWARD_URL)
TELEGRAM_BOT_TOKEN = env("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = env("TELEGRAM_CHAT_ID")
TG_ENABLED = bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)
TELEGRAM_API = env("TELEGRAM_API", "https://api.telegram.org").rstrip("/")  # override only for tests
RATE_LIMIT = int(env("RATE_LIMIT_PER_10MIN", "5"))
BACKUP_KEEP = int(env("BACKUP_KEEP", "30"))
TZ_OFFSET = float(env("TZ_OFFSET_HOURS", "5"))  # Kazakhstan, UTC+5 since 2024
LOCAL_TZ = timezone(timedelta(hours=TZ_OFFSET))
MAX_BODY = 16 * 1024
PAGE_SIZE = 100

UTM_KEYS = ("utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term")
CORE_KEYS = ("name", "phone", "city", "page", "website") + UTM_KEYS

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s",
                    stream=sys.stderr)
log = logging.getLogger("airl")


# -------------------------------------------------------------- database ----

SCHEMA = """
CREATE TABLE IF NOT EXISTS leads (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at       TEXT NOT NULL,             -- UTC, ISO 8601
  name             TEXT NOT NULL,
  phone            TEXT NOT NULL,
  phone_digits     TEXT NOT NULL,
  city             TEXT NOT NULL DEFAULT '',
  page             TEXT NOT NULL DEFAULT '',
  utm_source       TEXT NOT NULL DEFAULT '',
  utm_medium       TEXT NOT NULL DEFAULT '',
  utm_campaign     TEXT NOT NULL DEFAULT '',
  utm_content      TEXT NOT NULL DEFAULT '',
  utm_term         TEXT NOT NULL DEFAULT '',
  extra            TEXT NOT NULL DEFAULT '{}',
  ip               TEXT NOT NULL DEFAULT '',
  user_agent       TEXT NOT NULL DEFAULT '',
  origin           TEXT NOT NULL DEFAULT 'web',  -- web | import
  payload          TEXT NOT NULL DEFAULT '',     -- body as received, for forwarding
  forward_status   TEXT NOT NULL DEFAULT 'pending', -- pending|sent|failed|skipped
  forward_attempts INTEGER NOT NULL DEFAULT 0,
  forward_last_try TEXT NOT NULL DEFAULT '',
  forward_error    TEXT NOT NULL DEFAULT '',
  tg_status        TEXT NOT NULL DEFAULT 'skipped', -- Telegram channel: pending|sent|failed|skipped
  tg_attempts      INTEGER NOT NULL DEFAULT 0,
  tg_last_try      TEXT NOT NULL DEFAULT '',
  tg_error         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_leads_created ON leads(created_at);
CREATE INDEX IF NOT EXISTS idx_leads_phone   ON leads(phone_digits);
CREATE INDEX IF NOT EXISTS idx_leads_forward ON leads(forward_status);
"""

# Columns added after the first release; added to older databases on start.
MIGRATIONS = (
    ("tg_status", "TEXT NOT NULL DEFAULT 'skipped'"),
    ("tg_attempts", "INTEGER NOT NULL DEFAULT 0"),
    ("tg_last_try", "TEXT NOT NULL DEFAULT ''"),
    ("tg_error", "TEXT NOT NULL DEFAULT ''"),
)


class DB:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.path = path
        self.lock = threading.Lock()
        self.conn = sqlite3.connect(path, check_same_thread=False, timeout=15)
        self.conn.row_factory = sqlite3.Row
        with self.lock:
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.execute("PRAGMA synchronous=NORMAL")
            self.conn.execute("PRAGMA busy_timeout=15000")
            self.conn.executescript(SCHEMA)
            have = {r[1] for r in self.conn.execute("PRAGMA table_info(leads)")}
            for col, decl in MIGRATIONS:
                if col not in have:
                    self.conn.execute("ALTER TABLE leads ADD COLUMN %s %s" % (col, decl))
            self.conn.execute("CREATE INDEX IF NOT EXISTS idx_leads_tg ON leads(tg_status)")
            self.conn.commit()
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    def execute(self, sql, params=()):
        with self.lock:
            cur = self.conn.execute(sql, params)
            self.conn.commit()
            return cur

    def query(self, sql, params=()):
        with self.lock:
            return self.conn.execute(sql, params).fetchall()

    def one(self, sql, params=()):
        rows = self.query(sql, params)
        return rows[0] if rows else None


def utcnow():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def local_str(s):
    try:
        return parse_iso(s).astimezone(LOCAL_TZ).strftime("%d.%m.%Y %H:%M")
    except (ValueError, TypeError):
        return s or ""


# ----------------------------------------------------------------- leads ----

def digits(s):
    return re.sub(r"\D", "", s or "")


def clean(s, limit):
    s = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", str(s or ""))
    return re.sub(r"\s+", " ", s).strip()[:limit]


def validate_lead(fields):
    """Returns (lead_dict, error). Mirrors the checks the page already does."""
    name = clean(fields.get("name"), 120)
    phone = clean(fields.get("phone"), 40)
    city = clean(fields.get("city"), 120)
    d = digits(phone)
    if len(name) < 2:
        return None, "name"
    if not (10 <= len(d) <= 15):
        return None, "phone"
    if not city:
        return None, "city"
    lead = {
        "name": name, "phone": phone, "phone_digits": d, "city": city,
        "page": clean(fields.get("page"), 300),
    }
    for k in UTM_KEYS:
        lead[k] = clean(fields.get(k), 200)
    extra = {}
    for k, v in fields.items():
        if k not in CORE_KEYS and len(extra) < 20:
            extra[clean(k, 50)] = clean(v, 500)
    lead["extra"] = json.dumps(extra, ensure_ascii=False)
    return lead, None


def insert_lead(db, lead, created_at=None, ip="", ua="", origin="web",
                payload="", forward_status="pending", tg_status="skipped"):
    cols = ["created_at", "name", "phone", "phone_digits", "city", "page",
            *UTM_KEYS, "extra", "ip", "user_agent", "origin", "payload",
            "forward_status", "tg_status"]
    vals = [iso(created_at or utcnow()), lead["name"], lead["phone"],
            lead["phone_digits"], lead["city"], lead["page"],
            *[lead[k] for k in UTM_KEYS], lead["extra"], ip, ua[:300], origin,
            payload, forward_status, tg_status]
    cur = db.execute(
        "INSERT INTO leads (%s) VALUES (%s)" % (",".join(cols), ",".join("?" * len(cols))),
        vals)
    return cur.lastrowid


class RateLimiter:
    def __init__(self, limit, window):
        self.limit, self.window = limit, window
        self.hits = {}
        self.lock = threading.Lock()

    def allow(self, key):
        now = time.monotonic()
        with self.lock:
            if len(self.hits) > 10000:  # keep memory bounded
                self.hits = {k: v for k, v in self.hits.items()
                             if v and now - v[-1] < self.window}
            q = self.hits.setdefault(key, deque())
            while q and now - q[0] > self.window:
                q.popleft()
            if len(q) >= self.limit:
                return False
            q.append(now)
            return True


# ------------------------------------------------- forward to Google Sheet --

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def forward_once(payload):
    """POST the original form body to the Apps Script. Apps Script answers a
    successful doPost with 302 to googleusercontent.com, so 2xx/3xx = ok."""
    req = urllib.request.Request(
        FORWARD_URL, data=payload.encode("utf-8"), method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
                 "User-Agent": "airl-workshop-backend/1.0"})
    try:
        with _opener.open(req, timeout=25) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    if 200 <= code < 400:
        return True, ""
    return False, "HTTP %s" % code


# ------------------------------------------------------ Telegram channel ----

def wa_digits(d):
    """Phone digits in the form wa.me expects (Kazakhstan 8XXXXXXXXXX -> 7XXXXXXXXXX)."""
    if len(d) == 11 and d.startswith("8"):
        return "7" + d[1:]
    return d


def tg_call(token, method, payload=None, timeout=30):
    """Telegram Bot API call. Returns the parsed JSON (also for 4xx answers)."""
    data = json.dumps(payload or {}).encode("utf-8")
    req = urllib.request.Request(
        "%s/bot%s/%s" % (TELEGRAM_API, token, method), data=data, method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "airl-workshop-backend/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8"))
        except ValueError:
            return {"ok": False, "description": "HTTP %s" % e.code}


def telegram_text(r):
    e = html.escape
    lines = ["<b>Заявка на воркшоп №%d</b>" % r["id"], "",
             "<b>Имя:</b> " + e(r["name"]),
             "<b>Телефон:</b> " + e(r["phone"]),
             "<b>Город:</b> " + e(r["city"])]
    utm = " / ".join(x for x in (r["utm_source"], r["utm_medium"], r["utm_campaign"]) if x)
    if utm:
        lines.append("<b>Реклама:</b> " + e(utm))
    lines += ["", '<a href="https://wa.me/%s">Написать в WhatsApp</a>' % wa_digits(r["phone_digits"]),
              local_str(r["created_at"])]
    return "\n".join(lines)


def telegram_once(row):
    res = tg_call(TELEGRAM_BOT_TOKEN, "sendMessage", {
        "chat_id": TELEGRAM_CHAT_ID, "text": telegram_text(row), "parse_mode": "HTML",
        "disable_web_page_preview": True})
    if res.get("ok"):
        return True, ""
    return False, str(res.get("description") or res)[:300]


# ------------------------------------------- delivery (Sheet + Telegram) ----

CHANNELS = {
    # name: (status, attempts, last_try, error columns, label)
    "sheet": ("forward_status", "forward_attempts", "forward_last_try", "forward_error", "Google Sheet"),
    "tg": ("tg_status", "tg_attempts", "tg_last_try", "tg_error", "Telegram"),
}


class Notifier(threading.Thread):
    """Delivers each lead to the Google Sheet and the Telegram channel.
    Failed deliveries are retried with growing pauses (2, 4, 8 ... min)."""
    MAX_ATTEMPTS = 8
    RETRY_WINDOW_DAYS = 3

    def __init__(self, db):
        super().__init__(daemon=True, name="notifier")
        self.db = db
        self.q = queue.Queue()

    def submit(self, lead_id):
        if FORWARD_ENABLED:
            self.q.put((lead_id, "sheet"))
        if TG_ENABLED:
            self.q.put((lead_id, "tg"))

    def run(self):
        self.retry_due()
        while True:
            try:
                lead_id, ch = self.q.get(timeout=60)
            except queue.Empty:
                self.retry_due()
                continue
            self.process(lead_id, ch)

    def process(self, lead_id, ch):
        st, att, last, err_col, label = CHANNELS[ch]
        row = self.db.one("SELECT * FROM leads WHERE id=?", (lead_id,))
        if not row or row[st] in ("sent", "skipped"):
            return
        attempts = row[att] + 1
        try:
            if ch == "sheet":
                ok, err = forward_once(row["payload"])
            else:
                ok, err = telegram_once(row)
        except Exception as e:  # network errors, timeouts
            ok, err = False, "%s: %s" % (type(e).__name__, e)
        self.db.execute("UPDATE leads SET %s=?, %s=?, %s=?, %s=? WHERE id=?" % (st, att, last, err_col),
                        ("sent" if ok else "failed", attempts, iso(utcnow()), err[:300], lead_id))
        if ok:
            log.info("lead %s delivered to %s", lead_id, label)
        else:
            log.warning("lead %s: delivery to %s failed (try %s): %s", lead_id, label, attempts, err)

    def retry_due(self):
        since = iso(utcnow() - timedelta(days=self.RETRY_WINDOW_DAYS))
        now = utcnow()
        for ch, enabled in (("sheet", FORWARD_ENABLED), ("tg", TG_ENABLED)):
            if not enabled:
                continue
            st, att, last, _, _ = CHANNELS[ch]
            extra = " AND payload != ''" if ch == "sheet" else ""
            rows = self.db.query(
                "SELECT id, %s a, %s l FROM leads WHERE %s IN ('pending','failed') AND %s < ? "
                "AND created_at > ?%s ORDER BY id LIMIT 50" % (att, last, st, att, extra),
                (self.MAX_ATTEMPTS, since))
            for r in rows:
                if r["l"] and now - parse_iso(r["l"]) < timedelta(minutes=2 ** r["a"]):
                    continue
                self.process(r["id"], ch)


# ------------------------------------------------------------- exports ------

EXPORT_HEAD = ["№", "Дата (UTC+%g)" % TZ_OFFSET, "Имя", "Телефон", "Город",
               "utm_source", "utm_medium", "utm_campaign", "utm_content",
               "utm_term", "Страница", "Источник", "Google Sheet", "Telegram"]


def export_rows(db):
    rows = db.query("SELECT * FROM leads ORDER BY id DESC")
    for r in rows:
        yield [r["id"], local_str(r["created_at"]), r["name"], r["phone"],
               r["city"], r["utm_source"], r["utm_medium"], r["utm_campaign"],
               r["utm_content"], r["utm_term"], r["page"], r["origin"],
               r["forward_status"], r["tg_status"]]


def csv_safe(v):
    v = "" if v is None else str(v)
    return "'" + v if v[:1] in ("=", "+", "-", "@", "\t", "\r") else v


def build_csv(db):
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";")
    w.writerow(EXPORT_HEAD)
    for row in export_rows(db):
        w.writerow([csv_safe(c) for c in row])
    return ("﻿" + buf.getvalue()).encode("utf-8")


def _col(n):
    s = ""
    n += 1
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def build_xlsx(db):
    """Minimal .xlsx (every cell is text, so phones stay intact)."""
    widths = [6, 17, 24, 20, 16, 14, 14, 18, 14, 12, 34, 10, 14, 12]
    rows_xml = []
    for i, row in enumerate([EXPORT_HEAD] + list(export_rows(db))):
        cells = []
        for j, v in enumerate(row):
            ref = "%s%d" % (_col(j), i + 1)
            style = ' s="1"' if i == 0 else ""
            if isinstance(v, int) and i > 0:
                cells.append('<c r="%s"%s><v>%d</v></c>' % (ref, style, v))
            else:
                text = xml_escape(re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", str(v)))
                cells.append('<c r="%s" t="inlineStr"%s><is><t xml:space="preserve">%s</t></is></c>'
                             % (ref, style, text))
        rows_xml.append('<row r="%d">%s</row>' % (i + 1, "".join(cells)))
    cols = "".join('<col min="%d" max="%d" width="%d" customWidth="1"/>' % (k + 1, k + 1, w)
                   for k, w in enumerate(widths))
    sheet = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
             '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
             '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" '
             'activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
             '<cols>%s</cols><sheetData>%s</sheetData></worksheet>') % (cols, "".join(rows_xml))
    files = {
        "[Content_Types].xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
            '</Types>',
        "_rels/.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>',
        "xl/workbook.xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="Заявки" sheetId="1" r:id="rId1"/></sheets></workbook>',
        "xl/_rels/workbook.xml.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
            '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
            '</Relationships>',
        "xl/styles.xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
            '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
            '<fills count="2"><fill><patternFill patternType="none"/></fill>'
            '<fill><patternFill patternType="gray125"/></fill></fills>'
            '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
            '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
            '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
            '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
            '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
            '</styleSheet>',
        "xl/worksheets/sheet1.xml": sheet,
    }
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in files.items():
            z.writestr(name, content)
    return buf.getvalue()


# ------------------------------------------------------------- admin UI -----

ADMIN_CSS = """
:root{--bg:#f6f6fb;--card:#fff;--ink:#17162b;--mut:#6b6a80;--line:#e6e5f0;--acc:#5b4bff;--ok:#1f9d55;--warn:#c27c0e;--bad:#d64545}
@media (prefers-color-scheme:dark){:root{--bg:#0f0e1d;--card:#17162b;--ink:#eeeef7;--mut:#a3a2bb;--line:#2a2945;--acc:#8b7fff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
header{background:#17162b;color:#fff;padding:14px 16px}header b{font-size:16px}header span{opacity:.7;margin-left:8px}
main{max-width:1200px;margin:0 auto;padding:16px}
.stats{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:14px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 14px;flex:0 1 140px;min-width:90px}
.stat div{color:var(--mut);font-size:12px}.stat strong{font-size:22px}
.bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px}
input[type=search]{flex:1;min-width:200px;padding:9px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--ink);font:inherit}
.btn{display:inline-block;padding:9px 14px;border-radius:8px;background:var(--acc);color:#fff;text-decoration:none;border:0;font:inherit;cursor:pointer}
.btn.sec{background:transparent;color:var(--acc);border:1px solid var(--line)}
.wrap{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;min-width:820px}th,td{padding:9px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{font-size:12px;color:var(--mut);font-weight:600;white-space:nowrap}tr:last-child td{border-bottom:0}
td.n{color:var(--mut)}a{color:var(--acc)}.mut{color:var(--mut);font-size:12px}
.st{font-size:12px;white-space:nowrap}.st.sent{color:var(--ok)}.st.failed{color:var(--bad)}.st.pending{color:var(--warn)}.st.skipped{color:var(--mut)}
.pager{display:flex;gap:8px;margin-top:12px;align-items:center}
"""

STATUS_RU = {"sent": "✓", "failed": "✗ ошибка", "pending": "… в очереди", "skipped": "—"}


def status_html(label, st, err):
    title = " title='%s'" % html.escape(err) if st == "failed" and err else ""
    return "<div class='st %s'%s>%s %s</div>" % (html.escape(st), title, label,
                                               html.escape(STATUS_RU.get(st, st)))


def render_admin(db, q, page):
    esc = html.escape
    now = utcnow()
    total = db.one("SELECT COUNT(*) c FROM leads")["c"]
    local_midnight = now.astimezone(LOCAL_TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    today = db.one("SELECT COUNT(*) c FROM leads WHERE created_at >= ?", (iso(local_midnight),))["c"]
    week = db.one("SELECT COUNT(*) c FROM leads WHERE created_at >= ?",
                  (iso(now - timedelta(days=7)),))["c"]
    failed = db.one("SELECT COUNT(*) c FROM leads WHERE forward_status='failed'")["c"]
    tg_failed = db.one("SELECT COUNT(*) c FROM leads WHERE tg_status='failed'")["c"]

    where, params = "", []
    if q:
        like = "%" + q + "%"
        conds = ["name LIKE ?", "city LIKE ?", "utm_source LIKE ?", "utm_campaign LIKE ?", "phone LIKE ?"]
        params = [like] * 5
        d = digits(q)
        if len(d) >= 3:
            conds.append("phone_digits LIKE ?")
            params.append("%" + d + "%")
        where = "WHERE " + " OR ".join(conds)
    found = db.one("SELECT COUNT(*) c FROM leads " + where, params)["c"]
    pages = max(1, (found + PAGE_SIZE - 1) // PAGE_SIZE)
    page = min(max(1, page), pages)
    rows = db.query("SELECT * FROM leads %s ORDER BY id DESC LIMIT ? OFFSET ?" % where,
                    params + [PAGE_SIZE, (page - 1) * PAGE_SIZE])

    trs = []
    for r in rows:
        wa = r["phone_digits"]
        if len(wa) == 11 and wa.startswith("8"):
            wa = "7" + wa[1:]
        utm = " / ".join(x for x in (r["utm_source"], r["utm_medium"], r["utm_campaign"]) if x)
        delivery = (status_html("Таблица", r["forward_status"], r["forward_error"]) +
                    status_html("Telegram", r["tg_status"], r["tg_error"]))
        trs.append(
            "<tr><td class=n>%d</td><td>%s</td><td>%s</td>"
            "<td><a href='tel:+%s'>%s</a><br><a class=mut href='https://wa.me/%s' target=_blank rel=noopener>WhatsApp</a></td>"
            "<td>%s</td><td>%s</td><td>%s</td></tr>"
            % (r["id"], esc(local_str(r["created_at"])), esc(r["name"]), esc(wa), esc(r["phone"]),
               esc(wa), esc(r["city"]), esc(utm) or "<span class=mut>—</span>", delivery))
    if not trs:
        trs.append("<tr><td colspan=7 class=mut>Заявок пока нет</td></tr>")

    def link(p):
        qs = {"p": p}
        if q:
            qs["q"] = q
        return "/admin?" + urllib.parse.urlencode(qs)

    pager = ""
    if pages > 1:
        pager = "<div class=pager>%s<span class=mut>стр. %d из %d</span>%s</div>" % (
            "<a class='btn sec' href='%s'>← Новее</a>" % esc(link(page - 1)) if page > 1 else "",
            page, pages,
            "<a class='btn sec' href='%s'>Старее →</a>" % esc(link(page + 1)) if page < pages else "")
    targets = [x for x, on in (("Google Sheet", FORWARD_ENABLED), ("Telegram", TG_ENABLED)) if on]
    sheet_note = ("Каждая заявка также уходит в: %s." % ", ".join(targets) if targets
                  else "Заявки сохраняются только здесь.")
    if failed or tg_failed:
        sheet_note += " Пока не доставлено: таблица %d, Telegram %d (повторится автоматически)." % (failed, tg_failed)

    return ("<!doctype html><html lang=ru><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<meta name=robots content=noindex><title>Заявки на воркшоп</title>"
            "<style>%s</style></head><body><header><b>Заявки на воркшоп</b><span>AIRL</span></header><main>"
            "<div class=stats><div class=stat><div>Всего</div><strong>%d</strong></div>"
            "<div class=stat><div>Сегодня</div><strong>%d</strong></div>"
            "<div class=stat><div>За 7 дней</div><strong>%d</strong></div></div>"
            "<form class=bar method=get action=/admin><input type=search name=q value='%s' "
            "placeholder='Поиск: имя, телефон, город, utm'><button class=btn>Найти</button>"
            "<a class='btn sec' href='/admin/leads.xlsx'>Скачать Excel</a>"
            "<a class='btn sec' href='/admin/leads.csv'>CSV</a></form>"
            "<p class=mut>%s%s</p>"
            "<div class=wrap><table><thead><tr><th>№</th><th>Дата</th><th>Имя</th><th>Телефон</th>"
            "<th>Город</th><th>UTM</th><th>Доставка</th></tr></thead><tbody>%s</tbody></table></div>"
            "%s</main></body></html>") % (
        ADMIN_CSS, total, today, week, esc(q), esc(sheet_note),
        (" Найдено: %d." % found) if q else "", "".join(trs), pager)


# ---------------------------------------------------------------- server ----

class App:
    def __init__(self):
        self.db = DB(DB_PATH)
        self.notifier = Notifier(self.db)
        self.leads_rl = RateLimiter(RATE_LIMIT, 600)
        self.auth_fail = RateLimiter(10, 900)


class Handler(BaseHTTPRequestHandler):
    server_version = "airl"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    app = None  # set in serve()

    # -- helpers
    def client_ip(self):
        # Only Caddy on localhost talks to us; it overwrites X-Forwarded-For
        # with the real client address unless configured otherwise.
        xff = self.headers.get("X-Forwarded-For", "")
        return (xff.split(",")[0].strip() if xff else self.client_address[0])[:64]

    def log_message(self, fmt, *args):
        log.info("%s %s", self.client_ip(), fmt % args)

    def send(self, code, body=b"", ctype="application/json; charset=utf-8", headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, code, obj):
        self.send(code, json.dumps(obj, ensure_ascii=False))

    def path_only(self):
        return urllib.parse.urlsplit(self.path).path

    def query_params(self):
        return urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)

    def check_admin(self):
        if not ADMIN_PASSWORD:
            self.send(403, "Admin is disabled: ADMIN_PASSWORD is not set.", "text/plain; charset=utf-8")
            return False
        ip = self.client_ip()
        hdr = self.headers.get("Authorization", "")
        if hdr.startswith("Basic "):
            try:
                user, _, pw = base64.b64decode(hdr[6:]).decode("utf-8").partition(":")
            except Exception:
                user, pw = "", ""
            ok_user = hmac.compare_digest(user.encode(), ADMIN_USER.encode())
            ok_pw = hmac.compare_digest(pw.encode(), ADMIN_PASSWORD.encode())
            if ok_user and ok_pw:
                return True
            if not self.app.auth_fail.allow(ip):
                log.warning("too many failed admin logins from %s", ip)
                self.send(429, "Too many attempts. Try again in 15 minutes.", "text/plain; charset=utf-8")
                return False
            time.sleep(0.5)
        self.send(401, "Authentication required", "text/plain; charset=utf-8",
                  {"WWW-Authenticate": 'Basic realm="AIRL admin", charset="UTF-8"'})
        return False

    # -- routes
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path_only()
        if path == "/api/health":
            n = self.app.db.one("SELECT COUNT(*) c FROM leads")["c"]
            return self.json(200, {"ok": True, "leads": n, "forward": FORWARD_ENABLED})
        if path in ("/admin", "/admin/"):
            if not self.check_admin():
                return
            qp = self.query_params()
            q = clean((qp.get("q") or [""])[0], 100)
            try:
                page = int((qp.get("p") or ["1"])[0])
            except ValueError:
                page = 1
            return self.send(200, render_admin(self.app.db, q, page), "text/html; charset=utf-8",
                             {"X-Robots-Tag": "noindex", "X-Frame-Options": "DENY",
                              "Referrer-Policy": "no-referrer"})
        if path in ("/admin/leads.csv", "/admin/leads.xlsx"):
            if not self.check_admin():
                return
            stamp = utcnow().astimezone(LOCAL_TZ).strftime("%Y%m%d-%H%M")
            if path.endswith(".csv"):
                body, ctype, ext = build_csv(self.app.db), "text/csv; charset=utf-8", "csv"
            else:
                body = build_xlsx(self.app.db)
                ctype = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                ext = "xlsx"
            return self.send(200, body, ctype, {
                "Content-Disposition": 'attachment; filename="airl-workshop-leads-%s.%s"' % (stamp, ext)})
        if path == "/api/lead":
            return self.json(405, {"ok": False, "error": "method"})
        self.json(404, {"ok": False, "error": "not found"})

    def do_OPTIONS(self):
        if self.path_only() == "/api/lead":
            return self.send(204, b"", "text/plain", {"Allow": "POST, OPTIONS"})
        self.json(404, {"ok": False})

    def do_POST(self):
        if self.path_only() != "/api/lead":
            return self.json(404, {"ok": False, "error": "not found"})
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            self.close_connection = True
            return self.json(413, {"ok": False, "error": "too large"})
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        ctype = (self.headers.get("Content-Type") or "").lower()
        fields = {}
        try:
            if ctype.startswith("application/json"):
                data = json.loads(raw or "{}")
                fields = {str(k): str(v) for k, v in data.items()} if isinstance(data, dict) else {}
                payload = urllib.parse.urlencode(fields)
            else:
                fields = {k: v[0] for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}
                payload = raw
        except (ValueError, AttributeError):
            return self.json(400, {"ok": False, "error": "bad body"})

        ip = self.client_ip()
        if fields.get("website", "").strip():
            log.info("honeypot filled, ignored (ip %s)", ip)
            return self.json(200, {"ok": True})

        lead, err = validate_lead(fields)
        if err:
            return self.json(400, {"ok": False, "error": err})
        if not self.app.leads_rl.allow(ip):
            log.warning("rate limit hit for %s", ip)
            return self.json(429, {"ok": False, "error": "rate"})

        db = self.app.db
        dup = db.one("SELECT id FROM leads WHERE phone_digits=? AND created_at >= ? ORDER BY id DESC LIMIT 1",
                     (lead["phone_digits"], iso(utcnow() - timedelta(minutes=2))))
        if dup:
            log.info("duplicate of lead %s within 2 min, ignored", dup["id"])
            return self.json(200, {"ok": True, "id": dup["id"]})

        lead_id = insert_lead(db, lead, ip=ip, ua=self.headers.get("User-Agent", ""),
                              payload=payload,
                              forward_status="pending" if FORWARD_ENABLED else "skipped",
                              tg_status="pending" if TG_ENABLED else "skipped")
        log.info("new lead %s saved", lead_id)
        self.app.notifier.submit(lead_id)
        self.json(200, {"ok": True, "id": lead_id})


def serve():
    app = App()
    Handler.app = app
    app.notifier.start()
    log.info("copies to Google Sheet: %s, to Telegram: %s",
             "on" if FORWARD_ENABLED else "off", "on" if TG_ENABLED else "off")
    if not ADMIN_PASSWORD:
        log.warning("ADMIN_PASSWORD is empty: /admin is disabled")
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True

    def stop(*_):
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log.info("listening on http://%s:%d (db %s)", HOST, PORT, DB_PATH)
    httpd.serve_forever()
    log.info("stopped")


# ------------------------------------------------------------------- CLI ----

def cmd_backup():
    if not os.path.exists(DB_PATH):
        print("no database yet, nothing to back up")
        return
    os.makedirs(BACKUP_DIR, exist_ok=True)
    dst = os.path.join(BACKUP_DIR, "leads-%s.db" % utcnow().strftime("%Y%m%d-%H%M%S"))
    src = sqlite3.connect(DB_PATH, timeout=30)
    out = sqlite3.connect(dst)
    with out:
        src.backup(out)
    out.close()
    src.close()
    os.chmod(dst, 0o600)
    files = sorted(f for f in os.listdir(BACKUP_DIR) if f.startswith("leads-") and f.endswith(".db"))
    for old in files[:-BACKUP_KEEP] if BACKUP_KEEP > 0 else []:
        os.remove(os.path.join(BACKUP_DIR, old))
    print("backup written:", dst)


HEADER_ALIASES = {
    "name": ("name", "имя", "фио", "имя и фамилия", "клиент"),
    "phone": ("phone", "телефон", "номер", "номер телефона", "тел", "whatsapp"),
    "city": ("city", "город"),
    "page": ("page", "страница", "url"),
    "date": ("date", "дата", "timestamp", "время", "created", "created_at", "дата и время",
             "отметка времени", "дата заявки"),
}
DATE_FORMATS = ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S",
                "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d",
                "%d.%m.%Y %H:%M:%S", "%d.%m.%Y %H:%M", "%d.%m.%Y, %H:%M:%S", "%d.%m.%Y",
                "%m/%d/%Y %H:%M:%S", "%m/%d/%Y")


def parse_any_date(s):
    s = (s or "").strip()
    for fmt in DATE_FORMATS:
        try:
            dt = datetime.strptime(s, fmt)
        except ValueError:
            continue
        if s.endswith("Z"):
            return dt.replace(tzinfo=timezone.utc)
        return dt.replace(tzinfo=LOCAL_TZ)  # sheet times are local time
    return None


def cmd_import(path):
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        text = f.read()
    try:
        dialect = csv.Sniffer().sniff(text[:4096], delimiters=",;\t")
    except csv.Error:
        dialect = csv.excel
    rows = list(csv.reader(io.StringIO(text), dialect))
    if len(rows) < 2:
        print("file has no data rows")
        return
    head = [h.strip().lower() for h in rows[0]]
    index = {}
    for key, names in HEADER_ALIASES.items():
        for i, h in enumerate(head):
            if h in names and key not in index:
                index[key] = i
    for k in UTM_KEYS:
        if k in head:
            index[k] = head.index(k)
    missing = [k for k in ("name", "phone") if k not in index]
    if missing:
        print("cannot find columns: %s. Headers seen: %s" % (", ".join(missing), rows[0]))
        sys.exit(1)
    db = DB(DB_PATH)
    added = skipped = bad = 0
    for row in rows[1:]:
        get = lambda k: row[index[k]].strip() if k in index and index[k] < len(row) else ""
        fields = {k: get(k) for k in ("name", "phone", "city", "page") + UTM_KEYS}
        fields["city"] = fields["city"] or "—"
        lead, err = validate_lead(fields)
        if err:
            bad += 1
            continue
        created = parse_any_date(get("date")) or utcnow()
        if db.one("SELECT id FROM leads WHERE phone_digits=? AND created_at=?",
                  (lead["phone_digits"], iso(created))):
            skipped += 1
            continue
        insert_lead(db, lead, created_at=created, origin="import", forward_status="skipped")
        added += 1
    print("imported: %d, already there: %d, rows without valid name/phone: %d" % (added, skipped, bad))


def cmd_stats():
    db = DB(DB_PATH)
    print("%-18s %d" % ("total", db.one("SELECT COUNT(*) c FROM leads")["c"]))
    for col, name in (("forward_status", "sheet"), ("tg_status", "telegram")):
        for st in ("sent", "failed", "pending"):
            n = db.one("SELECT COUNT(*) c FROM leads WHERE %s=?" % col, (st,))["c"]
            print("%-18s %d" % ("%s %s" % (name, st), n))


def cmd_telegram_setup(out_path):
    """Interactive, run by install.sh on the server. Asks for the bot token
    (hidden input), finds the channel, sends a test post, and writes
    'token\\nchat_id\\n' to out_path (mode 600)."""
    import getpass
    try:  # separate handles: a terminal cannot be opened as one "r+" text stream
        tty_in = open("/dev/tty", "r", encoding="utf-8", errors="replace")
        tty = open("/dev/tty", "w", encoding="utf-8")
    except OSError:
        sys.exit("Telegram setup needs an interactive terminal.")

    def say(msg):
        tty.write(msg + "\n")
        tty.flush()

    def ask(prompt):
        tty.write(prompt)
        tty.flush()
        return tty_in.readline().strip()

    token = None
    for _ in range(3):
        t = getpass.getpass("Токен бота от @BotFather (ввод скрыт): ", stream=tty).strip()
        me = tg_call(t, "getMe") if t else {}
        if me.get("ok"):
            token = t
            say("  Бот: @%s" % me["result"].get("username"))
            break
        say("  Telegram не принял токен: %s" % (me.get("description") or "пусто"))
    if not token:
        sys.exit("Telegram: токен не подошёл.")

    for _ in range(3):
        chat = ask("Канал или группа: @username или ссылка t.me/... (если закрытые, просто Enter): ")
        chat = re.sub(r"^(https?://)?(t\.me|telegram\.me)/", "", chat).strip().strip("/")
        if chat and not chat.startswith(("@", "-")):
            chat = "@" + chat
        if not chat:
            say("  Опубликуйте любое сообщение в канале или группе (бот должен быть админом). Жду до 3 минут...")
            offset, deadline = None, time.time() + 180
            while not chat and time.time() < deadline:
                params = {"timeout": 25,
                          "allowed_updates": ["channel_post", "my_chat_member", "message"]}
                if offset is not None:
                    params["offset"] = offset
                res = tg_call(token, "getUpdates", params, timeout=35)
                for u in res.get("result", []):
                    offset = u["update_id"] + 1
                    src = u.get("channel_post") or u.get("my_chat_member") or u.get("message") or {}
                    c = src.get("chat") or {}
                    if c.get("type") in ("channel", "group", "supergroup"):
                        chat = str(c["id"])
                        kind = "канал" if c["type"] == "channel" else "группу"
                        say("  Нашёл %s: %s" % (kind, c.get("title", chat)))
                        break
                if not res.get("ok"):
                    say("  getUpdates: %s" % res.get("description"))
                    break
            if not chat:
                say("  Не дождался сообщения в канале или группе.")
                continue
        res = tg_call(token, "sendMessage", {
            "chat_id": chat, "text": "✅ Сюда будут приходить заявки с сайта воркшопа AIRL."})
        new_id = (res.get("parameters") or {}).get("migrate_to_chat_id")
        if not res.get("ok") and new_id:  # group was upgraded to a supergroup: new id
            res = tg_call(token, "sendMessage", {
                "chat_id": new_id, "text": "✅ Сюда будут приходить заявки с сайта воркшопа AIRL."})
        if res.get("ok"):
            chat_id = str(res["result"]["chat"]["id"])
            say("  Тестовое сообщение отправлено, проверьте Telegram.")
            fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write("%s\n%s\n" % (token, chat_id))
            return
        say("  Не получилось написать: %s" % res.get("description"))
        say("  Проверьте, что бот добавлен администратором (в канале: с правом публикации).")
    sys.exit("Telegram: канал не настроен.")


def cmd_telegram_test():
    if not TG_ENABLED:
        sys.exit("Telegram is not configured (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID).")
    res = tg_call(TELEGRAM_BOT_TOKEN, "sendMessage",
                  {"chat_id": TELEGRAM_CHAT_ID, "text": "Проверка: бот заявок AIRL на связи."})
    print("ok" if res.get("ok") else "failed: %s" % res.get("description"))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "serve"
    if cmd == "serve":
        serve()
    elif cmd == "backup":
        cmd_backup()
    elif cmd == "import" and len(argv) > 2:
        cmd_import(argv[2])
    elif cmd == "stats":
        cmd_stats()
    elif cmd == "telegram-setup" and len(argv) > 2:
        cmd_telegram_setup(argv[2])
    elif cmd == "telegram-test":
        cmd_telegram_test()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
AIRL_APP_PY_EOF

cat > "$BASE/app/sitetool.py" <<'AIRL_SITETOOL_PY_EOF'
#!/usr/bin/env python3
"""
Copy the deployed workshop page and prepare it for the VPS. Stdlib only.

  sitetool.py mirror --source https://airl-workshop.web.app --out DIR
      Downloads index.html and every file it references (JS, CSS, fonts,
      images, icons, og-image) into DIR, keeping paths.

  sitetool.py build --mirror DIR --out DIR2 --base-url https://example.kz --source URL
      Copies DIR to DIR2, points the form at /api/lead instead of Google Apps
      Script, rewrites absolute links to the old host, adds a 404 page.
      Prints JSON: {"forward_url": "<the Apps Script URL found>", ...}
"""
import argparse
import hashlib
import json
import os
import posixpath
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request

UA = "airl-workshop-migrator/1.0"
GAS_RE = re.compile(r"https://script\.google\.com/macros/s/[A-Za-z0-9_-]+/exec")
# Right after the form URL the page declares the manager's WhatsApp number:
#   e=`<form url>`,t=`<digits>`.replace(/\D/g,``)
# Empty = no WhatsApp step. Non-empty = after submitting, the page opens a chat
# with that number, the lead's name/city/phone already typed in.
WA_RE = re.compile(r'([`"\'])(/api/lead)\1(\s*,\s*[A-Za-z_$][\w$]*\s*=\s*)([`"\'])([^`"\'\n]{0,30})\4(\s*\.replace\(/\\D/g)')
EXTRA = ("/favicon.png", "/favicon.ico", "/favicon.svg", "/apple-touch-icon.png",
         "/og-image.jpg", "/og-image.png", "/robots.txt", "/sitemap.xml",
         "/manifest.webmanifest", "/site.webmanifest")
MAX_FILES = 500
MAX_BYTES = 80 * 1024 * 1024


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), b""
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        print("  cannot reach %s: %s" % (url, reason), file=sys.stderr)
        return 0, "", b""


def refs_html(text):
    out = re.findall(r'(?:src|href|content|poster|data-src)\s*=\s*["\']([^"\']+)["\']', text)
    for ss in re.findall(r'srcset\s*=\s*["\']([^"\']+)["\']', text):
        out += [p.strip().split(" ")[0] for p in ss.split(",") if p.strip()]
    out += re.findall(r'url\(\s*["\']?([^"\')]+)["\']?\s*\)', text)
    return out


def refs_css(text):
    return re.findall(r'url\(\s*["\']?([^"\')]+)["\']?\s*\)', text) + \
        re.findall(r'@import\s+["\']([^"\']+)["\']', text)


def refs_js(text):
    out = re.findall(r'["\'`](/?assets/[^"\'`\s?#]+)["\'`]', text)
    return ["/" + r.lstrip("/") for r in out]


def safe_local(root, path):
    path = posixpath.normpath("/" + urllib.parse.unquote(path)).lstrip("/")
    if not path or path.startswith(".."):
        return None
    full = os.path.realpath(os.path.join(root, path))
    if not full.startswith(os.path.realpath(root) + os.sep):
        return None
    return full


def mirror(source, out):
    source = source.rstrip("/")
    origin = urllib.parse.urlsplit(source)
    os.makedirs(out, exist_ok=True)

    code, ctype, body = fetch(source + "/")
    if code != 200 or b"<html" not in body[:4000].lower():
        sys.exit("ERROR: could not download %s/ (HTTP %s)" % (source, code))
    with open(os.path.join(out, "index.html"), "wb") as f:
        f.write(body)
    saved = {"/index.html": hashlib.sha256(body).hexdigest()}
    total = len(body)

    todo = [("/", r) for r in refs_html(body.decode("utf-8", "replace"))]
    todo += [("/", p) for p in EXTRA]
    seen = set(["/", "/index.html"])
    while todo:
        base, ref = todo.pop(0)
        ref = ref.strip()
        if not ref or ref.startswith(("data:", "mailto:", "tel:", "#", "javascript:")):
            continue
        if re.search(r"\s", ref) or ("/" not in ref and "." not in ref):
            continue  # meta text like og:type "website", not a file
        absu = urllib.parse.urljoin(source + base, ref)
        u = urllib.parse.urlsplit(absu)
        if (u.scheme, u.netloc) != (origin.scheme, origin.netloc):
            continue  # external link, not part of the site
        path = u.path or "/"
        if path in seen or path.endswith("/"):
            continue
        seen.add(path)
        local = safe_local(out, path)
        if not local:
            continue
        code, ctype, data = fetch("%s://%s%s" % (u.scheme, u.netloc, path))
        is_html = "text/html" in ctype.lower()
        if code != 200 or (is_html and not path.endswith((".html", ".htm"))):
            if path not in EXTRA:
                print("  skip %s (HTTP %s)" % (path, code), file=sys.stderr)
            continue
        os.makedirs(os.path.dirname(local), exist_ok=True)
        with open(local, "wb") as f:
            f.write(data)
        saved[path] = hashlib.sha256(data).hexdigest()
        total += len(data)
        if len(saved) > MAX_FILES or total > MAX_BYTES:
            sys.exit("ERROR: site is larger than expected, stopping")
        text = data.decode("utf-8", "replace")
        if path.endswith(".css"):
            todo += [(path, r) for r in refs_css(text)]
        elif path.endswith((".js", ".mjs")):
            todo += [("/", r) for r in refs_js(text)]
        elif path.endswith((".html", ".htm", ".webmanifest", ".svg")):
            todo += [(path, r) for r in refs_html(text)]
    with open(os.path.join(out, ".mirror.json"), "w") as f:
        json.dump({"source": source, "files": saved, "bytes": total}, f, indent=1, sort_keys=True)
    print(json.dumps({"files": len(saved), "bytes": total}))


NOT_FOUND = """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Страница не найдена</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#17162b;color:#fff;
font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;text-align:center;padding:24px}
a{color:#fff;background:#5b4bff;padding:12px 20px;border-radius:10px;text-decoration:none;display:inline-block;margin-top:16px}</style>
</head><body><div><h1 style="margin:0 0 8px">Страница не найдена</h1>
<p style="opacity:.75;margin:0">Возможно, ссылка устарела.</p><a href="/">На главную</a></div></body></html>
"""


def normalize_wa(number):
    d = re.sub(r"\D", "", number or "")
    if len(d) == 11 and d.startswith("8"):
        d = "7" + d[1:]
    if d and not 10 <= len(d) <= 15:
        sys.exit("ERROR: WhatsApp number %r does not look like a phone number" % number)
    return d


def build(mirror_dir, out, base_url, source, whatsapp=None):
    if not os.path.exists(os.path.join(mirror_dir, "index.html")):
        sys.exit("ERROR: %s has no index.html" % mirror_dir)
    if os.path.exists(out):
        shutil.rmtree(out)
    shutil.copytree(mirror_dir, out, ignore=shutil.ignore_patterns(".mirror.json"))

    found, patched = [], []
    for dirpath, _, files in os.walk(out):
        for name in files:
            if not name.endswith((".js", ".mjs", ".html")):
                continue
            p = os.path.join(dirpath, name)
            with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
                text = f.read()
            urls = GAS_RE.findall(text)
            if urls:
                found += urls
                text = GAS_RE.sub("/api/lead", text)
                patched.append(os.path.relpath(p, out))
                with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                    f.write(text)
    uniq = sorted(set(found))
    if len(uniq) != 1:
        sys.exit("ERROR: expected exactly one Google Apps Script URL in the site code, found %d. "
                 "The page code has changed; the form would not reach the new server." % len(uniq))

    wa = normalize_wa(whatsapp) if whatsapp is not None else None
    if wa is not None:
        hits = 0
        for rel in patched:
            p = os.path.join(out, rel)
            with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
                text = f.read()
            text, n = WA_RE.subn(lambda m: "%s%s%s%s%s%s%s%s" % (
                m.group(1), m.group(2), m.group(1), m.group(3), m.group(4), wa, m.group(4), m.group(6)), text)
            hits += n
            if n:
                with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                    f.write(text)
        if hits != 1 and wa:
            print("WARNING: could not find the WhatsApp number setting in the page code (found %d); "
                  "the WhatsApp step stays off." % hits, file=sys.stderr)
            wa = ""

    index = os.path.join(out, "index.html")
    with open(index, "r", encoding="utf-8") as f:
        text = f.read()
    old = source.rstrip("/")
    new = base_url.rstrip("/")
    if old and new and old != new:
        text = text.replace(old + "/", new + "/").replace(old, new)
    with open(index, "w", encoding="utf-8") as f:
        f.write(text)

    # Changed code files get a new name with a hash of their content
    # (index-X.js -> index-X.<hash>.js) and every reference is updated. Assets
    # are cached by browsers for a year, so a file whose content changed must
    # never keep its old name, or visitors keep running the old copy.
    renamed = {}
    for rel in [r for r in patched if r.endswith((".js", ".mjs"))]:
        p = os.path.join(out, rel)
        with open(p, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()[:8]
        stem, ext = os.path.splitext(os.path.basename(rel))
        new_name = "%s.%s%s" % (stem, digest, ext)
        os.rename(p, os.path.join(os.path.dirname(p), new_name))
        renamed[os.path.basename(rel)] = new_name
    if renamed:
        for dirpath, _, files in os.walk(out):
            for name in files:
                if not name.endswith((".html", ".js", ".mjs", ".css", ".webmanifest")):
                    continue
                p = os.path.join(dirpath, name)
                with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
                    text = f.read()
                new_text = text
                for old_name, new_name in renamed.items():
                    new_text = re.sub(r"(?<=[/\"'`])" + re.escape(old_name) + r"(?=[\"'`?#)])",
                                      new_name, new_text)
                if new_text != text:
                    with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                        f.write(new_text)
        with open(index, "r", encoding="utf-8") as f:
            index_text = f.read()
        for new_name in renamed.values():
            if new_name not in index_text:
                sys.exit("ERROR: index.html does not reference %s after renaming" % new_name)
        patched = [os.path.join(os.path.dirname(r), renamed.get(os.path.basename(r), os.path.basename(r)))
                   for r in patched]

    if not os.path.exists(os.path.join(out, "404.html")):
        with open(os.path.join(out, "404.html"), "w", encoding="utf-8") as f:
            f.write(NOT_FOUND)
    print(json.dumps({"forward_url": uniq[0], "patched": patched, "whatsapp": wa}))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("mirror")
    m.add_argument("--source", required=True)
    m.add_argument("--out", required=True)
    b = sub.add_parser("build")
    b.add_argument("--mirror", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--base-url", required=True)
    b.add_argument("--source", default="https://airl-workshop.web.app")
    b.add_argument("--whatsapp", default=None, help="manager number for the WhatsApp step; '' turns it off")
    a = ap.parse_args()
    if a.cmd == "mirror":
        mirror(a.source, a.out)
    else:
        build(a.mirror, a.out, a.base_url, a.source, a.whatsapp)


if __name__ == "__main__":
    main()
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
  OTHER_LINES="$(grep -vE '^(#|$|ADMIN_USER=|ADMIN_PASSWORD=|FORWARD_URL=|FORWARD_ENABLED=|SITE_DOMAIN=|SITE_WHATSAPP=|TELEGRAM_BOT_TOKEN=|TELEGRAM_CHAT_ID=|HOST=|PORT=|DATA_DIR=|BACKUP_DIR=)' "$ENV_FILE" || true)"
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
	handle {
		root * $BASE/site
		@assets path /assets/*
		header @assets Cache-Control "public, max-age=31536000, immutable"
		@page path / /index.html
		header @page Cache-Control "no-cache"
		file_server
	}
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
  if "${CURL[@]}" "$URL/" 2>/dev/null | grep -q '<title>'; then PAGE_OK=1; break; fi
  sleep 3
done
if [ "$PAGE_OK" = 1 ]; then
  ok "Page opens at $BASE_URL"
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
echo "  Database:        $BASE/data/leads.db, daily backups in $BASE/backups"
echo "  Logs:            journalctl -u airl-workshop -f"
echo "  Commands:        airl-workshop stats | backup | telegram-test | import old-leads.csv"
if [ -z "$DOMAIN" ]; then
  echo
  warn "No domain yet, so the admin page works over plain HTTP. Point a domain here and run:"
  warn "  bash install.sh --domain <your-domain>"
fi
