#!/usr/bin/env bash
# Tests for scripts/merge_when_green.sh: the decision rule, the check
# classifier and the merge-method choice (unit), plus an offline end-to-end
# run against the stub gh (tests/fixtures/gh_stub.sh).
# Run: bash tests/test_merge_when_green.sh   (exit 1 on any failure)
set -uo pipefail
TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTDIR/../scripts/merge_when_green.sh"
# shellcheck source=scripts/merge_when_green.sh
. "$SCRIPT"
set +e

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
dec() { merge_decision "$@"; }
#                 state draft base has_label wf total pend failed quiet ms upd
GOOD=(open false dev 1 0 3 0 0 900 clean 0)
with() { # with <index> <value>: GOOD with one field replaced
  local a=("${GOOD[@]}"); a[$1]="$2"; dec "${a[@]}"
}

echo "== merge_decision =="
[[ "$(dec "${GOOD[@]}")" == MERGE ]] && ok "open, dev, labelled, green, quiet, clean -> MERGE" || bad "good PR not merged"
for b in main master staging release release-1.2 release/1.2 Dev develop feature; do
  [[ "$(with 2 "$b")" == "SKIP base-not-dev" ]] && ok "base '$b' -> never merged" || bad "base '$b' merged"
done
[[ "$(with 0 closed)" == "SKIP not-open" ]] && ok "closed -> skip" || bad "closed"
[[ "$(with 1 true)" == "SKIP draft" ]] && ok "draft -> skip" || bad "draft"
[[ "$(with 1 "")" == "SKIP draft" ]] && ok "unknown draft flag -> skip" || bad "unknown draft"
[[ "$(with 3 0)" == "SKIP no-automerge-label" ]] && ok "no label -> skip" || bad "no label"
[[ "$(with 4 1)" == SKIP* ]] && ok "touches .github/workflows -> skip" || bad "workflows"
[[ "$(with 4 x)" == SKIP* ]] && ok "file list unreadable -> skip" || bad "files unknown"
[[ "$(with 5 0)" == "SKIP no-checks" ]] && ok "zero checks -> skip (>= 1 required)" || bad "zero checks"
[[ "$(with 6 1)" == "SKIP checks-pending" ]] && ok "pending check -> skip" || bad "pending"
[[ "$(with 7 1)" == "SKIP checks-failed" ]] && ok "failed check -> skip" || bad "failed"
[[ "$(with 5 -)" == "SKIP checks-unreadable" ]] && ok "unreadable checks -> skip" || bad "checks unreadable"
[[ "$(with 8 599)" == "SKIP head-not-quiet" ]] && ok "head changed 599 s ago -> skip" || bad "not quiet"
[[ "$(with 8 600)" == MERGE ]] && ok "quiet exactly 600 s -> merge" || bad "600 s"
[[ "$(with 8 x)" == "SKIP quiet-unreadable" ]] && ok "quiet unreadable -> skip" || bad "quiet x"
[[ "$(with 9 behind)" == UPDATE ]] && ok "behind, never updated -> UPDATE" || bad "behind -> update"
a=("${GOOD[@]}"); a[9]=behind; a[10]=1
[[ "$(dec "${a[@]}")" == "SKIP behind-already-updated-once" ]] && ok "behind, already updated once -> skip" || bad "update twice"
a[10]=x
[[ "$(dec "${a[@]}")" == SKIP* ]] && ok "behind, update history unreadable -> skip" || bad "update history unknown"
for m in blocked dirty unstable has_hooks draft; do
  [[ "$(with 9 "$m")" == "SKIP not-clean ($m)" ]] && ok "mergeable_state $m -> skip" || bad "state $m"
done
[[ "$(with 9 unknown)" == "SKIP mergeability-not-computed" ]] && ok "mergeability unknown -> skip" || bad "unknown"
[[ "$(with 9 "")" == "SKIP mergeability-not-computed" ]] && ok "mergeability empty -> skip" || bad "empty ms"

echo "== classify_checks =="
cr() { local d="${3:-2026-10-26T00:00:00Z}"; printf '{"status":"%s","conclusion":%s,"started_at":"%s","completed_at":"%s"}' "$1" "$( [[ "$2" == null ]] && echo null || echo "\"$2\"")" "$d" "$d"; }
stt() { local d="${2:-2026-10-26T00:00:00Z}"; printf '{"state":"%s","created_at":"%s","updated_at":"%s"}' "$1" "$d" "$d"; }
c() { classify_checks "$1" "$2"; }
[[ "$(c "[$(cr completed success),$(cr completed neutral),$(cr completed skipped)]" "[]")" == $'3\t0\t0\t2026-10-26T00:00:00Z' ]] && ok "success/neutral/skipped -> green" || bad "green set: $(c "[$(cr completed success)]" "[]")"
[[ "$(c "[$(cr in_progress null)]" "[]" | cut -f2)" == 1 ]] && ok "in_progress -> pending" || bad "in_progress"
[[ "$(c "[$(cr queued null)]" "[]" | cut -f2)" == 1 ]] && ok "queued -> pending" || bad "queued"
for k in failure cancelled timed_out action_required stale startup_failure; do
  [[ "$(c "[$(cr completed "$k")]" "[]" | cut -f3)" == 1 ]] && ok "conclusion $k -> failed" || bad "conclusion $k"
done
[[ "$(c "[]" "[$(stt success)]")" == $'1\t0\t0\t2026-10-26T00:00:00Z' ]] && ok "status success counts as a green check" || bad "status success"
[[ "$(c "[]" "[$(stt pending)]" | cut -f2)" == 1 ]] && ok "status pending -> pending" || bad "status pending"
[[ "$(c "[]" "[$(stt failure),$(stt error)]" | cut -f3)" == 2 ]] && ok "status failure/error -> failed" || bad "status failed"
[[ "$(c "[]" "[]")" == $'0\t0\t0\t-' ]] && ok "nothing -> total 0" || bad "empty"
[[ "$(c "[$(cr completed success 2026-10-26T05:00:00Z),$(cr completed success 2026-10-26T04:00:00Z)]" "[]" | cut -f4)" == 2026-10-26T05:00:00Z ]] && ok "last activity = latest start" || bad "last activity (start)"
[[ "$(c '[{"status":"completed","conclusion":"success","started_at":"2026-10-26T01:00:00Z","completed_at":"2026-10-26T06:00:00Z"}]' "[]" | cut -f4)" == 2026-10-26T06:00:00Z ]] && ok "last activity counts completed_at (a re-run finishing late)" || bad "last activity (completed)"
[[ "$(c "[$(cr completed success 2026-10-26T01:00:00Z)]" '[{"state":"success","created_at":"2026-10-26T02:00:00Z","updated_at":"2026-10-26T07:00:00Z"}]' | cut -f4)" == 2026-10-26T07:00:00Z ]] && ok "last activity counts a status update" || bad "last activity (status)"
[[ "$(c '[{"status":"completed","conclusion":"success","started_at":null,"completed_at":null}]' "[]" | cut -f4)" == x ]] && ok "check run with null dates -> clock unreadable (x)" || bad "null dates"
[[ "$(c '[{"status":"completed","conclusion":"success","started_at":"0000-invalid","completed_at":"2026-10-26T06:00:00Z"}]' "[]" | cut -f4)" == x ]] && ok "malformed date beside a valid one -> x" || bad "malformed date"
[[ "$(c '[{"status":"completed","conclusion":"success","started_at":"2026-02-30T00:00:00Z","completed_at":"2026-10-25T00:00:00Z"}]' "[]" | cut -f4)" == x ]] && ok "impossible date (Feb 30) beside a valid one -> x" || bad "Feb 30 accepted"
[[ -z "$(iso_epoch 2026-02-30T00:00:00Z)" && -n "$(iso_epoch 2026-10-25T00:00:00Z)" ]] && ok "iso_epoch rejects Feb 30, accepts a real date" || bad "iso_epoch calendar"
[[ "$(c "[]" '[{"state":"success","created_at":"2026-10-26T02:00:00Z"}]' | cut -f4)" == x ]] && ok "status without updated_at -> x" || bad "status missing updated_at"
[[ "$(c '[{"status":"in_progress","conclusion":null,"started_at":"2026-10-26T02:00:00Z","completed_at":null}]' "[]" | cut -f4)" == 2026-10-26T02:00:00Z ]] && ok "running check needs no completed_at" || bad "running check"
c bad "[]" >/dev/null 2>&1 && bad "bad check json accepted" || ok "unreadable check runs -> error"
c "[]" bad >/dev/null 2>&1 && bad "bad status json accepted" || ok "unreadable statuses -> error"

echo "== eligibility: automerge label or Dependabot minor/patch group =="
el() { is_eligible "$(jq -nc --arg t "$1" --arg u "$2" --argjson l "${3:-[]}" '{title: $t, user: {login: $u}, labels: $l}')"; }
DB='dependabot[bot]'
[[ "$(el 'chore(deps): bump the npm-minor-patch group with 2 updates' "$DB")" == true ]] && ok "dependabot grouped minor/patch -> eligible without a label" || bad "grouped"
[[ "$(el 'Bump the pip-minor-patch group across 1 directory with 5 updates' "$DB")" == true ]] && ok "capitalised, across-directory form -> eligible" || bad "across form"
[[ "$(el 'chore(deps-dev): bump tsx from 4.22.4 to 4.23.15 in the npm-minor-patch group' "$DB")" == true ]] && ok "single dependency in the group, same major -> eligible" || bad "single same major"
[[ "$(el 'chore(deps): bump nginx from 1.27-alpine to 1.31-alpine in the docker-minor-patch group' "$DB")" == true ]] && ok "docker tag, same major -> eligible" || bad "docker"
[[ "$(el 'chore(deps): bump react from 18.3.1 to 19.0.0 in the npm-minor-patch group' "$DB")" == false ]] && ok "major bump (18 -> 19) -> never eligible" || bad "major eligible"
[[ "$(el 'chore(deps): bump actions/checkout from v4 to v5 in the actions-minor-patch group' "$DB")" == false ]] && ok "major bump v4 -> v5 -> never eligible" || bad "v-major eligible"
[[ "$(el 'chore(deps): bump react from ^18.3.1 to ^19.0.0 in the npm-minor-patch group' "$DB")" == false ]] && ok "caret-prefixed major bump -> never eligible" || bad "caret major eligible"
[[ "$(el 'chore(deps): bump react from ~18.3.1 to ~18.4.0 in the npm-minor-patch group' "$DB")" == true ]] && ok "tilde-prefixed minor bump -> eligible" || bad "tilde minor"
[[ "$(el 'chore(deps): bump foo from latest to edge in the npm-minor-patch group' "$DB")" == false ]] && ok "unparseable from/to versions -> not eligible" || bad "unparseable versions eligible"
[[ "$(el 'chore(deps): bump the npm-major group with 2 updates' "$DB")" == false ]] && ok "a non minor-patch group -> not eligible" || bad "major group"
[[ "$(el 'chore(deps): bump lodash from 4.17.20 to 4.17.21' "$DB")" == false ]] && ok "ungrouped dependabot PR -> not eligible" || bad "ungrouped"
[[ "$(el 'chore(deps): bump the npm-minor-patch group with 2 updates' someone)" == false ]] && ok "same title by a human -> not eligible" || bad "human title"
[[ "$(el 'anything' someone '[{"name":"AutoMerge"}]')" == true ]] && ok "automerge label (any case) -> eligible" || bad "label"
[[ "$(el 'anything' someone '[{"name":"hold,automerge"}]')" == false ]] && ok "label merely containing automerge -> not eligible" || bad "comma label"

echo "== choose_merge_method =="
[[ "$(choose_merge_method true true true)" == merge ]] && ok "all allowed -> merge commit" || bad "all"
[[ "$(choose_merge_method false true true)" == squash ]] && ok "no merge commit -> squash" || bad "squash"
[[ "$(choose_merge_method false false true)" == rebase ]] && ok "rebase only -> rebase" || bad "rebase"
[[ -z "$(choose_merge_method false false false)" ]] && ok "none -> empty (error)" || bad "none"
[[ -z "$(choose_merge_method)" ]] && ok "unreadable -> empty (error)" || bad "unreadable"

echo "== offline end to end (stub gh) =="
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fx"
cp "$TESTDIR/fixtures/gh_stub.sh" "$T/bin/gh"; chmod +x "$T/bin/gh"
FX="$T/fx"
O_ISO="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
N_ISO="$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$FX/rest-orgs_Perditio-Labs_repos.json" <<JSON
[{"name":".github","archived":false,"fork":false,"private":false,"mirror_url":null,"default_branch":"main"},
 {"name":"zz-private-sentinel","archived":false,"fork":false,"private":true,"mirror_url":null,"default_branch":"main"},
 {"name":"zz-secret-repo","archived":false,"fork":false,"private":true,"mirror_url":null,"default_branch":"main"},
 {"name":"zz-archived","archived":true,"fork":false,"private":true,"mirror_url":null,"default_branch":"main"}]
JSON
echo '[]' > "$FX/rest-repos_Perditio-Labs_zz-private-sentinel_pulls.json"
echo '{"check_runs":[]}' > "$FX/rest-repos_Perditio-Labs_zz-private-sentinel_commits_main_check-runs.json"
echo '{"statuses":[]}' > "$FX/rest-repos_Perditio-Labs_zz-private-sentinel_commits_main_status.json"
for w in PUT-repos_Perditio-Labs_zz-private-sentinel_pulls_0_merge PUT-repos_Perditio-Labs_zz-private-sentinel_pulls_0_update-branch POST-repos_Perditio-Labs_zz-private-sentinel_issues_0_labels; do
  echo 'ERROR gh: Not Found (HTTP 404)' > "$FX/write-$w.json"
done
LIST_GH=""; LIST_ZZ=""
lbl() { # lbl <comma-separated label names> -> JSON label array
  local out="" IFS=';'
  for l in $1; do out+="{\"name\":\"$l\"},"; done
  printf '[%s]' "${out%,}"
}
sha_of() { printf '%040d' "$1"; }
# pr <repo> <num> <base> <mergeable_state> <check-conclusion> <check-start> <check-done> <commit-date> <suite-created> <files> <app-commit:0|1> <labels ;-separated> [<status-state>]
pr() {
  local repo="$1" n="$2" sha; sha="$(sha_of "$n")"
  local labels; labels="$(lbl "${12}")"
  local author="${14:-someone}" title="${15:-a change}"
  local item="{\"number\":$n,\"draft\":false,\"labels\":$labels,\"user\":{\"login\":\"$author\"},\"title\":\"$title\"}"
  if [[ "$repo" == ".github" ]]; then LIST_GH+="$item,"; else LIST_ZZ+="$item,"; fi
  printf '{"state":"open","draft":false,"base":{"ref":"%s"},"head":{"sha":"%s"},"labels":%s,"mergeable_state":"%s","user":{"login":"%s"},"title":"%s"}\n' "$3" "$sha" "$labels" "$4" "$author" "$title" > "$FX/rest-repos_Perditio-Labs_${repo}_pulls_$n.json"
  printf '{"check_runs":[{"status":"completed","conclusion":"%s","started_at":"%s","completed_at":"%s","output":{"text":"x"}}]}\n' "$5" "$6" "$7" > "$FX/rest-repos_Perditio-Labs_${repo}_commits_${sha}_check-runs.json"
  if [[ -n "${13:-}" ]]; then
    printf '{"statuses":[{"state":"%s","context":"ci/x","created_at":"%s","updated_at":"%s"}]}\n' "${13}" "$6" "$6" > "$FX/rest-repos_Perditio-Labs_${repo}_commits_${sha}_status.json"
  else
    echo '{"statuses":[]}' > "$FX/rest-repos_Perditio-Labs_${repo}_commits_${sha}_status.json"
  fi
  printf '{"commit":{"committer":{"date":"%s"}}}\n' "$8" > "$FX/rest-repos_Perditio-Labs_${repo}_commits_${sha}.json"
  printf '{"check_suites":[{"created_at":"%s"}]}\n' "$9" > "$FX/rest-repos_Perditio-Labs_${repo}_commits_${sha}_check-suites.json"
  printf '[{"filename":"%s"}]\n' "${10}" > "$FX/rest-repos_Perditio-Labs_${repo}_pulls_${n}_files.json"
  if [[ "${11}" == 1 ]]; then echo '[{"sha":"x","author":{"login":"perditio-ci-automation[bot]"}}]'; else echo '[{"sha":"y","author":{"login":"someone"}}]'; fi \
    > "$FX/rest-repos_Perditio-Labs_${repo}_pulls_${n}_commits.json"
}
O2="$O_ISO"
#  repo           n  base   ms      concl    start  done   commit  suite  files                       app labels
pr .github        1  dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "AutoMerge"
pr zz-secret-repo 9  dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/b.txt                   0   "automerge"
pr .github        2  main   clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge"
pr .github        3  dev    behind  success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge"
pr .github        4  dev    behind  success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   1   "automerge"
pr .github        5  dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  .github/workflows/ci.yml    0   "automerge"
pr .github        6  dev    clean   failure  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge"
pr .github        7  dev    clean   success  "$O2"  "$O2"  "$O2"   "$N_ISO" src/a.txt                 0   "automerge"
pr .github        8  dev    behind  success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge;automerge:branch-updated"
pr .github        10 dev    clean   success  "$O2"  "$N_ISO" "$O2" "$O2"  src/a.txt                   0   "automerge"
pr .github        11 dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "hold,automerge,review"
pr .github        12 dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge"  pending
pr .github        13 dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge"
pr .github        14 dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  package.json                0   ""  "" "dependabot[bot]" "chore(deps): bump the npm-minor-patch group with 3 updates"
pr .github        15 dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  package.json                0   ""  "" "dependabot[bot]" "chore(deps): bump react from 18.3.1 to 19.0.0 in the npm-minor-patch group"
pr .github        16 dev    clean   failure  "$O2"  "$O2"  "$O2"   "$O2"  package.json                0   ""  "" "dependabot[bot]" "chore(deps): bump the npm-minor-patch group with 2 updates"
pr .github        17 dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge"  success
echo '{"check_runs":[]}' > "$FX/rest-repos_Perditio-Labs_.github_commits_$(sha_of 17)_check-runs.json"
echo '{"check_suites":[]}' > "$FX/rest-repos_Perditio-Labs_.github_commits_$(sha_of 17)_check-suites.json"
pr .github        18 dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge"
echo '{"check_suites":[{"created_at":null}]}' > "$FX/rest-repos_Perditio-Labs_.github_commits_$(sha_of 18)_check-suites.json"
pr .github        19 dev    clean   success  "$O2"  "$O2"  "$O2"   "$O2"  src/a.txt                   0   "automerge"
jq -nc --arg d "$O2" '{check_suites: [range(1000) | {created_at: $d}]}' > "$FX/rest-repos_Perditio-Labs_.github_commits_$(sha_of 19)_check-suites.json"
printf '[%s]\n' "${LIST_GH%,}" > "$FX/rest-repos_Perditio-Labs_.github_pulls.json"
printf '[%s]\n' "${LIST_ZZ%,}" > "$FX/rest-repos_Perditio-Labs_zz-secret-repo_pulls.json"
# PR 11 must never be listed as a candidate: its only label is "hold,automerge,review".
# PR 13 is retargeted to main between discovery and the pre-write re-read.
sed 's/"ref":"dev"/"ref":"main"/' "$FX/rest-repos_Perditio-Labs_.github_pulls_13.json" > "$FX/rest-repos_Perditio-Labs_.github_pulls_13.json.after1"
echo '{"allow_merge_commit":false,"allow_squash_merge":true,"allow_rebase_merge":true}' > "$FX/rest-repos_Perditio-Labs_.github.json"
echo '{"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":false}' > "$FX/rest-repos_Perditio-Labs_zz-secret-repo.json"

e2e() { # e2e <fixtures> <out> <env...>
  local fx="$1" out="$2"; shift 2
  mkdir -p "$out"
  ( export PATH="$T/bin:$PATH" GH_TOKEN=stub GH_FIXTURES="$fx" GH_STUB_LOG="$out/gh.log" \
      OUT_DIR="$out" HOST_REPO="Perditio-Labs/.github" SENTINEL_REPOS=zz-private-sentinel MIN_REPOS=2 "$@"
    bash "$SCRIPT" > "$out/stdout" 2> "$out/stderr" ); echo $? > "$out/rc"
}
O="$T/report"; e2e "$FX" "$O" MODE=report
S="$O/summary.md"
[[ "$(cat "$O/rc")" == 0 ]] && ok "report exits 0" || { bad "report rc=$(cat "$O/rc")"; cat "$O/stderr"; }
grep -q '| .github | #1 | WOULD-MERGE |' "$S" && ok "green labelled dev PR -> WOULD-MERGE" || bad "PR 1: $(grep '#1 ' "$S")"
grep -q '| .github | #2 | SKIP base-not-dev |' "$S" && ok "base main -> skipped" || bad "PR 2"
grep -q '| .github | #3 | WOULD-UPDATE |' "$S" && ok "behind -> WOULD-UPDATE" || bad "PR 3"
grep -q '| .github | #4 | SKIP behind-already-updated-once |' "$S" && ok "behind after an App update commit -> skipped" || bad "PR 4"
grep -q '| .github | #5 | SKIP touches-workflows' "$S" && ok "workflow file -> skipped" || bad "PR 5"
grep -q '| .github | #6 | SKIP checks-failed |' "$S" && ok "red check -> skipped" || bad "PR 6"
grep -q '| .github | #7 | SKIP head-not-quiet |' "$S" && ok "old commit pushed 2 min ago (new check suite) -> not quiet" || bad "PR 7: $(grep '#7 ' "$S")"
grep -q '| .github | #8 | SKIP behind-already-updated-once |' "$S" && ok "behind with the update marker label (history rewritten) -> skipped" || bad "PR 8"
grep -q '| .github | #10 | SKIP head-not-quiet |' "$S" && ok "old check re-run finished 2 min ago -> not quiet" || bad "PR 10: $(grep '#10 ' "$S")"
grep -q '#11 ' "$S" && bad "label 'hold,automerge,review' treated as automerge" || ok "a label containing 'automerge' is not the automerge label"
grep -q '| .github | #12 | SKIP checks-pending |' "$S" && ok "pending commit status -> skipped" || bad "PR 12"
grep -q '| .github | #17 | SKIP quiet-unreadable |' "$S" && ok "statuses only, no check suite (push time unknown) -> fail closed" || bad "PR 17: $(grep '#17 ' "$S")"
grep -q '| .github | #19 | SKIP quiet-unreadable |' "$S" && ok "1000 check suites (check-run coverage not provable) -> fail closed" || bad "PR 19: $(grep '#19 ' "$S")"
grep -q '| .github | #18 | SKIP quiet-unreadable |' "$S" && ok "check suite with a null created_at -> fail closed" || bad "PR 18: $(grep '#18 ' "$S")"
grep -q '| .github | #14 | WOULD-MERGE |' "$S" && ok "unlabelled Dependabot minor-patch group PR -> WOULD-MERGE" || bad "PR 14: $(grep '#14 ' "$S")"
grep -q '#15 ' "$S" && bad "Dependabot major bump became a candidate" || ok "Dependabot major bump -> never a candidate"
grep -q '| .github | #16 | SKIP checks-failed |' "$S" && ok "Dependabot group PR with a red check -> skipped (same green rule)" || bad "PR 16"
grep -q 'Private-repo rows (not named, this repo is public): 1' "$S" && ok "private PR counted, not named" || bad "private count"
grep -q '^WRITE ' "$O/gh.log" && bad "report mode wrote" || ok "report mode made no writes"
grep -q zz-archived "$O/gh.log" && bad "archived repo read" || ok "archived repo skipped"
for ep in 'pulls[?]state=open&base=dev' 'check-runs' 'status[?]' 'check-suites'; do
  grep -E "GET repos/Perditio-Labs/(\.github|zz-secret-repo)/.*$ep" "$O/gh.log" | grep -vq ' paginate$' && bad "$ep read without pagination" || ok "$ep read with --paginate"
done
leak="$(cat "$S" "$O/stdout" "$O/stderr" | grep -E 'zz-secret|#9' || true)"
[[ -z "$leak" ]] && ok "no private repo or PR number in output" || bad "leak: $leak"

O="$T/apply"; e2e "$FX" "$O" MODE=apply
[[ "$(cat "$O/rc")" == 0 ]] && ok "apply exits 0" || bad "apply rc=$(cat "$O/rc")"
grep -q "WRITE PUT repos/Perditio-Labs/.github/pulls/1/merge .*merge_method=squash sha=$(sha_of 1)" "$O/gh.log" && ok "PR 1 merged with the repo's allowed method (squash), head sha pinned" || bad "PR 1 merge: $(grep WRITE "$O/gh.log")"
grep -q "WRITE PUT repos/Perditio-Labs/zz-secret-repo/pulls/9/merge .*merge_method=merge sha=$(sha_of 9)" "$O/gh.log" && ok "private PR merged with merge commit" || bad "PR 9 merge"
ml="$(grep -n "WRITE POST repos/Perditio-Labs/.github/issues/3/labels .*labels\[\]=automerge:branch-updated" "$O/gh.log" | head -1 | cut -d: -f1)"
ul="$(grep -n "WRITE PUT repos/Perditio-Labs/.github/pulls/3/update-branch .*expected_head_sha=$(sha_of 3)" "$O/gh.log" | head -1 | cut -d: -f1)"
[[ -n "$ml" && -n "$ul" && "$ml" -lt "$ul" ]] && ok "PR 3: marker label set BEFORE update-branch (pinned to the head)" || bad "PR 3 marker '$ml' update '$ul'"
grep -q "pulls/13/merge" "$O/gh.log" && bad "merged a PR retargeted to main after inspection" || ok "PR retargeted before the write -> re-evaluation skips it"
grep -q '| .github | #13 | SKIPPED (changed before the write: SKIP base-not-dev) |' "$O/summary.md" && ok "retarget reported" || bad "PR 13 row: $(grep '#13 ' "$O/summary.md")"
grep -q "WRITE PUT repos/Perditio-Labs/.github/pulls/14/merge .*sha=$(sha_of 14)" "$O/gh.log" && ok "Dependabot group PR merged" || bad "PR 14 not merged"
[[ "$(grep -c '^WRITE ' "$O/gh.log")" == 5 ]] && ok "exactly 5 writes (3 merges, 1 marker, 1 update)" || bad "writes: $(grep -c '^WRITE ' "$O/gh.log")"
leak="$(cat "$O/summary.md" "$O/stdout" "$O/stderr" | grep -E 'zz-secret|#9' || true)"
[[ -z "$leak" ]] && ok "apply output names no private repo or PR" || bad "apply leak: $leak"

FXM="$T/fx-marker-fail"; cp -r "$FX" "$FXM"
echo 'ERROR gh: Validation Failed (HTTP 422)' > "$FXM/write-POST.json"
O="$T/marker-fail"; e2e "$FXM" "$O" MODE=apply
grep -q 'pulls/3/update-branch' "$O/gh.log" && bad "updated without the marker" || ok "marker label refused -> no update-branch"

O="$T/cap"; e2e "$FX" "$O" MODE=apply MAX_ACTIONS=1
[[ "$(grep -c '^WRITE ' "$O/gh.log")" == 1 ]] && grep -q 'DEFERRED' "$O/summary.md" && ok "MAX_ACTIONS=1 -> one write, rest deferred" || bad "cap"

echo "== capability guard =="
O="$T/reach"; e2e "$FX" "$O" MODE=apply MIN_REPOS=30
[[ "$(cat "$O/rc")" == 1 ]] && ! grep -q '^WRITE ' "$O/gh.log" && ok "too few private repos -> exit 1, no writes" || bad "reach rc=$(cat "$O/rc")"
FXD="$T/fx-denied"; cp -r "$FX" "$FXD"
echo 'ERROR gh: Resource not accessible by integration (HTTP 403)' > "$FXD/rest-repos_Perditio-Labs_zz-private-sentinel_commits_main_check-runs.json"
O="$T/denied-tick"; e2e "$FXD" "$O" MODE=apply STRICT=0
[[ "$(cat "$O/rc")" == 0 ]] && grep -q 'BLOCKED.*checks' "$O/summary.md" && ! grep -q '^WRITE ' "$O/gh.log" && ok "checks read denied on a tick -> exit 0, BLOCKED, no writes" || bad "denied tick rc=$(cat "$O/rc")"
O="$T/denied-dispatch"; e2e "$FXD" "$O" MODE=apply STRICT=1
[[ "$(cat "$O/rc")" == 1 ]] && ok "checks read denied on a dispatched apply -> exit 1" || bad "denied dispatch rc=$(cat "$O/rc")"
grep -q '^WRITE-REFUSED PUT repos/Perditio-Labs/zz-private-sentinel/pulls/0/merge' "$T/report/gh.log" && ok "contents write probed (merge of PR 0, refused 404)" || bad "no contents write probe"
FXW="$T/fx-no-pr-write"; cp -r "$FX" "$FXW"
echo 'ERROR gh: Resource not accessible by integration (HTTP 403)' > "$FXW/write-PUT-repos_Perditio-Labs_zz-private-sentinel_pulls_0_update-branch.json"
O="$T/no-pr-write"; e2e "$FXW" "$O" MODE=apply STRICT=1
[[ "$(cat "$O/rc")" == 1 ]] && grep -q 'BLOCKED.*pull_requests_write' "$O/summary.md" && ! grep -q '^WRITE ' "$O/gh.log" && ok "pull requests read-only -> BLOCKED, no merges (dispatched apply exit 1)" || bad "no PR write rc=$(cat "$O/rc")"
FXR="$T/fx-merge-refused"; cp -r "$FX" "$FXR"
echo 'ERROR gh: Method Not Allowed (HTTP 405)' > "$FXR/write-PUT-repos_Perditio-Labs_.github_pulls_1_merge.json"
O="$T/merge-refused"; e2e "$FXR" "$O" MODE=apply STRICT=1
[[ "$(cat "$O/rc")" == 1 ]] && grep -q '| .github | #1 | MERGE REFUSED' "$O/summary.md" && ok "refused merge on a dispatched apply -> exit 1" || bad "refused merge rc=$(cat "$O/rc")"
O="$T/merge-refused-tick"; e2e "$FXR" "$O" MODE=apply STRICT=0
[[ "$(cat "$O/rc")" == 0 ]] && ok "refused merge on a scheduled tick -> warning, exit 0" || bad "refused merge tick rc=$(cat "$O/rc")"

for ws in "" $'\t' $' \n '; do
  O="$T/ws-sentinel"; rm -rf "$O"; e2e "$FX" "$O" MODE=apply SENTINEL_REPOS="$ws"
  [[ "$(cat "$O/rc")" == 1 ]] && grep -q 'NOT RUN' "$O/summary.md" && ! grep -q '^WRITE ' "$O/gh.log" && ok "empty/whitespace sentinel -> exit 1, NOT RUN, no writes" || bad "sentinel '$ws' rc=$(cat "$O/rc")"
done
grep -qE 'SENTINEL_REPOS:-[a-z]' "$SCRIPT" && bad "the merge script has a default sentinel name" || ok "no default sentinel name in the public merge source"

for d in reach denied-tick denied-dispatch; do
  leak="$(cat "$T/$d/summary.md" "$T/$d/stdout" "$T/$d/stderr" "$T/$d/capability.txt" 2>/dev/null | grep -E 'zz-private-sentinel|zz-secret' || true)"
  [[ -z "$leak" ]] && ok "$d: no private repo name in output" || bad "$d leaked: $leak"
done

echo
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
