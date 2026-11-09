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
