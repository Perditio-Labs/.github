#!/usr/bin/env bash
#
# merge_when_green.sh - merge open, non-draft PRs labelled `automerge` whose
# base is `dev`, across every non-archived Perditio-Labs repo, once green.
#
# A PR is merged only when ALL hold (merge_decision, unit-tested):
#   - open, not draft, base branch exactly `dev` (never main, staging,
#     release*, or anything else), an actual label named `automerge`
#     (exact, case-insensitive, matched over the JSON label array) OR
#     authored by dependabot[bot] with a "<eco>-minor-patch group" title
#     (grouped minor/patch; a title whose from/to majors differ is never
#     eligible);
#   - it does not touch .github/workflows/ (the App has no workflows
#     permission; GitHub refuses such merges by an App: merge by hand);
#   - its head sha has >= 1 check run or commit status, none pending, every
#     check run success/neutral/skipped and every status success (all pages
#     of both are read);
#   - the head has been quiet >= QUIET_SECS (default 600): measured from the
#     LATEST of the head commit's committer date, any check suite creation,
#     and any check run / status start, completion or update on that sha
#     (a re-run or a new push restarts the clock); a head with no check
#     suite (push time unknown) or any missing/malformed date fails closed;
#   - GitHub reports mergeable_state `clean` (rulesets, reviews, conflicts).
#     `behind` -> update-branch ONCE: the PR gets the marker label
#     `automerge:branch-updated` BEFORE the update (no marker, no update), and
#     a PR carrying the marker, or a commit authored by this App, is never
#     updated again.
# Discovery reads every repo's open PRs into dev (all pages; no search
# index). Immediately before every write the PR is fully re-evaluated and the
# decision and head sha must be unchanged; the merge then pins that head sha
# (GitHub refuses it if the head moved). The repo's allowed method is used
# (merge commit, else squash, else rebase). Rulesets and native auto-merge
# settings are never modified. At most MAX_ACTIONS merges/updates per tick.
# Residual race (no API can make the merge conditional on base/labels/
# checks): a change in the seconds between the re-evaluation and the merge
# call; branch rulesets on dev remain the server-side backstop.
#
# PRIVACY: the host repo (Perditio-Labs/.github) is public. When REDACT=1
# nothing printed names a private repo or its PRs (counts only).
#
# Env: GH_TOKEN (App token: contents write, pull requests write, issues
# write, checks + statuses read), ORG, MODE (report|apply), MIN_REPOS (30),
# SENTINEL_REPOS (REQUIRED, no default: from the secret
# SWEEPER_SENTINEL_REPOS; private names never live in this public repo),
# QUIET_SECS (600), MAX_ACTIONS (10),
# APP_BOT (perditio-ci-automation[bot]), STRICT, HOST_REPO, OUT_DIR.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hygiene_lib.sh
. "$HERE/hygiene_lib.sh"

LABEL="automerge"
# Eligibility without the label: Dependabot cannot label per group, so a PR
# authored by dependabot[bot] whose title names a "<ecosystem>-minor-patch"
# group (grouped minor/patch updates) counts as labelled. Never a major: a
# single-dependency title "bump X from A to B in the ...-minor-patch group"
# is rejected when the leading major numbers of A and B differ. All the
# other rules (base dev, all checks green, quiet, clean) still apply.
# shellcheck disable=SC2016
ELIGIBLE_JQ='def depbot_minor_patch:
    ((.user.login // "") == "dependabot[bot]")
    and ((.title // "") | test("(^|: )bump .*the [a-z0-9_.-]+-minor-patch group( |$)"; "i"))
    and ((.title // "") as $t
         | if ($t | test(" from .+ to "; "i")) then
             # A from/to pair must parse (any non-digit prefix such as v, ^, ~)
             # and keep the same major; unreadable = not eligible.
             (($t | capture(" from [^0-9 ]*(?<a>[0-9]+)[^ ]* to [^0-9 ]*(?<b>[0-9]+)"; "i")) // null)
             | if . == null then false else .a == .b end
           else true end);
  def has_automerge: any(.labels[]?; (.name | ascii_downcase) == "automerge");
  def eligible: has_automerge or depbot_minor_patch;'
MARKER="automerge:branch-updated"

# classify_checks <check-runs-json-array> <statuses-json-array>
#   prints: total<TAB>pending<TAB>failed<TAB>last_activity ("-" if none);
#   last_activity = the latest started_at/completed_at/created_at/updated_at;
#   "x" when any required date is missing, malformed or not a real calendar
#   instant (round-trip through strptime/mktime/todate must be identical).
#   Returns non-zero when either input is not a JSON array.
# shellcheck disable=SC2016
classify_checks() {
  jq -e 'type == "array"' <<< "$1" >/dev/null 2>&1 || return 1
  jq -e 'type == "array"' <<< "$2" >/dev/null 2>&1 || return 1
  printf '%s\n%s\n' "$1" "$2" | jq -rs '
    .[0] as $cr | .[1] as $st
    | ($cr | map(if (.status // "") != "completed" then "pending"
               elif ((.conclusion // "") | IN("success", "neutral", "skipped")) then "ok"
               else "failed" end)) as $c
    | ($st | map(if (.state // "") == "success" then "ok"
                 elif (.state // "") == "pending" then "pending"
                 else "failed" end)) as $s
    | ($c + $s) as $all
    | def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
               and ((. as $d | try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | todate) catch "") == .);
      # Required activity dates: started_at (+ completed_at once completed)
      # for check runs, created_at + updated_at for statuses. One missing or
      # malformed date makes the whole clock unreadable ("x"): fail closed.
      ([$cr[] | .started_at, (if (.status // "") == "completed" then .completed_at else empty end)]
       + [$st[] | .created_at, .updated_at]) as $req
    | (if ($req | all(iso)) then ($req | sort | last) else "x" end) as $last
    | [($all | length), ($all | map(select(. == "pending")) | length),
       ($all | map(select(. == "failed")) | length), ($last // "-")]
    | map(tostring) | @tsv' | tr -d '\r'
}

# is_eligible <pr-json>: "true" when the PR is labelled automerge or is a
# Dependabot minor/patch group PR (ELIGIBLE_JQ).
is_eligible() { jq -r "$ELIGIBLE_JQ eligible" <<< "$1" 2>/dev/null | tr -d '\r'; }

# merge_decision <state> <draft> <base> <has_label> <touches_workflows>
#                <total> <pending> <failed> <quiet_secs> <mergeable_state>
#                <updated_once>
#   prints MERGE | UPDATE | SKIP <reason>. Any unreadable field -> SKIP.
merge_decision() {
  local state="$1" draft="$2" base="$3" label="$4" wf="$5" total="$6" pend="$7" failed="$8" quiet="$9" ms="${10}" upd="${11}"
  local int='^[0-9]+$'
  [[ "$state" == "open" ]] || { echo "SKIP not-open"; return; }
  [[ "$draft" == "false" ]] || { echo "SKIP draft"; return; }
  [[ "$base" == "dev" ]] || { echo "SKIP base-not-dev"; return; }
  [[ "$label" == "1" ]] || { echo "SKIP no-automerge-label"; return; }
  [[ "$wf" == "0" ]] || { echo "SKIP touches-workflows-or-unknown (merge by hand)"; return; }
  [[ "$total" =~ $int && "$pend" =~ $int && "$failed" =~ $int ]] || { echo "SKIP checks-unreadable"; return; }
  (( total >= 1 )) || { echo "SKIP no-checks"; return; }
  (( pend == 0 )) || { echo "SKIP checks-pending"; return; }
  (( failed == 0 )) || { echo "SKIP checks-failed"; return; }
  [[ "$quiet" =~ $int ]] || { echo "SKIP quiet-unreadable"; return; }
  (( quiet >= ${QUIET_SECS:-600} )) || { echo "SKIP head-not-quiet"; return; }
  case "$ms" in
    clean) echo MERGE ;;
    behind)
      if [[ "$upd" == "0" ]]; then echo UPDATE
      elif [[ "$upd" == "1" ]]; then echo "SKIP behind-already-updated-once"
      else echo "SKIP behind-update-history-unreadable"; fi ;;
    unknown|"") echo "SKIP mergeability-not-computed" ;;
    *) echo "SKIP not-clean ($ms)" ;;
  esac
}

# choose_merge_method <allow_merge_commit> <allow_squash> <allow_rebase>
choose_merge_method() {
  if [[ "${1:-}" == "true" ]]; then echo merge
  elif [[ "${2:-}" == "true" ]]; then echo squash
  elif [[ "${3:-}" == "true" ]]; then echo rebase
  else echo ""; fi
}

# iso_epoch <iso>: epoch seconds, or empty when unparsable.
# The value must round-trip exactly (2026-02-30 is rejected, not rolled over).
iso_epoch() {
  local e
  [[ "$1" =~ $HYG_ISO_RE ]] || return 0
  e="$(date -u -d "$1" +%s 2>/dev/null)" || return 0
  [[ "$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" == "$1" ]] && echo "$e"
  return 0
}

# slurp <gh api args...>: run a paginated gh api call whose --jq emits one
# JSON value per item, and print them as ONE JSON array (fails on error).
slurp() {
  local raw
  raw="$(gh api "$@" 2>/dev/null)" || return 1
  jq -s -c . <<< "$raw" 2>/dev/null
}

# evaluate_pr <repo> <num>: reads everything about the PR and prints
#   decision<TAB>head_sha<TAB>has_marker
# Every read failure degrades to a SKIP (fail closed).
evaluate_pr() {
  local repo="$1" num="$2" pr state draft base head label ms marker cr st cls total pend failed last
  local cdate suites t qs quiet wf files upd commits
  if ! pr="$(gh api "repos/$ORG/$repo/pulls/$num" --jq "$ELIGIBLE_JQ [.state, (.draft | tostring), .base.ref, .head.sha,
        (if eligible then \"1\" else \"0\" end),
        (if any(.labels[]?; (.name | ascii_downcase) == \"$MARKER\") then \"1\" else \"0\" end),
        (.mergeable_state // \"\")] | @tsv" 2>/dev/null | tr -d '\r')"; then
    printf 'SKIP pr-unreadable\t-\t-\n'; return
  fi
  IFS=$'\t' read -r state draft base head label marker ms <<< "$pr"
  [[ "$head" =~ $HYG_SHA_RE ]] || { printf 'SKIP head-unreadable\t-\t-\n'; return; }
  # Cheap rejections first (no further API calls).
  local pre
  pre="$(merge_decision "$state" "$draft" "$base" "$label" 0 1 0 0 999999 clean 0)"
  if [[ "$pre" == SKIP* ]]; then printf '%s\t%s\t%s\n' "$pre" "$head" "$marker"; return; fi

  cr="$(slurp "repos/$ORG/$repo/commits/$head/check-runs?per_page=100" --paginate \
        --jq '.check_runs[] | {status, conclusion, started_at, completed_at}' || echo bad)"
  st="$(slurp "repos/$ORG/$repo/commits/$head/status?per_page=100" --paginate \
        --jq '.statuses[] | {state, context, created_at, updated_at}' || echo bad)"
  if ! cls="$(classify_checks "$cr" "$st")"; then cls=$'-\t-\t-\t-'; fi
  IFS=$'\t' read -r total pend failed last <<< "$cls"

  # Quiet clock: the latest of the head commit date, any check suite
  # creation on the sha, and any check/status activity. Unreadable -> x.
  quiet=x
  cdate="$(gh api "repos/$ORG/$repo/commits/$head" --jq '.commit.committer.date' 2>/dev/null | tr -d '\r' || true)"
  if suites="$(gh api "repos/$ORG/$repo/commits/$head/check-suites?per_page=100" --paginate \
        --jq '.check_suites[] | (.created_at // "null")' 2>/dev/null | tr -d '\r')"; then
    qs="$(iso_epoch "$cdate")"
    # No check suite = no record of when this head was pushed (an old commit
    # pushed a minute ago looks old): fail closed.
    [[ -n "$suites" ]] || qs=""
    # The commit check-runs endpoint covers only the 1000 most recent check
    # suites: at that size coverage is not provable, so fail closed.
    if (( $(grep -c . <<< "$suites") >= 1000 )); then qs=""; fi
    if [[ -n "$qs" ]]; then
      for t in $suites "$last"; do
        [[ "$t" == "-" ]] && continue
        t="$(iso_epoch "$t")"
        if [[ -z "$t" ]]; then qs=""; break; fi
        (( t > qs )) && qs="$t"
      done
      [[ -n "$qs" ]] && quiet=$(( NOW_EPOCH - qs ))
      if [[ "$quiet" =~ ^-[0-9]+$ ]]; then quiet=0; fi
    fi
  fi

  if files="$(gh api "repos/$ORG/$repo/pulls/$num/files?per_page=100" --paginate --jq '.[] | .filename' 2>/dev/null | tr -d '\r')"; then
    if grep -q '^\.github/workflows/' <<< "$files"; then wf=1; else wf=0; fi
  else wf=x; fi

  upd=x
  if [[ "$ms" == "behind" ]]; then
    if [[ "$marker" == "1" ]]; then upd=1
    elif commits="$(gh api "repos/$ORG/$repo/pulls/$num/commits?per_page=100" --paginate \
          --jq ".[] | select((.author.login // \"\") == \"$APP_BOT\") | .sha" 2>/dev/null | tr -d '\r')"; then
      if [[ -n "$commits" ]]; then upd=1; else upd=0; fi
    fi
  fi
  printf '%s\t%s\t%s\n' "$(merge_decision "$state" "$draft" "$base" "$label" "$wf" "$total" "$pend" "$failed" "$quiet" "$ms" "$upd")" "$head" "$marker"
}

main() {
  ORG="${ORG:-Perditio-Labs}"
  MODE="${MODE:-report}"
  MIN_REPOS="${MIN_REPOS:-30}"
  SENTINEL_REPOS="${SENTINEL_REPOS:-}"
  QUIET_SECS="${QUIET_SECS:-600}"
  MAX_ACTIONS="${MAX_ACTIONS:-10}"
  APP_BOT="${APP_BOT:-perditio-ci-automation[bot]}"
  STRICT="${STRICT:-0}"
  HOST_REPO="${HOST_REPO:-${GITHUB_REPOSITORY:-$ORG/.github}}"
  OUT_DIR="${OUT_DIR:-$PWD/merge-out}"
  case "$MODE" in report|apply) ;; *) echo "ERROR: MODE must be report or apply" >&2; exit 2 ;; esac
  [[ -n "${GH_TOKEN:-}" ]] || { echo "ERROR: GH_TOKEN required" >&2; exit 2; }
  mkdir -p "$OUT_DIR"
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT
  local NOW
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  NOW_EPOCH="$(date -u +%s)"

  set +e
  hyg_capability "$ORG" "$MIN_REPOS" "$SENTINEL_REPOS" \
    "pull_requests=repos/$ORG/{repo}/pulls?state=all&per_page=1" \
    "checks=repos/$ORG/{repo}/commits/{def}/check-runs?per_page=1" \
    "statuses=repos/$ORG/{repo}/commits/{def}/status" \
    "contents_write=PUT:repos/$ORG/{repo}/pulls/0/merge" \
    "pull_requests_write=PUT:repos/$ORG/{repo}/pulls/0/update-branch" \
    "issues_write=POST:repos/$ORG/{repo}/issues/0/labels"
  local cap_rc=$?
  set -e
  echo "$CAP_MSG" | tee "$OUT_DIR/capability.txt" >&2
  if [[ "$cap_rc" != "0" ]]; then
    { echo "# Merge when green ($MODE) $NOW: NOT RUN"; echo; echo "$CAP_MSG"; echo; echo "Nothing was merged or updated."; } > "$OUT_DIR/summary.md"
    exit "$(exit_for "$cap_rc" "$MODE" "$STRICT")"
  fi

  # ---- discovery: every repo's open, non-draft, labelled PRs into dev ----
  local targets cands="$WORKDIR/cands.tsv" read_ok=0 errs=0 repo priv nums n
  : > "$cands"
  targets="$(jq -r 'select(.archived == false) | [.name, (.private | tostring)] | @tsv' <<< "$REPOS_JSON" | tr -d '\r')"
  while IFS=$'\t' read -r repo priv; do
    [[ -n "$repo" ]] || continue
    if ! nums="$(gh api "repos/$ORG/$repo/pulls?state=open&base=dev&per_page=100" --paginate \
          --jq "$ELIGIBLE_JQ .[] | select(.draft == false) | select(eligible) | .number" 2>/dev/null | tr -d '\r')"; then
      errs=$((errs + 1)); echo "WARN: could not list open PRs in $(repo_label "$repo" "$priv" "$REDACT"); repo skipped" >&2; continue
    fi
    read_ok=$((read_ok + 1))
    for n in $nums; do [[ "$n" =~ ^[0-9]+$ ]] && printf '%s\t%s\t%s\n' "$repo" "$priv" "$n" >> "$cands"; done
  done <<< "$targets"
  if (( read_ok < MIN_REPOS )); then
    { echo "# Merge when green ($MODE) $NOW: NOT RUN"; echo; echo "FAIL: only $read_ok repos were read without error (< $MIN_REPOS). Nothing was merged."; } > "$OUT_DIR/summary.md"
    echo "FAIL: only $read_ok repos were read without error (< $MIN_REPOS). Nothing was merged." >&2
    exit 1
  fi

  # ---- decide, re-evaluate, act ------------------------------------------
  local results="$WORKDIR/results.tsv" acted=0 merged=0 updated=0 num ev dec head marker ev2 dec2 head2 allow method
  : > "$results"
  row() { printf '%s\t%s\t%s\t%s\n' "$repo" "$priv" "$num" "$1" >> "$results"; }
  while IFS=$'\t' read -r -u 3 repo priv num; do
    ev="$(evaluate_pr "$repo" "$num")"
    IFS=$'\t' read -r dec head marker <<< "$ev"
    case "$dec" in MERGE|UPDATE) ;; *) row "$dec"; continue ;; esac
    if (( acted >= MAX_ACTIONS )); then row "DEFERRED $dec (MAX_ACTIONS=$MAX_ACTIONS)"; continue; fi
    acted=$((acted + 1))
    if [[ "$MODE" != "apply" ]]; then row "WOULD-$dec"; continue; fi
    # Full re-evaluation immediately before the write: same decision, same head.
    ev2="$(evaluate_pr "$repo" "$num")"
    IFS=$'\t' read -r dec2 head2 _ <<< "$ev2"
    if [[ "$dec2" != "$dec" || "$head2" != "$head" ]]; then row "SKIPPED (changed before the write: $dec2)"; continue; fi
    if [[ "$dec" == MERGE ]]; then
      allow="$(gh api "repos/$ORG/$repo" --jq '[(.allow_merge_commit | tostring), (.allow_squash_merge | tostring), (.allow_rebase_merge | tostring)] | @tsv' 2>/dev/null | tr -d '\r' || true)"
      # shellcheck disable=SC2086
      method="$(choose_merge_method $allow)"
      if [[ -z "$method" ]]; then errs=$((errs + 1)); row "ERROR (no allowed merge method readable)"; continue; fi
      if gh api -X PUT "repos/$ORG/$repo/pulls/$num/merge" -f merge_method="$method" -f sha="$head" >/dev/null 2>&1; then
        merged=$((merged + 1)); row "MERGED ($method)"
      else
        errs=$((errs + 1)); row "MERGE REFUSED (head moved, rules, or permission)"
      fi
    else
      # The marker goes on FIRST: no marker, no update (once, even after a
      # force-push removes the update commit).
      if ! gh api -X POST "repos/$ORG/$repo/issues/$num/labels" -f "labels[]=$MARKER" >/dev/null 2>&1; then
        errs=$((errs + 1)); row "ERROR (could not set the update marker; not updated)"; continue
      fi
      if gh api -X PUT "repos/$ORG/$repo/pulls/$num/update-branch" -f expected_head_sha="$head" >/dev/null 2>&1; then
        updated=$((updated + 1)); row "UPDATED BRANCH (once)"
      else
        errs=$((errs + 1)); row "UPDATE REFUSED (marker set; will not retry)"
      fi
    fi
  done 3< "$cands"

  local total_n priv_n
  total_n="$(wc -l < "$results" | tr -d ' ')"
  priv_n="$(awk -F'\t' -v r="$REDACT" '(r == "1" && $2 != "false")' "$results" | wc -l | tr -d ' ')"
  {
    echo "# Merge when green ($MODE) $NOW"
    echo
    echo "| measure | value |"
    echo "|---|---|"
    echo "| repos read without error | $read_ok |"
    echo "| open non-draft PRs into dev labelled $LABEL or Dependabot minor-patch group | $total_n |"
    echo "| merged this tick | $merged |"
    echo "| branches updated this tick | $updated |"
    echo "| errors / warnings | $errs |"
    echo
    echo "| repo | PR | decision |"
    echo "|---|---|---|"
    awk -F'\t' -v r="$REDACT" '(r == "0" || $2 == "false") {printf "| %s | #%s | %s |\n", $1, $3, $4}' "$results"
    echo
    echo "Private-repo rows (not named, this repo is public): $priv_n"
  } > "$OUT_DIR/summary.md"
  echo "Merge-when-green done: mode=$MODE read_ok=$read_ok candidates=$total_n merged=$merged updated=$updated errors=$errs"
  if [[ "$errs" != "0" ]]; then
    echo "::warning::merge-when-green: $errs repo(s)/PR(s) could not be read, merged or updated; see the job summary."
    # A dispatched apply must not look green when a write failed.
    if [[ "$MODE" == "apply" && "$STRICT" == "1" ]] && grep -qE 'REFUSED|ERROR' "$results"; then exit 1; fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
