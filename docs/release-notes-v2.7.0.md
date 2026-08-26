# LLM Pulse v2.7.0

## 中文

### 本次更新

- **新增 GLM 页面。** LLM Pulse 现在会以只读方式读取 ZCode 本机 SQLite 与 event log，只展示当前选用 GLM 的交互式根任务；非 GLM 任务和子任务不会单独成行。
- **一个根任务，一个聚合视图。** 主 Agent 与活跃子 Agent 合并为 `Agent N`；GLM descendant 的 token 按根任务聚合，并显示可读取的 Coding Plan 成员身份。到期日由用户在设置中手动录入，不猜测 quota、reset 或订阅日期。
- **支持 GLM 等待授权。** 状态解析覆盖 ZCode 3.8.1 的 `tool.permission.evaluated/resolved/denied`，严格绑定当前 turn 与 tool call；日志不完整或格式不可信时，不会伪造精确状态。
- **三模型通知不再串台。** 通知标题带模型名，thread、route、稍后提醒和完成批次按 profile/session 隔离；任一模型的权威 source 降级时，不会因为不完整快照误报任务消失。
- **安全的打开行为。** Codex 仍使用已验证的 task deep link；Claude Code 和 ZCode 没有可信的 session deep link，因此只激活已运行的对应应用，不猜 URL。

### 已知边界

- ZCode / GLM 是针对本机 ZCode 3.8.1 数据布局验证的个人适配，不是通用 provider/API 集成。上游格式改变时，对应 source 会显示降级，而不是读取任意会话内容。
- ZCode 当前没有已验证的单任务定位能力，也没有可信的本机 quota/reset/到期日数据源。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- **A dedicated GLM page.** LLM Pulse now reads local ZCode SQLite and event logs in read-only mode and shows only interactive root tasks whose current selection uses GLM. Non-GLM tasks are excluded, and descendants do not become separate rows.
- **One root, one aggregate view.** The main agent and active descendants become `Agent N`; GLM descendant tokens roll up to the root, alongside the locally available Coding Plan membership. Expiry is entered manually in Settings instead of inferring quota, reset, or subscription dates.
- **GLM approval waits.** State parsing covers ZCode 3.8.1's `tool.permission.evaluated/resolved/denied` events, paired strictly to the current turn and tool call. Incomplete or untrusted logs do not manufacture an exact state.
- **Notifications stay isolated across three models.** Titles identify the model, while thread, route, snooze, and completion batching use profile/session identity. A degraded authoritative source no longer turns an incomplete snapshot into a false task disappearance.
- **Safe opening behavior.** Codex keeps its verified task deep link. Claude Code and ZCode have no trusted session deep link, so LLM Pulse only activates the matching running app and never guesses a URL.

### Known boundaries

- ZCode / GLM is a personal-machine adapter validated against the local ZCode 3.8.1 data layout, not a general provider/API integration. If the upstream format changes, the source reports degradation instead of reading arbitrary conversation content.
- ZCode currently has neither verified per-task navigation nor a trusted local source for quota, reset, or expiry dates.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI, Anthropic, or Zhipu AI.
