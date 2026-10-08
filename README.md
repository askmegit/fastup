# fastup

fastup updates AI coding CLIs (Claude Code, Codex, oh-my-pi, Antigravity) from a single command. Download speed to the official hosts varies a lot by network, so fastup probes every candidate source (the official host, npm mirrors, optional GitHub accelerator prefixes) by fetching the first 2 MiB of each, picks the fastest, and downloads from it. Partial downloads resume on another source if one stalls. Whatever source supplies the bytes, fastup installs them only if they match the checksum published by the official host.

macOS only in v0.1. Bash 3.2 compatible. Needs `curl`, `shasum`, `tar`, `openssl` and `/usr/bin/plutil` (all ship with macOS). No `jq`.

## Install

Homebrew (available once the tap is published):

```bash
brew install askmegit/tap/fastup
```

One-liner (installs to `~/.local/bin`, override with `FASTUP_INSTALL_DIR`):

```bash
curl -fsSL https://raw.githubusercontent.com/askmegit/fastup/main/install.sh | bash
```

## Usage

```
fastup [--check] [--force] [--via PREFIX] [--dry-run] [-v] <claude|codex|omp|agy|self|all>...
```

```bash
fastup all                      # update everything that is installed
fastup claude codex             # update specific tools
fastup self                     # update fastup itself (not part of `all`; Homebrew: brew upgrade fastup)
fastup --check all              # report only; exit 10 if any update is available
fastup --dry-run -v omp         # show the plan and probe speeds, install nothing
fastup --via https://gh-proxy.com/ omp     # GitHub downloads: try this prefix first, then the official URL; no probing
fastup --force agy              # reinstall, downgrade, or repair a broken binary
fastup --version
```

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Up to date, or updated |
| 1 | Failure |
| 2 | Usage error |
| 3 | Unsupported install layout (see below) |
| 10 | Update available (`--check`) |

With several CLIs, the most severe code wins: 1, then 3, then 10, then 0.

## How it works

1. Probe: for each candidate source, download the first `FASTUP_PROBE_BYTES` (2 MiB) in parallel and time it.
2. Rank: order sources by measured speed.
3. Fetch: download from the fastest; if it stays below a quarter of its probed speed for `FASTUP_STALL_TIME` seconds, or errors, resume the partial file from the next source. Downloads are capped at `FASTUP_MAX_BYTES`.
4. Verify: compare the SHA-256 / SHA-512 of the result with the checksum fetched from the official host. A mismatch discards the file and moves on to the next source.
5. Install atomically: swap the new version in place; if anything fails, roll back to the previous one.

## Trust model

Version numbers and checksums are fetched only from official hosts, never through a mirror or proxy. Mirrors and accelerators supply bytes only, and those bytes are discarded unless they match the official checksum. Auth tokens are never sent to mirrors.

| CLI | Trusted for version and checksum |
| --- | --- |
| claude | `downloads.claude.ai` (version, binary checksum); `registry.npmjs.org` (integrity of the npm copy) |
| codex | `releases.openai.com`, falling back to `api.github.com`; `registry.npmjs.org` (integrity of the npm copy) |
| omp | `api.github.com` |
| agy | the Antigravity `run.app` update manifest |

## Supported install layouts

| CLI | Layout |
| --- | --- |
| claude | Native installer: `~/.local/bin/claude` -> `~/.local/share/claude/versions/<v>`. Follows `autoUpdatesChannel` in `~/.claude/settings.json`. |
| codex | Standalone installer (`~/.codex/packages/standalone`). fastup pre-stages the verified release, then runs the official `codex update`, which skips its own download. |
| omp | Single Mach-O binary on `PATH`. |
| agy | Single Mach-O binary on `PATH`. |

Exit 3 means the tool was found but installed some other way (Homebrew, npm, ...). fastup does not touch it; update it with the package manager that installed it.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `FASTUP_GH_PROXIES` | Space-separated GitHub accelerator prefixes; set to empty for none | `https://gh-proxy.com/ https://ghfast.top/ https://gh.llkk.cc/ https://ghproxy.net/` |
| `FASTUP_NPM_MIRRORS` | Space-separated npm mirror registries | `https://registry.npmmirror.com` |
| `FASTUP_PROXIES` | Generic URL prefixes tried for agy downloads | none |
| `FASTUP_PROBE_BYTES` | Bytes fetched per probe | 2097152 (2 MiB) |
| `FASTUP_PROBE_TIMEOUT` | Per-probe timeout, seconds | 6 |
| `FASTUP_PROBE_PARALLEL` | Concurrent probes | 3 |
| `FASTUP_STALL_TIME` | Seconds below a quarter of the probed speed (min 1 KiB/s) before switching source | 30 |
| `GITHUB_TOKEN` | Sent to `api.github.com` only (rate limits); `gh` is used instead when logged in | unset |
| `FASTUP_MAX_BYTES` | Refuse downloads larger than this | 1073741824 (1 GiB) |
| `FASTUP_STATE` | State and partial-download directory | `~/.cache/fastup` |

## Limitations

- macOS only in v0.1.
- Public GitHub accelerators are third-party services and may disappear or change. Set `FASTUP_GH_PROXIES` to your own list (or empty to disable them); checksum verification keeps a bad source from being installed, but a dead one only costs probe time.

## License

MIT
