# shellcheck shell=bash
# Regression tests for the pre-publication review (2026-10-08). Sourced by tests/run.sh after the provider
# tests (uses mkbin, omp_release, fake_install, fu, SWITCH_CMD, codex_home, fu_codex, codex_now).

# --- group A: probe / fetch / CLI -----------------------------------------------

t_via_candidate_first() { # review #1
  got="$(FASTUP_VIA="$BASE/v/" lib "gh_candidates 'https://github.com/o/r/x' sha256 abc raw" | cut -f1)"
  want="$BASE/v/https://github.com/o/r/x
https://github.com/o/r/x"
  [ "$got" = "$want" ] && ok via_candidate_first || bad via_candidate_first "--via prefix must come first; got: $(echo $got)"
}

t_fetch_caps_size() { # review #4
  out="$WORK/r4"; mkdir -p "$out"
  line "$BASE/good.bin" sha256 "$GOOD256" raw | FASTUP_MAX_BYTES=1000000 lib "fetch_verified '$out'" >/dev/null 2>&1
  rc=$?
  [ $rc -ne 0 ] && ok fetch_caps_size || bad fetch_caps_size "a 3 MB download must be refused with FASTUP_MAX_BYTES=1000000"
}

t_stall_switches_after_one_window() { # review #5
  out="$WORK/r5"; mkdir -p "$out"
  input="$(printf '%s\t%s\t%s\t%s\t%s\n' "$BASE/good.bin?throttle=20" sha256 "$GOOD256" raw 10000000)
$(printf '%s\t%s\t%s\t%s\t%s\n' "$BASE/good.bin" sha256 "$GOOD256" raw 5000000)"
  start=$(date +%s)
  p="$(printf '%s\n' "$input" | FASTUP_STALL_TIME=3 lib "fetch_verified '$out'" 2>/dev/null)"
  el=$(($(date +%s) - start))
  rm -rf "$FASTUP_STATE/partial"
  [ -f "$p" ] && [ "$el" -le 7 ] && ok stall_switches_after_one_window ||
    bad stall_switches_after_one_window "took ${el}s with FASTUP_STALL_TIME=3 (curl --retry must not re-run a stalled source)"
}

t_check_failure_beats_update() { # review #7
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  BIN="$(mktemp -d "$WORK/bin.XXXXXX")"
  mkbin "$BIN/omp" "omp/18.8.3"          # outdated -> 10
  ln -s "$BIN/omp" "$BIN/agy"            # unsupported -> 3
  fu --check omp agy >/dev/null 2>&1; rc=$?
  [ $rc -eq 3 ] && ok check_failure_beats_update || bad check_failure_beats_update "rc=$rc (want 3: 1 > 3 > 10 > 0)"
}

t_interrupt_cleans_up() { # review #8
  omp_release v18.8.4 "$BASE/good.bin?throttle=50" "$GOOD256"   # 3 MB at 50 KiB/s: still downloading at t=3s
  fake_install omp "omp/18.8.3"
  st="$(mktemp -d "$WORK/st.XXXXXX")"
  # run fastup itself in the background (not the fu function, whose $! would be a wrapper subshell)
  PATH="$BIN:$PATH" FASTUP_OMP_API="$BASE/omp/latest.json" FASTUP_GH_PROXIES="" FASTUP_STATE="$st" \
    FASTUP_PROBE_TIMEOUT=1 "${TEST_BASH:-/bin/bash}" "$FASTUP" omp >/dev/null 2>&1 &
  pid=$!
  sleep 3
  # like Ctrl-C, signal the whole job (curl too); SIGTERM because background jobs ignore SIGINT here
  pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  left="$(find "$st" -maxdepth 1 \( -name 'payload.*' -o -name 'probe.*' \) | grep -c .)"
  [ "$left" = 0 ] && ok interrupt_cleans_up || bad interrupt_cleans_up "left behind after SIGTERM: $(find "$st" -maxdepth 1 | tail -3 | tr '\n' ' ')"
}

t_probe_no_content_type() { # review #9
  # throttled to ~300 KiB/s; with a missing Content-Type the fields must not shift and inflate the speed
  sp="$(line "$BASE/good.bin?throttle=300&notype=1" sha256 "$GOOD256" raw | lib 'probe' 2>/dev/null | cut -f5)"
  [ "${sp:-0}" -gt 0 ] 2>/dev/null && [ "$sp" -lt 1000000 ] && ok probe_no_content_type ||
    bad probe_no_content_type "measured ${sp} B/s for a ~307200 B/s source"
}

t_fetch_rejects_glob_symlink() { # review #10
  mkdir -p "$WORK/gsym/package" "$WORK/gcwd/a" "$WORK/gcwd/b" "$WORK/gcwd/c"
  ln -s '*/../../../evil' "$WORK/gsym/package/link"
  tar -czf "$ROOT/gsym.tgz" -C "$WORK/gsym" package
  out="$WORK/r10"; mkdir -p "$out"
  p="$(line "$BASE/gsym.tgz" sha512 "$(sha512 "$ROOT/gsym.tgz")" "tgz:package" |
    lib "cd '$WORK/gcwd' && fetch_verified '$out'" 2>/dev/null)"
  rc=$?
  [ $rc -ne 0 ] && [ -z "$p" ] && ok fetch_rejects_glob_symlink ||
    bad fetch_rejects_glob_symlink "link '*/../../../evil' escapes the payload; glob expansion must not hide it (rc=$rc)"
}

t_version_prerelease_lower() { # review #11
  lib 'fastup_version_gt 0.162.0 0.162.0-alpha.1'; a=$?
  lib 'fastup_version_gt 0.162.0-alpha.1 0.162.0'; b=$?
  lib 'fastup_version_gt 0.162.0-alpha.2 0.162.0-alpha.1'; c=$?
  [ $a -eq 0 ] && [ $b -ne 0 ] && [ $c -eq 0 ] && ok version_prerelease_lower ||
    bad version_prerelease_lower "release > its prerelease, alpha.2 > alpha.1 (got $a,$b,$c)"
}

t_force_repairs_broken_install() { # review #11
  omp_release v18.8.4 "$BASE/omp/$OMP_ASSET" "$OMP_NEW256"
  BIN="$(mktemp -d "$WORK/bin.XXXXXX")"; TARGET="$BIN/omp"
  printf 'int main(void){return 1;}\n' >"$WORK/broken.c"; cc -o "$TARGET" "$WORK/broken.c"
  fu --force omp >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$("$TARGET" --version)" = "omp/18.8.4" ] && ok force_repairs_broken_install ||
    bad force_repairs_broken_install "rc=$rc (--force must replace a binary whose --version fails)"
}

t_cli_version() { # review #12
  out="$("$FASTUP" --version 2>&1)"; rc=$?
  [ $rc -eq 0 ] && printf '%s' "$out" | grep -Eq '^fastup [0-9]+\.[0-9]+\.[0-9]+$' && ok cli_version ||
    bad cli_version "rc=$rc out=$out (want 'fastup X.Y.Z')"
}

# --- group B: locks / metadata / codex ------------------------------------------

t_lock_fresh_unowned_is_busy() { # review #3
  st="$(mktemp -d "$WORK/st.XXXXXX")"
  mkdir -p "$st/locks/x"            # just created by another run that has not written pid/start yet
  FASTUP_STATE="$st" lib 'lock_acquire x' >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && ok lock_fresh_unowned_is_busy || bad lock_fresh_unowned_is_busy "a lock dir under 60s old without pid must count as busy"
}

t_lock_stale_is_cleaned() { # review #3
  st="$(mktemp -d "$WORK/st.XXXXXX")"
  mkdir -p "$st/locks/x"; printf '999999\n' >"$st/locks/x/pid"; printf 'Thu Jan  1 00:00:00 2000\n' >"$st/locks/x/start"
  touch -t 200001010000 "$st/locks/x"
  FASTUP_STATE="$st" lib 'lock_acquire x && lock_release x'; rc=$?
  left="$(find "$st/locks" -name 'x.stale.*' | grep -c .)"
  [ $rc -eq 0 ] && [ "$left" = 0 ] && ok lock_stale_is_cleaned || bad lock_stale_is_cleaned "rc=$rc stale dirs left=$left"
}

t_omp_missing_asset_says_why() { # review #6
  printf '{"tag_name":"v18.8.4","assets":[]}\n' >"$ROOT/omp/latest.json"
  fake_install omp "omp/18.8.3"
  fu omp >/dev/null 2>"$WORK/err"; rc=$?
  [ $rc -eq 1 ] && grep -q '^omp: ' "$WORK/err" && ok omp_missing_asset_says_why ||
    bad omp_missing_asset_says_why "rc=$rc, stderr must explain the failure: $(head -2 "$WORK/err")"
}

t_codex_update_is_noninteractive() { # review open question
  codex_home 0.160.1
  FASTUP_CODEX_UPDATE_CMD='[ "${CODEX_NON_INTERACTIVE:-}" = 1 ] && '"$SWITCH_CMD" fu_codex codex >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$(codex_now)" = 0.161.0 ] && ok codex_update_is_noninteractive ||
    bad codex_update_is_noninteractive "rc=$rc (codex update must run with CODEX_NON_INTERACTIVE=1)"
}
