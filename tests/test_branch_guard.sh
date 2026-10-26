#!/usr/bin/env bash
# Tests for scripts/branch_guard.sh (the sweeper's only deletion rule).
# Ported from PTR-Labs/.github; adds the squash-merged path.
# Run: bash tests/test_branch_guard.sh   (exit 1 on any failure)
# Runs in the stale-branch-sweeper workflow BEFORE every sweep.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/branch_guard.sh
. "$HERE/../scripts/branch_guard.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

TIP=0123456789abcdef0123456789abcdef01234567
OLD=2026-01-01T00:00:00Z
NEW=2026-10-22T12:00:00Z
CUT=2026-10-19T12:00:00Z

elig() { merged_orphan_eligible "$@" 2>/dev/null; }

echo "== permanent / default branches are NEVER eligible, even 0 ahead with no PR =="
for b in main master staging dev release release-v1.2.3 release-anything release/v1.2.3 release/payments-v1.0.0 release2026 release_candidate releases trunk - ""; do
  if elig "$b" trunk "$TIP" "$OLD" 0 0 0 0 "$CUT" >/dev/null; then bad "'$b' was eligible"; else ok "'$b' not eligible"; fi
done

echo "== the staging -> release incident shape (merged promotion head) =="
if elig staging dev "$TIP" "$OLD" 0 0 0 0 "$CUT" >/dev/null; then bad "merged staging eligible"; else ok "merged staging protected"; fi

echo "== assert_deletable aborts the run on every protected name =="
for b in main master staging dev release release-v9.9.9 release/v9.9.9 release2026 release_candidate trunk; do
  ( assert_deletable "$b" trunk >/dev/null 2>&1 ); rc=$?
  if [[ $rc -eq 3 ]]; then ok "assert_deletable '$b' -> exit 3"; else bad "assert_deletable '$b' -> rc=$rc"; fi
done
( assert_deletable dev-feat/x trunk >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && ok "assert_deletable dev-feat/x -> allowed" || bad "assert_deletable dev-feat/x -> rc=$rc"

echo "== work branches =="
w="$(elig dev-feat/x main "$TIP" "$OLD" 0 5 0 0 "$CUT")" && [[ "$w" == cmp ]] && ok "merged into dev -> cmp" || bad "merged into dev"
w="$(elig fix/hot main "$TIP" "$OLD" 3 0 0 0 "$CUT")" && [[ "$w" == def ]] && ok "merged into default only -> def" || bad "merged into default only"
elig dev-feat/x main "$TIP" "$OLD" 1 1 0 0 "$CUT" >/dev/null && bad "ahead of both eligible" || ok "ahead of both -> kept"
elig dev-feat/x main "$TIP" "$OLD" 0 0 1 0 "$CUT" >/dev/null && bad "open PR head (any repo) eligible" || ok "open PR head -> kept"
elig dev-feat/x main "$TIP" "$OLD" 0 0 0 1 "$CUT" >/dev/null && bad "open PR head/base in repo eligible" || ok "open PR head/base in repo -> kept"
elig dev-feat/x main "$TIP" "$NEW" 0 0 0 0 "$CUT" >/dev/null && bad "recent tip eligible" || ok "tip newer than cutoff -> kept"
elig dev-feat/x main "notasha" "$OLD" 0 0 0 0 "$CUT" >/dev/null && bad "bad sha eligible" || ok "bad sha -> kept"
elig dev-feat/x main "$TIP" "-" 0 0 0 0 "$CUT" >/dev/null && bad "missing date eligible" || ok "missing date -> kept"
elig dev-feat/x main "$TIP" "$OLD" 0 0 "-" 0 "$CUT" >/dev/null && bad "unknown PR count eligible" || ok "unknown PR count -> kept"
elig dev-feat/x main "$TIP" "$OLD" x x 0 0 "$CUT" >/dev/null && bad "no comparison eligible" || ok "no comparison -> kept"

echo "== squash-merged path (merged PR head sha == branch tip) =="
w="$(elig dev-feat/sq main "$TIP" "$OLD" 2 2 0 0 "$CUT" 1)" && [[ "$w" == squash ]] && ok "squash-merged, tip == merged head -> squash" || bad "squash-merged not eligible"
elig dev-feat/sq main "$TIP" "$OLD" 2 2 0 0 "$CUT" 0 >/dev/null && bad "ahead, no merged PR at tip eligible" || ok "ahead, no merged PR at tip -> kept"
elig dev-feat/sq main "$TIP" "$OLD" 2 2 0 0 "$CUT" - >/dev/null && bad "unknown merged-PR list eligible" || ok "unknown merged-PR list -> kept"
elig dev-feat/sq main "$TIP" "$OLD" 2 2 0 0 "$CUT" >/dev/null && bad "no squash arg eligible" || ok "squash arg absent -> kept (default 0)"
elig dev-feat/sq main "$TIP" "$OLD" 2 2 1 0 "$CUT" 1 >/dev/null && bad "squash with open PR head eligible" || ok "squash but open PR head -> kept"
elig dev-feat/sq main "$TIP" "$OLD" 2 2 0 1 "$CUT" 1 >/dev/null && bad "squash with open PR base eligible" || ok "squash but open PR head/base in repo -> kept"
elig dev-feat/sq main "$TIP" "$NEW" 2 2 0 0 "$CUT" 1 >/dev/null && bad "squash with recent tip eligible" || ok "squash but tip newer than cutoff -> kept"
for b in main master staging dev release release-v1 release/v1 trunk; do
  if elig "$b" trunk "$TIP" "$OLD" 2 2 0 0 "$CUT" 1 >/dev/null; then bad "squash path: '$b' eligible"; else ok "squash path: '$b' protected"; fi
done
elig dev-feat/sq main "$TIP" "$OLD" 2 2 0 "-" "$CUT" 1 >/dev/null && bad "unknown kept flag eligible" || ok "unknown kept flag -> kept"
elig dev-feat/sq main "$TIP" "$OLD" 0 0 0 0 "garbage" 1 >/dev/null && bad "bad cutoff eligible" || ok "bad cutoff -> kept"

echo "== production lease_delete (extracted from the sweeper) aborts before git runs =="
# The exact lease_delete function text from the sweeper is evaluated with a
# stub git that records any call: a protected branch must exit 3 and never
# reach git; a work branch must reach git.
SWP="$HERE/../scripts/stale_branch_sweeper.sh"
LD="$(sed -n '/^lease_delete() {/,/^}/p' "$SWP")"
if [[ -z "$LD" ]]; then
  bad "could not extract lease_delete from the sweeper"
else
  STUB="$(mktemp -d)"
  for b in main staging dev release release-v1.2.3 release/v1.2.3 release2026 release_candidate trunk; do
    : > "$STUB/git.log"
    ( git() { echo "git $*" >> "$STUB/git.log"; return 0; }
      GH_TOKEN=x WORKDIR="$STUB"; eval "$LD"
      lease_delete Perditio-Labs/x "$b" "$TIP" trunk ) >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 3 && ! -s "$STUB/git.log" ]]; then ok "lease_delete '$b' -> exit 3, git never called"
    else bad "lease_delete '$b' -> rc=$rc, git calls: $(wc -l < "$STUB/git.log")"; fi
  done
  : > "$STUB/git.log"
  ( git() { echo "git $*" >> "$STUB/git.log"; return 0; }
    GH_TOKEN=x WORKDIR="$STUB"; eval "$LD"
    lease_delete Perditio-Labs/x dev-feat/x "$TIP" trunk ) >/dev/null 2>&1; rc=$?
  if [[ $rc -eq 0 ]] && grep -q -- "--force-with-lease=refs/heads/dev-feat/x:$TIP" "$STUB/git.log"; then
    ok "lease_delete dev-feat/x -> leased push on the inspected tip"
  else bad "lease_delete dev-feat/x -> rc=$rc log=$(cat "$STUB/git.log")"; fi
  rm -rf "$STUB"
fi

echo "== the sweeper really uses these functions =="
SW="$HERE/../scripts/stale_branch_sweeper.sh"
grep -q 'branch_guard.sh' "$SW" && ok "sweeper sources branch_guard.sh" || bad "sweeper does not source branch_guard.sh"
grep -q 'merged_orphan_eligible .*"\$sq"' "$SW" && ok "sweeper passes the squash flag to merged_orphan_eligible" || bad "sweeper does not pass the squash flag"
grep -q 'merged_orphan_eligible' "$SW" && ok "sweeper decides via merged_orphan_eligible" || bad "no merged_orphan_eligible call"
n_assert="$(grep -c 'assert_deletable' "$SW")"
[[ "$n_assert" -ge 3 ]] && ok "assert_deletable called $n_assert times (phase 2 entry, before push, inside lease_delete)" || bad "assert_deletable only $n_assert call(s)"

echo
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
