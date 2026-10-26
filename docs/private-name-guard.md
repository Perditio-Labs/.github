## Private repo name guard

`.github/workflows/private-name-guard.yml` fails any pull request or push to
`main` that adds the name of a PRIVATE Perditio-Labs repository to this public
repository. The private names are read at run time with a read-only GitHub App
token; none are stored here. The log shows only `file:line` and a count, never
the name (a name inside a file path is shown as `<withheld>`).

What it scans (git objects, never a diff, so `.gitattributes` or odd line
separators cannot hide content):

| Event | Scanned |
| --- | --- |
| pull request from a branch of this repo (`pull_request_target`, job `guard`) | every file version, file path and commit (message and author) the PR adds, including a name added in one commit and removed in a later one; the PR title, body and branch name. The workflow, script and allowlist come from the PR's BASE branch; the PR's commits are only read as data |
| pull request (`pull_request`, job `self-test`) | the PR's own copy of `tests/test_private_name_guard.py`, with no secrets |
| pull request from a fork | not scanned, with a notice (pass/fail would let a fork author test guesses of private names); a maintainer reviews it and the push to `main` scans the result |
| push to `main` | every path and file of the current tree, plus every commit, file version and path the push added (the whole history when the previous tip is unknown) |

If it fails: remove the name from the change (and from the PR's commits, or
squash-merge). If the match is an ordinary word that happens to be a private
repo name, add the word (never a product, client or project name) to
`scripts/private-name-allowlist.txt`; that change only takes effect for PRs
after it is merged. Names shorter than 5 characters are ignored. Deleting a
file whose path holds a name always passes.

The guard checks itself: the tests run first in every job (a planted name must
fail, clean input must pass, the name must never appear in the output), and
the job fails if the token cannot list the private repositories.

First PR: the PR that adds this workflow is not guarded by it
(`pull_request_target` runs the base branch's workflow, which does not exist
yet). The push to `main` after merging scans the full current tree plus the
commits that push added; older history is scanned only when the previous tip
is unknown (zero or missing `before`). History published before the guard
existed is therefore not re-checked by later pushes; clean it separately.

Setup (one time, org/repo settings):

| Setting | Value |
| --- | --- |
| Org secrets `ORG_READ_APP_ID`, `ORG_READ_APP_PRIVATE_KEY` | already exist with visibility `all` (org-read App, contents+metadata read); nothing to add |
| Runner | GitHub-hosted `ubuntu-latest` by default (free for public repos; self-hosted runners must not serve a public repo, and the Perditio runner group does not allow public repos). Override only via the repo variable `PERDITIO_PUBLIC_CI_RUNS_ON` |
| Ruleset on `main` | require PRs and the status checks `guard` and `self-test`; block force pushes |
