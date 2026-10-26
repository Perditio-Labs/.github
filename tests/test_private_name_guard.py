#!/usr/bin/env python3
"""Offline tests for scripts/private_name_guard.py (stdlib unittest + git).

A planted private name MUST fail the guard and MUST NOT appear in its output
(the output of a public repo's CI is public); clean input MUST pass; a token
that cannot list private repos MUST exit 2.

Run: python3 -B tests/test_private_name_guard.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "scripts", "private_name_guard.py")
ALLOW = os.path.join(ROOT, "tests", "fixtures", "private-name-guard", "allowlist.txt")
REPOS = os.path.join(ROOT, "tests", "fixtures", "private-name-guard", "org-repos.json")
PLANTED = ("secret-widget-api", "hidden-roadmap", "payroll-export")


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                    "-c", "commit.gpgsign=false", *args], cwd=cwd, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def head(cwd):
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, check=True,
                          stdout=subprocess.PIPE).stdout.decode().strip()


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp(prefix="png-test-")
        git(self.repo, "init", "-q", "-b", "main")
        self.write("README.md", "Public profile\nNothing to see\n")
        self.write("profile/README.md", "We build open-thing in public\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        self.base = head(self.repo)

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)

    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)

    def commit(self, msg="change", allow_empty=False):
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", *(["--allow-empty"] if allow_empty else []), "-m", msg)
        return head(self.repo)

    def run_guard(self, *args, env_extra=None, repos=REPOS):
        env = dict(os.environ)
        env.pop("GITHUB_ACTIONS", None)
        extra = dict(env_extra or {})
        pr = {k: extra.pop(e) for k, e in (("title", "PR_TITLE"), ("body", "PR_BODY")) if e in extra}
        if "PR_HEAD_REF" in extra:
            pr["head"] = {"ref": extra.pop("PR_HEAD_REF")}
        if pr:
            ev = os.path.join(self.repo, "..", os.path.basename(self.repo) + "-event.json")
            with open(ev, "w", encoding="utf-8") as fh:
                json.dump({"pull_request": pr}, fh)
            env["GITHUB_EVENT_PATH"] = ev
            args = args + ("--pr-event",)
        env.update(extra)
        p = subprocess.run([sys.executable, "-B", GUARD, "--org", "Acme", "--min-private", "3",
                            "--allowlist", ALLOW, "--fixture-repos", repos, *args],
                           cwd=self.repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = p.stdout.decode("utf-8", "replace")
        for name in PLANTED:
            self.assertNotIn(name.lower(), out.lower(), "guard output leaked a private name")
        return p.returncode, out

    def test_diff_with_planted_name_fails_with_location_only(self):
        self.write("README.md", "Public profile\nBuilt on Secret-Widget-API\nNothing to see\n")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertIn("README.md:2", out)
        self.assertIn("FAIL: 1 private repo name occurrence(s) in 1 location(s)", out)

    def test_diff_clean_change_passes(self):
        self.write("README.md", "Public profile\nsecret-widget-api-v2 and xhidden-roadmap are not names\n"
                                "website and tiny are allowlisted or short\n")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 0, out)
        self.assertIn("PASS", out)

    def test_diff_flags_a_new_file_path(self):
        self.write("notes/payroll-export.md", "harmless body\n")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertIn("notes/<withheld>.md (path)", out)
        self.assertIn("(path)", out)

    def test_diff_content_line_cannot_fake_a_file_header(self):
        self.write("README.md", "Public profile\n++ /dev/null\npayroll-export\n")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertIn("README.md:3", out)

    def test_diff_flags_a_binary_file_path(self):
        path = os.path.join(self.repo, "assets")
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "hidden-roadmap.bin"), "wb") as fh:
            fh.write(b"\x00\x01\x02binary")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertIn("assets/<withheld>.bin (path)", out)

    def test_diff_deleting_a_leaked_path_is_allowed(self):
        self.write("notes/payroll-export.md", "x\n")
        mid = self.commit()
        os.remove(os.path.join(self.repo, "notes", "payroll-export.md"))
        h = self.commit()
        code, out = self.run_guard("--diff", mid, h)
        self.assertEqual(code, 0, out)

    def test_diff_flags_a_commit_message(self):
        self.write("README.md", "Public profile\nNothing to see\nmore\n")
        h = self.commit("sync from hidden-roadmap")
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"commit [0-9a-f]{10}:6")

    def test_diff_gitattributes_cannot_hide_content(self):
        self.write(".gitattributes", "README.md -diff\n")
        self.write("README.md", "Public profile\nsecret-widget-api\n")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertIn("README.md:2", out)

    def test_diff_record_separator_in_message_cannot_hide_it(self):
        h = self.commit("clean\x1ehidden-roadmap", allow_empty=True)
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)

    def test_tree_scans_large_files_and_commit_messages(self):
        self.write("big.txt", "a" * 1000001 + "\nsecret-widget-api\n")
        self.commit()
        code, out = self.run_guard("--tree")
        self.assertEqual(code, 1, out)
        self.assertIn("big.txt:2", out)

    def test_tree_scans_history_messages(self):
        self.commit("import from payroll-export", allow_empty=True)
        code, out = self.run_guard("--tree")
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"commit [0-9a-f]{10}:6")

    def test_usage_error_does_not_echo_arguments(self):
        code, out = self.run_guard("--tree", "--secret-widget-api")
        self.assertEqual(code, 3, out)
        code, out = self.run_guard("--tree", "--min-len", "hidden-roadmap")
        self.assertEqual(code, 3, out)

    def test_non_lf_separators_cannot_hide_content(self):
        for i, sep in enumerate(("\x0b", "\x0c", "\r", "\u2028")):
            self.write("payload%d.txt" % i, "clean" + sep + "secret-widget-api\n")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertEqual(out.count("payload"), 4, out)

    def test_name_added_then_removed_inside_the_pr_is_caught(self):
        self.write("notes.md", "draft for hidden-roadmap\n")
        self.commit()
        self.write("notes.md", "draft\n")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertIn("notes.md:1", out)

    def test_file_named_like_a_pr_field_cannot_mask_the_pr_title_or_body(self):
        self.write("pull request title", "clean\n")
        self.write("pull request body", "clean\n")
        h = self.commit()
        for env in ({"PR_TITLE": "secret-widget-api"}, {"PR_BODY": "payroll-export"}):
            code, out = self.run_guard("--diff", self.base, h, env_extra=env)
            self.assertEqual(code, 1, out)

    def test_capability_output_never_echoes_the_org_value(self):
        code, out = self.run_guard("--tree", "--org", "hidden-roadmap", "--min-private", "99")
        self.assertEqual(code, 2, out)

    def test_control_characters_in_paths_are_escaped(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("png_guard", GUARD)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertEqual(mod.safe("x\n::warning::y"), "x\\x0a::warning::y")
        self.assertNotIn("\n", mod.safe("a\r\nb\x1b"))

    def test_renamed_file_with_a_name_is_flagged_but_old_paths_are_not(self):
        self.write("docs/plain.md", "x\n")
        mid = self.commit()
        os.rename(os.path.join(self.repo, "docs", "plain.md"), os.path.join(self.repo, "docs", "payroll-export.md"))
        h = self.commit()
        code, out = self.run_guard("--diff", mid, h)
        self.assertEqual(code, 1, out)
        self.assertIn("docs/<withheld>.md (path)", out)
        self.assertNotIn("README.md", out)

    def test_empty_directory_entry_with_a_name_is_flagged(self):
        def out_of(*args, stdin=None):
            return subprocess.run(["git", *args], cwd=self.repo, check=True, input=stdin,
                                  stdout=subprocess.PIPE).stdout.decode().strip()
        empty = out_of("mktree", stdin=b"")
        base_tree = out_of("rev-parse", self.base + "^{tree}")
        entries = out_of("ls-tree", base_tree) + "\n040000 tree %s\thidden-roadmap\n" % empty
        tree = out_of("mktree", stdin=entries.encode())
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
        h = subprocess.run(["git", "commit-tree", tree, "-p", self.base, "-m", "clean"], cwd=self.repo,
                           check=True, env=env, stdout=subprocess.PIPE).stdout.decode().strip()
        code, out = self.run_guard("--diff", self.base, h)
        self.assertEqual(code, 1, out)
        self.assertIn("<withheld> (path)", out)
        git(self.repo, "reset", "-q", "--soft", h)
        code, out = self.run_guard("--tree")
        self.assertEqual(code, 1, out)

    def test_tree_since_skips_old_history_but_not_the_current_tree(self):
        old = self.commit("old history mentions payroll-export", allow_empty=True)
        self.write("README.md", "Public profile\nNothing\nnew line\n")
        self.commit("clean push")
        code, out = self.run_guard("--tree", "--since", old)
        self.assertEqual(code, 0, out)
        self.write("docs/x.md", "hidden-roadmap\n")
        mid = self.commit("clean")
        self.write("README.md", "Public profile\n")
        self.commit("clean again")
        code, out = self.run_guard("--tree", "--since", mid)
        self.assertEqual(code, 1, out)
        self.assertIn("docs/x.md:1", out)

    def test_pr_branch_name_is_scanned(self):
        code, out = self.run_guard("--diff", self.base, self.base, env_extra={"PR_HEAD_REF": "dev-feat/hidden-roadmap"})
        self.assertEqual(code, 1, out)
        self.assertIn("pull request branch name:1", out)

    def test_diff_ignores_removed_lines(self):
        self.write("README.md", "Public profile\nBuilt on secret-widget-api\n")
        mid = self.commit()
        self.write("README.md", "Public profile\n")
        h = self.commit()
        code, out = self.run_guard("--diff", mid, h)
        self.assertEqual(code, 0, out)

    def test_pr_body_is_scanned(self):
        h = self.commit("empty") if False else self.base
        code, out = self.run_guard("--diff", self.base, h,
                                   env_extra={"PR_TITLE": "Docs", "PR_BODY": "line one\nport HIDDEN-ROADMAP"})
        self.assertEqual(code, 1, out)
        self.assertIn("pull request body:2", out)

    def test_tree_mode_scans_the_whole_tree(self):
        self.write("profile/README.md", "We build open-thing in public\nand payroll-export\n")
        self.commit()
        code, out = self.run_guard("--tree")
        self.assertEqual(code, 1, out)
        self.assertIn("profile/README.md:2", out)

    def test_tree_mode_clean(self):
        code, out = self.run_guard("--tree")
        self.assertEqual(code, 0, out)

    def test_annotation_withholds_the_name(self):
        self.write("README.md", "Public profile\nsecret-widget-api\n")
        h = self.commit()
        code, out = self.run_guard("--diff", self.base, h, env_extra={"GITHUB_ACTIONS": "true"})
        self.assertEqual(code, 1, out)
        self.assertIn("::error file=README.md,line=2::private repo name found here (name withheld)", out)

    def test_capability_guard(self):
        only_public = os.path.join(self.repo, "..", os.path.basename(self.repo) + "-repos.json")
        with open(only_public, "w", encoding="utf-8") as fh:
            fh.write('[{"name": ".github", "private": false}, {"name": "secret-widget-api", "private": true}]')
        try:
            code, out = self.run_guard("--tree", repos=only_public)
        finally:
            os.remove(only_public)
        self.assertEqual(code, 2, out)
        self.assertIn("cannot list private repos, so this guard cannot fire", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
