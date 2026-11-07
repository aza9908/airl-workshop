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
