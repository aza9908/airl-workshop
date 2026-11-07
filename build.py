#!/usr/bin/env python3
"""Assemble install.sh from install.template.sh + app/*.py (single file to upload to the VPS)."""
import os

here = os.path.dirname(os.path.abspath(__file__))
tpl = open(os.path.join(here, "install.template.sh"), encoding="utf-8").read()
for marker, name, delim in (("@@APP_PY@@", "app.py", "AIRL_APP_PY_EOF"),
                            ("@@SITETOOL_PY@@", "sitetool.py", "AIRL_SITETOOL_PY_EOF")):
    code = open(os.path.join(here, "app", name), encoding="utf-8").read().rstrip("\n")
    assert delim not in code, "heredoc delimiter found inside " + name
    assert marker in tpl
    tpl = tpl.replace(marker, code)
out = os.path.join(here, "install.sh")
with open(out, "w", encoding="utf-8", newline="\n") as f:
    f.write(tpl)
os.chmod(out, 0o755)
print("written", out, len(tpl), "bytes")
