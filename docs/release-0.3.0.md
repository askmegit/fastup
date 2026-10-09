# fastup 0.3.0

fastup now selects Linux release assets for supported x86_64 and arm64 installations, alongside macOS. Linux uses Python 3 for official JSON metadata and can verify downloads with GNU checksum tools.

- Clean up self-update staging files when an update is interrupted.
- Run tests on both macOS and Ubuntu before publishing releases.
- Pin GitHub Actions to immutable commits.
- Restore the daily upstream schedule on a push to main or a manual recovery run. A completely inactive repository still needs a maintainer or an external trigger.
- Document a measured download example and its limits.

## Install or update

macOS with Homebrew:

```bash
brew install askmegit/tap/fastup
# Already installed:
brew upgrade fastup
```

macOS or Linux with the standalone installer:

```bash
curl -fsSL https://raw.githubusercontent.com/askmegit/fastup/main/install.sh | bash
# Already installed with the script:
fastup self
```

`fastup all` updates supported installations of Claude Code, Codex, oh-my-pi and Antigravity. It excludes fastup itself. Target CLIs installed through a package manager remain managed by that package manager.
