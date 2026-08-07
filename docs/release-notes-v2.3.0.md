# LLM Pulse v2.3.0

## 中文

### 本次更新

- Claude Code 的 5 小时与 7 天窗口现在显示预计重置时间（如「约 周四 20:59 重置」）。
- 重置时间是推算的：官方从不把它写入磁盘，但重置发生时已用百分比会在相邻两个采样之间坍缩，这个痕迹足以定位它。周窗口是固定锚点，观测到一次坍缩即可按整周外推，实测与 Claude 自己面板显示的时间分钟级一致；5 小时窗口由「0% 变为正值」的开窗时刻加 5 小时得出。
- 误差以采样间隔为界（不超过 ±10 分钟），因此界面一律标注「约」。坍缩发生时桌面应用没有运行、或推算已过期时，宁可不显示。
- 限额调整造成的比例下调、以及多组织样本的交界，都不会被误认为重置。
- 用量历史文件改为按变更解析而非每次轮询解析，避免随文件增长而重复开销。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- The 5-hour and 7-day windows for Claude Code now show an expected reset time, e.g. "Resets around Thu 8:59 PM".
- These times are inferred, not reported: nothing official ever writes them to disk, but a reset cannot happen without the used percentage collapsing between two adjacent samples in the usage history. The weekly reset is a fixed anchor — one observed collapse projects forward by whole weeks, validated to the minute against the panel Claude itself draws. The five-hour reset is the observed window opening plus five hours.
- The error bar is the sampling cadence (at most ±10 minutes), which is why every time carries an "around". A collapse that happened while the desktop app was closed, or an estimate that has already passed, is withheld rather than shown.
- A percentage rescaled by a limit change, and the boundary between two organizations' interleaved samples, are both excluded from reset detection.
- The usage history file is now parsed when it changes rather than on every poll, so the cost no longer grows with the file.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI or Anthropic.
