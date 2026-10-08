# shellcheck shell=bash
# Provider tests for claude and codex. Sourced by tests/run.sh after providers_omp_agy.sh (uses mkbin).
#
# Provider contract under test (plan.md §3 + 评审修订 5/7/8):
#   claude: FASTUP_CLAUDE_BASE (default https://downloads.claude.ai/claude-code-releases);
#           <base>/<channel> -> version text, channel from $HOME/.claude/settings.json autoUpdatesChannel (default latest);
#           <base>/<v>/manifest.json platforms.<p>.checksum (sha256 of the bare binary); binary at <base>/<v>/<p>/claude.
#           Layout: $HOME/.local/bin/claude is a symlink into $HOME/.local/share/claude/versions/; anything else -> exit 3.
#   codex:  FASTUP_CODEX_RELEASES (default https://releases.openai.com/codex); <base>/channels/latest is
#           {"tag_name":"rust-v<v>","assets":[{"name","digest":"sha256:..","browser_download_url"}]}.
#           FASTUP_CODEX_GITHUB (default https://github.com/openai/codex/releases/download) for the GitHub copy.
#           Layout: ${CODEX_HOME:-$HOME/.codex}/packages/standalone with `current` symlink; otherwise exit 3.
#           After staging releases/<v>-<target>, runs `sh -c "$FASTUP_CODEX_UPDATE_CMD"` (default: the
#           standalone codex binary's `update`), then requires current -> the staged dir and --version == v.
#   npm candidates are disabled here by pointing FASTUP_NPM_REGISTRY at a 404.

case "$(uname -m)" in arm64) CL_PLAT=darwin-arm64; CX_TARGET=aarch64-apple-darwin ;; *) CL_PLAT=darwin-x64; CX_TARGET=x86_64-apple-darwin ;; esac

# --- claude fixtures -----------------------------------------------------------
claude_release() { # <version> [<binary-version-output>]
  mkdir -p "$ROOT/claude/$1/$CL_PLAT"
  mkbin "$ROOT/claude/$1/$CL_PLAT/claude" "${2:-$1} (Claude Code)"
  printf '{"version":"%s","platforms":{"%s":{"binary":"claude","checksum":"%s"}}}\n' \
    "$1" "$CL_PLAT" "$(sha256 "$ROOT/claude/$1/$CL_PLAT/claude")" >"$ROOT/claude/$1/manifest.json"
}
claude_release 2.1.294
claude_release 2.1.286
claude_release 2.1.295 2.1.999   # binary lies about its version
printf '2.1.294\n' >"$ROOT/claude/latest"
printf '2.1.286\n' >"$ROOT/claude/stable"

claude_home() { # <installed-version> -> sets CHOME
  CHOME="$(mktemp -d "$WORK/chome.XXXXXX")"
  mkdir -p "$CHOME/.local/bin" "$CHOME/.local/share/claude/versions"
  mkbin "$CHOME/.local/share/claude/versions/$1" "$1 (Claude Code)"
  ln -s "$CHOME/.local/share/claude/versions/$1" "$CHOME/.local/bin/claude"
}

fu_claude() {
  HOME="$CHOME" FASTUP_CLAUDE_BASE="$BASE/claude" FASTUP_NPM_REGISTRY="$BASE/no-npm" \
    FASTUP_STATE="$CHOME/.cache/fastup" "${TEST_BASH:-/bin/bash}" "$FASTUP" "$@"
}

claude_now() { "$CHOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}'; }

t_claude_updates() {
  claude_home 2.1.293
  fu_claude claude >"$WORK/out" 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$(claude_now)" = 2.1.294 ] && [ -L "$CHOME/.local/bin/claude" ] &&
    [ -x "$CHOME/.local/share/claude/versions/2.1.294" ] && ok claude_updates ||
    bad claude_updates "rc=$rc now=$(claude_now) out=$(tail -3 "$WORK/out")"
}

t_claude_already_latest_no_download() {
  claude_home 2.1.294
  : >"$LOG"
  fu_claude claude >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && ! grep -q "/claude/2.1.294/$CL_PLAT/claude" "$LOG" && ok claude_already_latest_no_download ||
    bad claude_already_latest_no_download "rc=$rc"
}

t_claude_follows_stable_channel() {
  claude_home 2.1.280
  mkdir -p "$CHOME/.claude"
  printf '{"autoUpdatesChannel": "stable"}\n' >"$CHOME/.claude/settings.json"
  fu_claude claude >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$(claude_now)" = 2.1.286 ] && ok claude_follows_stable_channel ||
    bad claude_follows_stable_channel "rc=$rc now=$(claude_now) (stable channel is 2.1.286)"
}

t_claude_no_downgrade() {
  claude_home 2.1.300
  fu_claude claude >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$(claude_now)" = 2.1.300 ] && ok claude_no_downgrade || bad claude_no_downgrade "rc=$rc now=$(claude_now)"
}

t_claude_non_native_layout() {
  claude_home 2.1.293
  rm "$CHOME/.local/bin/claude"
  mkbin "$CHOME/.local/bin/claude" "2.1.293 (Claude Code)"
  fu_claude claude >/dev/null 2>&1; rc=$?
  [ $rc -eq 3 ] && [ ! -L "$CHOME/.local/bin/claude" ] && ok claude_non_native_layout ||
    bad claude_non_native_layout "rc=$rc (a non-symlink claude must be left alone, exit 3)"
}

t_claude_rollback_on_wrong_version() {
  claude_home 2.1.293
  printf '2.1.295\n' >"$ROOT/claude/latest"
  fu_claude claude >/dev/null 2>&1; rc=$?
  printf '2.1.294\n' >"$ROOT/claude/latest"
  [ $rc -eq 1 ] && [ "$(claude_now)" = 2.1.293 ] && ok claude_rollback_on_wrong_version ||
    bad claude_rollback_on_wrong_version "rc=$rc now=$(claude_now) (link must point back to 2.1.293)"
}

# --- codex fixtures ------------------------------------------------------------
codex_release() { # <version>
  local d="$WORK/cxpkg-$1"
  mkdir -p "$d/bin" "$d/codex-path" "$d/codex-resources"
  mkbin "$d/bin/codex" "codex-cli $1"
  mkbin "$d/bin/codex-code-mode-host" "host"
  mkbin "$d/codex-path/rg" "rg"
  printf '{"layoutVersion":1,"version":"%s","target":"%s","entrypoint":"bin/codex"}\n' "$1" "$CX_TARGET" >"$d/codex-package.json"
  mkdir -p "$ROOT/codex/releases/$1" "$ROOT/codex/channels"
  local asset="codex-package-$CX_TARGET.tar.gz"
  tar -czf "$ROOT/codex/releases/$1/$asset" -C "$d" .
  printf '{"tag_name":"rust-v%s","assets":[{"name":"%s","digest":"sha256:%s","browser_download_url":"%s"}]}\n' \
    "$1" "$asset" "$(sha256 "$ROOT/codex/releases/$1/$asset")" "$BASE/codex/releases/$1/$asset" >"$ROOT/codex/channels/latest"
}
codex_release 0.161.0

codex_home() { # <installed-version> -> sets XHOME (CODEX_HOME) and SROOT
  XHOME="$(mktemp -d "$WORK/xhome.XXXXXX")"
  SROOT="$XHOME/packages/standalone"
  mkdir -p "$SROOT/releases/$1-$CX_TARGET/bin"
  mkbin "$SROOT/releases/$1-$CX_TARGET/bin/codex" "codex-cli $1"
  ln -s "$SROOT/releases/$1-$CX_TARGET" "$SROOT/current"
  printf '%s' "$1-$CX_TARGET" >"$SROOT/auto-update-version"
}

# Stand-in for the official `codex update`: switches current to the staged dir if it is complete.
SWITCH_CMD='d="$CODEX_HOME/packages/standalone/releases/0.161.0-'"$CX_TARGET"'"; [ -x "$d/bin/codex" ] && ln -sfn "$d" "$CODEX_HOME/packages/standalone/current"'

fu_codex() {
  CODEX_HOME="$XHOME" HOME="$XHOME" FASTUP_CODEX_RELEASES="$BASE/codex" FASTUP_CODEX_GITHUB="$BASE/no-gh" \
    FASTUP_NPM_REGISTRY="$BASE/no-npm" FASTUP_GH_PROXIES="" FASTUP_STATE="$XHOME/.cache/fastup" \
    "${TEST_BASH:-/bin/bash}" "$FASTUP" "$@"
}

codex_now() { "$SROOT/current/bin/codex" --version 2>/dev/null | awk '{print $NF}'; }

t_codex_updates() {
  codex_home 0.160.1
  FASTUP_CODEX_UPDATE_CMD="$SWITCH_CMD" fu_codex codex >"$WORK/out" 2>&1; rc=$?
  staged="$SROOT/releases/0.161.0-$CX_TARGET"
  [ $rc -eq 0 ] && [ "$(codex_now)" = 0.161.0 ] && [ -x "$staged/codex-path/rg" ] &&
    [ "$(readlink "$staged/codex")" = bin/codex ] && ok codex_updates ||
    bad codex_updates "rc=$rc now=$(codex_now) out=$(tail -3 "$WORK/out")"
}

t_codex_update_cmd_must_switch() {
  codex_home 0.160.1
  FASTUP_CODEX_UPDATE_CMD="true" fu_codex codex >/dev/null 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(codex_now)" = 0.160.1 ] && ok codex_update_cmd_must_switch ||
    bad codex_update_cmd_must_switch "rc=$rc (official update left current alone -> must report failure)"
}

t_codex_not_standalone() {
  XHOME="$(mktemp -d "$WORK/xhome.XXXXXX")"; SROOT="$XHOME/packages/standalone"
  FASTUP_CODEX_UPDATE_CMD="$SWITCH_CMD" fu_codex codex >/dev/null 2>&1; rc=$?
  [ $rc -eq 3 ] && [ ! -d "$SROOT/releases" ] && ok codex_not_standalone || bad codex_not_standalone "rc=$rc (want 3)"
}

t_codex_already_latest_no_download() {
  codex_home 0.161.0
  : >"$LOG"
  FASTUP_CODEX_UPDATE_CMD="$SWITCH_CMD" fu_codex codex >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && ! grep -q "codex-package-$CX_TARGET.tar.gz" "$LOG" && ok codex_already_latest_no_download ||
    bad codex_already_latest_no_download "rc=$rc"
}

t_all_skips_not_installed() {
  # only omp is installed; claude/codex/agy are absent -> `all` must skip them and succeed
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  BIN="$(mktemp -d "$WORK/bin.XXXXXX")"
  mkbin "$BIN/omp" "omp/18.8.4"
  empty="$(mktemp -d "$WORK/empty.XXXXXX")"
  HOME="$empty" CODEX_HOME="$empty/.codex" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    FASTUP_OMP_API="$BASE/omp/latest.json" FASTUP_CLAUDE_BASE="$BASE/claude" FASTUP_CODEX_RELEASES="$BASE/codex" \
    FASTUP_AGY_MANIFEST="$BASE/agy/darwin_$AGY_ARCH.json" FASTUP_NPM_REGISTRY="$BASE/no-npm" \
    FASTUP_GH_PROXIES="" FASTUP_PROXIES="" FASTUP_STATE="$empty/state" \
    "${TEST_BASH:-/bin/bash}" "$FASTUP" all >"$WORK/out" 2>&1; rc=$?
  [ $rc -eq 0 ] && grep -q 'claude: not installed' "$WORK/out" && grep -q 'agy: not installed' "$WORK/out" &&
    ok all_skips_not_installed || bad all_skips_not_installed "rc=$rc out=$(tr '\n' '|' <"$WORK/out")"
}

t_explicit_not_installed_is_3() {
  empty="$(mktemp -d "$WORK/empty.XXXXXX")"
  HOME="$empty" PATH="/usr/bin:/bin" FASTUP_STATE="$empty/state" \
    "${TEST_BASH:-/bin/bash}" "$FASTUP" agy >/dev/null 2>&1; rc=$?
  [ $rc -eq 3 ] && ok explicit_not_installed_is_3 || bad explicit_not_installed_is_3 "rc=$rc (want 3)"
}
