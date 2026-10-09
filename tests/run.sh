#!/usr/bin/env bash
# fastup tests. No network: everything is served by tests/fixture_server.py on 127.0.0.1.
# Usage: tests/run.sh [name-filter]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FASTUP="$HERE/../fastup"
FILTER="${1:-}"

WORK="$(mktemp -d)"
LOG="$WORK/requests.log"
ROOT="$WORK/www"
mkdir -p "$ROOT"
: >"$LOG"

python3 "$HERE/fixture_server.py" "$ROOT" "$WORK/port" "$LOG" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT
# A cold CI runner can take several seconds to start python3.
for _ in $(seq 300); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo "fixture server did not start within 30s" >&2; exit 1; }
PORT="$(cat "$WORK/port")"
BASE="http://127.0.0.1:$PORT"

pass=0
fail=0
failed=()

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); failed+=("$1"); printf '  FAIL %s: %s\n' "$1" "$2"; }

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}
sha512() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 512 "$1" | awk '{print $1}'
  else sha512sum "$1" | awk '{print $1}'; fi
}

# --- fixtures --------------------------------------------------------------
head -c $((3 * 1024 * 1024)) /dev/urandom >"$ROOT/good.bin"
head -c $((3 * 1024 * 1024)) /dev/urandom >"$ROOT/evil.bin"
GOOD256="$(sha256 "$ROOT/good.bin")"

mkdir -p "$WORK/pkg/package/bin"
printf '#!/bin/sh\necho tool 1.2.3\n' >"$WORK/pkg/package/bin/tool"
chmod +x "$WORK/pkg/package/bin/tool"
tar -czf "$ROOT/good.tgz" -C "$WORK/pkg" package
TGZ512="$(sha512 "$ROOT/good.tgz")"

# tarball whose member escapes the extraction dir
mkdir -p "$WORK/trav/a"
printf 'pwned\n' >"$WORK/trav/evil"
(cd "$WORK/trav/a" && tar -czf "$ROOT/trav.tgz" ../evil 2>/dev/null)
TRAV512="$(sha512 "$ROOT/trav.tgz")"

# npm registry metadata fixture (official registry + one mirror serve the same tarball)
INTEGRITY="sha512-$(python3 -c 'import base64,hashlib,sys; print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$ROOT/good.tgz")"
mkdir -p "$ROOT/npm/@scope/pkg/-" "$ROOT/mirror/@scope/pkg/-"
cp "$ROOT/good.tgz" "$ROOT/npm/@scope/pkg/-/pkg-1.2.3.tgz"
cp "$ROOT/good.tgz" "$ROOT/mirror/@scope/pkg/-/pkg-1.2.3.tgz"
printf '{"name":"@scope/pkg","version":"1.2.3","dist":{"tarball":"%s/npm/@scope/pkg/-/pkg-1.2.3.tgz","integrity":"%s"}}\n' \
  "$BASE" "$INTEGRITY" >"$ROOT/npm/@scope/pkg/1.2.3"

line() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# Run a snippet with fastup sourced as a library (sourcing must not run main).
lib() {
  "${TEST_BASH:-/bin/bash}" -c 'set -uo pipefail; source "$1"; shift; eval "$1"' _ "$FASTUP" "$1"
}

export FASTUP_PROBE_BYTES=$((1024 * 1024))
export FASTUP_PROBE_TIMEOUT=3
export FASTUP_STATE="$WORK/state"

run() { [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]] || return 0; "$1"; }

# --- core: CLI ---------------------------------------------------------------

t_cli_help() {
  "$FASTUP" --help >"$WORK/out" 2>&1 && grep -q 'fastup' "$WORK/out" &&
    ok cli_help || bad cli_help "--help should exit 0 and print usage"
}

t_cli_unknown() {
  "$FASTUP" no-such-cli >/dev/null 2>&1
  [ $? -eq 2 ] && ok cli_unknown || bad cli_unknown "unknown cli should exit 2"
}

t_sourcing_is_quiet() {
  out="$(lib 'true' 2>&1)"
  [ -z "$out" ] && ok sourcing_is_quiet || bad sourcing_is_quiet "sourcing printed: $out"
}

t_json_accessor_validates() {
  json="$WORK/json.json"
  printf '{"assets":[{"name":"fastup","digest":"sha256:abc"}]}\n' >"$json"
  got="$(lib "fastup_json_get assets.0.name '$json'")"; valid_rc=$?
  lib "fastup_json_get assets '$json'" >/dev/null 2>&1; object_rc=$?
  lib "fastup_json_get assets.1.name '$json'" >/dev/null 2>&1; missing_rc=$?
  printf '{"assets": [}\n' >"$json"
  lib "fastup_json_get assets.0.name '$json'" >/dev/null 2>&1; invalid_rc=$?
  [ "$valid_rc" -eq 0 ] && [ "$got" = fastup ] && [ "$object_rc" -ne 0 ] && [ "$missing_rc" -ne 0 ] && [ "$invalid_rc" -ne 0 ] &&
    ok json_accessor_validates || bad json_accessor_validates "valid=$valid_rc value=$got missing=$missing_rc invalid=$invalid_rc"
}

# --- core: probe -------------------------------------------------------------

t_probe_orders_by_speed() {
  input="$(line "$BASE/good.bin?throttle=400" sha256 "$GOOD256" raw)
$(line "$BASE/missing.bin" sha256 "$GOOD256" raw)
$(line "$BASE/good.bin" sha256 "$GOOD256" raw)"
  got="$(printf '%s\n' "$input" | lib 'probe' 2>/dev/null | cut -f1)"
  want="$BASE/good.bin
$BASE/good.bin?throttle=400
$BASE/missing.bin"
  [ "$got" = "$want" ] && ok probe_orders_by_speed ||
    bad probe_orders_by_speed "want fast,slow,failed; got: $(echo $got)"
}

t_probe_html_error_page_ranks_last() {
  input="$(line "$BASE/good.bin?status=200" sha256 "$GOOD256" raw)
$(line "$BASE/good.bin?throttle=400" sha256 "$GOOD256" raw)"
  got="$(printf '%s\n' "$input" | lib 'probe' 2>/dev/null | head -1 | cut -f1)"
  [ "$got" = "$BASE/good.bin?throttle=400" ] && ok probe_html_error_page_ranks_last ||
    bad probe_html_error_page_ranks_last "a 200 text/html page must count as a failed probe; first was $got"
}

t_probe_respects_timeout_without_range() {
  start=$(date +%s)
  printf '%s\n' "$(line "$BASE/good.bin?norange=1&throttle=100" sha256 "$GOOD256" raw)" |
    lib 'probe' >/dev/null 2>&1
  el=$(($(date +%s) - start))
  [ "$el" -le $((FASTUP_PROBE_TIMEOUT + 2)) ] && ok probe_respects_timeout_without_range ||
    bad probe_respects_timeout_without_range "took ${el}s with timeout ${FASTUP_PROBE_TIMEOUT}s"
}

t_probe_stderr_quiet() {
  printf '%s\n' "$(line "$BASE/good.bin" sha256 "$GOOD256" raw)" | lib 'probe' >/dev/null 2>"$WORK/err"
  [ ! -s "$WORK/err" ] && ok probe_stderr_quiet || bad probe_stderr_quiet "probe wrote to stderr: $(head -3 "$WORK/err")"
}

t_probe_keeps_all_candidates() {
  input="$(line "$BASE/a" sha256 x raw)
$(line "$BASE/b" sha256 x raw)"
  n="$(printf '%s\n' "$input" | lib 'probe' 2>/dev/null | grep -c .)"
  [ "$n" = 2 ] && ok probe_keeps_all_candidates || bad probe_keeps_all_candidates "kept $n of 2"
}

# --- core: fetch_verified ----------------------------------------------------

t_fetch_skips_tampered_source() {
  out="$WORK/f1"; mkdir -p "$out"
  input="$(line "$BASE/evil.bin" sha256 "$GOOD256" raw)
$(line "$BASE/good.bin" sha256 "$GOOD256" raw)"
  p="$(printf '%s\n' "$input" | lib "fetch_verified '$out'" 2>"$WORK/err")"
  [ -f "$p" ] && [ "$(sha256 "$p")" = "$GOOD256" ] && grep -qi 'mismatch\|checksum' "$WORK/err" &&
    ok fetch_skips_tampered_source || bad fetch_skips_tampered_source "payload=$p err=$(head -2 "$WORK/err")"
}

t_fetch_all_bad_fails_clean() {
  out="$WORK/f2"; mkdir -p "$out"
  input="$(line "$BASE/evil.bin" sha256 "$GOOD256" raw)
$(line "$BASE/missing.bin" sha256 "$GOOD256" raw)"
  printf '%s\n' "$input" | lib "fetch_verified '$out'" >/dev/null 2>&1
  rc=$?
  left="$(find "$out" -type f | grep -c .)"
  [ $rc -ne 0 ] && [ "$left" = 0 ] && ok fetch_all_bad_fails_clean ||
    bad fetch_all_bad_fails_clean "rc=$rc, files left=$left"
}

t_fetch_tgz_extracts_inner_path() {
  out="$WORK/f3"; mkdir -p "$out"
  p="$(line "$BASE/good.tgz" sha512 "$TGZ512" "tgz:package/bin/tool" | lib "fetch_verified '$out'" 2>/dev/null)"
  [ -x "$p" ] && [ "$("$p")" = "tool 1.2.3" ] && ok fetch_tgz_extracts_inner_path ||
    bad fetch_tgz_extracts_inner_path "payload=$p"
}

t_fetch_tgz_dir_payload() {
  out="$WORK/f4"; mkdir -p "$out"
  p="$(line "$BASE/good.tgz" sha512 "$TGZ512" "tgz:package" | lib "fetch_verified '$out'" 2>/dev/null)"
  [ -d "$p" ] && [ -x "$p/bin/tool" ] && ok fetch_tgz_dir_payload || bad fetch_tgz_dir_payload "payload=$p"
}

t_fetch_rejects_path_traversal() {
  out="$WORK/f5/inner"; mkdir -p "$out"
  line "$BASE/trav.tgz" sha512 "$TRAV512" "tgz:evil" | lib "fetch_verified '$out'" >/dev/null 2>&1
  rc=$?
  [ $rc -ne 0 ] && [ ! -e "$WORK/f5/evil" ] && ok fetch_rejects_path_traversal ||
    bad fetch_rejects_path_traversal "rc=$rc, escaped file exists: $([ -e "$WORK/f5/evil" ] && echo yes || echo no)"
}

# --- core: candidate builders ------------------------------------------------

t_gh_candidates_default_and_env() {
  got="$(FASTUP_GH_PROXIES="$BASE/p1/ $BASE/p2/" lib "gh_candidates 'https://github.com/o/r/releases/download/v1/x' sha256 abc raw" | cut -f1)"
  want="https://github.com/o/r/releases/download/v1/x
$BASE/p1/https://github.com/o/r/releases/download/v1/x
$BASE/p2/https://github.com/o/r/releases/download/v1/x"
  [ "$got" = "$want" ] && ok gh_candidates_default_and_env || bad gh_candidates_default_and_env "got: $(echo $got)"
}

t_gh_candidates_via() {
  got="$(FASTUP_GH_PROXIES="$BASE/p1/" FASTUP_VIA="$BASE/v/" lib "gh_candidates 'https://github.com/o/r/x' sha256 abc raw" | cut -f1 | sort)"
  want="$(printf '%s\n' "$BASE/v/https://github.com/o/r/x" "https://github.com/o/r/x" | sort)"
  [ "$got" = "$want" ] && ok gh_candidates_via || bad gh_candidates_via "got: $(echo $got)"
}

t_npm_candidates_use_official_integrity() {
  got="$(FASTUP_NPM_REGISTRY="$BASE/npm" FASTUP_NPM_MIRRORS="$BASE/mirror" \
    lib "npm_candidates @scope/pkg 1.2.3 tgz:package/bin/tool")"
  want="$(line "$BASE/npm/@scope/pkg/-/pkg-1.2.3.tgz" sha512 "$TGZ512" tgz:package/bin/tool)
$(line "$BASE/mirror/@scope/pkg/-/pkg-1.2.3.tgz" sha512 "$TGZ512" tgz:package/bin/tool)"
  [ "$got" = "$want" ] && ok npm_candidates_use_official_integrity ||
    bad npm_candidates_use_official_integrity "got: $got"
}

t_via_skips_probe() {
  : >"$LOG"
  input="$(line "$BASE/good.bin" sha256 "$GOOD256" raw)
$(line "$BASE/good.bin?throttle=400" sha256 "$GOOD256" raw)"
  got="$(printf '%s\n' "$input" | FASTUP_VIA="$BASE/v/" lib 'probe' 2>/dev/null | cut -f1)"
  [ "$got" = "$(printf '%s\n' "$input" | cut -f1)" ] && ! grep -q . "$LOG" && ok via_skips_probe ||
    bad via_skips_probe "with FASTUP_VIA, probe must pass input through unchanged and send no requests"
}

# --- critic fixes (plan.md "评审修订") ----------------------------------------

t_probe_follows_redirect_and_adds_speed() {
  input="$(line "$BASE/x?redirect=$BASE/good.bin" sha256 "$GOOD256" raw)"
  out="$(printf '%s\n' "$input" | lib 'probe' 2>/dev/null)"
  url="$(printf '%s' "$out" | cut -f1)"
  speed="$(printf '%s' "$out" | cut -f5)"
  [ "$url" = "$BASE/x?redirect=$BASE/good.bin" ] && [ "${speed:-0}" -gt 0 ] 2>/dev/null &&
    ok probe_follows_redirect_and_adds_speed ||
    bad probe_follows_redirect_and_adds_speed "302 source must be followed and get a 5th column speed > 0; got: $out"
}

t_fetch_aborts_stalled_source() {
  out="$WORK/f6"; mkdir -p "$out"
  # probed at 10 MB/s, actually delivers 20 KiB/s -> must be abandoned after FASTUP_STALL_TIME
  input="$(printf '%s\t%s\t%s\t%s\t%s\n' "$BASE/good.bin?throttle=20" sha256 "$GOOD256" raw 10000000)
$(printf '%s\t%s\t%s\t%s\t%s\n' "$BASE/good.bin" sha256 "$GOOD256" raw 5000000)"
  start=$(date +%s)
  p="$(printf '%s\n' "$input" | FASTUP_STALL_TIME=2 lib "fetch_verified '$out'" 2>/dev/null)"
  el=$(($(date +%s) - start))
  [ -f "$p" ] && [ "$(sha256 "$p")" = "$GOOD256" ] && [ "$el" -le 12 ] && ok fetch_aborts_stalled_source ||
    bad fetch_aborts_stalled_source "payload=$p elapsed=${el}s"
}

t_fetch_resumes_partial() {
  out="$WORK/f7"; mkdir -p "$out" "$FASTUP_STATE/partial"
  head -c 1048576 "$ROOT/good.bin" >"$FASTUP_STATE/partial/$GOOD256"
  : >"$LOG"
  p="$(line "$BASE/good.bin" sha256 "$GOOD256" raw | lib "fetch_verified '$out'" 2>/dev/null)"
  [ -f "$p" ] && [ "$(sha256 "$p")" = "$GOOD256" ] && grep -q 'bytes=1048576-' "$LOG" &&
    ok fetch_resumes_partial || bad fetch_resumes_partial "payload=$p log=$(tr '\n' '|' <"$LOG")"
  rm -rf "$FASTUP_STATE/partial"
}

t_fetch_reuses_complete_partial() {
  # a previous run left a complete, valid download behind; no source is reachable now
  out="$WORK/f11"; mkdir -p "$out" "$FASTUP_STATE/partial"
  cp "$ROOT/good.tgz" "$FASTUP_STATE/partial/$TGZ512"
  p="$(line "$BASE/gone.tgz" sha512 "$TGZ512" "tgz:package/bin/tool" | lib "fetch_verified '$out'" 2>/dev/null)"
  [ -x "$p" ] && [ ! -e "$FASTUP_STATE/partial/$TGZ512" ] && ok fetch_reuses_complete_partial ||
    bad fetch_reuses_complete_partial "a complete verified partial must be used (and then removed); payload=$p"
  rm -rf "$FASTUP_STATE/partial"
}

t_fetch_tgz_cleans_partial() {
  out="$WORK/f12"; mkdir -p "$out"
  line "$BASE/good.tgz" sha512 "$TGZ512" "tgz:package" | lib "fetch_verified '$out'" >/dev/null 2>&1
  [ ! -e "$FASTUP_STATE/partial/$TGZ512" ] && ok fetch_tgz_cleans_partial ||
    bad fetch_tgz_cleans_partial "partial left behind after a successful tgz fetch"
}

t_downloads_never_send_auth() {
  out="$WORK/f8"; mkdir -p "$out"
  : >"$LOG"
  input="$(line "$BASE/good.bin" sha256 "$GOOD256" raw)"
  printf '%s\n' "$input" | GITHUB_TOKEN=sekrit-token GH_TOKEN=sekrit-token lib 'probe' >/dev/null 2>&1
  printf '%s\n' "$input" | GITHUB_TOKEN=sekrit-token GH_TOKEN=sekrit-token lib "fetch_verified '$out'" >/dev/null 2>&1
  grep -q . "$LOG" && ! grep -q 'auth=[^-]' "$LOG" && ok downloads_never_send_auth ||
    bad downloads_never_send_auth "probe/fetch must not send Authorization: $(grep 'auth=' "$LOG" | head -2)"
}

t_npm_candidates_404_is_empty() {
  got="$(FASTUP_NPM_REGISTRY="$BASE/npm" FASTUP_NPM_MIRRORS="$BASE/mirror" \
    lib "npm_candidates @scope/pkg 9.9.9 tgz:package; echo rc=\$?" 2>/dev/null)"
  [ "$got" = "rc=0" ] && ok npm_candidates_404_is_empty ||
    bad npm_candidates_404_is_empty "unpublished version must yield zero lines and rc=0; got: $got"
}

t_fetch_rejects_escaping_symlink() {
  mkdir -p "$WORK/sym/package"
  ln -s /etc/passwd "$WORK/sym/package/link"
  tar -czf "$ROOT/sym.tgz" -C "$WORK/sym" package
  out="$WORK/f9"; mkdir -p "$out"
  p="$(line "$BASE/sym.tgz" sha512 "$(sha512 "$ROOT/sym.tgz")" "tgz:package" | lib "fetch_verified '$out'" 2>/dev/null)"
  rc=$?
  [ $rc -ne 0 ] && [ -z "$p" ] && ok fetch_rejects_escaping_symlink ||
    bad fetch_rejects_escaping_symlink "payload with a symlink to /etc/passwd must be rejected; rc=$rc p=$p"
}

t_fetch_rejects_bad_inner_path() {
  out="$WORK/f10"; mkdir -p "$out"
  line "$BASE/good.tgz" sha512 "$TGZ512" "tgz:../package" | lib "fetch_verified '$out'" >/dev/null 2>&1
  rc1=$?
  line "$BASE/good.tgz" sha512 "$TGZ512" "tgz:/package" | lib "fetch_verified '$out'" >/dev/null 2>&1
  rc2=$?
  [ $rc1 -ne 0 ] && [ $rc2 -ne 0 ] && ok fetch_rejects_bad_inner_path ||
    bad fetch_rejects_bad_inner_path "inner paths with .. or leading / must be rejected (rc=$rc1,$rc2)"
}

# --- lint ----------------------------------------------------------------------

t_shellcheck() {
  shellcheck -x "$FASTUP" >"$WORK/sc" 2>&1 && ok shellcheck || bad shellcheck "$(head -5 "$WORK/sc")"
}

t_shellcheck_disable_budget() {
  n="$(grep -c 'shellcheck disable' "$FASTUP" 2>/dev/null)"
  [ -f "$FASTUP" ] && [ "${n:-0}" -le 3 ] && ok shellcheck_disable_budget ||
    bad shellcheck_disable_budget "at most 3 '# shellcheck disable' lines (found ${n:-?})"
}

# shellcheck source=tests/providers_omp_agy.sh
. "$HERE/providers_omp_agy.sh"
# shellcheck source=tests/providers_claude_codex.sh
. "$HERE/providers_claude_codex.sh"
# shellcheck source=tests/review_fixes.sh
. "$HERE/review_fixes.sh"
# shellcheck source=tests/self_update.sh
. "$HERE/self_update.sh"

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do run "$t"; done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || { printf '  - %s\n' "${failed[@]}"; exit 1; }
