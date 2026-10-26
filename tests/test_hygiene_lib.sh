#!/usr/bin/env bash
# Tests for scripts/hygiene_lib.sh: the capability guard, the probe mapping,
# the exit-code policy and the public-repo redaction rule.
# Run: bash tests/test_hygiene_lib.sh   (exit 1 on any failure)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hygiene_lib.sh
. "$HERE/../scripts/hygiene_lib.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
cap() { capability_decision "$@" >/dev/null 2>&1; echo $?; }

echo "== capability_decision =="
[[ "$(cap 56 30 "" "pulls=ok")" == 0 ]] && ok "56 private, sentinel seen, pulls ok -> 0" || bad "healthy token not accepted"
[[ "$(cap 29 30 "" "pulls=ok")" == 1 ]] && ok "29 private (< 30) -> 1 (cannot fire)" || bad "too few repos accepted"
[[ "$(cap 0 30 "" "pulls=ok")" == 1 ]] && ok "job token shape (0 private) -> 1" || bad "job token accepted"
[[ "$(cap 56 30 "zz-private-sentinel " "pulls=ok")" == 1 ]] && ok "missing sentinel -> 1" || bad "missing sentinel accepted"
[[ "$(cap 56 30 "" "pulls=denied")" == 4 ]] && ok "pulls denied -> 4 (BLOCKED)" || bad "denied permission not BLOCKED"
[[ "$(cap 56 30 "" "pulls=ok" "checks=denied" "statuses=denied")" == 4 ]] && ok "checks/statuses denied -> 4" || bad "checks denied not BLOCKED"
[[ "$(cap 56 30 "" "pulls=error")" == 1 ]] && ok "inconclusive probe -> 1 (fail closed)" || bad "inconclusive probe accepted"
[[ "$(cap 56 30 "" "pulls=denied" "checks=error")" == 1 ]] && ok "error beats denied -> 1" || bad "error+denied not failed"
[[ "$(cap "" 30 "")" == 1 ]] && ok "empty count -> 1" || bad "empty count accepted"
[[ "$(cap abc 30 "")" == 1 ]] && ok "non-numeric count -> 1" || bad "non-numeric count accepted"
[[ "$(cap 30 30 "")" == 0 ]] && ok "exactly the minimum, no probes -> 0" || bad "minimum rejected"
msg="$(capability_decision 56 30 "" "pull_requests=denied")"
grep -q 'lacks permission(s): pull_requests' <<< "$msg" && ok "BLOCKED message names the permission" || bad "BLOCKED message: $msg"
msg="$(capability_decision 56 30 "zz-private-sentinel zz-private ")"
grep -q 'cannot see 2 sentinel repo(s)' <<< "$msg" && ! grep -qE 'zz-private-sentinel|zz-private' <<< "$msg" && ok "missing sentinels counted, never named" || bad "missing-sentinel message: $msg"

echo "== probe_state =="
[[ "$(probe_state 0 '[]')" == ok ]] && ok "rc 0 -> ok" || bad "rc 0"
[[ "$(probe_state 1 'gh: Resource not accessible by integration (HTTP 403)')" == denied ]] && ok "integration 403 -> denied" || bad "integration 403"
[[ "$(probe_state 1 'gh: API rate limit exceeded (HTTP 403)')" == error ]] && ok "rate-limit 403 -> error (not a permission)" || bad "rate limit read as denied"
[[ "$(probe_state 1 'gh: Not Found (HTTP 404)')" == error ]] && ok "404 -> error" || bad "404"
[[ "$(probe_state 1 '')" == error ]] && ok "silent failure -> error" || bad "silent failure"

echo "== hyg_capability refuses an empty or whitespace-only sentinel list =="
for ws in "" " " $'\t' $'\n' $' \t\n '; do
  ( gh() { echo "gh must not be called" >&2; return 99; }
    hyg_capability Perditio-Labs 1 "$ws" "x=repos/Perditio-Labs/{repo}/pulls" >/dev/null 2>&1; echo "rc=$? msg=$CAP_MSG" ) > "${TMPDIR:-/tmp}/hyg_ws.out" 2>&1
  grep -q '^rc=1 msg=FAIL: no sentinel repo configured' "${TMPDIR:-/tmp}/hyg_ws.out" && ok "sentinel '$(printf '%q' "$ws")' -> FAIL" || bad "sentinel '$(printf '%q' "$ws")': $(cat "${TMPDIR:-/tmp}/hyg_ws.out")"
done

echo "== probe_write_state (write probe on a resource that cannot exist) =="
[[ "$(probe_write_state 1 'gh: Not Found (HTTP 404)')" == ok ]] && ok "404 -> permission granted" || bad "write 404"
[[ "$(probe_write_state 1 'gh: Resource not accessible by integration (HTTP 403)')" == denied ]] && ok "integration 403 -> denied" || bad "write 403"
[[ "$(probe_write_state 0 '{}')" == error ]] && ok "write succeeded -> error (fail closed)" || bad "write success"
[[ "$(probe_write_state 1 'gh: API rate limit exceeded (HTTP 403)')" == error ]] && ok "rate limit -> error" || bad "write rate limit"
[[ "$(probe_write_state 1 'gh: Server Error (HTTP 500)')" == error ]] && ok "500 -> error" || bad "write 500"

echo "== exit_for =="
[[ "$(exit_for 0 apply 1)" == 0 ]] && ok "ok -> 0" || bad "ok"
[[ "$(exit_for 1 report 0)" == 1 ]] && ok "reach failure in report -> 1" || bad "reach report"
[[ "$(exit_for 1 apply 0)" == 1 ]] && ok "reach failure in apply -> 1" || bad "reach apply"
[[ "$(exit_for 4 apply 1)" == 1 ]] && ok "BLOCKED strict apply -> 1" || bad "blocked strict"
[[ "$(exit_for 4 apply 0)" == 0 ]] && ok "BLOCKED scheduled tick -> 0 (warning, no mail storm)" || bad "blocked tick"
[[ "$(exit_for 4 report 1)" == 0 ]] && ok "BLOCKED report -> 0" || bad "blocked report"
[[ "$(exit_for 7 report 0)" == 1 ]] && ok "unknown rc -> 1" || bad "unknown rc"

echo "== redaction =="
[[ "$(repo_label secret-x true 1)" == "(private repo)" ]] && ok "private in public host -> redacted" || bad "private not redacted"
[[ "$(repo_label secret-x "" 1)" == "(private repo)" ]] && ok "unknown privacy -> redacted" || bad "unknown privacy shown"
[[ "$(repo_label open-x false 1)" == "open-x" ]] && ok "public repo shown" || bad "public repo hidden"
[[ "$(repo_label secret-x true 0)" == "secret-x" ]] && ok "private host -> shown" || bad "private host redacted"
J='{"name":".github","private":false}
{"name":"zz-private-sentinel","private":true}'
[[ "$(host_redact "$J" .github)" == 1 ]] && ok "public host -> redact" || bad "public host"
[[ "$(host_redact "$J" zz-private-sentinel)" == 0 ]] && ok "private host -> no redact" || bad "private host"
[[ "$(host_redact "$J" missing)" == 1 ]] && ok "absent host -> redact" || bad "absent host"
[[ "$(host_redact "not json" .github)" == 1 ]] && ok "unreadable -> redact" || bad "unreadable"

echo
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
