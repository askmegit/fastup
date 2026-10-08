#!/usr/bin/env bash
# Install the latest fastup release from github.com/askmegit/fastup.
set -euo pipefail

# Everything runs inside main, so a truncated `curl | bash` download executes nothing.
main() {
  REPO="askmegit/fastup"
  API="https://api.github.com/repos/$REPO/releases/latest"
  INSTALL_DIR="${FASTUP_INSTALL_DIR:-$HOME/.local/bin}"
  PLUTIL=/usr/bin/plutil
  PROXIES="${FASTUP_GH_PROXIES-https://gh-proxy.com/ https://ghfast.top/ https://gh.llkk.cc/ https://ghproxy.net/}"

  die() { echo "install.sh: $*" >&2; exit 1; }

  [ "$(uname -s)" = Darwin ] || die "macOS only"
  [ -x "$PLUTIL" ] || die "$PLUTIL not found"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # Fetch release metadata. The token is only ever sent to api.github.com.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "repos/$REPO/releases/latest" >"$tmp/release.json" || die "gh api failed"
  else
    auth=()
    [ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} \
      -o "$tmp/release.json" "$API" || die "cannot fetch $API"
  fi

  json_get() { "$PLUTIL" -extract "$1" raw -o - "$tmp/release.json" 2>/dev/null; }

  url="" digest="" i=0
  while name="$(json_get "assets.$i.name")"; do
    if [ "$name" = fastup ]; then
      url="$(json_get "assets.$i.browser_download_url")" || url=""
      digest="$(json_get "assets.$i.digest")" || digest=""
      break
    fi
    i=$((i + 1))
  done
  [ -n "$url" ] || die "release has no asset named fastup"
  case "$digest" in
    sha256:????????????????????????????????????????????????????????????????) want="${digest#sha256:}" ;;
    *) die "release asset has no sha256 digest" ;;
  esac

  got=""
  try_download() {
    rm -f "$tmp/fastup"
    curl -fsSL --connect-timeout 10 -o "$tmp/fastup" "$1" 2>/dev/null || return 1
    got="$(shasum -a 256 "$tmp/fastup" | awk '{print $1}')"
    [ "$got" = "$want" ]
  }

  ok=0
  # A logged-in gh can also fetch assets of private releases, which the plain URL cannot.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 &&
    gh release download --repo "$REPO" --pattern fastup --dir "$tmp" --clobber >/dev/null 2>&1 &&
    [ "$(shasum -a 256 "$tmp/fastup" | awk '{print $1}')" = "$want" ]; then
    ok=1
  elif try_download "$url"; then
    ok=1
  else
    for p in $PROXIES; do
      if try_download "${p%/}/$url"; then ok=1; break; fi
    done
  fi
  [ "$ok" = 1 ] || die "download failed or checksum mismatch (expected $want)"

  mkdir -p "$INSTALL_DIR"
  chmod 755 "$tmp/fastup"
  # Stage inside the target dir so the final mv is an atomic same-filesystem rename.
  stage="$INSTALL_DIR/.fastup.$$"
  cp "$tmp/fastup" "$stage"
  mv -f "$stage" "$INSTALL_DIR/fastup"
  echo "installed fastup to $INSTALL_DIR/fastup"

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) echo "warning: $INSTALL_DIR is not on PATH; add it to your shell profile" >&2 ;;
  esac
}

main "$@"
