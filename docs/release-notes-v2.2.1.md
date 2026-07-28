# LLM Pulse v2.2.1

## 中文

### 本次更新

- 修复正在运行的 Claude Code 会话被误判为已结束的问题。此前该会话会被折叠进「最近完成」，同时失去项目路径、标题退化为 `/`，点击也无法跳转——四个症状源自同一处：会话存活判定过于严格。
- 会话创建时刻必然晚于其进程启动，冷启动或高负载时这个间隔可超过 2 秒，原先的对称容差会把它误判为 PID 复用。现改为只拒绝「记录时刻早于进程启动」这一真正的复用特征。
- 行标题改用 Claude 自己显示的会话标题（如「暮色森林迁移」），而非注册表生成的短代号（如 `mc-mods-1c`）。注册表名称仅在其 `nameSource` 表明由用户设定时才使用。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- Fixed a running Claude Code session being reported as finished. It was folded into “Recently Completed” and simultaneously lost its project path, showed `/` as its title, and could not be opened — four symptoms from one cause: the session liveness check was too strict.
- A session is created after its process starts, and on a cold or loaded machine that gap can exceed two seconds, which the previous symmetric tolerance read as pid reuse. Only the genuine reuse signature is rejected now: a recorded start that predates the running process.
- Rows now carry the session title Claude itself displays rather than the short identifier the registry generates. The registry name is used only when its `nameSource` says a person chose it.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI or Anthropic.
