#!/usr/bin/env bash
# Build the workshop page for https://airl.kz/ai-for-work/workshop/ into dist/airl/.
# Then copy dist/airl/ into aza9908/landing as ai-for-work/workshop/ and push:
# Firebase App Hosting publishes airl.kz from that repo.
set -euo pipefail
cd "$(dirname "$0")"
python3 app/sitetool.py build --mirror site --out dist/airl --overlay hq \
  --source https://airl-workshop.web.app \
  --base-url https://airl.kz/ai-for-work/workshop --base-path /ai-for-work/workshop/ \
  --api-url https://server.airl.kz/api/lead --whatsapp 77072314955

# Extra tags for the airl.kz version only (Meta Pixel), inserted at the end of <head>.
python3 - <<'EOF'
p = "dist/airl/index.html"
html = open(p, encoding="utf-8").read()
extra = open("airl-head.html", encoding="utf-8").read()
if "</head>" not in html:
    raise SystemExit("no </head> in " + p)
html = html.replace("  </head>", extra + "  </head>", 1) if "  </head>" in html else html.replace("</head>", extra + "</head>", 1)
open(p, "w", encoding="utf-8").write(html)
print("added airl-head.html to", p)
EOF
