#!/usr/bin/env bash
# Offline end-to-end test of scripts/stale_branch_sweeper.sh against a stub
# `gh` (tests/fixtures/gh_stub.sh) serving tests/fixtures/sweeper/*.json.
# Proves: the squash-merged path selects only tip == merged-head branches in
# the same repo; report mode never writes; a public host never prints a
# private repo name, branch, PR title; the capability guard fails / blocks.
# Run: bash tests/test_sweeper_offline.sh   (exit 1 on any failure)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$HERE/../scripts/stale_branch_sweeper.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cp "$HERE/fixtures/gh_stub.sh" "$T/bin/gh"; chmod +x "$T/bin/gh"

run() { # run <fixtures-dir> <out> <env...>
  local fx="$1" out="$2"; shift 2
  mkdir -p "$out"
  ( export PATH="$T/bin:$PATH" GH_TOKEN=stub GH_FIXTURES="$fx" GH_STUB_LOG="$out/gh.log" \
      OUT_DIR="$out" HOST_REPO="Perditio-Labs/.github" SENTINEL_REPOS=zz-private-sentinel MIN_REPOS=2 MIN_AGE_HOURS=72 "$@"
    bash "$SW" > "$out/stdout" 2> "$out/stderr" ); echo $? > "$out/rc"
}

FX="$HERE/fixtures/sweeper"
O="$T/report"
run "$FX" "$O" MODE=report
rc="$(cat "$O/rc")"
[[ "$rc" == 0 ]] && ok "report run exits 0" || { bad "report run rc=$rc"; cat "$O/stderr"; }
S="$O/summary.md"
grep -q '| .github | dev-feat/public-old | dddddddd | cmp |' "$S" && ok "public 0-ahead branch listed (cmp)" || bad "public-old missing"
grep -q '| .github | dev-feat/public-squash | eeeeeeee | squash |' "$S" && ok "public squash-merged branch listed (squash)" || bad "public-squash missing"
grep -q 'public-other-base' "$S" && bad "merged PR into ANOTHER repo counted as squash" || ok "merged PR into another repo -> kept"
grep -q 'public-pushed-after' "$S" && bad "branch pushed after its squash merge counted" || ok "tip != merged head -> kept"
grep -q 'public-recent' "$S" && bad "recent branch listed" || ok "recent branch kept"
grep -q '| of which via the squash-merged path | 2 |' "$S" && ok "squash count = 2 (1 public + 1 private)" || bad "squash count wrong: $(grep squash-merged "$S")"
grep -q 'Private-repo branch rows (not named): 2' "$S" && ok "private rows counted (2)" || bad "private row count wrong"
grep -q 'Private-repo stale PRs (not named): 1' "$S" && ok "private stale PR counted (1)" || bad "private stale PR count wrong"
grep -q 'WRITE' "$O/gh.log" && bad "report mode wrote to GitHub" || ok "report mode made no writes"
leak="$(cat "$O/summary.md" "$O/stdout" "$O/stderr" "$O"/*.txt | grep -E 'zz-secret|secret-squashed|secret-zero|secret-open|Secret title|zz-archived' || true)"
[[ -z "$leak" ]] && ok "no private repo/branch/title in summary, stdout, stderr" || bad "private info leaked: $leak"
grep -q 'zz-archived-secret' "$O/gh.log" && bad "archived repo was read" || ok "archived repo skipped"

echo "== private host: full detail allowed =="
O="$T/private-host"
run "$FX" "$O" MODE=report HOST_REPO=Perditio-Labs/zz-private-sentinel
grep -q '| zz-secret-repo | dev-feat/secret-squashed | 66666666 | squash |' "$O/summary.md" && ok "private host names private rows" || bad "private host redacted"

echo "== capability guard =="
O="$T/reach"
run "$FX" "$O" MODE=report MIN_REPOS=30
[[ "$(cat "$O/rc")" == 1 ]] && grep -q 'cannot reach the org' "$O/stderr" && ok "too few private repos -> exit 1 (cannot fire)" || bad "reach guard rc=$(cat "$O/rc")"
grep -q 'WRITE' "$O/gh.log" && bad "reach failure wrote" || ok "reach failure made no writes"

FXD="$T/fx-denied"; cp -r "$FX" "$FXD"
echo 'ERROR gh: Resource not accessible by integration (HTTP 403)' > "$FXD/rest-repos_Perditio-Labs_zz-private-sentinel_pulls.json"
O="$T/denied-report"
run "$FXD" "$O" MODE=report
[[ "$(cat "$O/rc")" == 0 ]] && grep -q 'BLOCKED' "$O/summary.md" && ok "PR read denied, report -> exit 0 + BLOCKED summary" || bad "denied report rc=$(cat "$O/rc")"
O="$T/denied-apply"
run "$FXD" "$O" MODE=apply
[[ "$(cat "$O/rc")" == 1 ]] && grep -q 'BLOCKED' "$O/summary.md" && ok "PR read denied, apply -> exit 1 + BLOCKED" || bad "denied apply rc=$(cat "$O/rc")"
grep -q 'WRITE' "$O/gh.log" && bad "blocked apply wrote" || ok "blocked apply made no writes"
grep -q 'graphql' "$O/gh.log" && bad "blocked run kept reading repos" || ok "blocked run stopped before phase 1"

O="$T/no-sentinel"
run "$FX" "$O" MODE=report SENTINEL_REPOS=
[[ "$(cat "$O/rc")" == 1 ]] && grep -q 'no sentinel repo configured' "$O/summary.md" && ! grep -q 'graphql' "$O/gh.log" && ok "sentinel secret empty -> exit 1 before reading any repo (no default sentinel)" || bad "no sentinel rc=$(cat "$O/rc")"
for ws in $'\t' $'\n' $' \t\n '; do
  O="$T/ws-sentinel"; rm -rf "$O"
  run "$FX" "$O" MODE=apply SENTINEL_REPOS="$ws"
  [[ "$(cat "$O/rc")" == 1 ]] && grep -q 'NOT RUN' "$O/summary.md" && ! grep -q '^WRITE ' "$O/gh.log" && ok "whitespace-only sentinel -> exit 1, NOT RUN, no writes" || bad "whitespace sentinel rc=$(cat "$O/rc")"
done
grep -qE 'SENTINEL_REPOS:-[a-z]' "$SW" && bad "the sweeper has a default sentinel name" || ok "no default sentinel name in the public sweeper source"

echo "== privacy on the failure paths (sentinels are private) =="
for d in reach denied-report denied-apply; do
  leak="$(cat "$T/$d/summary.md" "$T/$d/stdout" "$T/$d/stderr" "$T/$d/capability.txt" 2>/dev/null | grep -E 'zz-private-sentinel|zz-secret' || true)"
  [[ -z "$leak" ]] && ok "$d: no private repo name in output" || bad "$d leaked: $leak"
done

echo "== apply: archive-tag then leased delete, re-read before acting =="
# git stub: records pushes in the gh log; init just makes the directory.
cat > "$T/bin/git" <<'GIT'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == push ]] && { echo "GITPUSH $*" >> "$GH_STUB_LOG"; exit "${GIT_STUB_PUSH_RC:-0}"; }; done
[[ " $* " == *" init "* ]] && { mkdir -p "${!#}"; exit 0; }
exit 0
GIT
chmod +x "$T/bin/git"
TODAY="$(date -u +%Y-%m-%d)"
one() { # one <file> <default> <tip> <a1> <a2> <merged-head-or-empty> <repo>
  local merged="[]"
  [[ -n "$6" ]] && merged="[{\"headRefOid\":\"$6\",\"baseRepository\":{\"nameWithOwner\":\"Perditio-Labs/$7\"}}]"
  printf '{"data":{"repository":{"defaultBranchRef":{"name":"%s"},"bases":{"totalCount":0},"ref":{"target":{"oid":"%s","committedDate":"2026-01-01T00:00:00Z"},"c1":{"behindBy":%s},"c2":{"behindBy":%s},"heads":{"totalCount":0},"merged":{"nodes":%s}}}}}\n' \
    "$2" "$3" "$4" "$5" "$merged" > "$1"
}
d40() { local s=""; for _ in $(seq 40); do s+="$1"; done; printf '%s' "$s"; }
FXA="$T/fx-apply"; cp -r "$FX" "$FXA"
one "$FXA/graphql-one-.github-dev-feat_public-old.json" main "$(d40 d)" 0 0 "" .github
one "$FXA/graphql-one-.github-dev-feat_public-squash.json" main "$(d40 e)" 3 3 "$(d40 e)" .github
one "$FXA/graphql-one-zz-secret-repo-dev-feat_secret-squashed.json" main "$(d40 6)" 2 2 "" zz-secret-repo
one "$FXA/graphql-one-zz-secret-repo-dev-feat_secret-zero-ahead.json" main "$(d40 9)" 0 4 "" zz-secret-repo
EMPTY='{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
for r in .github zz-secret-repo; do
  echo "$EMPTY" > "$FXA/graphql-recoverhead-$r.json"; echo "$EMPTY" > "$FXA/graphql-recoverbase-$r.json"
done
O="$T/apply"
run "$FXA" "$O" MODE=apply GH_STATE="$T/state-apply"
[[ "$(cat "$O/rc")" == 0 ]] && ok "apply exits 0" || { bad "apply rc=$(cat "$O/rc")"; cat "$O/stderr"; }
grep -q '| archived + deleted this run | 2 |' "$O/summary.md" && ok "2 branches archived + deleted" || bad "deleted count: $(grep 'archived + deleted' "$O/summary.md")"
for pair in "dev-feat/public-old:$(d40 d)" "dev-feat/public-squash:$(d40 e)"; do
  br="${pair%%:*}"; tip="${pair#*:}"
  tl="$(grep -n "WRITE POST repos/Perditio-Labs/.github/git/refs ref=refs/tags/archive/$TODAY/$br sha=$tip" "$O/gh.log" | head -1 | cut -d: -f1)"
  pl="$(grep -n -- "--force-with-lease=refs/heads/$br:$tip" "$O/gh.log" | head -1 | cut -d: -f1)"
  [[ -n "$tl" && -n "$pl" && "$tl" -lt "$pl" ]] && ok "$br: tag at the tip, then leased delete on that tip" || bad "$br: tag line '$tl' push line '$pl'"
done
grep -E 'WRITE|GITPUSH' "$O/gh.log" | grep -qE 'secret-squashed|secret-zero-ahead' && bad "changed private branch was touched" || ok "squash proof gone / tip moved on re-read -> kept, untouched"
leak="$(cat "$O/summary.md" "$O/stdout" "$O/stderr" | grep -E 'zz-secret|secret-' || true)"
[[ -z "$leak" ]] && ok "apply output names no private repo or branch" || bad "apply leaked: $leak"

FXC="$T/fx-conflict"; cp -r "$FXA" "$FXC"
echo '{"object":{"type":"commit","sha":"ffffffffffffffffffffffffffffffffffffffff"}}' \
  > "$FXC/rest-repos_Perditio-Labs_.github_git_ref_tags_archive_${TODAY}_dev-feat_public-old.json"
O="$T/conflict"
run "$FXC" "$O" MODE=apply GH_STATE="$T/state-conflict"
grep -q -- '--force-with-lease=refs/heads/dev-feat/public-old:' "$O/gh.log" && bad "deleted despite a conflicting archive tag" || ok "archive tag at another sha -> never moved, branch kept"
[[ "$(cat "$O/rc")" == 1 ]] && ok "conflict is reported as an error (exit 1)" || bad "conflict rc=$(cat "$O/rc")"

O="$T/lease-refused"
run "$FXA" "$O" MODE=apply GH_STATE="$T/state-lease" GIT_STUB_PUSH_RC=1
grep -q '| archived + deleted this run | 0 |' "$O/summary.md" && [[ "$(cat "$O/rc")" == 1 ]] && ok "lease refused -> nothing counted deleted, exit 1" || bad "lease refused rc=$(cat "$O/rc")"

echo
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
