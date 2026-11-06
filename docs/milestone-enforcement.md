# Milestone-per-release enforcement (Perditio-Labs)

Rule (Kim 2026-11-02): every PR carries a milestone whose title is a release version
(semver `X.Y.Z`, optional leading `v`, optional `-pre-release`). Enforced org-wide here,
not only by the local agent hook.

| File | Purpose |
|---|---|
| `.github/workflows/pr-milestone.yml` | PR check: `enforce` fails, `assign` auto-attaches the lowest open version milestone |
| `.github/workflows/release-milestone.yml` | On release: milestone every merged un-milestoned PR in the tag, close X.Y.Z, open X.Y.(Z+1), append `Milestone:` link |
| `docs/*-caller.example.yml` | The per-repo caller (fallback when an org ruleset cannot require the workflow) |

## Mode: enforce vs assign

Mode comes from workflow input `mode`, else variable `PR_MILESTONE_MODE` (repo var overrides
org var), else `enforce`.

| | enforce | assign |
|---|---|---|
| Pro | forces a deliberate, correct version; no silent guessing | invariant "every PR has a version milestone" holds for humans, Codex and cloud sessions with no friction |
| Con | blocks bots and anyone without a milestone; red noise | guesses the lowest open milestone, wrong when two versions are open; hides missing discipline |
| Fails when | no milestone, or non-version title | non-version title, or the token is read-only (fork and Dependabot PRs: attach by hand) |

The default is `enforce`: attach the deliberate open shipping version before merging.
Open PRs fail when their milestone is closed; historical closed PRs retain theirs.
Assignment mode accepts `target_version` (or `PR_MILESTONE_TARGET_VERSION`), which
selects that version rather than guessing the lowest open milestone. Enforcement
also rejects a milestone that differs from this explicit target. Without a target,
legacy assignment behavior remains available as an opt-in rollout aid.

## Known limits

- Org-ruleset required workflows ignore the `types` filter and run on opened/synchronize/reopened only. A milestone removed or added after a run is re-checked on the next push or a manual re-run. The per-repo caller honours all types, so Plan B is the stricter option.
- `release-milestone` uses the commit-to-PR association of every commit between the nearest ANCESTOR version tag and the new tag. The first release uses history reachable from the tag. Both paths stop pagination after exceeding 500 commits and fail before any write; larger histories require a separately reviewed backfill.
- A PR counts for a release only if its merge commit is inside the tag range. Runs are serialised per repo; if one is dropped from the queue, re-run it with `workflow_dispatch` (`dry_run=false`). The next patch milestone is created or reopened only when no newer stable tag exists.
- Fork and Dependabot PRs get a read-only token: `assign` cannot write there.

## Plan limits (checked 2026-11-02)

Both orgs are on the GitHub **Team** plan (`gh api orgs/<org> -q .plan.name`). Org rulesets
exist (both orgs already have `permanent-branch-protection`). The ruleset `workflows` rule
("require workflows to pass") and `evaluate` enforcement are documented as Enterprise
features; this was NOT probed because creating a ruleset is out of scope. Step 4 of the
rollout tries it; if the API rejects it, use Plan B (same check, delivered by caller file +
`required_status_checks` rule, both available on Team).

## Rollout (Kim runs; replace ORG and IDs)

See the session report for the exact commands. Order: merge this PR; allow org access to the
private `.github` repo (PTR only); set `PR_MILESTONE_MODE=assign`; create the ruleset
(Plan A) or roll callers then the status-check ruleset (Plan B); audit for a week; flip to
`enforce`. Rollback: set the ruleset `enforcement` to `disabled` (or delete it) and the
variable back to `assign`.

## Proposed GitFlow text (add to GITFLOW.md under "Governance")

- **`pr-milestone`** - every PR (into `dev`, `staging` and `main`) must carry a milestone titled with a release version (`X.Y.Z`, optional `v`, optional `-pre`). Enforced org-wide by the `.github` repo workflow `pr-milestone.yml` (mode `assign` or `enforce`, org variable `PR_MILESTONE_MODE`). The milestone is the version the PR ships in; the next version's milestone exists before work starts.
- **`release-milestone`** - when a release is published, `release-milestone.yml` milestones every merged PR in the tag that has none, closes milestone `X.Y.Z` (its due date is the release's Pacific date and line 1 of its description is `Released YYYY-MM-DD HH:MM PT - <release url>`; created first if missing), opens `X.Y.(Z+1)` and ends the release notes with `Milestone: <url>`.
- Open the PR with `gh pr create --milestone <X.Y.Z>`; create the milestone first if absent: `gh api repos/<org>/<repo>/milestones -f title=<X.Y.Z>`.

## Proposed PR template field

Add under `## Summary` (the governance parsers key on other headings; this one is additive):

```
Milestone: <version, e.g. 1.3.19>  <!-- must equal the PR's GitHub milestone; pr-milestone checks the GitHub field -->
```

## Recovery and deterministic dates

The caller handles release publication, tag pushes, and manual recovery. Its
concurrency group is owned only by the reusable workflow; duplicate events are
idempotent. GitHub concurrency can replace a pending run: manually recover any
dropped tag with `dry_run=true`, inspect the summary, then run with `dry_run=false`.

Invalid tags fail visibly. A historical prefixed or leading-zero tag requires an
explicit normalized `version` (for example tag `release-01.02.03`, version `1.2.3`).
Use `previous_tag` to select a legacy ancestor; ancestry is verified before writes.
Canonical tags cannot be remapped to a different version. Legacy recovery closes
and dates the normalized version but does not guess a next patch because legacy
names cannot reliably establish the newest stable release. Create its deliberate
successor separately. Existing PR milestones are always retained.

Dates use valid `published_at`, then the immutable tag tip commit date, then valid
release `created_at`. Missing/invalid timestamps fail before writes; the clock is
never substituted. The due date is the Pacific calendar date at 12:00Z. Replaying
a published release repairs missing or incorrect dates and the generated header,
while preserving the rest of the description.

Run `node tests/milestone/run.js` (Python + PyYAML required). To exercise the same
regressions against a base, set `MILESTONE_TEST_REF` to the base commit. The suite
executes the actual embedded scripts against an offline API fixture.

Before any release write, an existing stable milestone is fetched live. Any open
issue or pull request blocks assignment, closure, successor creation and notes
updates. Finish or deliberately retarget unfinished work, then retry the release.
