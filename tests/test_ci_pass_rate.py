#!/usr/bin/env python3
"""Unit tests for metrics/ci_pass_rate.py.

Stdlib only (unittest). No live gh: the pure math functions are exercised with
in-memory fixture run dicts, and the gh boundary is monkeypatched.

Run: C:/Python313/python.exe -m unittest tests.test_ci_pass_rate -v
  or C:/Python313/python.exe tests/test_ci_pass_rate.py
"""

import os
import sys
import unittest

# Make metrics/ importable regardless of cwd.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "metrics"))

import ci_pass_rate as cpr  # noqa: E402


def _run(conclusion, status="completed"):
    return {"status": status, "conclusion": conclusion}


class ComputeRepoStatsTest(unittest.TestCase):
    def test_cancelled_excluded_from_pass_rate(self):
        runs = [
            _run("success"),
            _run("success"),
            _run("failure"),
            _run("cancelled"),
            _run("cancelled"),
        ]
        stats = cpr.compute_repo_stats("demo", runs)
        # 2 passed, 1 failed -> 2/3; cancelled must not change the denominator.
        self.assertEqual(stats["runs_passed"], 2)
        self.assertEqual(stats["runs_failed"], 1)
        self.assertEqual(stats["runs_cancelled"], 2)
        self.assertEqual(stats["runs_total"], 5)
        self.assertAlmostEqual(stats["pass_rate"], round(2 / 3, 4))
        self.assertFalse(stats["low_signal"])

    def test_all_cancelled_is_unknown_and_low_signal(self):
        runs = [_run("cancelled"), _run("cancelled"), _run("cancelled")]
        stats = cpr.compute_repo_stats("demo", runs)
        self.assertIsNone(stats["pass_rate"])
        self.assertTrue(stats["low_signal"])
        self.assertEqual(stats["runs_cancelled"], 3)
        self.assertEqual(stats["runs_total"], 3)

    def test_zero_real_runs_is_unknown_and_low_signal(self):
        stats = cpr.compute_repo_stats("empty", [])
        self.assertEqual(stats["runs_total"], 0)
        self.assertIsNone(stats["pass_rate"])
        self.assertTrue(stats["low_signal"])

    def test_low_signal_threshold_boundary(self):
        # Exactly 2 real runs -> below the min (3) -> low_signal True.
        two = [_run("success"), _run("failure")]
        self.assertTrue(cpr.compute_repo_stats("two", two)["low_signal"])
        # Exactly 3 real runs -> meets the min -> low_signal False.
        three = [_run("success"), _run("failure"), _run("success")]
        self.assertFalse(cpr.compute_repo_stats("three", three)["low_signal"])

    def test_pass_rate_rounds_correctly(self):
        # 1 of 3 -> 0.3333 (4dp).
        runs = [_run("success"), _run("failure"), _run("failure")]
        stats = cpr.compute_repo_stats("r", runs)
        self.assertEqual(stats["pass_rate"], 0.3333)
        # all pass -> 1.0
        allpass = [_run("success")] * 4
        self.assertEqual(cpr.compute_repo_stats("a", allpass)["pass_rate"], 1.0)
        # all fail -> 0.0
        allfail = [_run("failure")] * 4
        self.assertEqual(cpr.compute_repo_stats("f", allfail)["pass_rate"], 0.0)

    def test_non_completed_runs_ignored(self):
        runs = [
            _run("success"),
            _run(None, status="in_progress"),
            _run(None, status="queued"),
        ]
        stats = cpr.compute_repo_stats("r", runs)
        self.assertEqual(stats["runs_passed"], 1)
        self.assertEqual(stats["runs_failed"], 0)
        self.assertEqual(stats["runs_total"], 1)

    def test_timed_out_and_startup_failure_count_as_failed(self):
        runs = [
            _run("success"),
            _run("timed_out"),
            _run("startup_failure"),
        ]
        stats = cpr.compute_repo_stats("r", runs)
        self.assertEqual(stats["runs_passed"], 1)
        self.assertEqual(stats["runs_failed"], 2)
        self.assertAlmostEqual(stats["pass_rate"], round(1 / 3, 4))

    def test_skipped_and_neutral_ignored(self):
        runs = [_run("success"), _run("skipped"), _run("neutral")]
        stats = cpr.compute_repo_stats("r", runs)
        self.assertEqual(stats["runs_passed"], 1)
        self.assertEqual(stats["runs_failed"], 0)
        self.assertEqual(stats["runs_cancelled"], 0)
        self.assertEqual(stats["runs_total"], 1)


class BuildRowsTest(unittest.TestCase):
    def test_build_rows_attaches_date_per_repo(self):
        runs_by_repo = {
            "a": [_run("success"), _run("failure"), _run("success")],
            "b": [],
        }
        rows = cpr.build_rows("2026-06-30", ["a", "b"], runs_by_repo)
        self.assertEqual(len(rows), 2)
        for row in rows:
            self.assertEqual(row["date"], "2026-06-30")
        by_repo = {r["repo"]: r for r in rows}
        self.assertEqual(by_repo["a"]["pass_rate"], round(2 / 3, 4))
        self.assertIsNone(by_repo["b"]["pass_rate"])
        self.assertTrue(by_repo["b"]["low_signal"])


class RenderMarkdownTest(unittest.TestCase):
    def _rows(self):
        runs_by_repo = {
            "good": [_run("success")] * 5,
            "bad": [_run("failure")] * 4 + [_run("success")],
            "unknown": [],
        }
        return cpr.build_rows(
            "2026-06-30", ["good", "bad", "unknown"], runs_by_repo)

    def test_sorted_worst_first_unknown_last(self):
        md = cpr.render_markdown("2026-06-30", self._rows())
        # ASCII only.
        self.assertTrue(all(ord(c) < 128 for c in md))
        body = md.splitlines()
        data_lines = [ln for ln in body if ln.startswith("| ") and
                      "Repo" not in ln and "---" not in ln]
        order = [ln.split("|")[1].strip() for ln in data_lines]
        # 'bad' (20%) before 'good' (100%); 'unknown' sinks to the bottom.
        self.assertEqual(order, ["bad", "good", "unknown"])

    def test_unknown_renders_as_word(self):
        md = cpr.render_markdown("2026-06-30", self._rows())
        self.assertIn("unknown", md)
        self.assertIn("100%", md)
        self.assertIn("20%", md)


class HistoryRoundTripTest(unittest.TestCase):
    def test_load_save_round_trip(self):
        import tempfile
        rows = cpr.build_rows(
            "2026-06-30", ["a"], {"a": [_run("success"), _run("failure")]})
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "ci-pass-rate.json")
            self.assertEqual(cpr.load_history(path), [])  # absent -> []
            cpr.save_history(path, rows)
            loaded = cpr.load_history(path)
            self.assertEqual(loaded, rows)

    def test_empty_file_loads_as_empty_list(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "ci-pass-rate.json")
            with open(path, "w", encoding="ascii") as fh:
                fh.write("")
            self.assertEqual(cpr.load_history(path), [])


class GhBoundaryMonkeypatchTest(unittest.TestCase):
    """Prove the gh-facing functions parse fixture JSON without invoking gh."""

    def test_list_repos_filters_archived(self):
        captured = {}

        def fake(args):
            captured["args"] = args
            return [
                {"name": "live", "isArchived": False},
                {"name": "old", "isArchived": True},
            ]

        orig = cpr._run_gh_json
        cpr._run_gh_json = fake
        try:
            repos = cpr.list_repos()
        finally:
            cpr._run_gh_json = orig
        self.assertEqual(repos, ["live"])
        self.assertIn("repo", captured["args"])

    def test_fetch_runs_extracts_workflow_runs(self):
        def fake(args):
            self.assertEqual(args[0], "api")
            return {"workflow_runs": [_run("success"), _run("failure")]}

        orig = cpr._run_gh_json
        cpr._run_gh_json = fake
        try:
            runs = cpr.fetch_runs("demo")
        finally:
            cpr._run_gh_json = orig
        self.assertEqual(len(runs), 2)


class PrivateRedactionTest(unittest.TestCase):
    """Perditio-Labs/.github is PUBLIC: private repo names must never reach
    the published scorecard (2026-10-26 leak on the ci-metrics branch)."""

    PUB = {"pub"}

    def _rows(self, date="2026-10-26"):
        return cpr.build_rows(date, ["pub", "secret-a", "secret-b"], {
            "pub": [_run("success"), _run("failure")],
            "secret-a": [_run("success"), _run("success"), _run("cancelled")],
            "secret-b": [_run("failure")],
        })

    def test_markdown_has_no_private_names(self):
        rows = cpr.redact_private(self._rows(), self.PUB)
        md = cpr.render_markdown("2026-10-26", rows)
        self.assertNotIn("secret-a", md)
        self.assertNotIn("secret-b", md)
        self.assertIn("pub", md)
        self.assertIn(cpr.PRIVATE_AGGREGATE_LABEL + " x2", md)

    def test_aggregate_counts_and_rate(self):
        rows = cpr.redact_private(self._rows(), self.PUB)
        agg = [r for r in rows if "private_repo_count" in r]
        self.assertEqual(len(agg), 1)
        self.assertEqual(agg[0]["private_repo_count"], 2)
        self.assertEqual(agg[0]["runs_passed"], 2)
        self.assertEqual(agg[0]["runs_failed"], 1)
        self.assertEqual(agg[0]["runs_cancelled"], 1)
        self.assertEqual(agg[0]["runs_total"], 4)
        self.assertEqual(agg[0]["pass_rate"], round(2 / 3, 4))

    def test_unknown_names_are_private_allowlist(self):
        # a historical repo absent from the listing (deleted/renamed) is hidden
        rows = cpr.build_rows("2026-06-30", ["gone-repo"], {})
        out = cpr.redact_history(rows, self.PUB)
        self.assertNotIn("gone-repo", [r["repo"] for r in out])

    def test_history_redaction_idempotent_and_merges_aggregates(self):
        old = self._rows() + cpr.build_rows("2026-06-30", ["secret-a"], {})
        out = cpr.redact_history(old, self.PUB)
        names = [r["repo"] for r in out]
        self.assertNotIn("secret-a", names)
        self.assertEqual(cpr.redact_history(out, self.PUB), out)
        # pub turns private later: still ONE aggregate per date, counts merged
        again = cpr.redact_history(out, set())
        day = [r for r in again if r["date"] == "2026-10-26"]
        self.assertEqual(len(day), 1)
        self.assertEqual(day[0]["private_repo_count"], 3)
        self.assertEqual(day[0]["runs_total"], 6)

    def test_same_day_rerun_replaces_snapshot(self):
        first = cpr.redact_private(self._rows(), self.PUB)
        hist = cpr.merge_snapshot([], first, "2026-10-26")
        hist = cpr.merge_snapshot(hist, first, "2026-10-26")
        self.assertEqual(len(hist), len(first))

    def test_visibility_fails_closed(self):
        orig = cpr._run_gh_json
        cpr._run_gh_json = lambda args: [
            {"name": "p", "isArchived": False, "visibility": "PUBLIC"},
            {"name": "i", "isArchived": False, "visibility": "INTERNAL"},
            {"name": "m", "isArchived": False},
            {"name": "x", "isArchived": True, "visibility": "PRIVATE"},
        ]
        try:
            vis = dict(cpr.list_repos_with_visibility())
        finally:
            cpr._run_gh_json = orig
        self.assertEqual(vis, {"p": False, "i": True, "m": True})

    def test_main_end_to_end_no_private_names_in_files_or_logs(self):
        import io
        import subprocess
        import tempfile
        tmp = tempfile.mkdtemp()
        jp = os.path.join(tmp, "h.json")
        mp = os.path.join(tmp, "s.md")
        with open(jp, "w", encoding="ascii") as fh:
            fh.write('[{"date": "2026-06-30", "repo": "old-secret", '
                     '"runs_total": 1, "runs_passed": 1, "runs_failed": 0, '
                     '"runs_cancelled": 0, "pass_rate": 1.0, '
                     '"low_signal": true}]')

        def fake(args):
            if args[0] == "repo":
                return [
                    {"name": "pub", "isArchived": False, "visibility": "PUBLIC"},
                    {"name": "secret-a", "isArchived": False, "visibility": "PRIVATE"},
                    {"name": "secret-b", "isArchived": False, "visibility": "PRIVATE"},
                ]
            if "secret-b" in args[1]:
                raise subprocess.CalledProcessError(
                    1, ["gh"] + args, stderr="HTTP 404 repos/Perditio-Labs/secret-b")
            return {"workflow_runs": [_run("success")]}

        saved = (cpr._run_gh_json, cpr.JSON_PATH, cpr.MD_PATH, sys.stdout, sys.stderr)
        out, err = io.StringIO(), io.StringIO()
        cpr._run_gh_json, cpr.JSON_PATH, cpr.MD_PATH = fake, jp, mp
        sys.stdout, sys.stderr = out, err
        try:
            cpr.main([])
            cpr.main([])  # same-day rerun
        finally:
            (cpr._run_gh_json, cpr.JSON_PATH, cpr.MD_PATH,
             sys.stdout, sys.stderr) = saved
        blob = (open(jp, encoding="ascii").read() + open(mp, encoding="ascii").read()
                + out.getvalue() + err.getvalue())
        for name in ("secret-a", "secret-b", "old-secret"):
            self.assertNotIn(name, blob)
        self.assertIn("pub", blob)
        hist = cpr.load_history(jp)
        self.assertEqual(len([r for r in hist if r["repo"] == "pub"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
