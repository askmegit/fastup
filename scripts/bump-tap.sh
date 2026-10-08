#!/bin/bash
# Point the Homebrew formula in askmegit/homebrew-tap at a published fastup release.
# Usage: scripts/bump-tap.sh v0.2.0     (needs a logged-in gh with push access to the tap)
set -euo pipefail
tag="${1:?usage: $0 vX.Y.Z}"
version="${tag#v}"
tap=askmegit/homebrew-tap
repo="$(cd "$(dirname "$0")/.." && pwd)"  # commit with this repo's identity (the noreply email)
digest="$(gh release view "$tag" --repo askmegit/fastup --json assets -q '.assets[] | select(.name=="fastup") | .digest')"
sha="${digest#sha256:}"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "no sha256 digest for fastup in $tag" >&2; exit 1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
gh repo clone "$tap" "$work/tap" -- -q
mkdir -p "$work/tap/Formula"
sed -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
  -e '/^# Template for/d' -e '/sha256 is filled at release time/d' \
  "$repo/packaging/homebrew/fastup.rb" >"$work/tap/Formula/fastup.rb"
git -C "$work/tap" add Formula/fastup.rb
git -C "$work/tap" diff --cached --quiet && { echo "tap already at $version"; exit 0; }
git -C "$work/tap" -c user.name="$(git -C "$repo" config user.name)" -c user.email="$(git -C "$repo" config user.email)" commit -q -m "fastup $version"
git -C "$work/tap" push -q origin HEAD:main
echo "tap updated to fastup $version"
