#!/usr/bin/env python3
'''Checks publishable working-tree files for obvious private content.'''

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_NAMES = {
    ".env", ".env.local", ".env.production", ".dev.vars",
    "id_rsa", "id_ed25519", "credentials.json", "service-account.json",
}
FORBIDDEN_SUFFIXES = (".pem", ".p12", ".pfx", ".key", ".sam")
PATTERNS = (
    ("private key", rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    ("GitHub token", rb"(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,})"),
    ("API token", rb"(?:sk-(?:proj-)?[A-Za-z0-9_-]{24,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{16,})"),
    ("cloud key", rb"(?:AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[A-Za-z0-9_-]{30,})"),
    ("credentials in URL", rb"[a-z]+://[^\s/@:]{1,60}:[^\s/@]{2,60}@"),
    ("personal home path", rb"/Users/(?!example/|username/|your-name/)[A-Za-z0-9_.-]+/"),
    ("private LAN IP", rb"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2[0-9]|3[01])\.\d{1,3}\.\d{1,3})\b"),
    ("internal hostname", rb"\b[A-Za-z0-9_.-]+\.(?:lan|internal|corp)\b"),
    ("personal email", rb"[A-Za-z0-9._%+-]+@(?:qq|163|126|gmail|outlook)\.com"),
)
COMPILED = [(label, re.compile(pattern, re.IGNORECASE)) for label, pattern in PATTERNS]


def main() -> int:
    raw = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    )
    paths = [Path(part.decode()) for part in raw.split(b"\x00") if part]
    errors: list[str] = []
    scanned = 0
    for rel in paths:
        # This scanner intentionally contains patterns as data.
        if rel == Path("tools/check-public-source.py"):
            continue
        target = ROOT / rel
        if not target.is_file():
            continue
        scanned += 1
        name = rel.name.lower()
        if name in FORBIDDEN_NAMES or name.endswith(FORBIDDEN_SUFFIXES):
            errors.append(f"{rel}: forbidden private file type")
            continue
        data = target.read_bytes()
        if b"\x00" in data[:4096]:
            continue
        for label, pattern in COMPILED:
            if pattern.search(data):
                errors.append(f"{rel}: {label}")
    if errors:
        for error in errors:
            print("ERROR:", error)
        return 1
    print(f"Public source check: passed ({scanned} working-tree files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
