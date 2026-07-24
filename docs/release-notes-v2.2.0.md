# LLM Pulse v2.2.0

## 中文

### 本次更新

- Claude Code 模型页新增用量卡片。此前该卡片始终显示「待刷新」，因为没有任何数据写入它。
- 卡片上半部分显示 LLM Pulse 在本机观测到的 token 累计与请求次数，口径与 Codex 一致（缓存计入输入），两个运行时的数字可直接比较。统计范围与列表一致，随保留窗口滚动。
- 卡片下半部分显示 5 小时与 7 天窗口的已用比例。**这两个数字没有重置时间**：写入它们的桌面应用不会持久化重置时刻，只读方式无法获得，因此卡片刻意不采用 Codex 那张额度卡的样式，并明确标注「账户级用量 · 无重置时间」。
- 该百分比覆盖整个账户（含桌面对话等），而非 Claude Code 单独消耗；且只在桌面应用运行时更新，超过 6 小时未更新即不再显示，避免把陈旧数字当作当前状态。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- The Claude Code model page now has a working usage card. It previously read “Waiting to refresh” permanently, because nothing ever populated it.
- The top half shows the tokens and request count LLM Pulse observed locally, counted the same way as Codex — cache counts toward input — so the two runtimes are directly comparable. It covers the sessions currently listed and moves with the retention window.
- The bottom half shows how much of the 5-hour and 7-day windows has been used. **Neither carries a reset time**: the desktop app that records these percentages never persists when a window turns over, and there is no read-only source for it. The card is therefore drawn differently from the Codex quota card and states plainly that it is account-wide with no reset time.
- Those percentages span the whole account rather than Claude Code alone, and they only advance while the desktop app is running. A reading older than six hours is withheld rather than shown as if it were current.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI or Anthropic.
