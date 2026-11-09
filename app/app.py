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
  app.py bitrix-setup OUTFILE      interactive Bitrix24 webhook setup (used by install.sh)
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
BITRIX_WEBHOOK_URL = env("BITRIX_WEBHOOK_URL").rstrip("/")
BITRIX_CATEGORY_ID = env("BITRIX_CATEGORY_ID", "0")
BITRIX_STAGE_ID = env("BITRIX_STAGE_ID", "NEW")
BX_ENABLED = bool(BITRIX_WEBHOOK_URL)
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
  tg_error         TEXT NOT NULL DEFAULT '',
  bx_status        TEXT NOT NULL DEFAULT 'skipped', -- Bitrix24 deal: pending|sent|failed|skipped
  bx_attempts      INTEGER NOT NULL DEFAULT 0,
  bx_last_try      TEXT NOT NULL DEFAULT '',
  bx_error         TEXT NOT NULL DEFAULT ''
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
    ("bx_status", "TEXT NOT NULL DEFAULT 'skipped'"),
    ("bx_attempts", "INTEGER NOT NULL DEFAULT 0"),
    ("bx_last_try", "TEXT NOT NULL DEFAULT ''"),
    ("bx_error", "TEXT NOT NULL DEFAULT ''"),
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
                payload="", forward_status="pending", tg_status="skipped",
                bx_status="skipped"):
    cols = ["created_at", "name", "phone", "phone_digits", "city", "page",
            *UTM_KEYS, "extra", "ip", "user_agent", "origin", "payload",
            "forward_status", "tg_status", "bx_status"]
    vals = [iso(created_at or utcnow()), lead["name"], lead["phone"],
            lead["phone_digits"], lead["city"], lead["page"],
            *[lead[k] for k in UTM_KEYS], lead["extra"], ip, ua[:300], origin,
            payload, forward_status, tg_status, bx_status]
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


# ------------------------------------------------------- Bitrix24 deals ----

class BitrixError(Exception):
    pass


def bx_call(base, method, payload=None, timeout=30):
    """Bitrix24 REST call through an inbound webhook. Returns "result"; raises
    BitrixError with Bitrix's own message. The webhook URL is secret: it must
    never get into an error text."""
    req = urllib.request.Request(
        "%s/%s.json" % (base, method), data=json.dumps(payload or {}).encode("utf-8"), method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "airl-workshop-backend/1.0"})
    try:
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            try:
                data = json.loads(e.read().decode("utf-8"))
            except ValueError:
                raise BitrixError("HTTP %s" % e.code) from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise BitrixError(type(e).__name__) from None
    if not isinstance(data, dict) or "result" not in data:
        data = data if isinstance(data, dict) else {}
        raise BitrixError(str(data.get("error_description") or data.get("error") or "bad answer")[:300])
    return data["result"]


def bitrix_contact_id(row):
    """Contact for the lead's phone: an existing one, or a new one."""
    phone = "+" + wa_digits(row["phone_digits"])
    found = bx_call(BITRIX_WEBHOOK_URL, "crm.duplicate.findbycomm",
                    {"type": "PHONE", "values": [phone], "entity_type": "CONTACT"})
    ids = found.get("CONTACT") if isinstance(found, dict) else None
    if ids:
        return ids[0]
    return bx_call(BITRIX_WEBHOOK_URL, "crm.contact.add", {"fields": {
        "NAME": row["name"], "ADDRESS_CITY": row["city"], "OPENED": "Y",
        "PHONE": [{"VALUE": phone, "VALUE_TYPE": "WORK"}]}})


def bitrix_once(row):
    """Creates the deal. A timed-out call may have worked on Bitrix's side, so
    retries first look for the deal by ORIGIN_ID to avoid a duplicate."""
    origin_id = "lead-%d" % row["id"]
    if row["bx_attempts"]:
        same = bx_call(BITRIX_WEBHOOK_URL, "crm.deal.list", {
            "filter": {"ORIGINATOR_ID": "airl-workshop", "ORIGIN_ID": origin_id}, "select": ["ID"]})
        if same:
            return True, ""
    utm = {"UTM_SOURCE": row["utm_source"], "UTM_MEDIUM": row["utm_medium"],
           "UTM_CAMPAIGN": row["utm_campaign"], "UTM_CONTENT": row["utm_content"],
           "UTM_TERM": row["utm_term"]}
    comments = "Заявка №%d с сайта\nТелефон: %s\nГород: %s\nСтраница: %s" % (
        row["id"], row["phone"], row["city"], row["page"])
    bx_call(BITRIX_WEBHOOK_URL, "crm.deal.add", {"fields": {
        "TITLE": "Заявка на воркшоп: %s" % row["name"],
        "CATEGORY_ID": BITRIX_CATEGORY_ID, "STAGE_ID": BITRIX_STAGE_ID,
        "CONTACT_ID": bitrix_contact_id(row), "SOURCE_ID": "WEB", "OPENED": "Y",
        "ORIGINATOR_ID": "airl-workshop", "ORIGIN_ID": origin_id,
        "COMMENTS": comments, **{k: v for k, v in utm.items() if v}}})
    return True, ""


# ------------------------------- delivery (Sheet + Telegram + Bitrix24) ----

CHANNELS = {
    # name: (status, attempts, last_try, error columns, label)
    "sheet": ("forward_status", "forward_attempts", "forward_last_try", "forward_error", "Google Sheet"),
    "tg": ("tg_status", "tg_attempts", "tg_last_try", "tg_error", "Telegram"),
    "bx": ("bx_status", "bx_attempts", "bx_last_try", "bx_error", "Bitrix24"),
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
        if BX_ENABLED:
            self.q.put((lead_id, "bx"))

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
            elif ch == "bx":
                ok, err = bitrix_once(row)
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
        for ch, enabled in (("sheet", FORWARD_ENABLED), ("tg", TG_ENABLED), ("bx", BX_ENABLED)):
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
               "utm_term", "Страница", "Источник", "Google Sheet", "Telegram", "Bitrix24"]


def export_rows(db):
    rows = db.query("SELECT * FROM leads ORDER BY id DESC")
    for r in rows:
        yield [r["id"], local_str(r["created_at"]), r["name"], r["phone"],
               r["city"], r["utm_source"], r["utm_medium"], r["utm_campaign"],
               r["utm_content"], r["utm_term"], r["page"], r["origin"],
               r["forward_status"], r["tg_status"], r["bx_status"]]


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
    bx_failed = db.one("SELECT COUNT(*) c FROM leads WHERE bx_status='failed'")["c"]

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
                    status_html("Telegram", r["tg_status"], r["tg_error"]) +
                    status_html("Битрикс", r["bx_status"], r["bx_error"]))
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
    targets = [x for x, on in (("Google Sheet", FORWARD_ENABLED), ("Telegram", TG_ENABLED),
                                       ("Битрикс", BX_ENABLED)) if on]
    sheet_note = ("Каждая заявка также уходит в: %s." % ", ".join(targets) if targets
                  else "Заявки сохраняются только здесь.")
    if failed or tg_failed or bx_failed:
        sheet_note += " Пока не доставлено: таблица %d, Telegram %d, Битрикс %d (повторится автоматически)." % (
            failed, tg_failed, bx_failed)

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
            return self.json(200, {"ok": True, "leads": n, "forward": FORWARD_ENABLED,
                                   "telegram": TG_ENABLED, "bitrix": BX_ENABLED})
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
                              tg_status="pending" if TG_ENABLED else "skipped",
                              bx_status="pending" if BX_ENABLED else "skipped")
        log.info("new lead %s saved", lead_id)
        self.app.notifier.submit(lead_id)
        self.json(200, {"ok": True, "id": lead_id})


def serve():
    app = App()
    Handler.app = app
    app.notifier.start()
    log.info("copies to Google Sheet: %s, to Telegram: %s, to Bitrix24: %s",
             "on" if FORWARD_ENABLED else "off", "on" if TG_ENABLED else "off",
             "on" if BX_ENABLED else "off")
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
    for col, name in (("forward_status", "sheet"), ("tg_status", "telegram"), ("bx_status", "bitrix")):
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


def cmd_bitrix_setup(out_path):
    """Interactive, run by install.sh on the server. Asks for the inbound webhook
    URL (hidden input), finds the stage "Новая" of the main funnel with a read-only
    call, and writes 'url\\nstage_id\\n' to out_path (mode 600). Creates nothing."""
    import getpass
    try:
        tty = open("/dev/tty", "w", encoding="utf-8")
    except OSError:
        sys.exit("Bitrix24 setup needs an interactive terminal.")

    def say(msg):
        tty.write(msg + "\n")
        tty.flush()

    for _ in range(3):
        url = getpass.getpass("Адрес входящего вебхука Битрикс24 (ввод скрыт): ", stream=tty).strip().rstrip("/")
        if not re.match(r"^https://[\w.-]+/rest/\d+/[\w-]+$", url):
            say("  Нужен адрес вида https://компания.bitrix24.kz/rest/1/код/")
            continue
        try:
            stages = bx_call(url, "crm.dealcategory.stage.list", {"id": 0})
        except BitrixError as e:
            say("  Битрикс не принял адрес: %s" % e)
            continue
        stage = next((x for x in stages if x.get("NAME", "").strip().lower() == "новая"), None)
        if not stage:
            say("  В основной воронке нет этапа «Новая». Этапы: %s" % ", ".join(x.get("NAME", "") for x in stages))
            sys.exit("Bitrix24: этап не найден.")
        say("  Этап: %s (%s)" % (stage["NAME"], stage["STATUS_ID"]))
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("%s\n%s\n" % (url, stage["STATUS_ID"]))
        return
    sys.exit("Bitrix24: адрес не подошёл.")


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
    elif cmd == "bitrix-setup" and len(argv) > 2:
        cmd_bitrix_setup(argv[2])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
