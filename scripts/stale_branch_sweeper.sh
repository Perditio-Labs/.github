#!/usr/bin/env bash
#
# stale_branch_sweeper.sh - archive-tag then delete merged-orphan branches
# across every non-archived Perditio-Labs repo (private AND public), and
# report stale open PRs. Port of PTR-Labs/.github scripts/stale_branch_sweeper.sh
# plus the squash-merged path.
#
# Run by .github/workflows/stale-branch-sweeper.yml with a perditio-ci-automation
# GitHub App token. FAILS LOUDLY unless the token can read at least MIN_REPOS
# private repos including every SENTINEL_REPOS repo AND can read pull requests
# there (without PR read, an open-PR head would look deletable). It also fails
# unless at least MIN_REPOS target repos were read without error; that
# coverage gate runs after the read-only phase 1 and BEFORE any mutation.
#
# A branch is a merged orphan, and is archived + deleted, only when ALL hold:
#   - the repo is not archived, not a fork, not a mirror (mirror_url set or a
#     name starting mirror-), not vendor-*, and not in SKIP_REPOS;
#   - the branch is not permanent (dev staging main master release*) and not
#     the default branch;
#   - it is not the head of ANY open PR (Ref.associatedPullRequests) and not
#     the head or base of an open PR into this repo;
#   - its tip commit is older than MIN_AGE_HOURS (an active lane keeps it);
#   - it is 0 commits ahead of dev (or of the default branch when the repo has
#     no dev), or 0 ahead of the default branch (a merged hotfix), OR
#     (squash path) a MERGED PR into this repo has head sha == the branch tip
#     (squash/rebase merges leave the branch "ahead"; tip == merged head proves
#     nothing was pushed after the merge);
#   - every field above was read unambiguously (anything missing keeps it).
# apply mode, per branch: re-read everything immediately before acting and
# require it unchanged; create tag archive/<YYYY-MM-DD>/<branch> at the
# inspected tip and verify it; then delete with
# `git push --force-with-lease=refs/heads/<b>:<tip>` so the server refuses the
# delete if anyone pushed after inspection. A tag that already exists at a
# DIFFERENT sha is never moved: the branch is kept. Residual race (GitHub
# cannot lock PR creation): a post-delete check finds PRs closed by the
# deletion, restores the branch at the verified tip and reopens them.
#
# PRIVACY: when the host repo is public (REDACT=1), nothing this script writes
# (stdout, stderr, summary.md) names a private repo, its branches or PRs;
# private repos appear only as aggregate counts. Full detail stays in each
# private repo as its archive/* tags.
#
# Env:
#   GH_TOKEN          App token (required)
#   ORG               default Perditio-Labs
#   MODE              report | apply   (report = dry run, nothing written)
#   MIN_REPOS         default 30
#   SENTINEL_REPOS    private repos that must be visible. REQUIRED, no default:
#                     from the secret SWEEPER_SENTINEL_REPOS (masked in logs);
#                     private repo names never live in this public repo.
#   MIN_AGE_HOURS     default 72
#   STALE_PR_DAYS     default 21
#   MAX_DELETIONS     default 400 (per run; the rest is reported as deferred)
#   SKIP_REPOS        space-separated repo names never touched
#   HOST_REPO         this repo's name (default: from GITHUB_REPOSITORY, else .github)
#   OUT_DIR           where summary.md (and the private-safe tables) go
#
set -euo pipefail

ORG="${ORG:-Perditio-Labs}"
MODE="${MODE:-report}"
MIN_REPOS="${MIN_REPOS:-30}"
SENTINEL_REPOS="${SENTINEL_REPOS:-}"
MIN_AGE_HOURS="${MIN_AGE_HOURS:-72}"
STALE_PR_DAYS="${STALE_PR_DAYS:-21}"
MAX_DELETIONS="${MAX_DELETIONS:-400}"
SKIP_REPOS="${SKIP_REPOS:-}"
HOST_REPO="${HOST_REPO:-${GITHUB_REPOSITORY:-$ORG/.github}}"
HOST_REPO="${HOST_REPO#*/}"
OUT_DIR="${OUT_DIR:-$PWD/sweep-out}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hygiene_lib.sh
. "$HERE/hygiene_lib.sh"
# Protected-branch rules + eligibility (single source, unit-tested).
# shellcheck source=scripts/branch_guard.sh
. "$HERE/branch_guard.sh"

case "$MODE" in report|apply) ;; *) echo "ERROR: MODE must be report or apply" >&2; exit 2 ;; esac
[[ -n "${GH_TOKEN:-}" ]] || { echo "ERROR: GH_TOKEN required" >&2; exit 2; }
mkdir -p "$OUT_DIR"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
# Raw tables (may hold private names) live only in WORKDIR, never in OUT_DIR.
RESULTS="$WORKDIR/results.tsv"
STALE_PRS="$WORKDIR/stale-prs.tsv"
ERRORS="$WORKDIR/errors.tsv"
: > "$RESULTS"; : > "$STALE_PRS"; : > "$ERRORS"

TODAY="$(date -u +%Y-%m-%d)"
NOW_EPOCH="$(date -u +%s)"
AGE_CUTOFF="$(date -u -d "@$((NOW_EPOCH - MIN_AGE_HOURS * 3600))" +%Y-%m-%dT%H:%M:%SZ)"
PR_CUTOFF="$(date -u -d "@$((NOW_EPOCH - STALE_PR_DAYS * 86400))" +%Y-%m-%dT%H:%M:%SZ)"

declare -A SKIP
for r in $SKIP_REPOS; do [[ -n "$r" ]] && SKIP["${r#*/}"]=1; done

# Every gh call inside the per-repo loops goes through ghq: gh prints the
# request URL (with the repo name) on failure, and logs here are public.
ghq() { gh "$@" 2>/dev/null; }

# URL-encode a ref name for a REST path, keeping '/' (GitHub expects it raw).
enc() { jq -rn --arg v "$1" '$v | @uri | gsub("%2F"; "/")' | tr -d '\r'; }

# err/row: <repo> <private> ... ; printing is redacted, the raw row is kept
# in WORKDIR for the (redacted) summary.
err() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$ERRORS"
  if [[ "$REDACT" == "1" && "$2" != "false" ]]; then
    echo "ERROR: (private repo): $4" >&2
  else
    echo "ERROR: $1 $3: $4" >&2
  fi
}
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RESULTS"; }

# ---- 1. capability: can this token really see the org? ---------------------
if ! REPOS_JSON="$(gh api "orgs/$ORG/repos?per_page=100&type=all" --paginate \
  --jq '.[] | {name, archived, fork, private, mirror: (.mirror_url != null), default_branch}' 2>/dev/null | tr -d '\r')"; then
  echo "FAIL: could not list $ORG repos with this token. Refusing to report a clean sweep." >&2
  exit 1
fi
REDACT="$(host_redact "$REPOS_JSON" "$HOST_REPO")"
SEEN="$(grep -c '"name"' <<< "$REPOS_JSON" || true)"
SEEN_PRIVATE="$(jq -s '[.[] | select(.private == true and .archived == false)] | length' <<< "$REPOS_JSON" | tr -d '\r')"
echo "Repos visible to this token: $SEEN (private, not archived: $SEEN_PRIVATE; minimum $MIN_REPOS). Host public-safe redaction: $REDACT"
printf '%s total, %s private non-archived\n' "$SEEN" "$SEEN_PRIVATE" > "$OUT_DIR/repos-seen.txt"
if [[ -z "${SENTINEL_REPOS//[[:space:]]/}" ]]; then
  CAP_MSG="FAIL: no sentinel repo configured (secret SWEEPER_SENTINEL_REPOS is empty). Without a private sentinel this guard cannot fire. Refusing to report a clean sweep."
  echo "$CAP_MSG" | tee "$OUT_DIR/capability.txt" >&2
  { echo "# Stale branch sweep ($MODE) $TODAY: NOT RUN"; echo; echo "$CAP_MSG"; } > "$OUT_DIR/summary.md"
  exit 1
fi
missing_sentinels=""
probes=()
for s in $SENTINEL_REPOS; do
  if jq -e --arg n "$s" 'select(.name == $n and .private == true)' <<< "$REPOS_JSON" >/dev/null 2>&1; then
    set +e; out="$(gh api "repos/$ORG/$s/pulls?state=all&per_page=1" 2>&1)"; rc=$?; set -e
    # Probe labels never carry the (private) sentinel name: logs are public.
    probes+=("pull_requests=$(probe_state "$rc" "$out")")
  else
    missing_sentinels+="$s "
  fi
done
set +e
CAP_MSG="$(capability_decision "$SEEN_PRIVATE" "$MIN_REPOS" "$missing_sentinels" "${probes[@]}")"; CAP_RC=$?
set -e
echo "$CAP_MSG" | tee "$OUT_DIR/capability.txt" >&2
if [[ "$CAP_RC" != "0" ]]; then
  {
    echo "# Stale branch sweep ($MODE) $TODAY: NOT RUN"
    echo
    echo "$CAP_MSG"
    echo
    echo "Nothing was archived or deleted."
  } > "$OUT_DIR/summary.md"
  exit "$(exit_for "$CAP_RC" "$MODE" 1)"
fi

TARGETS="$(jq -r 'select(.archived == false and .fork == false and .mirror == false)
  | select(.name | test("^(mirror-|vendor-)") | not)
  | [.name, .default_branch, (.private | tostring)] | @tsv' <<< "$REPOS_JSON" | tr -d '\r')"

deleted=0
deferred=0
read_ok=0
CANDIDATES="$WORKDIR/candidates.tsv"
: > "$CANDIDATES"
COVERAGE_FAIL=""
# Branch tips, dates, ahead-counts, open-PR-head counts and merged-PR heads in
# one GraphQL page per 50 branches. Ref.compare(headRef) uses this ref as
# BASE: behindBy = commits on this branch that headRef lacks = "ahead of
# headRef".
REF_QUERY='query($owner:String!,$name:String!,$cmp:String!,$def:String!,$after:String){repository(owner:$owner,name:$name){refs(refPrefix:"refs/heads/",first:50,after:$after){pageInfo{hasNextPage endCursor} nodes{name target{oid ... on Commit{committedDate}} c1:compare(headRef:$cmp){behindBy} c2:compare(headRef:$def){behindBy} heads:associatedPullRequests(states:OPEN){totalCount} merged:associatedPullRequests(states:MERGED,first:20,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{headRefOid baseRepository{nameWithOwner}}}}}}}'
PR_QUERY='query($owner:String!,$name:String!,$after:String){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{number title isDraft createdAt updatedAt baseRefName headRefName headRepository{nameWithOwner}}}}}'
DEV_QUERY='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){ref(qualifiedName:"refs/heads/dev"){name}}}'
# Post-delete recovery: closed PRs with this branch as head / as base.
RECOVER_HEAD_QUERY='query($owner:String!,$name:String!,$b:String!,$after:String){repository(owner:$owner,name:$name){pullRequests(headRefName:$b,states:CLOSED,first:50,after:$after,orderBy:{field:UPDATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{number merged closedAt baseRefName headRepository{nameWithOwner}}}}}'
RECOVER_BASE_QUERY='query($owner:String!,$name:String!,$b:String!,$after:String){repository(owner:$owner,name:$name){pullRequests(baseRefName:$b,states:CLOSED,first:50,after:$after,orderBy:{field:UPDATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{number merged closedAt baseRefName headRepository{nameWithOwner}}}}}'
# Immediately-before-apply re-read of one branch.
ONE_QUERY='query($owner:String!,$name:String!,$q:String!,$b:String!,$cmp:String!,$def:String!){repository(owner:$owner,name:$name){defaultBranchRef{name} bases:pullRequests(states:OPEN,baseRefName:$b){totalCount} ref(qualifiedName:$q){target{oid ... on Commit{committedDate}} c1:compare(headRef:$cmp){behindBy} c2:compare(headRef:$def){behindBy} heads:associatedPullRequests(states:OPEN){totalCount} merged:associatedPullRequests(states:MERGED,first:20,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{headRefOid baseRepository{nameWithOwner}}}}}}'

# jq: "1" when a merged PR into <full> has head sha == this ref's tip, "0"
# when the list was read and none matches, "-" when unreadable.
SQ_JQ='(.target.oid // "") as $t
  | if (.merged == null or (.merged.nodes | type) != "array") then "-"
    elif ([.merged.nodes[] | select(.headRefOid == $t and $t != "" and (.baseRepository.nameWithOwner // "") == $full)] | length) > 0 then "1"
    else "0" end'

gql_all() { # gql_all <query> <repo> <jq path to connection> [extra gh -F args...]
  local q="$1" repo="$2" conn="$3" after="" out page more nodes
  shift 3
  out=""
  while :; do
    # Explicit `|| return 1` on EVERY step: this function runs inside an
    # `if !` test, where set -e is OFF, and a silently short list would make
    # a PR head look deletable.
    if [[ -z "$after" ]]; then
      page="$(ghq api graphql -f query="$q" -F owner="$ORG" -F name="$repo" "$@")" || return 1
    else
      page="$(ghq api graphql -f query="$q" -F owner="$ORG" -F name="$repo" "$@" -F after="$after")" || return 1
    fi
    jq -e "$conn.nodes | type == \"array\"" <<< "$page" >/dev/null 2>&1 || return 1
    nodes="$(jq -c "$conn.nodes[]" <<< "$page" | tr -d '\r')" || return 1
    out+="$nodes"$'\n'
    more="$(jq -r "$conn.pageInfo.hasNextPage | if type == \"boolean\" then tostring else \"bad\" end" <<< "$page" | tr -d '\r')" || return 1
    case "$more" in
      false) break ;;
      true)
        local next
        next="$(jq -r "$conn.pageInfo.endCursor // \"\"" <<< "$page" | tr -d '\r')" || return 1
        [[ -n "$next" && "$next" != "$after" ]] || return 1
        after="$next" ;;
      *) return 1 ;;
    esac
  done
  printf '%s' "$out"
}

# Delete refs/heads/<b> only if it still points at <tip>: the server checks
# the old value in the push command, so a push after inspection makes the
# delete fail instead of losing that work. Token passed via env config, never
# argv.
lease_delete() { # lease_delete <full> <branch> <tip> <default>
  assert_deletable "$2" "${4:-}"   # hard stop: aborts the whole run
  local auth
  auth="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" \
    git -C "$WORKDIR/lease" push --quiet --force-with-lease="refs/heads/$2:$3" \
      "https://github.com/$1.git" ":refs/heads/$2"
}
git init -q "$WORKDIR/lease"

while IFS=$'\t' read -r repo def priv; do
  [[ -n "$repo" ]] || continue
  if [[ -n "${SKIP[$repo]:-}" ]]; then
    row "$repo" "$priv" - - - - - "SKIP-REPO (held)"
    continue
  fi
  full="$ORG/$repo"

  if ! prs="$(gql_all "$PR_QUERY" "$repo" '.data.repository.pullRequests')"; then
    err "$repo" "$priv" "-" "could not list open PRs; repo skipped"; continue
  fi

  # Stale open PRs (no update for STALE_PR_DAYS days).
  jq -r --arg cut "$PR_CUTOFF" --arg repo "$repo" --arg priv "$priv" --argjson now "$NOW_EPOCH" '
    select(.updatedAt < $cut)
    | [$repo, $priv, (.number|tostring), (((($now - (.createdAt|fromdateiso8601)) / 86400)|floor)|tostring),
       .updatedAt, .baseRefName, .headRefName, (.isDraft|tostring), (.title|gsub("[\t\n|]";" "))] | @tsv' \
    <<< "$prs" 2>/dev/null | tr -d '\r' >> "$STALE_PRS" || true

  # Branches kept because an open PR INTO this repo uses them as head or base
  # (fork heads do not live here). Heads of PRs into OTHER repos are caught
  # per branch by associatedPullRequests below.
  unset KEEP; declare -A KEEP=()
  while IFS= read -r b; do [[ -n "$b" ]] && KEEP["$b"]=1; done < <(
    jq -r --arg full "$full" '(select((.headRepository.nameWithOwner // "") == $full) | .headRefName), .baseRefName' <<< "$prs" | tr -d '\r')

  if ! devq="$(ghq api graphql -f query="$DEV_QUERY" -F owner="$ORG" -F name="$repo" --jq '.data.repository.ref.name // ""')"; then
    err "$repo" "$priv" "-" "could not check for a dev branch; repo skipped"; continue
  fi
  devq="$(tr -d '\r' <<< "$devq")"
  cmp_base="dev"; [[ "$devq" == "dev" ]] || cmp_base="$def"
  if ! refs="$(gql_all "$REF_QUERY" "$repo" '.data.repository.refs' -F cmp="$cmp_base" -F def="$def")"; then
    err "$repo" "$priv" "-" "could not list branches; repo skipped"; continue
  fi
  if ! rows="$(jq -r --arg full "$full" "[(.name // \"-\"), (.target.oid // \"-\"), (.target.committedDate // \"-\"),
                      (if .c1 == null then \"x\" else (.c1.behindBy // \"-\" | tostring) end),
                      (if .c2 == null then \"x\" else (.c2.behindBy // \"-\" | tostring) end),
                      (.heads.totalCount // \"-\" | tostring),
                      ($SQ_JQ)] | @tsv" <<< "$refs" | tr -d '\r')"; then
    err "$repo" "$priv" "-" "could not parse branches; repo skipped"; continue
  fi
  read_ok=$((read_ok + 1))

  # Every field is a non-empty token ("-" = missing), so tab-splitting can
  # never shift columns.
  while IFS=$'\t' read -r br tip when a1 a2 heads sq; do
    [[ -n "$br" && "$br" != "-" ]] || continue
    kept=0; [[ -n "${KEEP[$br]:-}" ]] && kept=1
    if ! which="$(merged_orphan_eligible "$br" "$def" "$tip" "$when" "$a1" "$a2" "$heads" "$kept" "$AGE_CUTOFF" "$sq")"; then
      # Report "no comparison" only for a branch that would otherwise have
      # qualified (valid sha/date, zero open head PRs, old tip, unprotected).
      if [[ "$a1" == "x" && "$a2" == "x" && "$sq" != "1" && "$kept" == "0" && "$heads" == "0" \
            && "$tip" =~ $HYG_SHA_RE && "$when" =~ $HYG_ISO_RE && "$when" < "$AGE_CUTOFF" ]] \
         && ! is_protected_branch "$br" "$def"; then
        row "$repo" "$priv" "$br" "$tip" "?" "-" "$when" "KEPT (no comparison possible)"
      fi
      continue
    fi
    case "$which" in cmp) base_used="$cmp_base" ;; def) base_used="$def" ;; *) base_used="squash-merged PR" ;; esac

    if [[ "$MODE" != "apply" ]]; then
      row "$repo" "$priv" "$br" "$tip" "$which" "$base_used" "$when" "WOULD-ARCHIVE+DELETE"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$priv" "$def" "$cmp_base" "$br" "$tip" "$when" "$which" "$base_used" >> "$CANDIDATES"
    fi
  done <<< "$rows"
done <<< "$TARGETS"

# ---- coverage gate: BEFORE any mutation -------------------------------------
if (( read_ok < MIN_REPOS )); then
  echo "FAIL: only $read_ok target repos were read without error (< $MIN_REPOS). Nothing was archived or deleted." >&2
  COVERAGE_FAIL=1
fi

# ---- phase 2 (apply only): re-check, archive-tag, lease-delete, post-check --
recheck() { # recheck <repo> <br> <cmp_base> <def> -> prints d2 bases2 tip2 heads2 b1 b2 sq2
  ghq api graphql -f query="$ONE_QUERY" -F owner="$ORG" -F name="$1" \
    -F q="refs/heads/$2" -F b="$2" -F cmp="$3" -F def="$4" \
    | jq -r --arg full "$ORG/$1" ".data.repository | [(.defaultBranchRef.name // \"-\"), (.bases.totalCount // \"-\" | tostring),
          (.ref.target.oid // \"-\"), (.ref.heads.totalCount // \"-\" | tostring),
          (if .ref.c1 == null then \"x\" else (.ref.c1.behindBy | tostring) end),
          (if .ref.c2 == null then \"x\" else (.ref.c2.behindBy | tostring) end),
          (if .ref == null then \"-\" else (.ref | $SQ_JQ) end)] | @tsv" | tr -d '\r'
}
still_ok() { # still_ok <recheck-line> <def> <tip> <which>
  local d2 bases2 tip2 heads2 b1 b2 sq2
  IFS=$'\t' read -r d2 bases2 tip2 heads2 b1 b2 sq2 <<< "$1"
  [[ "$d2" == "$2" && "$bases2" == "0" && "$tip2" == "$3" && "$heads2" == "0" ]] || return 1
  case "$4" in
    cmp) [[ "$b1" == "0" ]] ;;
    def) [[ "$b2" == "0" ]] ;;
    squash) [[ "$sq2" == "1" ]] ;;
    *) return 1 ;;
  esac
}
PHASE2_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$MODE" == "apply" && -z "${COVERAGE_FAIL:-}" && -s "$CANDIDATES" ]]; then
  # fd 3: nothing inside the loop (gh, git) can consume the candidate list.
  while IFS=$'\t' read -r -u 3 repo priv def cmp_base br tip when which base_used; do
    full="$ORG/$repo"
    tag="archive/$TODAY/$br"
    assert_deletable "$br" "$def"   # hard stop before any write for this branch
    if (( deleted >= MAX_DELETIONS )); then
      deferred=$((deferred + 1))
      row "$repo" "$priv" "$br" "$tip" "$which" "$base_used" "$when" "DEFERRED (MAX_DELETIONS)"
      continue
    fi
    # Re-read 1: everything inspected in phase 1 must still hold.
    if ! one="$(recheck "$repo" "$br" "$cmp_base" "$def")" || [[ -z "$one" ]]; then
      err "$repo" "$priv" "$br" "re-read before apply failed; branch kept"; continue
    fi
    if ! still_ok "$one" "$def" "$tip" "$which"; then
      row "$repo" "$priv" "$br" "$tip" "$which" "$base_used" "$when" "KEPT (changed since inspection)"
      continue
    fi

    # Archive tag: only a confirmed 404 means "absent".
    existing=""
    if out="$(gh api "repos/$full/git/ref/tags/$(enc "$tag")" --jq '.object.type + " " + .object.sha' 2>&1)"; then
      existing="$(tr -d '\r' <<< "$out")"
    elif ! grep -q 'HTTP 404' <<< "$out"; then
      err "$repo" "$priv" "$br" "tag lookup inconclusive; branch kept"; continue
    fi
    if [[ -z "$existing" ]]; then
      if ! ghq api -X POST "repos/$full/git/refs" -f ref="refs/tags/$tag" -f sha="$tip" >/dev/null; then
        err "$repo" "$priv" "$br" "tag create failed; branch kept"; continue
      fi
      # A freshly created ref can read back 404 for a moment: retry.
      existing=""
      for attempt in 1 2 3 4 5; do
        existing="$(ghq api "repos/$full/git/ref/tags/$(enc "$tag")" --jq '.object.type + " " + .object.sha' | tr -d '\r' || echo "")"
        [[ "$existing" == "commit $tip" ]] && break
        sleep $((attempt * 2))
      done
    fi
    if [[ "$existing" != "commit $tip" ]]; then
      err "$repo" "$priv" "$br" "archive tag exists at another object or is unreadable; branch kept"; continue
    fi

    # Re-read 2, immediately before the push, to shrink the race window.
    if ! one="$(recheck "$repo" "$br" "$cmp_base" "$def")" || ! still_ok "$one" "$def" "$tip" "$which"; then
      row "$repo" "$priv" "$br" "$tip" "$which" "$base_used" "$when" "KEPT (changed after archive tag; tag left in place)"
      continue
    fi
    assert_deletable "$br" "$def"
    if ! lease_delete "$full" "$br" "$tip" "$def" 2>"$WORKDIR/lease.err"; then
      # lease.err holds the remote URL (repo name): never printed.
      err "$repo" "$priv" "$br" "lease delete refused/failed after the archive tag was verified (moved since inspection?); branch kept"
      continue
    fi
    deleted=$((deleted + 1))

    # Post-check: a PR opened on this branch (head or base) inside the
    # remaining window is closed by GitHub when the branch goes away.
    if ! rh="$(gql_all "$RECOVER_HEAD_QUERY" "$repo" '.data.repository.pullRequests' -F b="$br")" \
       || ! rb="$(gql_all "$RECOVER_BASE_QUERY" "$repo" '.data.repository.pullRequests' -F b="$br")" \
       || ! raced="$(printf '%s\n%s\n' "$rh" "$rb" | jq -r --arg full "$full" --arg since "$PHASE2_START" --arg b0 "$br" '
              select(type == "object")
              | select(.merged == false and (.closedAt // "") >= $since)
              | select(.baseRefName == $b0 or (.headRepository.nameWithOwner // "") == $full)
              | .number' | tr -d '\r' | sort -un | tr '\n' ' ' | sed 's/ $//')"; then
      err "$repo" "$priv" "$br" "deleted (archive tag kept); post-delete PR check FAILED - inspect closed PRs for this branch by hand"
      row "$repo" "$priv" "$br" "$tip" "$which" "$base_used" "$when" "ARCHIVED+DELETED (post-check failed)"
      continue
    fi
    if [[ -n "$raced" ]]; then
      if ghq api -X POST "repos/$full/git/refs" -f ref="refs/heads/$br" -f sha="$tip" >/dev/null; then
        deleted=$((deleted - 1))
        reopened=0; failed=0
        for n in $raced; do
          if ghq api -X PATCH "repos/$full/pulls/$n" -f state=open >/dev/null; then reopened=$((reopened + 1))
          else failed=$((failed + 1)); err "$repo" "$priv" "$br" "restored branch but could not reopen a PR"; fi
        done
        row "$repo" "$priv" "$br" "$tip" "$which" "$base_used" "$when" "RESTORED (PR(s) used it during the sweep; reopened $reopened, failed $failed)"
      else
        err "$repo" "$priv" "$br" "PR(s) used the branch during the sweep and the restore FAILED; restore from the archive tag and reopen by hand"
      fi
      continue
    fi
    row "$repo" "$priv" "$br" "$tip" "$which" "$base_used" "$when" "ARCHIVED+DELETED"
  done 3< "$CANDIDATES"
fi

# ---- summary (public-safe when REDACT=1) -------------------------------------
# A row is printable when the host is private or the repo is public.
printable() { awk -F'\t' -v r="$REDACT" '(r == "0" || $2 == "false")' "$1"; }
private_n() { awk -F'\t' -v r="$REDACT" '(r == "1" && $2 != "false")' "$1" | wc -l | tr -d ' '; }
acted="$(wc -l < "$RESULTS" | tr -d ' ')"
stale_n="$(wc -l < "$STALE_PRS" | tr -d ' ')"
err_n="$(wc -l < "$ERRORS" | tr -d ' ')"
n_targets="$(grep -c . <<< "$TARGETS" || true)"
squash_n="$(awk -F'\t' '$5 == "squash"' "$RESULTS" | wc -l | tr -d ' ')"
{
  echo "# Stale branch sweep ($MODE) $TODAY"
  echo
  echo "| measure | value |"
  echo "|---|---|"
  echo "| repos visible to token (private, not archived) | $SEEN ($SEEN_PRIVATE) |"
  echo "| target repos (non-archived, non-fork, non-mirror, non-vendor; private and public) | $n_targets |"
  echo "| target repos read without error | $read_ok |"
  echo "| held repos | $(if [[ -n "$SKIP_REPOS" ]]; then echo "$(wc -w <<< "$SKIP_REPOS" | tr -d ' ') (names in the workflow file)"; else echo none; fi) |"
  echo "| branch rows (merged orphans: 0 ahead or squash-merged, > ${MIN_AGE_HOURS} h, no open PR; plus KEPT rows) | $acted |"
  echo "| of which via the squash-merged path | $squash_n |"
  echo "| archived + deleted this run | $deleted |"
  echo "| deferred (MAX_DELETIONS=$MAX_DELETIONS) | $deferred |"
  echo "| open PRs not updated for > ${STALE_PR_DAYS} days | $stale_n |"
  echo "| errors | $err_n |"
  echo
  echo "Archive tag form: archive/$TODAY/<branch> (restore: git push origin refs/tags/archive/$TODAY/<branch>:refs/heads/<branch>)."
  if [[ "$REDACT" == "1" ]]; then
    echo
    echo "This repo is public: rows for private repos are counted, never named. Each private repo keeps its own archive/* tags."
  fi
  echo
  echo "## Branches"
  echo
  echo "| repo | branch | tip | merged via | vs | last commit | action |"
  echo "|---|---|---|---|---|---|---|"
  printable "$RESULTS" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s | %s |\n", $1, $3, substr($4,1,8), $5, $6, $7, $8}'
  echo
  echo "Private-repo branch rows (not named): $(private_n "$RESULTS")"
  echo
  echo "## Open PRs not updated for > ${STALE_PR_DAYS} days"
  echo
  echo "| repo | PR | age (days) | last update | base | head | draft | title |"
  echo "|---|---|---|---|---|---|---|---|"
  printable "$STALE_PRS" | sort -t$'\t' -k4,4nr | awk -F'\t' '{printf "| %s | #%s | %s | %s | %s | %s | %s | %s |\n", $1, $3, $4, $5, $6, $7, $8, $9}'
  echo
  echo "Private-repo stale PRs (not named): $(private_n "$STALE_PRS")"
  if [[ "$err_n" != "0" ]]; then
    echo
    echo "## Errors"
    echo
    echo "| repo | branch | error |"
    echo "|---|---|---|"
    printable "$ERRORS" | awk -F'\t' '{printf "| %s | %s | %s |\n", $1, $3, $4}'
    echo
    echo "Private-repo errors (not named): $(private_n "$ERRORS")"
  fi
} > "$OUT_DIR/summary.md"
echo "Sweep done: seen=$SEEN private=$SEEN_PRIVATE read_ok=$read_ok rows=$acted squash=$squash_n deleted=$deleted deferred=$deferred stale_prs=$stale_n errors=$err_n"
if [[ -n "$COVERAGE_FAIL" ]]; then
  echo "FAIL: only $read_ok target repos were read without error (< $MIN_REPOS); nothing was archived or deleted." >&2
  exit 1
fi
if [[ "$err_n" != "0" ]]; then
  echo "FAIL: $err_n error(s). See the Errors table." >&2
  exit 1
fi
