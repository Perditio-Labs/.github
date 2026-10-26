#!/usr/bin/env bash
# branch_guard.sh - the ONE definition of which branches the stale-branch
# sweeper may ever delete. Sourced by scripts/stale_branch_sweeper.sh and by
# tests/test_branch_guard.sh (so the test exercises the production code).
#
# Ported from PTR-Labs/.github (same rules). Background: a merged promotion
# branch (e.g. staging after a staging -> release PR) is "0 ahead" of its
# target and not an open-PR head, exactly like a merged work branch. These
# functions make a permanent name undeletable by construction, independent of
# any comparison.

# is_protected_branch <branch> <default-branch>: 0 if the branch must never
# be deleted. Pure string test.
is_protected_branch() {
  local b="$1" def="${2:-}"
  case "$b" in
    main|master|staging|dev|release*) return 0 ;;   # release* covers release, release-x, release/x, release2026, release_x
  esac
  [[ -n "$def" && "$b" == "$def" ]] && return 0
  [[ -z "$b" || "$b" == "-" ]] && return 0   # unknown name: protect
  return 1
}

# merged_orphan_eligible <branch> <default> <tip> <when> <a1> <a2> <heads> <kept> <age_cutoff> [<sq>]
#   Phase-1 decision. Prints how the branch was found merged and returns 0
#   only when the branch is deletable:
#     cmp    0 commits ahead of dev (or of the default branch when no dev)
#     def    0 commits ahead of the default branch (a merged hotfix)
#     squash ahead of both, but a MERGED PR into this repo has head sha ==
#            this tip (squash/rebase merge; nothing was pushed after merge)
#   <kept> = 1 when an open PR into this repo uses the branch as head or base.
#   <heads> = open PRs anywhere with this branch as head (must be 0).
#   <sq> = 1 when such a merged PR exists, 0 when not, anything else unknown.
merged_orphan_eligible() {
  local br="$1" def="$2" tip="$3" when="$4" a1="$5" a2="$6" heads="$7" kept="$8" cutoff="$9" sq="${10:-0}"
  is_protected_branch "$br" "$def" && return 1
  [[ "$kept" == "1" ]] && return 1
  [[ "$kept" == "0" ]] || return 1
  [[ "$tip" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$when" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [[ "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [[ "$heads" =~ ^[0-9]+$ && "$heads" == "0" ]] || return 1
  [[ "$when" < "$cutoff" ]] || return 1
  if [[ "$a1" == "0" ]]; then echo cmp; return 0; fi
  if [[ "$a2" == "0" ]]; then echo def; return 0; fi
  if [[ "$sq" == "1" ]]; then echo squash; return 0; fi
  return 1
}

# assert_deletable <branch> <default>: HARD STOP. Called immediately before
# every tag/delete. A protected name here means a logic error upstream, so
# the whole run aborts (exit 3) instead of continuing.
assert_deletable() {
  if is_protected_branch "$1" "${2:-}"; then
    echo "FATAL: refusing to delete a protected branch (default '${2:-?}'). Aborting the run." >&2
    exit 3
  fi
}
