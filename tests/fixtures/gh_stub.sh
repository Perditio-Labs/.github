#!/usr/bin/env bash
# gh_stub.sh - offline stand-in for `gh api` used by the hygiene tests.
# Serves JSON from $GH_FIXTURES, applies --jq like gh does, and records every
# call in $GH_STUB_LOG. Any write (-X POST/PATCH/PUT/DELETE) is recorded as
# "WRITE <method> <endpoint> ref=<ref> sha=<sha> args: <-f/-F pairs>" and
# answered from write-<method>-<endpoint key>.json, else write-<method>.json,
# else write.json, else {}. A write fixture starting "ERROR" refuses the
# write: logged as "WRITE-REFUSED ...", gh exits 1.
# A POST of refs/tags/<t> is remembered in $GH_STATE so a later GET of that
# tag returns it (like the real API).
# Fixture lookup (first match wins):
#   graphql: graphql-<kind>-<name>[-<b>].json  (kind from the query text)
#   REST:    rest-<path with / ? & = replaced by _>.json, then the same with
#            the query string dropped.
# <fixture>.after1, when present, is served from the second read of that
# fixture on. GET lines in the log end with " paginate" for --paginate.
# A fixture file whose first line is "ERROR <message>" makes gh print the
# message to stderr and exit 1. A write fixture starting "ERROR" fails too.
set -uo pipefail
log="${GH_STUB_LOG:-/dev/null}"
state="${GH_STATE:-}"
[[ "${1:-}" == "api" ]] || { echo "gh_stub: only 'gh api' is supported" >&2; exit 2; }
shift
endpoint="" jqexpr="" method="GET" query="" name="" b="" ref="" sha="" kvs="" pg=""
while (($#)); do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    --paginate) pg=" paginate"; shift ;;
    -X) method="$2"; shift 2 ;;
    -f|-F)
      kv="$2"; shift 2; kvs+=" $kv"
      case "$kv" in
        query=*) query="${kv#query=}" ;;
        name=*) name="${kv#name=}" ;;
        b=*) b="${kv#b=}" ;;
        ref=*) ref="${kv#ref=}" ;;
        sha=*) sha="${kv#sha=}" ;;
      esac ;;
    graphql) endpoint="graphql"; shift ;;
    *) [[ -z "$endpoint" ]] && endpoint="$1"; shift ;;
  esac
done

emit() { # emit <file>
  if head -n1 "$1" | grep -q '^ERROR '; then
    head -n1 "$1" | sed 's/^ERROR //' >&2
    exit 1
  fi
  if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr" "$1"; else cat "$1"; fi
}

if [[ "$method" != "GET" ]]; then
  f="$GH_FIXTURES/write-$method-$(printf '%s' "$endpoint" | tr '/?&=' '____').json"
  [[ -f "$f" ]] || f="$GH_FIXTURES/write-$method.json"
  [[ -f "$f" ]] || f="$GH_FIXTURES/write.json"
  if [[ -f "$f" ]] && head -n1 "$f" | grep -q '^ERROR '; then
    # A refused write changes nothing: logged as WRITE-REFUSED, not WRITE.
    echo "WRITE-REFUSED $method $endpoint args:$kvs" >> "$log"
    emit "$f"
  fi
  echo "WRITE $method $endpoint ref=$ref sha=$sha args:$kvs" >> "$log"
  if [[ -f "$f" ]]; then emit "$f"; exit 0; fi
  if [[ -n "$state" && "$method" == "POST" && "$ref" == refs/tags/* ]]; then
    repo="$(cut -d/ -f3 <<< "$endpoint")"
    mkdir -p "$state"
    printf '%s' "$sha" > "$state/$(printf '%s|%s' "$repo" "${ref#refs/tags/}" | tr '/|' '__')"
  fi
  echo '{}'
  exit 0
fi
echo "GET $endpoint $name $b$pg" >> "$log"
if [[ "$endpoint" == "graphql" ]]; then
  kind=other
  case "$query" in
    *'bases:pullRequests'*) kind=one ;;
    *'pullRequests(headRefName'*) kind=recoverhead ;;
    *'pullRequests(baseRefName'*) kind=recoverbase ;;
    *'refs(refPrefix'*) kind=refs ;;
    *'ref(qualifiedName:"refs/heads/dev")'*) kind=dev ;;
    *'pullRequests(states:OPEN'*) kind=prs ;;
  esac
  f="$GH_FIXTURES/graphql-$kind-$name.json"
  if [[ -n "$b" ]]; then
    fb="$GH_FIXTURES/graphql-$kind-$name-$(tr '/' '_' <<< "$b").json"
    [[ -f "$fb" ]] && f="$fb"
  fi
else
  if [[ -n "$state" && "$endpoint" == repos/*/git/ref/tags/* ]]; then
    repo="$(cut -d/ -f3 <<< "$endpoint")"
    tag="${endpoint#*/git/ref/tags/}"
    sf="$state/$(printf '%s|%s' "$repo" "$tag" | tr '/|' '__')"
    if [[ -f "$sf" ]]; then
      t="$(mktemp)"; printf '{"object":{"type":"commit","sha":"%s"}}' "$(cat "$sf")" > "$t"
      emit "$t"; rm -f "$t"; exit 0
    fi
  fi
  key="$(printf '%s' "$endpoint" | tr '/?&=' '____')"
  f="$GH_FIXTURES/rest-$key.json"
  if [[ ! -f "$f" ]]; then
    key="$(printf '%s' "${endpoint%%\?*}" | tr '/' '_')"
    f="$GH_FIXTURES/rest-$key.json"
  fi
fi
# Sequential responses: <fixture>.after1 is served from the 2nd read on
# (models state that changes between discovery and the pre-write re-read).
if [[ -f "$f" && -f "$f.after1" && "$log" != /dev/null ]]; then
  cdir="${GH_STATE:-$(dirname "$log")/ghstate}"; mkdir -p "$cdir"
  cf="$cdir/count-$(basename "$f")"
  c=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$cf"
  (( c >= 2 )) && f="$f.after1"
fi
if [[ ! -f "$f" ]]; then
  echo "gh: Not Found (HTTP 404) stub-missing:$(basename "$f")" >&2
  exit 1
fi
emit "$f"
