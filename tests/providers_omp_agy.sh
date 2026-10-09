# shellcheck shell=bash
# Provider tests for omp and agy. Sourced by tests/run.sh (uses its helpers and $BASE/$ROOT/$WORK/$LOG).
#
# Provider contract under test (plan.md §3 + 评审修订 4/5/10):
#   FASTUP_OMP_API       release JSON URL (default https://api.github.com/repos/can1357/oh-my-pi/releases/latest)
#   FASTUP_AGY_MANIFEST  manifest JSON URL (default the run.app manifests/darwin_<arch>.json)
#   FASTUP_GH_PROXIES="" / FASTUP_PROXIES=""  -> no accelerator candidates
#   the target is whatever `command -v omp|agy` resolves to on PATH.

# A tiny native executable that prints a fixed version string.
mkbin() { # <out> <version-output>
  printf '#include <stdio.h>\nint main(void){puts("%s");return 0;}\n' "$2" >"$WORK/v.c"
  cc -o "$1" "$WORK/v.c" 2>/dev/null
}

case "$(uname -s):$(uname -m)" in
  Darwin:arm64) OMP_ASSET=omp-darwin-arm64; AGY_MANIFEST_FILE=darwin_arm64.json ;;
  Darwin:x86_64|Darwin:amd64) OMP_ASSET=omp-darwin-x64; AGY_MANIFEST_FILE=darwin_amd64.json ;;
  Linux:arm64|Linux:aarch64)
    AGY_MANIFEST_FILE=linux_arm64.json
    if ldd --version 2>&1 | head -n 1 | grep -qi musl; then OMP_ASSET=omp-linux-musl-arm64
    else OMP_ASSET=omp-linux-arm64; fi
    ;;
  Linux:x86_64|Linux:amd64)
    AGY_MANIFEST_FILE=linux_amd64.json
    if ldd --version 2>&1 | head -n 1 | grep -qi musl; then OMP_ASSET=omp-linux-musl-x64
    else OMP_ASSET=omp-linux-x64; fi
    ;;
  *) echo "unsupported test platform: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$ROOT/omp" "$ROOT/agy/pkg"
mkbin "$ROOT/omp/$OMP_ASSET" "omp/18.8.4"
mkbin "$ROOT/omp/wrong" "omp/0.0.1"
OMP_NEW256="$(sha256 "$ROOT/omp/$OMP_ASSET")"
OMP_WRONG256="$(sha256 "$ROOT/omp/wrong")"
omp_release() { # <tag> <asset-url> <sha256>
  printf '{"tag_name":"%s","assets":[{"name":"%s","digest":"sha256:%s","browser_download_url":"%s"}]}\n' \
    "$1" "$OMP_ASSET" "$3" "$2" >"$ROOT/omp/latest.json"
}

mkbin "$ROOT/agy/pkg/antigravity" "1.3.1"
tar -czf "$ROOT/agy/cli.tar.gz" -C "$ROOT/agy/pkg" antigravity
AGY512="$(sha512 "$ROOT/agy/cli.tar.gz")"
mkdir -p "$ROOT/agy/wrongpkg"
mkbin "$ROOT/agy/wrongpkg/antigravity" "0.0.1"
tar -czf "$ROOT/agy/wrong.tar.gz" -C "$ROOT/agy/wrongpkg" antigravity
AGYWRONG512="$(sha512 "$ROOT/agy/wrong.tar.gz")"
agy_manifest() { # <version> <url> <sha512>
  printf '{"version":"%s","url":"%s","sha512":"%s"}\n' "$1" "$2" "$3" >"$ROOT/agy/$AGY_MANIFEST_FILE"
}

# Fresh fake install: <cli> <version-output> -> sets BIN (dir on PATH) and TARGET
fake_install() {
  BIN="$(mktemp -d "$WORK/bin.XXXXXX")"
  TARGET="$BIN/$1"
  mkbin "$TARGET" "$2"
}

t_native_binary_layout() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  fake_install omp "omp/18.8.4"
  fu --check omp >/dev/null 2>&1; rc=$?
  magic="$(od -An -tx1 -N4 "$TARGET" | tr -d ' \n')"
  case "$(uname -s):$magic" in
    Darwin:cffaedfe|Darwin:cefaedfe|Darwin:cafebabe|Linux:7f454c46) ;;
    *) rc=1 ;;
  esac
  [ "$rc" -eq 0 ] && ok native_binary_layout || bad native_binary_layout "rc=$rc magic=$magic"
}

fu() { # run fastup with the fake install first on PATH
  PATH="$BIN:$PATH" FASTUP_OMP_API="$BASE/omp/latest.json" \
    FASTUP_AGY_MANIFEST="$BASE/agy/$AGY_MANIFEST_FILE" \
    FASTUP_GH_PROXIES="" FASTUP_PROXIES="" "${TEST_BASH:-/bin/bash}" "$FASTUP" "$@"
}

# --- omp -----------------------------------------------------------------------

t_omp_updates() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  fake_install omp "omp/18.8.3"
  fu omp >"$WORK/out" 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$("$TARGET" --version)" = "omp/18.8.4" ] && [ ! -e "$TARGET.fastup-bak" ] && [ ! -L "$TARGET" ] &&
    ok omp_updates || bad omp_updates "rc=$rc now=$("$TARGET" --version) out=$(tail -3 "$WORK/out")"
}

t_omp_already_latest_no_download() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  fake_install omp "omp/18.8.4"
  : >"$LOG"
  fu omp >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && ! grep -q "/omp/$OMP_ASSET" "$LOG" && ok omp_already_latest_no_download ||
    bad omp_already_latest_no_download "rc=$rc, asset requested: $(grep -c "/omp/$OMP_ASSET" "$LOG")"
}

t_omp_no_downgrade() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  fake_install omp "omp/18.10.0"
  fu omp >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$("$TARGET" --version)" = "omp/18.10.0" ] && ok omp_no_downgrade ||
    bad omp_no_downgrade "rc=$rc now=$("$TARGET" --version) (18.10.0 > 18.8.4 must not be replaced)"
}

t_omp_check_reports_update() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  fake_install omp "omp/18.8.3"
  fu --check omp >/dev/null 2>&1; rc=$?
  [ $rc -eq 10 ] && [ "$("$TARGET" --version)" = "omp/18.8.3" ] && ok omp_check_reports_update ||
    bad omp_check_reports_update "rc=$rc (want 10, target untouched)"
}

t_omp_symlink_target_unsupported() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  fake_install omp "omp/18.8.3"
  mv "$TARGET" "$BIN/real-omp"; ln -s "$BIN/real-omp" "$TARGET"
  fu omp >/dev/null 2>&1; rc=$?
  [ $rc -eq 3 ] && [ -L "$TARGET" ] && [ "$("$TARGET" --version)" = "omp/18.8.3" ] &&
    ok omp_symlink_target_unsupported || bad omp_symlink_target_unsupported "rc=$rc (want 3, symlink untouched)"
}

t_omp_script_target_unsupported() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  BIN="$(mktemp -d "$WORK/bin.XXXXXX")"; TARGET="$BIN/omp"
  printf '#!/bin/sh\necho omp/18.8.3\n' >"$TARGET"; chmod +x "$TARGET"
  fu omp >/dev/null 2>&1; rc=$?
  [ $rc -eq 3 ] && head -c 2 "$TARGET" | grep -q '#!' && ok omp_script_target_unsupported ||
    bad omp_script_target_unsupported "rc=$rc (a non-Mach-O shim must not be overwritten)"
}

t_omp_rollback_on_wrong_version() {
  # official digest matches, but the binary reports an unexpected version -> roll back
  omp_release v18.8.4 "$BASE/omp/wrong" "$OMP_WRONG256"
  fake_install omp "omp/18.8.3"
  fu omp >/dev/null 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$("$TARGET" --version)" = "omp/18.8.3" ] && [ ! -e "$TARGET.fastup-bak" ] &&
    ok omp_rollback_on_wrong_version || bad omp_rollback_on_wrong_version "rc=$rc now=$("$TARGET" --version)"
}

t_omp_metadata_never_prefixed() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  fake_install omp "omp/18.8.3"
  : >"$LOG"
  PATH="$BIN:$PATH" FASTUP_OMP_API="$BASE/omp/latest.json" FASTUP_GH_PROXIES="" \
    "${TEST_BASH:-/bin/bash}" "$FASTUP" --via "$BASE/via/" omp >/dev/null 2>&1
  grep -q ' /omp/latest.json ' "$LOG" && ! grep -q '/via/.*latest.json' "$LOG" &&
    ok omp_metadata_never_prefixed || bad omp_metadata_never_prefixed "release JSON must go to the official URL even with --via"
}

# --- agy -----------------------------------------------------------------------

t_agy_updates() {
  agy_manifest 1.3.1 "$BASE/agy/cli.tar.gz" "$AGY512"
  fake_install agy "1.2.16"
  fu agy >"$WORK/out" 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$("$TARGET" --version)" = "1.3.1" ] && [ ! -e "$TARGET.fastup-bak" ] &&
    ok agy_updates || bad agy_updates "rc=$rc now=$("$TARGET" --version) out=$(tail -3 "$WORK/out")"
}

t_agy_already_latest_no_download() {
  agy_manifest 1.3.1 "$BASE/agy/cli.tar.gz" "$AGY512"
  fake_install agy "1.3.1"
  : >"$LOG"
  fu agy >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && ! grep -q '/agy/cli.tar.gz' "$LOG" && ok agy_already_latest_no_download ||
    bad agy_already_latest_no_download "rc=$rc"
}

t_agy_rollback_on_wrong_version() {
  agy_manifest 1.3.1 "$BASE/agy/wrong.tar.gz" "$AGYWRONG512"
  fake_install agy "1.2.16"
  fu agy >/dev/null 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$("$TARGET" --version)" = "1.2.16" ] && ok agy_rollback_on_wrong_version ||
    bad agy_rollback_on_wrong_version "rc=$rc now=$("$TARGET" --version)"
}

t_agy_check_reports_update() {
  agy_manifest 1.3.1 "$BASE/agy/cli.tar.gz" "$AGY512"
  fake_install agy "1.2.16"
  fu --check agy >/dev/null 2>&1; rc=$?
  [ $rc -eq 10 ] && [ "$("$TARGET" --version)" = "1.2.16" ] && ok agy_check_reports_update ||
    bad agy_check_reports_update "rc=$rc (want 10)"
}

t_agy_googleapis_candidate() {
  # a storage.googleapis.com URL must also yield the www.googleapis.com JSON-API download candidate
  got="$(lib "agy_candidates_for 'https://storage.googleapis.com/antigravity-public/antigravity-cli/1.3.1-1/darwin-arm/cli_mac_arm64.tar.gz' abc" 2>/dev/null | cut -f1)"
  printf '%s\n' "$got" | grep -qx 'https://storage.googleapis.com/antigravity-public/antigravity-cli/1.3.1-1/darwin-arm/cli_mac_arm64.tar.gz' &&
    printf '%s\n' "$got" | grep -qx 'https://www.googleapis.com/download/storage/v1/b/antigravity-public/o/antigravity-cli%2F1.3.1-1%2Fdarwin-arm%2Fcli_mac_arm64.tar.gz?alt=media' &&
    ok agy_googleapis_candidate || bad agy_googleapis_candidate "got: $(echo $got)"
}

t_all_returns_worst_code() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  agy_manifest 1.3.1 "$BASE/agy/cli.tar.gz" "$AGY512"
  BIN="$(mktemp -d "$WORK/bin.XXXXXX")"
  mkbin "$BIN/omp" "omp/18.8.3"
  ln -s "$BIN/omp" "$BIN/agy"   # agy: unsupported layout -> 3
  fu omp agy >/dev/null 2>&1; rc=$?
  [ $rc -eq 3 ] && [ "$("$BIN/omp" --version)" = "omp/18.8.4" ] && ok all_returns_worst_code ||
    bad all_returns_worst_code "rc=$rc (want 3; omp must still be updated)"
}

t_no_payload_left_behind() {
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  fake_install omp "omp/18.8.3"
  st="$(mktemp -d "$WORK/st.XXXXXX")"
  FASTUP_STATE="$st" fu omp >/dev/null 2>&1; rc=$?
  left="$(find "$st" -type f 2>/dev/null | grep -v '/locks/' | grep -c .)"
  [ $rc -eq 0 ] && [ "$left" = 0 ] && ok no_payload_left_behind ||
    bad no_payload_left_behind "rc=$rc, files left under FASTUP_STATE: $(find "$st" -type f | head -3)"
}
