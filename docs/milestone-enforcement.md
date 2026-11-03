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

Recommendation: org default `assign` permanently; repo variable `PR_MILESTONE_MODE=enforce`
on repos that run two open versions at once (the VR library repos). Agents are already forced
to choose by the local hook (`gh pr create --milestone`), so `assign` only catches the rest.

## Known limits

- Org-ruleset required workflows ignore the `types` filter and run on opened/synchronize/reopened only. A milestone removed or added after a run is re-checked on the next push or a manual re-run. The per-repo caller honours all types, so Plan B is the stricter option.
- `release-milestone` uses the commit-to-PR association of every commit between the nearest ANCESTOR version tag and the new tag. It fails, changing nothing, if there is no ancestor version tag (first release) or more than 500 commits; use `backfill_milestones.py` then.
- A PR counts for a release only if its merge commit is inside the tag range. Runs are serialised per repo; if one is dropped from the queue, re-run it with `workflow_dispatch` (`dry_run=false`). The next patch milestone is reopened only when no newer stable tag exists.
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
- **`release-milestone`** - when a release is published, `release-milestone.yml` milestones every merged PR in the tag that has none, closes milestone `X.Y.Z`, opens `X.Y.(Z+1)` and ends the release notes with `Milestone: <url>`.
- Open the PR with `gh pr create --milestone <X.Y.Z>`; create the milestone first if absent: `gh api repos/<org>/<repo>/milestones -f title=<X.Y.Z>`.

## Proposed PR template field (the PR template file pull_request_template.md in each org devkit repo)

Add under `## Summary` (the governance parsers key on other headings; this one is additive):

```
Milestone: <version, e.g. 1.3.19>  <!-- must equal the PR's GitHub milestone; pr-milestone checks the GitHub field -->
```
