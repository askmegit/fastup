# shellcheck shell=bash
# `fastup self` tests. Sourced by tests/run.sh after the provider tests.
#
# Contract:
#   FASTUP_SELF_API  release JSON URL (default https://api.github.com/repos/askmegit/fastup/releases/latest);
#                    asset "fastup" with "digest":"sha256:<hex>" and browser_download_url.
#   The target is the running script itself (symlinks resolved). Under a Homebrew Cellar path it refuses
#   with exit 3 and points at `brew upgrade fastup`. `all` never includes self.

mkdir -p "$ROOT/self"
# A release copy of fastup that reports 9.9.9.
sed 's/^FASTUP_VERSION=.*/FASTUP_VERSION=9.9.9/' "$FASTUP" >"$ROOT/self/fastup"
SELF_NEW256="$(sha256 "$ROOT/self/fastup")"
# A "release" that claims 9.9.9 but whose script reports 9.9.8.
sed 's/^FASTUP_VERSION=.*/FASTUP_VERSION=9.9.8/' "$FASTUP" >"$ROOT/self/liar"
SELF_LIAR256="$(sha256 "$ROOT/self/liar")"

self_release() { # <tag> <asset-url> <sha256>
  printf '{"tag_name":"%s","assets":[{"name":"fastup","digest":"sha256:%s","browser_download_url":"%s"}]}\n' \
    "$1" "$3" "$2" >"$ROOT/self/latest.json"
}

self_copy() { # [subdir] -> sets SELF (an installed copy of the current fastup)
  local d
  d="$(mktemp -d "$WORK/self.XXXXXX")/${1:-bin}"
  mkdir -p "$d"
  SELF="$d/fastup"
  cp "$FASTUP" "$SELF"; chmod 755 "$SELF"
}

fu_self() {
  FASTUP_SELF_API="$BASE/self/latest.json" FASTUP_GH_PROXIES="" FASTUP_PROXIES="" \
    "${TEST_BASH:-/bin/bash}" "$SELF" "$@"
}

self_version() { "${TEST_BASH:-/bin/bash}" "$SELF" --version 2>/dev/null; }

t_self_updates() {
  self_release v9.9.9 "$BASE/self/fastup" "$SELF_NEW256"
  self_copy
  fu_self self >"$WORK/out" 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$(self_version)" = "fastup 9.9.9" ] && [ -x "$SELF" ] &&
    [ -z "$(find "$(dirname "$SELF")" -mindepth 1 ! -name fastup)" ] && ok self_updates ||
    bad self_updates "rc=$rc now=$(self_version) out=$(tail -3 "$WORK/out" | tr '\n' '|') dir=$(ls -A "$(dirname "$SELF")" | tr '\n' ' ')"
}

t_self_interrupt_cleans_temp() {
  self_release v9.9.9 "$BASE/self/fastup" "$SELF_NEW256"
  self_copy
  self_dir="$(cd "$(dirname "$SELF")" && pwd -P)"
  before="$(sha256 "$SELF")"
  marker="$WORK/self-copy.marker"
  slow_bin="$(mktemp -d "$WORK/slow-cp.XXXXXX")"
  printf '#!/bin/sh\nlast=\nfor arg do last="$arg"; done\n/bin/cp "$@"\ncase "$last" in\n  "$FASTUP_SELF_TMP_DIR"/.fastup.*) : >"$FASTUP_SELF_TMP_MARKER"; sleep 30 ;;\nesac\n' >"$slow_bin/cp"
  chmod 755 "$slow_bin/cp"
  FASTUP_SELF_API="$BASE/self/latest.json" FASTUP_GH_PROXIES="" FASTUP_PROXIES="" \
    FASTUP_STATE="$WORK/self-state" FASTUP_SELF_TMP_DIR="$self_dir" FASTUP_SELF_TMP_MARKER="$marker" \
    PATH="$slow_bin:$PATH" "${TEST_BASH:-/bin/bash}" "$SELF" self >"$WORK/out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [ -e "$marker" ] && break; sleep 0.1; done
  if [ -e "$marker" ]; then
    pkill -TERM -P "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
  else
    kill -TERM "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
  left="$(find "$self_dir" -mindepth 1 ! -name fastup -print)"
  [ -e "$marker" ] && [ "$(sha256 "$SELF")" = "$before" ] && [ -z "$left" ] && ok self_interrupt_cleans_temp ||
    bad self_interrupt_cleans_temp "marker=$([ -e "$marker" ] && echo yes || echo no) original=$([ "$(sha256 "$SELF")" = "$before" ] && echo unchanged || echo changed) left=$(printf '%s' "$left" | tr '\n' ' ')"
}

t_self_follows_symlink() {
  self_release v9.9.9 "$BASE/self/fastup" "$SELF_NEW256"
  self_copy
  link="$(dirname "$SELF")/../fastup-link"
  ln -s "$SELF" "$link"
  FASTUP_SELF_API="$BASE/self/latest.json" FASTUP_GH_PROXIES="" FASTUP_PROXIES="" \
    "${TEST_BASH:-/bin/bash}" "$link" self >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && [ -L "$link" ] && [ "$(self_version)" = "fastup 9.9.9" ] && ok self_follows_symlink ||
    bad self_follows_symlink "rc=$rc; the symlink must stay a symlink and its target must be updated"
}

t_self_check_reports_update() {
  self_release v9.9.9 "$BASE/self/fastup" "$SELF_NEW256"
  self_copy
  before="$(sha256 "$SELF")"
  fu_self --check self >/dev/null 2>&1; rc=$?
  [ $rc -eq 10 ] && [ "$(sha256 "$SELF")" = "$before" ] && ok self_check_reports_update ||
    bad self_check_reports_update "rc=$rc (want 10, file untouched)"
}

t_self_already_latest_no_download() {
  cur="$("$FASTUP" --version | awk '{print $2}')"
  self_release "v$cur" "$BASE/self/fastup?self-latest" "$SELF_NEW256"
  self_copy
  : >"$LOG"
  fu_self self >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && ! grep -q 'self-latest' "$LOG" && [ "$(sha256 "$SELF")" = "$(sha256 "$FASTUP")" ] &&
    ok self_already_latest_no_download || bad self_already_latest_no_download "rc=$rc"
}

t_self_rejects_wrong_version_payload() {
  self_release v9.9.9 "$BASE/self/liar" "$SELF_LIAR256"
  self_copy
  before="$(sha256 "$SELF")"
  fu_self self >/dev/null 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(sha256 "$SELF")" = "$before" ] && [ -z "$(find "$(dirname "$SELF")" -mindepth 1 ! -name fastup)" ] &&
    ok self_rejects_wrong_version_payload || bad self_rejects_wrong_version_payload "rc=$rc (payload says 9.9.8, release says 9.9.9)"
}

t_self_rejects_bad_checksum() {
  self_release v9.9.9 "$BASE/self/fastup" "$SELF_LIAR256"
  self_copy
  before="$(sha256 "$SELF")"
  fu_self self >/dev/null 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(sha256 "$SELF")" = "$before" ] && ok self_rejects_bad_checksum ||
    bad self_rejects_bad_checksum "rc=$rc"
}

t_self_refuses_homebrew() {
  self_release v9.9.9 "$BASE/self/fastup" "$SELF_NEW256"
  self_copy Cellar/fastup/0.1.0/bin
  before="$(sha256 "$SELF")"
  fu_self self >/dev/null 2>"$WORK/err"; rc=$?
  [ $rc -eq 3 ] && [ "$(sha256 "$SELF")" = "$before" ] && grep -q 'brew upgrade fastup' "$WORK/err" &&
    ok self_refuses_homebrew || bad self_refuses_homebrew "rc=$rc err=$(head -2 "$WORK/err")"
}

t_self_not_in_all() {
  self_release v9.9.9 "$BASE/self/fastup" "$SELF_NEW256"
  self_copy
  before="$(sha256 "$SELF")"
  # no CLIs on PATH beyond the system ones: every provider is skipped as not installed
  HOME="$WORK/nohome" PATH="/usr/bin:/bin" FASTUP_SELF_API="$BASE/self/latest.json" FASTUP_GH_PROXIES="" \
    FASTUP_PROXIES="" "${TEST_BASH:-/bin/bash}" "$SELF" all >"$WORK/out" 2>&1
  [ "$(sha256 "$SELF")" = "$before" ] && ! grep -q '^self' "$WORK/out" && ok self_not_in_all ||
    bad self_not_in_all "fastup all must not touch fastup itself: $(head -5 "$WORK/out" | tr '\n' '|')"
}

t_self_usage_lists_self() {
  "$FASTUP" --help 2>&1 | grep -q 'self' && ok self_usage_lists_self || bad self_usage_lists_self "--help must mention self"
}
