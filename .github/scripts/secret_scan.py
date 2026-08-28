#!/usr/bin/env python3
"""secret_scan.py - hardened, self-contained secret-pattern scan for CI distribution.

LIGHTWEIGHT HEURISTIC, not an exhaustive secret scanner. Catches common high-confidence
token shapes; complements (does not replace) provider-side scanning.

Hardened:
- Root = argv[1] or CWD; safe to vendor into any repo.
- Scans ONLY git-tracked files (`git ls-files`). FAILS CLOSED (exit 2) if not a git repo / no tracked files,
  rather than recursively reading untracked files.
- Skips symlinks (repo confinement; a PR cannot make it read runner-local files).
- Scans full line content (no length-based bypass).
- NEVER prints matched line CONTENT - reports file:line:label only (no secret VALUE ever in logs).
- KNOWN BLIND SPOT (accepted, documented): test/fixture files (*.test.*, test_*.py, /tests/, fixtures, mocks,
  snapshots) are skipped to keep false positives ~0, because security-tool test fixtures legitimately embed
  fabricated keys. Real secrets accidentally committed ONLY inside a test fixture path will not be flagged.
Pure standard library. Exit 0 = clean, 1 = findings (location only), 2 = could-not-enumerate (fail closed).
"""
from __future__ import annotations
import re
import subprocess
import sys
from pathlib import Path

SECRET_PATTERNS = [
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key id"),
    (re.compile(r"-----BEGIN (RSA|OPENSSH|EC|DSA|PRIVATE) KEY-----"), "private key header"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}"), "GitHub token"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9-]{12,}"), "Slack token"),
    (re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"), "Anthropic API key"),
    (re.compile(r"sk-(proj-)?[A-Za-z0-9]{32,}"), "OpenAI-style API key"),
    (re.compile(r"AIza[0-9A-Za-z_-]{35}"), "Google API key"),
    (re.compile(r'"private_key":\s*"-----BEGIN'), "GCP service-account private key"),
    (re.compile(r'"type":\s*"service_account"'), "GCP service-account JSON"),
]

IGNORE_SUBSTR = (
    "node_modules/", ".git/", "/dist/", "/build/", "/.next/", "/coverage/",
    "test_no_secrets", "secret_pattern_check.py", "secret_scan.py",
    "/fixtures/", "/__fixtures__/", "/testdata/", "/golden/", "/snapshots/",
    "/test/", "/tests/", "/__tests__/", "/e2e/", "/spec/", "/mocks/", "/__mocks__/",
)
IGNORE_NAME_RE = re.compile(r"(.*\.(test|spec)\.[jt]sx?$)|(^test_.*\.py$)|(.*_test\.py$)|(.*\.test\.py$)|(conftest\.py$)")
IGNORE_SUFFIX = (
    ".example", ".sample", ".lock", "-lock.json", ".lockb", ".min.js", ".map",
    ".svg", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".woff", ".woff2", ".ttf",
)
IGNORE_NAMES = {".env.example", ".env.sample", ".env.template", "package-lock.json",
                "pnpm-lock.yaml", "yarn.lock", "poetry.lock", "uv.lock", "Pipfile.lock"}
# Public-by-design client keys (Firebase web apiKey is NOT a secret) -> not a leak.
PUBLIC_KEY_CTX = re.compile(r"FIREBASE|NEXT_PUBLIC|VITE_|REACT_APP_|EXPO_PUBLIC")


def tracked_files(root: Path):
    try:
        out = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, text=True, timeout=120)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    files = [f for f in out.stdout.split("\0") if f]
    return files if files else None


def ignored(rel: str) -> bool:
    low = rel.lower()
    name = rel.rsplit("/", 1)[-1]
    if name in IGNORE_NAMES or IGNORE_NAME_RE.match(name):
        return True
    if any(s in low for s in IGNORE_SUBSTR):
        return True
    if any(low.endswith(s) for s in IGNORE_SUFFIX):
        return True
    return False


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
    files = tracked_files(root)
    if files is None:
        print("ERROR secret_scan: not a git repo or no tracked files - failing closed (exit 2)")
        return 2
    findings = []  # (file, line, label) - NO content, ever
    for rel in files:
        if ignored(rel):
            continue
        p = root / rel
        if p.is_symlink() or not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            for pat, label in SECRET_PATTERNS:
                if pat.search(line):
                    if label == "Google API key" and PUBLIC_KEY_CTX.search(line):
                        continue
                    findings.append((rel, lineno, label))
                    break
    if findings:
        print(f"FAIL secret_scan: {len(findings)} match(es) (location only; values NOT printed):")
        for f in findings:
            print(f"  {f[0]}:{f[1]}  {f[2]}")
        return 1
    print("PASS secret_scan: no obvious secret patterns in tracked files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
