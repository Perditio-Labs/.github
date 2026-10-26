#!/usr/bin/env bash
# Tests for scripts/rerun_cancelled_once.sh: the selection rule (unit) and an
# offline end-to-end run against the stub gh (tests/fixtures/gh_stub.sh).
# Run: bash tests/test_rerun_cancelled.sh   (exit 1 on any failure)
set -uo pipefail
TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTDIR/../scripts/rerun_cancelled_once.sh"
# shellcheck source=scripts/rerun_cancelled_once.sh
. "$SCRIPT"
set +e

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

SINCE=2026-10-25T00:00:00Z
R=2026-10-25T12:00:00Z     # inside the window
R2=2026-10-25T13:00:00Z
OLD=2026-10-24T12:00:00Z   # outside the window
run() { # run <id> <wf> <created> <updated> <status> <conclusion> <attempt>
  printf '{"id":%s,"workflow_id":%s,"created_at":"%s","updated_at":"%s","status":"%s","conclusion":%s,"run_attempt":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$( [[ "$6" == null ]] && echo null || echo "\"$6\"")" "$7"
}
sel() { select_reruns "[$1]" "$SINCE" | cut -f1 | tr '\n' ' ' | sed 's/ $//'; }

echo "== selection rule =="
[[ "$(sel "$(run 1 10 $R $R completed cancelled 1)")" == "1" ]] && ok "cancelled, attempt 1, in window -> rerun" || bad "basic case"
[[ -z "$(sel "$(run 1 10 $R $R completed cancelled 2)")" ]] && ok "attempt 2 -> never again" || bad "attempt 2 selected"
[[ -z "$(sel "$(run 1 10 $OLD $OLD completed cancelled 1)")" ]] && ok "cancelled before the window -> skip" || bad "old cancel selected"
[[ -z "$(sel "$(run 1 10 $R $R completed cancelled 1),$(run 2 10 $R2 $R2 completed success 1)")" ]] && ok "superseded by a newer run of the same workflow -> skip" || bad "superseded selected"
[[ "$(sel "$(run 1 10 $R $R completed success 1),$(run 2 10 $R2 $R2 completed cancelled 1)")" == "2" ]] && ok "newest is cancelled (older success) -> rerun newest" || bad "newest cancelled missed"
[[ "$(sel "$(run 1 10 $R2 $R2 completed cancelled 1),$(run 2 11 $R $R completed success 1)")" == "1" ]] && ok "other workflow green -> only the cancelled workflow" || bad "per-workflow grouping"
[[ "$(sel "$(run 1 10 $R $R completed cancelled 1),$(run 3 11 $R $R completed cancelled 1)")" == "1 3" ]] && ok "two cancelled workflows -> both" || bad "two workflows"
[[ -z "$(sel "$(run 1 10 $R $R completed cancelled 1),$(run 2 10 $R2 $R2 in_progress null 1)")" ]] && ok "newer run in progress -> skip" || bad "in-progress superseder"
[[ -z "$(sel "$(run 1 10 $R $R completed failure 1)")" ]] && ok "failure is not cancelled -> skip" || bad "failure selected"
[[ "$(sel "$(run 5 10 $R $R completed cancelled 1),$(run 4 10 $R $R completed success 1)")" == "5" ]] && ok "same created_at -> higher id is newest" || bad "tie-break"
[[ -z "$(sel "")" ]] && ok "no runs -> nothing" || bad "empty"
select_reruns '{"not":"array"}' "$SINCE" >/dev/null 2>&1 && bad "non-array accepted" || ok "non-array input -> error"
select_reruns 'garbage' "$SINCE" >/dev/null 2>&1 && bad "garbage accepted" || ok "garbage input -> error"

echo "== offline end to end (stub gh) =="
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fx"
cp "$TESTDIR/fixtures/gh_stub.sh" "$T/bin/gh"; chmod +x "$T/bin/gh"
NOWR="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
FX="$T/fx"
cat > "$FX/rest-orgs_Perditio-Labs_repos.json" <<JSON
[{"name":".github","archived":false,"fork":false,"private":false,"mirror_url":null,"default_branch":"main"},
 {"name":"zz-private-sentinel","archived":false,"fork":false,"private":true,"mirror_url":null,"default_branch":"main"},
 {"name":"zz-secret-repo","archived":false,"fork":false,"private":true,"mirror_url":null,"default_branch":"main"},
 {"name":"pub-fork","archived":false,"fork":true,"private":false,"mirror_url":null,"default_branch":"main"},
 {"name":"zz-archived-secret","archived":true,"fork":false,"private":true,"mirror_url":null,"default_branch":"main"}]
JSON
echo '[]' > "$FX/rest-repos_Perditio-Labs_zz-private-sentinel_pulls.json"
echo '{"workflow_runs":[]}' > "$FX/rest-repos_Perditio-Labs_zz-private-sentinel_actions_runs.json"
echo 'ERROR gh: Not Found (HTTP 404)' > "$FX/write-POST-repos_Perditio-Labs_zz-private-sentinel_actions_runs_1_rerun.json"
echo "[{\"number\":1,\"head\":{\"sha\":\"$S2\"}}]" > "$FX/rest-repos_Perditio-Labs_.github_pulls.json"
echo "[{\"number\":9,\"head\":{\"sha\":\"$S1\"}}]" > "$FX/rest-repos_Perditio-Labs_zz-secret-repo_pulls.json"
echo "{\"workflow_runs\":[$(run 222 20 "$NOWR" "$NOWR" completed cancelled 1)]}" > "$FX/rest-repos_Perditio-Labs_.github_actions_runs_head_sha_${S2}_per_page_100.json"
S3=3333333333333333333333333333333333333333
echo "[{\"number\":4,\"head\":{\"sha\":\"$S3\"}}]" > "$FX/rest-repos_Perditio-Labs_pub-fork_pulls.json"
echo "{\"workflow_runs\":[$(run 333 40 "$NOWR" "$NOWR" completed cancelled 1)]}" > "$FX/rest-repos_Perditio-Labs_pub-fork_actions_runs_head_sha_${S3}_per_page_100.json"
echo "{\"workflow_runs\":[$(run 111 30 "$NOWR" "$NOWR" completed cancelled 1)]}" > "$FX/rest-repos_Perditio-Labs_zz-secret-repo_actions_runs_head_sha_${S1}_per_page_100.json"

e2e() { # e2e <fixtures> <out> <env...>
  local fx="$1" out="$2"; shift 2
  mkdir -p "$out"
  ( export PATH="$T/bin:$PATH" GH_TOKEN=stub GH_FIXTURES="$fx" GH_STUB_LOG="$out/gh.log" \
      OUT_DIR="$out" HOST_REPO="Perditio-Labs/.github" SENTINEL_REPOS=zz-private-sentinel MIN_REPOS=2 "$@"
    bash "$SCRIPT" > "$out/stdout" 2> "$out/stderr" ); echo $? > "$out/rc"
}
O="$T/report"; e2e "$FX" "$O" MODE=report
[[ "$(cat "$O/rc")" == 0 ]] && ok "report exits 0" || { bad "report rc=$(cat "$O/rc")"; cat "$O/stderr"; }
grep -q '| .github | 222 | WOULD-RERUN' "$O/summary.md" && ok "public cancelled run listed" || bad "public run missing"
grep -q 'Private-repo rows (not named, this repo is public): 1' "$O/summary.md" && ok "private run counted, not named" || bad "private count"
grep -q '^WRITE ' "$O/gh.log" && bad "report mode wrote" || ok "report mode made no writes"
grep -q '^WRITE-REFUSED POST repos/Perditio-Labs/zz-private-sentinel/actions/runs/1/rerun' "$O/gh.log" && ok "actions write probed with a refused re-run of a run that cannot exist" || bad "no actions write probe"
leak="$(cat "$O/summary.md" "$O/stdout" "$O/stderr" | grep -E 'zz-secret|111' || true)"
[[ -z "$leak" ]] && ok "no private repo name or run id in output" || bad "leak: $leak"
grep -q zz-archived "$O/gh.log" && bad "archived repo read" || ok "archived repo skipped"

O="$T/apply"; e2e "$FX" "$O" MODE=apply
[[ "$(cat "$O/rc")" == 0 ]] && ok "apply exits 0" || bad "apply rc=$(cat "$O/rc")"
[[ "$(grep -c 'WRITE POST .*actions/runs/[0-9]*/rerun' "$O/gh.log")" == 3 ]] && ok "apply re-ran all 3 runs (incl. the fork)" || bad "apply writes: $(grep WRITE "$O/gh.log")"

O="$T/cap"; e2e "$FX" "$O" MODE=apply MAX_RERUNS=1
[[ "$(grep -c 'WRITE POST' "$O/gh.log")" == 1 ]] && grep -q 'DEFERRED (MAX_RERUNS=1)' "$O/summary.md" && ok "cap 1 -> one rerun, rest deferred" || bad "cap not enforced"

grep -q '| pub-fork | 333 | WOULD-RERUN' "$T/report/summary.md" && ok "non-archived fork repo is covered" || bad "fork repo skipped"
grep -E 'GET repos/Perditio-Labs/[^ ]+/actions/runs[?]head_sha' "$T/report/gh.log" | grep -vq ' paginate$' && bad "runs read without pagination" || ok "runs per sha read with --paginate"
grep -E 'GET repos/Perditio-Labs/[^ ]+/pulls[?]state=open' "$T/report/gh.log" | grep -vq ' paginate$' && bad "open PRs read without pagination" || ok "open PRs read with --paginate"

R222="rest-repos_Perditio-Labs_.github_actions_runs_head_sha_${S2}_per_page_100.json"
FX2="$T/fx-moved"; cp -r "$FX" "$FX2"
echo "{\"workflow_runs\":[$(run 222 20 "$NOWR" "$NOWR" completed cancelled 2)]}" > "$FX2/$R222.after1"
O="$T/moved"; e2e "$FX2" "$O" MODE=apply
grep -q 'WRITE POST .*runs/222/rerun' "$O/gh.log" && bad "re-ran a run already re-run elsewhere" || ok "re-read before rerun: attempt 2 -> skipped"

FX3="$T/fx-superseded"; cp -r "$FX" "$FX3"
echo "{\"workflow_runs\":[$(run 222 20 "$NOWR" "$NOWR" completed cancelled 1),$(run 223 20 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" queued null 1)]}" > "$FX3/$R222.after1"
O="$T/superseded"; e2e "$FX3" "$O" MODE=apply
grep -q 'WRITE POST .*runs/222/rerun' "$O/gh.log" && bad "re-ran a run superseded during the scan" || ok "newer run appeared during the scan -> skipped"
grep -q 'WRITE POST .*runs/111/rerun' "$O/gh.log" && ok "other candidates still re-run" || bad "unrelated candidate dropped"

FX4="$T/fx-closed"; cp -r "$FX" "$FX4"
echo '[]' > "$FX4/rest-repos_Perditio-Labs_.github_pulls.json.after1"
O="$T/closed"; e2e "$FX4" "$O" MODE=apply
grep -q 'WRITE POST .*runs/222/rerun' "$O/gh.log" && bad "re-ran for a PR closed during the scan" || ok "PR closed during the scan -> skipped"
grep -q 'no longer an open-PR head' "$O/summary.md" && ok "closed PR reported" || bad "closed PR not reported"

echo "== capability guard =="
O="$T/reach"; e2e "$FX" "$O" MODE=apply MIN_REPOS=30
[[ "$(cat "$O/rc")" == 1 ]] && ! grep -q '^WRITE ' "$O/gh.log" && ok "too few private repos -> exit 1, no writes" || bad "reach rc=$(cat "$O/rc")"
FXD="$T/fx-denied"; cp -r "$FX" "$FXD"
echo 'ERROR gh: Resource not accessible by integration (HTTP 403)' > "$FXD/rest-repos_Perditio-Labs_zz-private-sentinel_pulls.json"
O="$T/denied-tick"; e2e "$FXD" "$O" MODE=apply STRICT=0
[[ "$(cat "$O/rc")" == 0 ]] && grep -q BLOCKED "$O/summary.md" && ! grep -q '^WRITE ' "$O/gh.log" && ok "PR read denied on a scheduled tick -> exit 0, BLOCKED, no writes" || bad "denied tick rc=$(cat "$O/rc")"
O="$T/denied-dispatch"; e2e "$FXD" "$O" MODE=apply STRICT=1
[[ "$(cat "$O/rc")" == 1 ]] && grep -q BLOCKED "$O/summary.md" && ok "PR read denied on a dispatched apply -> exit 1" || bad "denied dispatch rc=$(cat "$O/rc")"

FXW="$T/fx-readonly-actions"; cp -r "$FX" "$FXW"
echo 'ERROR gh: Resource not accessible by integration (HTTP 403)' > "$FXW/write-POST-repos_Perditio-Labs_zz-private-sentinel_actions_runs_1_rerun.json"
O="$T/ro-dispatch"; e2e "$FXW" "$O" MODE=apply STRICT=1
[[ "$(cat "$O/rc")" == 1 ]] && grep -q 'BLOCKED.*actions_write' "$O/summary.md" && ! grep -q '^WRITE ' "$O/gh.log" && ok "actions read-only token, dispatched apply -> exit 1, BLOCKED, no re-run" || bad "read-only actions dispatch rc=$(cat "$O/rc")"
FXW0="$T/fx-readonly-empty"; cp -r "$FXW" "$FXW0"
for f in "$FXW0"/rest-repos_Perditio-Labs_*_pulls.json; do echo '[]' > "$f"; done
O="$T/ro-empty"; e2e "$FXW0" "$O" MODE=report
grep -q 'BLOCKED.*actions_write' "$O/summary.md" && ok "read-only actions with zero candidates -> still BLOCKED, never clean" || bad "read-only actions, empty -> $(head -3 "$O/summary.md")"

FXF="$T/fx-rerun-fails"; cp -r "$FX" "$FXF"
echo 'ERROR gh: Server Error (HTTP 500)' > "$FXF/write-POST-repos_Perditio-Labs_.github_actions_runs_222_rerun.json"
O="$T/fail-dispatch"; e2e "$FXF" "$O" MODE=apply STRICT=1
[[ "$(cat "$O/rc")" == 1 ]] && grep -q '| .github | 222 | RERUN FAILED |' "$O/summary.md" && ok "a failed re-run on a dispatched apply -> exit 1" || bad "failed rerun rc=$(cat "$O/rc")"
O="$T/fail-tick"; e2e "$FXF" "$O" MODE=apply STRICT=0
[[ "$(cat "$O/rc")" == 0 ]] && grep -q 'warning' "$O/stdout" && ok "a failed re-run on a scheduled tick -> warning, exit 0" || bad "failed rerun tick rc=$(cat "$O/rc")"

for kind in pulls runs; do
  FXE="$T/fx-reval-$kind"; cp -r "$FX" "$FXE"
  if [[ "$kind" == pulls ]]; then f="$FXE/rest-repos_Perditio-Labs_.github_pulls.json"; else f="$FXE/$R222"; fi
  echo 'ERROR gh: Server Error (HTTP 502)' > "$f.after1"
  O="$T/reval-$kind"; e2e "$FXE" "$O" MODE=apply STRICT=1
  grep -q 'WRITE POST .*runs/222/rerun' "$O/gh.log" && bad "re-ran with unreadable re-validation ($kind)" || ok "re-validation $kind unreadable -> not re-run"
  grep -q '| .github | 222 | ERROR (re-validation' "$O/summary.md" && [[ "$(cat "$O/rc")" == 1 ]] && ok "re-validation $kind unreadable -> ERROR row, dispatched apply exit 1" || bad "reval $kind rc=$(cat "$O/rc") row=$(grep 222 "$O/summary.md")"
done

echo "== the window is re-computed before each re-run (controlled clock) =="
# Fake date: the first 'date -u +%s' is the real clock; every later one is
# 2 h ahead, as if discovery took 2 h. A run cancelled 23 h ago is in the
# window at discovery and out of it at re-validation.
mkdir -p "$T/clockbin"; REALDATE="$(command -v date)"
cat > "$T/clockbin/date" <<CLOCK
#!/usr/bin/env bash
if [[ "\$*" == "-u +%s" ]]; then
  c=\$(( \$(cat "$T/clock.n" 2>/dev/null || echo 0) + 1 )); echo "\$c" > "$T/clock.n"
  now=\$("$REALDATE" -u +%s)
  if (( c > 1 )); then echo \$(( now + 7200 )); else echo "\$now"; fi
  exit 0
fi
exec "$REALDATE" "\$@"
CLOCK
chmod +x "$T/clockbin/date"
FXC="$T/fx-clock"; cp -r "$FX" "$FXC"
OLD23="$(date -u -d '-23 hours' +%Y-%m-%dT%H:%M:%SZ)"
echo "{\"workflow_runs\":[$(run 222 20 "$OLD23" "$OLD23" completed cancelled 1)]}" > "$FXC/$R222"
rm -f "$T/clock.n"
O="$T/clock"; mkdir -p "$O"
( export PATH="$T/clockbin:$T/bin:$PATH" GH_TOKEN=stub GH_FIXTURES="$FXC" GH_STUB_LOG="$O/gh.log" \
    OUT_DIR="$O" HOST_REPO="Perditio-Labs/.github" SENTINEL_REPOS=zz-private-sentinel MIN_REPOS=2 MODE=apply
  bash "$SCRIPT" > "$O/stdout" 2> "$O/stderr" ); echo $? > "$O/rc"
grep -q '| .github | 222 | SKIPPED (superseded or changed since inspection) |' "$O/summary.md" && ok "cancellation aged out during the scan -> skipped" || bad "clock: $(grep '222' "$O/summary.md")"
grep -q 'WRITE POST .*runs/222/rerun' "$O/gh.log" && bad "re-ran an aged-out run" || ok "aged-out run not re-run"
grep -q 'WRITE POST .*runs/111/rerun' "$O/gh.log" && ok "fresh cancellation (1 h old) still re-run" || bad "fresh run dropped"

O="$T/no-sentinel"; e2e "$FX" "$O" MODE=report SENTINEL_REPOS=
[[ "$(cat "$O/rc")" == 1 ]] && grep -q 'no sentinel repo configured' "$O/summary.md" && ok "sentinel secret empty -> exit 1 (no default sentinel)" || bad "no sentinel rc=$(cat "$O/rc")"
for ws in $'\t' $'\n' $' \t\n '; do
  O="$T/ws-sentinel"; rm -rf "$O"; e2e "$FX" "$O" MODE=apply SENTINEL_REPOS="$ws"
  [[ "$(cat "$O/rc")" == 1 ]] && grep -q 'NOT RUN' "$O/summary.md" && ! grep -q '^WRITE ' "$O/gh.log" && ok "whitespace-only sentinel -> exit 1, NOT RUN, no writes" || bad "whitespace sentinel rc=$(cat "$O/rc")"
done
grep -qE 'SENTINEL_REPOS:-[a-z]' "$SCRIPT" && bad "the rerun script has a default sentinel name" || ok "no default sentinel name in the public rerun source"

for d in reach denied-tick denied-dispatch; do
  leak="$(cat "$T/$d/summary.md" "$T/$d/stdout" "$T/$d/stderr" "$T/$d/capability.txt" 2>/dev/null | grep -E 'zz-private-sentinel|zz-secret' || true)"
  [[ -z "$leak" ]] && ok "$d: no private repo name in output" || bad "$d leaked: $leak"
done

echo
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
