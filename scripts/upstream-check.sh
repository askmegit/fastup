#!/bin/bash
# Live check against the real upstreams: for each CLI, resolve the latest release from its official
# metadata, probe every candidate source, then download and checksum-verify the fastest one while
# requiring the provider-declared payload path to exist. It does not execute payloads or validate
# every archive entry, so it does not claim full archive-layout coverage.
# Usage: scripts/upstream-check.sh [cli...]   (default: claude codex omp agy)
set -u
FASTUP="$(cd "$(dirname "$0")/.." && pwd)/fastup"
[ "$#" -gt 0 ] || set -- claude codex omp agy
fail=0
for cli in "$@"; do
  out="$(mktemp -d)"
  # shellcheck disable=SC2016
  if /bin/bash -c '
    source "$1"
    FASTUP_STATE="$2/state"
    "$3"_resolve || exit 1
    ranked="$(printf "%s\n" "$CANDIDATES" | probe)"
    printf "%s\n" "$ranked" | awk -F "\t" "{ printf \"  %8d B/s  %s\n\", \$5, \$1 }"
    payload="$(printf "%s\n" "$ranked" | fetch_verified "$2")" && [ -e "$payload" ] || exit 1
    echo "$3 $LATEST: downloaded and verified"
  ' _ "$FASTUP" "$out" "$cli"; then :; else
    echo "::error::$cli: upstream check failed"
    fail=1
  fi
  rm -rf "$out"
done
exit "$fail"
