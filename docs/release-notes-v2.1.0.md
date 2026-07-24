# LLM Pulse v2.1.0

## 中文

### 本次更新

- 新增 Claude Code 支持。Codex Desktop 任务与本机 Claude Code 会话在同一个面板中并列观测，菜单栏总数跨两个运行时全局统计。
- 双指左右滑动，或按 `Control+←/→`，即可在模型页之间切换；模型标签支持点击、键盘操作和 VoiceOver 播报。
- Claude 会话显示项目、会话名、耗时、最新状态、累计 token 用量与活跃 Agent 数。token 口径与 Codex 一致（缓存计入输入），两个运行时的数字可直接比较。
- 点击 Claude 会话行会通过 `claude://resume` 直接跳转到该会话；由桌面应用之外启动的会话只激活应用而不发送深链，避免触发转录文件重写。
- Claude 侧不提供每周额度卡片：额度百分比可以只读获得，但重置时间不会被持久化，展示一个没有重置时间的卡片会让人误以为与 Codex 的窗口语义相同。
- 修复英文界面下一处状态提示回落显示中文的问题，并为中英文案对齐补充了静态与运行时双重校验。
- 当 Codex 本地数据格式发生变化时，界面会明确提示「数据格式可能已更新」，而不再表现为一个空白但显示健康的面板。
- 由错误事件推断出的失败在自动重试后会恢复为运行中，此类推断不再立即推送无法撤回的失败通知，改为确认稳定后再提醒。
- 保持只读边界不变：不写入、不修复 Codex 或 Claude Code 的任何任务数据，也不读取或上传提示词、工具输入输出与对话内容。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- Added Claude Code support. Codex Desktop tasks and local Claude Code sessions are observed side by side in one panel, and menu bar totals span both runtimes.
- Swipe left or right with two fingers, or press `Control+Left/Right`, to move between model pages. The model tabs are also clickable, keyboard reachable, and announced by VoiceOver.
- Claude sessions show the project, session name, elapsed time, latest state, cumulative token use, and active agent count. Token totals follow the same convention as Codex — cache counts toward input — so the two runtimes are directly comparable.
- Clicking a Claude row opens that session through `claude://resume`. Sessions started outside the desktop app activate the app instead, because resuming those rewrites the transcript in place.
- No weekly usage card is shown for Claude Code. The percentage is readable, but its reset time is never persisted, and a card without one would read as if it shared Codex's window semantics.
- Fixed a status message that fell back to Simplified Chinese in the English interface, and added static and runtime checks that keep both catalogs aligned.
- A change to Codex's local data format now says so explicitly, instead of appearing as an empty panel that reports perfect health.
- A failure inferred from a quiet error event reverts to running when an automatic retry resumes. Those inferences no longer send a failure notification that cannot be recalled; the alert waits until the state settles.
- Read-only boundaries are unchanged: nothing is written to or repaired in Codex or Claude Code task data, and no prompts, tool input or output, or conversation content is read or uploaded.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI or Anthropic.
