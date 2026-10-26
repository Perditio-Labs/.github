#!/usr/bin/env python3
"""Fleet CI pass-rate scorecard for the Perditio-Labs org.

Stdlib + gh CLI only (no third-party deps). Intended to run under
C:/Python313/python.exe on a self-hosted Perditio runner.

For each non-archived Perditio-Labs repo it:
  1. lists recent Actions runs (gh api repos/Perditio-Labs/<repo>/actions/runs),
  2. tallies passed / failed / cancelled completed runs,
  3. computes pass_rate = passed / (passed + failed)  -- cancelled EXCLUDED,
  4. flags low_signal=true when (passed + failed) < LOW_SIGNAL_MIN,
  5. appends a dated row per repo to metrics/ci-pass-rate.json (a committed
     list), and re-renders CI_PASS_RATE.md (a table sorted worst-first).

Pure functions (compute_repo_stats, build_rows, render_markdown) hold all the
math and are unit-tested with monkeypatched fixture data -- no live gh in tests.
"""

import datetime
import json
import os
import subprocess
import sys

# A repo needs at least this many real (passed+failed) runs to be high-signal.
LOW_SIGNAL_MIN = 3

# How many recent runs to pull per repo.
RUNS_PER_PAGE = 50

HERE = os.path.dirname(os.path.abspath(__file__))
JSON_PATH = os.path.join(HERE, "ci-pass-rate.json")
MD_PATH = os.path.join(os.path.dirname(HERE), "CI_PASS_RATE.md")

ORG = "Perditio-Labs"


def _run_gh_json(args):
    """Run a gh command and parse stdout as JSON. Raises on non-zero exit."""
    proc = subprocess.run(
        ["gh"] + args,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(proc.stdout)


def list_repos():
    """Return a list of non-archived repo names in the org."""
    return sorted(name for name, _private in list_repos_with_visibility())


def list_repos_with_visibility():
    """Return [(name, is_private)] for non-archived repos in the org.

    Anything not explicitly PUBLIC counts as private (fail closed), so an
    INTERNAL or missing visibility never leaks a name into the public output.
    """
    data = _run_gh_json(
        ["repo", "list", ORG, "--no-archived", "--limit", "1000",
         "--json", "name,isArchived,visibility"]
    )
    return sorted(
        (r["name"], str(r.get("visibility", "")).upper() != "PUBLIC")
        for r in data if not r.get("isArchived", False)
    )


# This scorecard is published in Perditio-Labs/.github, a PUBLIC repo. Private
# repo names must never appear in it (files, history rows, or run logs). Named
# rows are ALLOWLISTED: only repos verified PUBLIC in the current listing keep a
# row; everything else (private, internal, archived, deleted, renamed, missing
# from the listing) folds into ONE counts-only aggregate row per date.
PRIVATE_AGGREGATE_LABEL = "private repos (aggregate)"


def _is_aggregate(row):
    return "private_repo_count" in row


def redact_private(rows, public_names):
    """Pure: keep named rows only for verified-public repos; fold the rest
    (and any existing aggregate rows) into ONE aggregate row per call.

    pass_rate is recomputed the same way (cancelled excluded).
    """
    public_rows = []
    agg = {"passed": 0, "failed": 0, "cancelled": 0, "total": 0, "n": 0}
    date_str = None
    for row in rows:
        date_str = row.get("date", date_str)
        if not _is_aggregate(row) and row.get("repo") in public_names:
            public_rows.append(row)
            continue
        agg["passed"] += row.get("runs_passed", 0)
        agg["failed"] += row.get("runs_failed", 0)
        agg["cancelled"] += row.get("runs_cancelled", 0)
        agg["total"] += row.get("runs_total", 0)
        agg["n"] += row.get("private_repo_count", 1)
    if agg["n"]:
        real = agg["passed"] + agg["failed"]
        public_rows.append({
            "repo": "{} x{}".format(PRIVATE_AGGREGATE_LABEL, agg["n"]),
            "private_repo_count": agg["n"],
            "date": date_str,
            "runs_total": agg["total"],
            "runs_passed": agg["passed"],
            "runs_failed": agg["failed"],
            "runs_cancelled": agg["cancelled"],
            "pass_rate": None if real == 0 else round(agg["passed"] / real, 4),
            "low_signal": real < LOW_SIGNAL_MIN,
        })
    return public_rows


def redact_history(history, public_names):
    """Pure: re-redact a loaded history list, one date at a time (idempotent)."""
    by_date = {}
    order = []
    for row in history:
        d = row.get("date")
        if d not in by_date:
            by_date[d] = []
            order.append(d)
        by_date[d].append(row)
    out = []
    for d in order:
        out.extend(redact_private(by_date[d], public_names))
    return out


def merge_snapshot(history, rows, date_str):
    """Pure: replace any existing snapshot for date_str (same-day reruns must
    not duplicate rows), then append the new one."""
    return [r for r in history if r.get("date") != date_str] + list(rows)


def fetch_runs(repo):
    """Return the list of workflow_runs dicts for a repo (most recent first)."""
    data = _run_gh_json(
        ["api", "repos/{}/{}/actions/runs?per_page={}".format(
            ORG, repo, RUNS_PER_PAGE)]
    )
    return data.get("workflow_runs", [])


def compute_repo_stats(repo, runs):
    """Pure: turn a list of run dicts into a stats dict.

    pass_rate = passed / (passed + failed), with cancelled EXCLUDED.
    When there are no real (passed+failed) runs, pass_rate is None (unknown)
    and low_signal is True.
    """
    passed = 0
    failed = 0
    cancelled = 0
    for run in runs:
        # Only completed runs carry a meaningful conclusion.
        if run.get("status") != "completed":
            continue
        conclusion = run.get("conclusion")
        if conclusion == "success":
            passed += 1
        elif conclusion in ("failure", "timed_out", "startup_failure"):
            failed += 1
        elif conclusion == "cancelled":
            cancelled += 1
        # skipped / neutral / action_required / stale are ignored (no signal).

    real = passed + failed
    if real == 0:
        pass_rate = None
    else:
        pass_rate = round(passed / real, 4)

    return {
        "repo": repo,
        "runs_total": passed + failed + cancelled,
        "runs_passed": passed,
        "runs_failed": failed,
        "runs_cancelled": cancelled,
        "pass_rate": pass_rate,
        "low_signal": real < LOW_SIGNAL_MIN,
    }


def build_rows(date_str, repos, runs_by_repo):
    """Pure: build a dated row list (one per repo) from fetched runs."""
    rows = []
    for repo in repos:
        stats = compute_repo_stats(repo, runs_by_repo.get(repo, []))
        stats["date"] = date_str
        rows.append(stats)
    return rows


def _sort_key(row):
    """Worst-first: lowest pass_rate first; unknown (None) sinks to the bottom;
    ties broken by more failures first, then repo name."""
    pr = row.get("pass_rate")
    # None -> treat as 2.0 so it sorts after any real 0.0..1.0 value.
    rate = 2.0 if pr is None else pr
    return (rate, -row.get("runs_failed", 0), row.get("repo", ""))


def render_markdown(date_str, rows):
    """Pure: render the scorecard markdown table, sorted worst-first. ASCII."""
    ordered = sorted(rows, key=_sort_key)
    lines = []
    lines.append("# Perditio-Labs Fleet CI Pass-Rate Scorecard")
    lines.append("")
    lines.append("Generated: {} (UTC). Source: GitHub Actions runs "
                 "(last {} per repo).".format(date_str, RUNS_PER_PAGE))
    lines.append("")
    lines.append("pass_rate = passed / (passed + failed); cancelled runs are "
                 "excluded. low_signal marks repos with fewer than {} real "
                 "(passed+failed) runs.".format(LOW_SIGNAL_MIN))
    lines.append("")
    lines.append("| Repo | Pass rate | Passed | Failed | Cancelled | Total | "
                 "Low signal |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    for row in ordered:
        pr = row.get("pass_rate")
        rate_str = "unknown" if pr is None else "{:.0f}%".format(pr * 100)
        low = "yes" if row.get("low_signal") else "no"
        lines.append("| {} | {} | {} | {} | {} | {} | {} |".format(
            row.get("repo", ""),
            rate_str,
            row.get("runs_passed", 0),
            row.get("runs_failed", 0),
            row.get("runs_cancelled", 0),
            row.get("runs_total", 0),
            low,
        ))
    lines.append("")
    return "\n".join(lines)


def load_history(path):
    """Load the committed JSON list of rows, or [] if absent/empty."""
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="ascii") as fh:
        text = fh.read().strip()
    if not text:
        return []
    return json.loads(text)


def save_history(path, history):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        json.dump(history, fh, indent=2, sort_keys=True)
        fh.write("\n")


def write_markdown(path, text):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write(text)


def main(argv=None):
    date_str = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%d")

    repo_vis = list_repos_with_visibility()
    repos = [name for name, _private in repo_vis]
    public_names = set(name for name, private in repo_vis if not private)
    runs_by_repo = {}
    fetch_failures = 0
    for repo in repos:
        try:
            runs_by_repo[repo] = fetch_runs(repo)
        except (subprocess.CalledProcessError, ValueError):
            # Run logs of a public repo are public: never print a repo name,
            # gh stderr or the command (both can quote the repo path).
            fetch_failures += 1
            runs_by_repo[repo] = []
    if fetch_failures:
        sys.stderr.write(
            "warn: could not fetch runs for {} repo(s)\n".format(
                fetch_failures))

    rows = redact_private(
        build_rows(date_str, repos, runs_by_repo), public_names)

    history = redact_history(
        merge_snapshot(load_history(JSON_PATH), rows, date_str),
        public_names)
    save_history(JSON_PATH, history)

    md = render_markdown(date_str, rows)
    write_markdown(MD_PATH, md)

    sys.stdout.write(
        "ci_pass_rate: wrote {} rows for {}\n".format(len(rows), date_str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
