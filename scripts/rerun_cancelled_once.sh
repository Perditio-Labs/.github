#!/usr/bin/env bash
#
# rerun_cancelled_once.sh - re-run ONCE the workflow runs on open-PR heads that
# were cancelled in the last WINDOW_HOURS, across every non-archived
# Perditio-Labs repo (private and public, forks included).
#
# A run is re-run only when ALL hold (decided by RERUN_SELECT_JQ, unit-tested):
#   - its head sha is the head of an open PR in that repo;
#   - it is the NEWEST run of its workflow for that sha (not superseded);
#   - status completed, conclusion cancelled, run_attempt == 1 (never twice);
#   - it was cancelled (updated_at) inside the window.
# At most MAX_RERUNS per tick (newest cancellations first). Immediately
# before each re-run the open-PR heads and the sha's runs are re-read (all
# pages): the sha must still be an open-PR head and the run must still be
# the newest cancelled attempt-1 run of its workflow. The coverage gate (>= MIN_REPOS repos read) runs before any
# re-run.
#
# PRIVACY: the host repo (Perditio-Labs/.github) is public. When REDACT=1
# nothing printed names a private repo, its PRs or its workflows.
#
# Env: GH_TOKEN (App token: actions write, pull requests read), ORG, MODE
# (report|apply), MIN_REPOS (30), SENTINEL_REPOS (REQUIRED, no default: from
# the secret SWEEPER_SENTINEL_REPOS; private names never live in this public
# repo), WINDOW_HOURS
# (24), MAX_RERUNS (20), STRICT (1 = a missing permission fails the job),
# HOST_REPO, OUT_DIR.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hygiene_lib.sh
. "$HERE/hygiene_lib.sh"

# Input: a JSON array of workflow runs for ONE head sha. Output: one TSV row
# per run to re-run: id, workflow_id, updated_at.
# shellcheck disable=SC2016
RERUN_SELECT_JQ='
  [ .[] | select(type == "object" and (.id | type) == "number" and (.workflow_id | type) == "number") ]
  | group_by(.workflow_id)
  | map(max_by([(.created_at // ""), .id]))
  | .[]
  | select(.status == "completed" and .conclusion == "cancelled"
           and .run_attempt == 1 and ((.updated_at // "") >= $since))
  | [(.id | tostring), (.workflow_id | tostring), .updated_at] | @tsv'

# select_reruns <runs-json-array> <since-iso>: prints the rows; returns
# non-zero when the input is not a JSON array (caller counts an error).
select_reruns() {
  jq -e 'type == "array"' <<< "$1" >/dev/null 2>&1 || return 1
  jq -r --arg since "$2" "$RERUN_SELECT_JQ" <<< "$1" | tr -d '\r'
}

# since_iso: the start of the window, from the clock NOW (re-computed before
# every re-run, so a cancellation that ages out during the scan is skipped).
since_iso() { date -u -d "@$(( $(date -u +%s) - WINDOW_HOURS * 3600 ))" +%Y-%m-%dT%H:%M:%SZ; }

# open_heads <repo>: head shas of every open PR (all pages).
open_heads() { gh api "repos/$ORG/$1/pulls?state=open&per_page=100" --paginate --jq '.[] | .head.sha' 2>/dev/null | tr -d '\r'; }
# runs_for <repo> <sha>: every workflow run for that head sha (all pages) as
# one JSON array.
runs_for() {
  local raw
  raw="$(gh api "repos/$ORG/$1/actions/runs?head_sha=$2&per_page=100" --paginate --jq '.workflow_runs[]' 2>/dev/null)" || return 1
  jq -s -c . <<< "$raw" 2>/dev/null
}

main() {
  ORG="${ORG:-Perditio-Labs}"
  MODE="${MODE:-report}"
  MIN_REPOS="${MIN_REPOS:-30}"
  SENTINEL_REPOS="${SENTINEL_REPOS:-}"
  WINDOW_HOURS="${WINDOW_HOURS:-24}"
  MAX_RERUNS="${MAX_RERUNS:-20}"
  STRICT="${STRICT:-0}"
  HOST_REPO="${HOST_REPO:-${GITHUB_REPOSITORY:-$ORG/.github}}"
  OUT_DIR="${OUT_DIR:-$PWD/rerun-out}"
  case "$MODE" in report|apply) ;; *) echo "ERROR: MODE must be report or apply" >&2; exit 2 ;; esac
  [[ -n "${GH_TOKEN:-}" ]] || { echo "ERROR: GH_TOKEN required" >&2; exit 2; }
  mkdir -p "$OUT_DIR"
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT
  local NOW SINCE
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  SINCE="$(since_iso)"

  set +e
  hyg_capability "$ORG" "$MIN_REPOS" "$SENTINEL_REPOS" \
    "pull_requests=repos/$ORG/{repo}/pulls?state=all&per_page=1" \
    "actions=repos/$ORG/{repo}/actions/runs?per_page=1" \
    "actions_write=POST:repos/$ORG/{repo}/actions/runs/1/rerun"
  local cap_rc=$?
  set -e
  echo "$CAP_MSG" | tee "$OUT_DIR/capability.txt" >&2
  if [[ "$cap_rc" != "0" ]]; then
    { echo "# Re-run cancelled once ($MODE) $NOW: NOT RUN"; echo; echo "$CAP_MSG"; echo; echo "Nothing was re-run."; } > "$OUT_DIR/summary.md"
    exit "$(exit_for "$cap_rc" "$MODE" "$STRICT")"
  fi

  local targets cands="$WORKDIR/cands.tsv" errs=0 read_ok=0 prs_seen=0 shas_seen=0
  : > "$cands"
  targets="$(jq -r 'select(.archived == false) | [.name, (.private | tostring)] | @tsv' <<< "$REPOS_JSON" | tr -d '\r')"
  local repo priv shas sha runs sel
  while IFS=$'\t' read -r repo priv; do
    [[ -n "$repo" ]] || continue
    if ! shas="$(open_heads "$repo")"; then
      errs=$((errs + 1)); echo "WARN: could not list open PRs in $(repo_label "$repo" "$priv" "$REDACT"); repo skipped" >&2; continue
    fi
    read_ok=$((read_ok + 1))
    [[ -n "$shas" ]] || continue
    prs_seen=$((prs_seen + $(grep -c . <<< "$shas")))
    while IFS= read -r sha; do
      [[ "$sha" =~ $HYG_SHA_RE ]] || continue
      shas_seen=$((shas_seen + 1))
      if ! runs="$(runs_for "$repo" "$sha")" || ! sel="$(select_reruns "$runs" "$SINCE")"; then
        errs=$((errs + 1)); echo "WARN: could not read runs for an open PR head in $(repo_label "$repo" "$priv" "$REDACT")" >&2; continue
      fi
      while IFS=$'\t' read -r id wf upd; do
        [[ -n "$id" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$upd" "$repo" "$priv" "$id" "$wf" "$sha" >> "$cands"
      done <<< "$sel"
    done < <(sort -u <<< "$shas")
  done <<< "$targets"

  if (( read_ok < MIN_REPOS )); then
    { echo "# Re-run cancelled once ($MODE) $NOW: NOT RUN"; echo; echo "FAIL: only $read_ok repos were read without error (< $MIN_REPOS). Nothing was re-run."; } > "$OUT_DIR/summary.md"
    echo "FAIL: only $read_ok repos were read without error (< $MIN_REPOS). Nothing was re-run." >&2
    exit 1
  fi

  local results="$WORKDIR/results.tsv" n=0 done_n=0 upd id wf heads_now runs_now sel_now
  : > "$results"
  # Newest cancellations first, one row per repo + run id, capped.
  while IFS=$'\t' read -r upd repo priv id wf sha; do
    [[ -n "$id" ]] || continue
    if (( n >= MAX_RERUNS )); then
      printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$id" "DEFERRED (MAX_RERUNS=$MAX_RERUNS)" >> "$results"; continue
    fi
    n=$((n + 1))
    if [[ "$MODE" != "apply" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$id" "WOULD-RERUN (cancelled $upd)" >> "$results"; continue
    fi
    # Re-validate everything immediately before the write: the sha is
    # still an open-PR head, and this run is still the newest run of its
    # workflow for that sha, cancelled, attempt 1, inside the window.
    # A read/parse failure is an ERROR (counted, fails a dispatched apply);
    # only a successful read that rejects the candidate is a SKIP.
    if ! heads_now="$(open_heads "$repo")"; then
      errs=$((errs + 1)); printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$id" "ERROR (re-validation: open PRs unreadable; not re-run)" >> "$results"; continue
    fi
    if ! grep -qx "$sha" <<< "$heads_now"; then
      printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$id" "SKIPPED (no longer an open-PR head)" >> "$results"; continue
    fi
    if ! runs_now="$(runs_for "$repo" "$sha")" || ! sel_now="$(select_reruns "$runs_now" "$(since_iso)")"; then
      errs=$((errs + 1)); printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$id" "ERROR (re-validation: runs unreadable; not re-run)" >> "$results"; continue
    fi
    if ! cut -f1 <<< "$sel_now" | grep -qx "$id"; then
      printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$id" "SKIPPED (superseded or changed since inspection)" >> "$results"; continue
    fi
    if gh api -X POST "repos/$ORG/$repo/actions/runs/$id/rerun" >/dev/null 2>&1; then
      done_n=$((done_n + 1))
      printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$id" "RERUN" >> "$results"
    else
      errs=$((errs + 1))
      printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$id" "RERUN FAILED" >> "$results"
    fi
  done < <(sort -t$'\t' -k1,1r -k4,4 "$cands" | awk -F'\t' '!seen[$2 FS $4]++')

  local total priv_n
  total="$(wc -l < "$results" | tr -d ' ')"
  priv_n="$(awk -F'\t' -v r="$REDACT" '(r == "1" && $2 != "false")' "$results" | wc -l | tr -d ' ')"
  {
    echo "# Re-run cancelled once ($MODE) $NOW"
    echo
    echo "| measure | value |"
    echo "|---|---|"
    echo "| repos read without error | $read_ok |"
    echo "| open PRs / distinct head shas checked | $prs_seen / $shas_seen |"
    echo "| window | cancelled since $SINCE (${WINDOW_HOURS} h) |"
    echo "| candidate runs (newest per workflow+sha, cancelled, attempt 1) | $total |"
    echo "| re-run this tick (cap $MAX_RERUNS) | $done_n |"
    echo "| errors / warnings | $errs |"
    echo
    echo "| repo | run id | action |"
    echo "|---|---|---|"
    awk -F'\t' -v r="$REDACT" '(r == "0" || $2 == "false") {printf "| %s | %s | %s |\n", $1, $3, $4}' "$results"
    echo
    echo "Private-repo rows (not named, this repo is public): $priv_n"
  } > "$OUT_DIR/summary.md"
  echo "Re-run done: mode=$MODE read_ok=$read_ok shas=$shas_seen candidates=$total rerun=$done_n errors=$errs"
  if [[ "$errs" != "0" ]]; then
    echo "::warning::rerun-cancelled-once: $errs read or re-run error(s); see the job summary."
    # A dispatched apply must not look green when a re-run failed.
    if [[ "$MODE" == "apply" && "$STRICT" == "1" ]] && grep -qE 'RERUN FAILED|ERROR' "$results"; then exit 1; fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
