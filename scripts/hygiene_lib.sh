#!/usr/bin/env bash
# hygiene_lib.sh - shared helpers for the Perditio-Labs org hygiene workflows
# (stale-branch-sweeper, rerun-cancelled-once, merge-when-green). Sourced by
# the scripts and by the tests, so the tests exercise the production code.
#
# Two rules live here:
#   1. Capability guard: a hygiene job whose token cannot see the org must
#      FAIL instead of reporting a clean run (a guard that cannot fire).
#   2. Privacy: this repo (Perditio-Labs/.github) is PUBLIC, so its run logs,
#      job summaries and issues are public. Names of PRIVATE repos (and their
#      branches, PR numbers and titles) must never be printed there.

HYG_ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
HYG_SHA_RE='^[0-9a-f]{40}$'
HYG_INT_RE='^[0-9]+$'

# capability_decision <seen_private> <min_repos> <missing_sentinels> <probe>...
#   Pure. <probe> args are "<name>=<ok|denied|error>" for each permission the
#   job needs (e.g. pulls=ok checks=denied). Returns:
#     0 the token reaches the org and has every probed permission
#     1 the token cannot reach the org (too few private repos / no sentinel)
#       or a probe was inconclusive (error): FAIL, never report clean
#     4 the token reaches the org but lacks a permission (denied): BLOCKED
#   Prints one human line (no repo names other than the sentinels).
capability_decision() {
  local seen="$1" min="$2" missing="$3"
  shift 3
  if ! [[ "$seen" =~ $HYG_INT_RE && "$min" =~ $HYG_INT_RE ]]; then
    echo "FAIL: repo count unreadable (seen='$seen', min='$min'); refusing to report a clean run."
    return 1
  fi
  local nmiss
  nmiss="$(wc -w <<< "$missing" | tr -d ' ')"
  if (( seen < min )) || (( nmiss > 0 )); then
    # Sentinels are private repos: counted, never named (public logs).
    echo "FAIL: this token sees $seen private repos (minimum $min) and/or cannot see $nmiss sentinel repo(s). It cannot reach the org, so this guard cannot fire. Refusing to report a clean run."
    return 1
  fi
  local p name state denied="" errored=""
  for p in "$@"; do
    name="${p%%=*}"; state="${p#*=}"
    case "$state" in
      ok) ;;
      denied) denied+="$name " ;;
      *) errored+="$name " ;;
    esac
  done
  if [[ -n "$errored" ]]; then
    echo "FAIL: permission probe(s) inconclusive: ${errored% }. Refusing to report a clean run."
    return 1
  fi
  if [[ -n "$denied" ]]; then
    echo "BLOCKED: the token reaches the org ($seen private repos) but lacks permission(s): ${denied% }. Nothing was changed."
    return 4
  fi
  echo "OK: the token reaches the org ($seen private repos) and has every probed permission."
  return 0
}

# probe_state <exit-code> <captured stdout+stderr>: maps a `gh api` probe
# result to ok | denied | error. Only an explicit permission refusal counts
# as denied; anything else unexpected is an error (fail closed).
probe_state() {
  local rc="$1" out="$2"
  if [[ "$rc" == "0" ]]; then echo ok; return; fi
  if grep -qi 'Resource not accessible by integration' <<< "$out"; then echo denied; return; fi
  echo error
}

# probe_write_state <exit-code> <captured stdout+stderr>: for a WRITE probe
# aimed at a resource that cannot exist (e.g. re-run of workflow run 1 in
# the sentinel repo). GitHub checks the App permission before resolving the
# resource, so 404 = the permission is granted, an integration 403 = denied.
# Success (the write happened) or anything else = error (fail closed).
probe_write_state() {
  local rc="$1" out="$2"
  if [[ "$rc" == "0" ]]; then echo error; return; fi
  if grep -qi 'Resource not accessible by integration' <<< "$out"; then echo denied; return; fi
  if grep -q 'HTTP 404' <<< "$out"; then echo ok; return; fi
  echo error
}

# repo_label <name> <is_private:true|false> <redact:0|1>: what may be printed
# for a repo. In a public host repo (redact=1) a private repo prints as
# "(private repo)". Unknown privacy is treated as private.
repo_label() {
  local name="$1" priv="$2" redact="$3"
  if [[ "$redact" == "0" || "$priv" == "false" ]]; then printf '%s' "$name"; else printf '(private repo)'; fi
}

# host_redact <repos-json-lines> <host-repo-name>: prints 0 only when the host
# repo is listed AND private; anything else (public, absent, unreadable) = 1.
host_redact() {
  local v
  v="$(jq -r --arg n "$2" 'select(.name == $n) | .private | tostring' <<< "$1" 2>/dev/null | tr -d '\r' | head -n1)"
  if [[ "$v" == "true" ]]; then echo 0; else echo 1; fi
}

# exit_for <decision-rc> <mode> <strict:0|1>: the job exit code for a
# capability decision. A reach failure (1) always fails. A missing
# permission (4) fails in apply mode when strict=1 (weekly jobs), and is a
# loud warning (exit 0) otherwise, so a 15/30-minute schedule does not send
# a failure mail every tick while the permission is pending.
exit_for() {
  local rc="$1" mode="$2" strict="$3"
  case "$rc" in
    0) echo 0 ;;
    4) if [[ "$mode" == "apply" && "$strict" == "1" ]]; then echo 1; else echo 0; fi ;;
    *) echo 1 ;;
  esac
}

# hyg_capability <org> <min_repos> <sentinels> <probe>...: list the org's
# repos with $GH_TOKEN and decide whether this job may run. <probe> is
# "<permission>=<REST path>" (a GET probe) or "<permission>=<METHOD>:<REST
# path>" (a write probe on a resource that cannot exist, judged by
# probe_write_state), with {repo} and {def} replaced by each sentinel and
# its default branch. Sets REPOS_JSON (one JSON object per repo),
# SEEN_PRIVATE, REDACT (host = $HOST_REPO) and CAP_MSG; returns the
# capability_decision code (0 ok, 1 cannot reach / inconclusive, 4 blocked).
# Never prints a non-sentinel repo name. Call it with set -e OFF.
hyg_capability() {
  local org="$1" min="$2" sentinels="$3" s def spec perm path out rc missing=""
  shift 3
  local probes=()
  if [[ -z "${sentinels//[[:space:]]/}" ]]; then
    REPOS_JSON=""; SEEN_PRIVATE=0; REDACT=1
    CAP_MSG="FAIL: no sentinel repo configured (secret SWEEPER_SENTINEL_REPOS is empty). Without a private sentinel this guard cannot fire. Refusing to report a clean run."
    return 1
  fi
  if ! REPOS_JSON="$(gh api "orgs/$org/repos?per_page=100&type=all" --paginate \
      --jq '.[] | {name, archived, fork, private, mirror: (.mirror_url != null), default_branch}' 2>/dev/null | tr -d '\r')"; then
    REPOS_JSON=""; SEEN_PRIVATE=0; REDACT=1
    CAP_MSG="FAIL: could not list $org repos with this token. Refusing to report a clean run."
    return 1
  fi
  REDACT="$(host_redact "$REPOS_JSON" "${HOST_REPO#*/}")"
  SEEN_PRIVATE="$(jq -s '[.[] | select(.private == true and .archived == false)] | length' <<< "$REPOS_JSON" 2>/dev/null | tr -d '\r')"
  for s in $sentinels; do
    def="$(jq -r --arg n "$s" 'select(.name == $n and .private == true) | .default_branch' <<< "$REPOS_JSON" 2>/dev/null | tr -d '\r' | head -n1)"
    if [[ -z "$def" ]]; then missing+="$s "; continue; fi
    for spec in "$@"; do
      perm="${spec%%=*}"; path="${spec#*=}"
      path="${path//\{repo\}/$s}"; path="${path//\{def\}/$def}"
      case "$path" in
        POST:*|PUT:*|PATCH:*)
          out="$(gh api -X "${path%%:*}" "${path#*:}" 2>&1)"; rc=$?
          probes+=("$perm=$(probe_write_state "$rc" "$out")") ;;   # no repo name: logs are public
        *)
          out="$(gh api "$path" 2>&1)"; rc=$?
          probes+=("$perm=$(probe_state "$rc" "$out")") ;;
      esac
    done
  done
  CAP_MSG="$(capability_decision "$SEEN_PRIVATE" "$min" "$missing" "${probes[@]}")"
}
