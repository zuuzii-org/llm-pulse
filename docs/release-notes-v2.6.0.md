# LLM Pulse v2.6.0

## 中文

### 本次更新

- **可选：接入 Claude Code，获得准确的重置时间。** 5 小时窗口此前经常没有重置时间——那个窗口在桌面应用未采样时开启，本应用无从推算。Claude Code 自己从响应头拿到了准确值，桌面应用收到后只保留了百分比。新增的 `usage-bridge.sh` 随包发布，装为 Claude Code 状态栏命令后，5 小时和 7 天窗口直接显示上游给的真实重置时间，不再带「约」字。
- 安装由你自己完成：设置页新增「Claude Code 用量桥接」，提供配置片段、复制按钮和实时接入状态。**LLM Pulse 不会修改 `~/.claude/settings.json`**，删掉配置即恢复原状。
- 桥接脚本只读取 `rate_limits` 一个子树，不触碰会话 ID、工作目录、模型和转录内容；仅用 `/bin/sh` 与 `/usr/bin/plutil`，不引入任何额外依赖。
- 推算不出重置时间时，行内改为明确显示「重置时间未知」并说明原因，而不是留空——空白看起来像故障。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- **Optional: connect Claude Code for exact reset times.** The five-hour row often showed no reset at all — that window opened while the desktop app was not sampling, leaving nothing to infer from. Claude Code reads the real values from response headers, and the desktop app receives the same object but keeps only the percentages. The new bundled `usage-bridge.sh`, installed as your Claude Code status line, makes the five-hour and seven-day rows show the reported reset times, stated without hedging.
- Installing it stays your move: Settings gains a "Claude Code Usage Bridge" section with the snippet, a copy button, and a live connection status. **LLM Pulse never edits `~/.claude/settings.json`**; delete the snippet to undo.
- The bridge reads exactly one subtree, `rate_limits`. It never touches the session id, workspace, model, or transcript, and uses only `/bin/sh` and `/usr/bin/plutil` — no added dependencies.
- When a reset genuinely cannot be inferred, the row now says so and explains why instead of going blank, because a blank space where a time belongs reads as a broken app.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI or Anthropic.
