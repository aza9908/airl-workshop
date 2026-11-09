#!/usr/bin/env python3
"""
Copy the deployed workshop page and prepare it for the VPS. Stdlib only.

  sitetool.py mirror --source https://airl-workshop.web.app --out DIR
      Downloads index.html and every file it references (JS, CSS, fonts,
      images, icons, og-image) into DIR, keeping paths.

  sitetool.py build --mirror DIR --out DIR2 --base-url https://example.kz --source URL
          [--whatsapp NUM] [--api-url URL] [--base-path /sub/path/] [--overlay DIR]
      Copies DIR to DIR2, points the form at --api-url instead of Google Apps
      Script, sets the WhatsApp number, swaps in higher-quality files, rewrites
      links for a sub-path and to the old host, renames changed files by hash.
      Prints JSON: {"forward_url": "<the Apps Script URL found>", ...}

  For airl.kz/ai-for-work/workshop/:
      sitetool.py build --mirror site --out dist --overlay hq \
          --base-url https://airl.kz/ai-for-work/workshop --base-path /ai-for-work/workshop/ \
          --api-url https://server.airl.kz/api/lead --whatsapp 77072314955
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


def _read(p):
    with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def _write(p, text):
    with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)


def _text_files(root, exts=(".html", ".js", ".mjs", ".css", ".webmanifest")):
    for dirpath, _, files in os.walk(root):
        for name in files:
            if name.endswith(exts):
                yield os.path.join(dirpath, name)


def _sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def build(mirror_dir, out, base_url, source, whatsapp=None, api_url="/api/lead",
          base_path="/", overlay=None):
    """base_url: public address of the page (for og:url/og:image), e.g.
    https://airl.kz/ai-for-work/workshop. base_path: URL path the files are
    served under, e.g. /ai-for-work/workshop/. overlay: folder with files that
    replace mirrored ones by the same relative path (higher-quality photos)."""
    if not os.path.exists(os.path.join(mirror_dir, "index.html")):
        sys.exit("ERROR: %s has no index.html" % mirror_dir)
    base_path = "/" + base_path.strip("/") + "/" if base_path.strip("/") else "/"
    if os.path.exists(out):
        shutil.rmtree(out)
    shutil.copytree(mirror_dir, out, ignore=shutil.ignore_patterns(".mirror.json"))
    original = {os.path.relpath(p, out): _sha(p)
                for p in (os.path.join(d, n) for d, _, fs in os.walk(out) for n in fs)}

    # 1. higher-quality files over the mirrored ones (same names)
    replaced = []
    if overlay:
        for dirpath, _, files in os.walk(overlay):
            for name in files:
                src = os.path.join(dirpath, name)
                rel = os.path.relpath(src, overlay)
                if rel not in original:
                    print("WARNING: overlay file %s has no counterpart in the page, skipped" % rel,
                          file=sys.stderr)
                    continue
                shutil.copyfile(src, os.path.join(out, rel))
                replaced.append(rel)

    # 2. form: Google Apps Script -> our backend
    found, patched = [], []
    for p in _text_files(out, (".js", ".mjs", ".html")):
        text = _read(p)
        urls = GAS_RE.findall(text)
        if urls:
            found += urls
            _write(p, GAS_RE.sub(api_url, text))
            patched.append(os.path.relpath(p, out))
    uniq = sorted(set(found))
    if len(uniq) != 1:
        sys.exit("ERROR: expected exactly one Google Apps Script URL in the site code, found %d. "
                 "The page code has changed; the form would not reach the new server." % len(uniq))

    # 3. WhatsApp number of the manager
    wa = normalize_wa(whatsapp) if whatsapp is not None else None
    if wa is not None:
        wa_re = re.compile(r'([`"\'])(' + re.escape(api_url) + r')\1(\s*,\s*[A-Za-z_$][\w$]*\s*=\s*)'
                           r'([`"\'])([^`"\'\n]{0,30})\4(\s*\.replace\(/\\D/g)')
        hits = 0
        for rel in patched:
            p = os.path.join(out, rel)
            text, n = wa_re.subn(lambda m: "%s%s%s%s%s%s%s%s" % (
                m.group(1), m.group(2), m.group(1), m.group(3), m.group(4), wa, m.group(4), m.group(6)),
                _read(p))
            hits += n
            if n:
                _write(p, text)
        if hits != 1 and wa:
            print("WARNING: could not find the WhatsApp number setting in the page code (found %d); "
                  "the WhatsApp step stays off." % hits, file=sys.stderr)
            wa = ""

    # 4. absolute links to the old host (og:url, og:image)
    index = os.path.join(out, "index.html")
    text = _read(index)
    old = source.rstrip("/")
    new = base_url.rstrip("/")
    if old and new and old != new:
        text = text.replace(old + "/", new + "/").replace(old, new)
    if new and 'rel="canonical"' not in text:
        text = text.replace("</head>", '  <link rel="canonical" href="%s/">\n  </head>' % new, 1)
    _write(index, text)

    # 5. files whose content changed get a new name (name.<hash>.ext), so
    # browsers that cached the old file for a year load the new one
    renamed = {}
    for dirpath, _, files in os.walk(out):
        for name in files:
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, out)
            if not rel.startswith("assets" + os.sep) or original.get(rel) == _sha(p):
                continue
            stem, ext = os.path.splitext(name)
            new_name = "%s.%s%s" % (stem, _sha(p)[:8], ext)
            os.rename(p, os.path.join(dirpath, new_name))
            renamed[name] = new_name
    if renamed:
        pat = re.compile(r"(?<=[/\"'`(])(%s)(?=[\"'`?#)])" % "|".join(re.escape(n) for n in renamed))
        for p in _text_files(out):
            text = _read(p)
            new_text = pat.sub(lambda m: renamed[m.group(1)], text)
            if new_text != text:
                _write(p, new_text)

    # 6. serve from a sub-path: /x -> <base_path>x for files that exist here
    if base_path != "/":
        local = lambda path: os.path.exists(os.path.join(out, path.lstrip("/").split("?")[0].split("#")[0]))
        attr = re.compile(r'(\s(?:src|href)=["\'])(/[^/"\'][^"\']*)(["\'])')
        cssurl = re.compile(r'(url\(\s*["\']?)(/[^/"\')][^"\')]*)(["\']?\s*\))')
        jsstr = re.compile(r'([`"\'])(/assets/[^`"\'\s]+)([`"\'])')
        fix = lambda m: m.group(1) + (base_path + m.group(2).lstrip("/") if local(m.group(2)) else m.group(2)) + m.group(3)
        for p in _text_files(out):
            text = _read(p)
            if p.endswith(".html"):
                new_text = attr.sub(fix, text)
            elif p.endswith(".css"):
                new_text = cssurl.sub(fix, text)
            else:
                new_text = jsstr.sub(fix, text)
            if new_text != text:
                _write(p, new_text)
        left = [m.group(2) for m in attr.finditer(_read(index)) if local(m.group(2))]
        if left:
            sys.exit("ERROR: some links still point to the site root: %s" % left)
    elif not os.path.exists(os.path.join(out, "404.html")):
        _write(os.path.join(out, "404.html"), NOT_FOUND)

    rename = lambda r: os.path.join(os.path.dirname(r), renamed.get(os.path.basename(r), os.path.basename(r)))
    print(json.dumps({"forward_url": uniq[0], "patched": [rename(r) for r in patched],
                      "photos": sorted(rename(r) for r in replaced), "whatsapp": wa,
                      "api_url": api_url, "base_path": base_path}))


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
    b.add_argument("--api-url", default="/api/lead", help="where the form sends leads")
    b.add_argument("--base-path", default="/", help="URL path the page is served under")
    b.add_argument("--overlay", default=None, help="folder with higher-quality files to swap in")
    a = ap.parse_args()
    if a.cmd == "mirror":
        mirror(a.source, a.out)
    else:
        build(a.mirror, a.out, a.base_url, a.source, a.whatsapp, a.api_url, a.base_path, a.overlay)


if __name__ == "__main__":
    main()
