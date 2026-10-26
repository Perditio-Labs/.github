#!/usr/bin/env bash
#
# post_tracking_issue.sh - open or update ONE tracking issue in this repo with
# the latest stale-branch-sweeper summary. The summary is produced by
# scripts/stale_branch_sweeper.sh and is already public-safe (private repos
# are counted, never named, while this repo is public).
#
# Env: GH_TOKEN (issues:write on this repo), GITHUB_REPOSITORY, RUN_URL, MODE,
#      SWEEP_OUTCOME, OUT_DIR.
# REST only: `gh issue edit` also queries Projects, which a job token cannot.
set -euo pipefail

TITLE="Stale branch sweeper: org branch hygiene report"
BODY="${RUNNER_TEMP:-/tmp}/sweeper-issue-body.md"

num="$(gh api "repos/$GITHUB_REPOSITORY/issues?state=open&per_page=100" --paginate \
        --jq ".[] | select(.pull_request == null and .title == \"$TITLE\") | .number" | tr -d '\r')"
num="${num%%$'\n'*}"

{
  echo "<!-- stale-branch-sweeper -->"
  echo "Latest run: $RUN_URL (mode: $MODE, sweep step: ${SWEEP_OUTCOME:-unknown})"
  echo
  if [[ -f "$OUT_DIR/summary.md" ]]; then cat "$OUT_DIR/summary.md"; else echo "The sweep did not finish; no summary was produced. See the run log."; fi
} > "$BODY"

# GitHub caps an issue body at 65536 characters.
if [[ "$(wc -c < "$BODY")" -gt 60000 ]]; then
  head -c 60000 "$BODY" > "$BODY.cut"
  printf '\n\n(truncated: the full summary is on the run page %s)\n' "$RUN_URL" >> "$BODY.cut"
  mv "$BODY.cut" "$BODY"
fi

if [[ -n "$num" ]]; then
  gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/$num" -F body=@"$BODY" --jq .html_url
else
  gh api -X POST "repos/$GITHUB_REPOSITORY/issues" -f title="$TITLE" -F body=@"$BODY" --jq .html_url
fi
