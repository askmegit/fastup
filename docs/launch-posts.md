# Launch copy

## X draft

CLI updates timing out? I built fastup: probe download sources on every run, pick the fastest, resume if one stalls, and verify against official checksums.

Claude Code, Codex, oh-my-pi and Antigravity.

brew install askmegit/tap/fastup

https://github.com/askmegit/fastup

## V2EX draft

Title: 做了个开源小工具 fastup：CLI 更新前先测速，再校验下载

最近更新 Claude Code、Codex、oh-my-pi 和 Antigravity 经常碰到下载超时，于是把换源、测速、续传和校验整理成一个 Bash 工具。

每次运行会探测官方地址、npm 镜像和可选的 GitHub 加速地址，按实测速度排序，源卡住时尝试续传。版本和校验值从官方来源获取；镜像只提供文件，校验通过才安装。

安装：`brew install askmegit/tap/fastup`

使用：`fastup all`，或 `fastup claude codex`。`fastup --check all` 只检查。`all` 只处理已安装且布局受支持的四个 CLI，不是通用包管理器；通过 npm/Homebrew 安装的目标 CLI 仍用原包管理器更新。

一次 macOS 实测中，Codex 的 129 MB 安装包下载约 7 秒；Claude 与 Codex 连检查和安装总共约 48 秒。只是一次网络下的观测，不是同文件对照实验或速度保证。

agy 的 GCS 下载没有找到可用的免费公共加速路线，所以没有假装 GitHub 加速地址也能代理它；可用 `FASTUP_PROXIES` 提供兼容前缀参与测速。

仓库：https://github.com/askmegit/fastup ，MIT。欢迎反馈安装方式、平台和网络下遇到的问题。
