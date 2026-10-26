#!/usr/bin/env python3
"""private_name_guard.py - fail a PUBLIC repo's PR / push that adds a PRIVATE
org repo name. Prints ONLY location (file:line) and a count, NEVER the name:
the logs and annotations of a public repo are public.

The private names are listed at RUNTIME with a read-only GitHub App token
(GH_TOKEN); nothing private is stored in this repo. A name is matched as a
whole token (case-insensitive; letters, digits, '_' and '-' bind; '/', '.',
space and punctuation separate). Skipped: names shorter than --min-len, names
in --allowlist (generic words only), and names that are also a PUBLIC repo of
the org.

What is scanned is decided from git OBJECTS, never from a diff, so repository
attributes, diff drivers and line-separator tricks cannot hide content:
  --diff BASE HEAD   every blob, path and commit object reachable from HEAD
                     and not from BASE (so a name added in one PR commit and
                     removed in a later one is still caught: once merged it
                     is public history); paths already in BASE are not
                     re-reported, and deleting a leaked path always passes
  --tree [--since S] every path and blob of the current tree, plus every blob,
                     path and commit object reachable from HEAD and not from
                     S (the pushed commits); without --since, the whole
                     history
  --pr-event         also scan the PR title, body and branch name, read from the event JSON
                     at $GITHUB_EVENT_PATH (never passed through step env,
                     whose values the runner prints in the public log)

Exit: 0 clean, 1 findings, 2 capability guard (cannot list private repos, so
the guard cannot fire), 3 internal or usage error (incl. any git failure).
Stdlib only, ASCII only. Never executes repository content.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
BOUNDARY = "A-Za-z0-9_-"
SHA_RE = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")


class QuietParser(argparse.ArgumentParser):
    """Usage errors must not echo argument values (they could hold a name)."""

    def error(self, message):
        print("ERROR: invalid arguments; the guard did not run.")
        sys.exit(3)


class GuardError(Exception):
    pass


def list_org_repos(org, token):
    url = "%s/orgs/%s/repos?type=all&per_page=100" % (API, org)
    repos = []
    while url:
        req = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json", "Authorization": "Bearer " + token,
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "private-name-guard"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            repos.extend(json.loads(resp.read()))
            link = resp.headers.get("Link") or ""
        url = None
        for part in link.split(","):
            if 'rel="next"' in part:
                url = part[part.find("<") + 1:part.find(">")]
    return repos


def read_allowlist(path):
    out = set()
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip().lower()
                if line:
                    out.add(line)
    return out


def build_matcher(repos, allow, min_len):
    priv = {r["name"].lower() for r in repos
            if r.get("private") or r.get("visibility") in ("private", "internal")}
    public = {r["name"].lower() for r in repos
              if not (r.get("private") or r.get("visibility") in ("private", "internal"))}
    names = {n for n in priv if len(n) >= min_len and n not in allow and n not in public}
    if not names:
        return None, len(priv), 0
    alts = "|".join(re.escape(n) for n in sorted(names, key=lambda s: (-len(s), s)))
    rx = re.compile(r"(?<![%s])(?:%s)(?![%s])" % (BOUNDARY, alts, BOUNDARY), re.IGNORECASE)
    return rx, len(priv), len(names)


def git(*args, stdin=None):
    return subprocess.run(["git", "-c", "core.quotepath=off", *args], check=True, input=stdin,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def cat_objects(shas, want_type):
    """Yield (sha, bytes) for each sha via `git cat-file --batch`, checking the
    framing completely: header '<sha> <type> <size>', exactly size bytes, LF."""
    if not shas:
        return
    out = git("cat-file", "--batch", stdin=("\n".join(shas) + "\n").encode())
    pos = 0
    for sha in shas:
        nl = out.find(b"\n", pos)
        if nl < 0:
            raise GuardError("truncated batch")
        header = out[pos:nl].decode("ascii", "replace").split(" ")
        if len(header) != 3 or header[0] != sha or header[1] != want_type or not header[2].isdigit():
            raise GuardError("unexpected object")
        size = int(header[2])
        end = nl + 1 + size
        if out[end:end + 1] != b"\n":
            raise GuardError("bad framing")
        yield sha, out[nl + 1:end]
        pos = end + 1
    if pos != len(out):
        raise GuardError("trailing batch data")


def ls_tree(commit):
    """Yield (mode, type, sha, path) for every entry of a commit's tree."""
    for rec in git("ls-tree", "-r", "-t", "-z", "--full-tree", commit).split(b"\0"):
        if not rec:
            continue
        meta, sep, p = rec.partition(b"\t")
        parts = meta.decode("ascii").split(" ")
        if not sep or len(parts) != 3 or not SHA_RE.match(parts[2]):
            raise GuardError("bad ls-tree record")
        yield parts[0], parts[1], parts[2], p.decode("utf-8", "replace")


class Findings:
    def __init__(self, rx):
        self.rx = rx
        self.locations = []
        self.count = 0
        self.seen = set()

    def text(self, kind, label, text, file=None):
        # LF only: other separators (VT, FF, CR, U+2028 ...) stay inside a line.
        for i, line in enumerate(text.split("\n"), 1):
            self.line(kind, label, i, line, file)

    def line(self, kind, label, line_no, line, file=None):
        key = (kind, label, line_no)
        if key in self.seen:
            return
        self.seen.add(key)
        n = len(self.rx.findall(line))
        if n:
            self.count += n
            self.locations.append((kind, label, line_no, file))


def scan_range(f, head, base=None):
    """Scan every commit, path and blob reachable from head and not from base."""
    for ref in (head, base):
        if ref is not None and not SHA_RE.match(git("rev-parse", "--verify", "%s^{commit}" % ref)
                                                .decode("ascii").strip()):
            raise GuardError("bad revision")
    excl = ["^%s" % base] if base else []
    commits = git("rev-list", head, *excl).decode("ascii").split()
    new_objects = set(git("rev-list", "--objects", "--no-object-names", head, *excl).decode("ascii").split())
    base_paths = set()
    if base:
        base_paths = {path for _, _, _, path in ls_tree(base)}
    blob_path = {}
    for c in commits:                       # newest first: the latest path wins
        for mode, typ, sha, path in ls_tree(c):
            if path not in base_paths:
                f.line("path", path, 0, path, file=path)
            if typ == "blob" and sha in new_objects and sha not in blob_path:
                blob_path[sha] = path
    for sha, data in cat_objects(list(blob_path), "blob"):
        # The key holds the blob id: two versions of one path are two inputs.
        f.text(("file", sha), blob_path[sha], data.decode("utf-8", "replace"), file=blob_path[sha])
    for sha, data in cat_objects(commits, "commit"):
        f.text("commit", "commit %s" % sha[:10], data.decode("utf-8", "replace"))


def scan_head_tree(f):
    """Every path and blob of the CURRENT tree (HEAD), whatever its history."""
    blob_path = {}
    for mode, typ, sha, path in ls_tree("HEAD"):
        f.line("path", path, 0, path, file=path)
        if typ == "blob" and sha not in blob_path:
            blob_path[sha] = path
    for sha, data in cat_objects(list(blob_path), "blob"):
        f.text(("file", sha), blob_path[sha], data.decode("utf-8", "replace"), file=blob_path[sha])


def safe(s):
    """One printable line: control characters (incl. newline) are escaped, so an
    untrusted path can never start a workflow command line."""
    return "".join(ch if 32 <= ord(ch) != 127 else "\\x%02x" % ord(ch) for ch in s)


def annotation_escape(s):
    return (s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            .replace(":", "%3A").replace(",", "%2C"))


def main(argv=None):
    p = QuietParser()
    p.add_argument("--org", required=True)
    p.add_argument("--allowlist")
    p.add_argument("--min-len", type=int, default=5)
    p.add_argument("--min-private", type=int, default=20)
    p.add_argument("--diff", nargs=2, metavar=("BASE", "HEAD"))
    p.add_argument("--tree", action="store_true")
    p.add_argument("--since", help="with --tree: history already scanned up to this commit (push 'before')")
    p.add_argument("--pr-event", action="store_true")
    p.add_argument("--fixture-repos", help="offline JSON list of org repos (tests)")
    a = p.parse_args(argv)
    if bool(a.diff) == bool(a.tree):
        p.error("exactly one of --diff or --tree")

    if a.fixture_repos:
        with open(a.fixture_repos, encoding="utf-8") as fh:
            repos = json.load(fh)
    else:
        token = os.environ.get("GH_TOKEN", "")
        try:
            repos = list_org_repos(a.org, token)
        except (urllib.error.URLError, OSError, ValueError) as e:
            code = getattr(e, "code", "network")
            print("CAPABILITY GUARD: cannot list the org's repos (HTTP %s); it cannot list private repos, so this "
                  "guard cannot fire." % code)
            return 2
    rx, n_priv, n_names = build_matcher(repos, read_allowlist(a.allowlist), a.min_len)
    if n_priv < a.min_private or rx is None:
        print("CAPABILITY GUARD: the token lists %d private repos (minimum %d) and %d usable names; "
              "it cannot list private repos, so this guard cannot fire." % (n_priv, a.min_private, n_names))
        return 2
    print("private repo names guarded: %d (of %d private repos)" % (n_names, n_priv))

    f = Findings(rx)
    try:
        if a.diff:
            scan_range(f, a.diff[1], a.diff[0])
        else:
            scan_head_tree(f)
            scan_range(f, "HEAD", a.since)
        if a.pr_event:
            with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as fh:
                pr = json.load(fh).get("pull_request") or {}
            head_ref = (pr.get("head") or {}).get("ref") or ""
            for kind, value in (("pull request title", pr.get("title")), ("pull request body", pr.get("body")),
                                ("pull request branch name", head_ref)):
                if value:
                    f.text(kind, kind, value)
    except subprocess.CalledProcessError as e:
        print("ERROR: git failed (exit %d); the guard did not complete." % e.returncode)
        return 3
    except (GuardError, ValueError, UnicodeDecodeError, OSError, KeyError):
        print("ERROR: could not read the git objects; the guard did not complete.")
        return 3

    if not f.count:
        print("PASS: no private repo name found.")
        return 0
    for kind, label, line_no, file in f.locations:
        # A path can itself hold a name: mask it before it reaches the public log.
        shown = rx.sub("<withheld>", label)
        where = "%s:%d" % (shown, line_no) if line_no else "%s (path)" % shown
        print("private repo name found at %s" % safe(where))
        if file and shown == label and os.environ.get("GITHUB_ACTIONS") == "true":
            print("::error file=%s,line=%d::private repo name found here (name withheld)"
                  % (annotation_escape(file), max(line_no, 1)))
    print("FAIL: %d private repo name occurrence(s) in %d location(s). Names are withheld because this log is "
          "public. Remove them, or (generic words only) add the word to scripts/private-name-allowlist.txt."
          % (f.count, len(f.locations)))
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as e:  # never echo data that could carry a name
        print("ERROR: %s; the guard did not complete." % type(e).__name__)
        sys.exit(3)
