# LLM Pulse v2.5.0

## 中文

### 本次更新

- 修复点击 Claude Code 任务会在桌面应用里多出一个「General coding session」的问题。根因是 `claude://resume` 深链的语义是「导入转录副本」而非「跳转会话」，对桌面已有的会话每点一次就复制一份；桌面自身的会话 ID 不落盘、无法从外部精确定位。现在点击 Claude 行会激活桌面应用——会话就在它的侧栏里。
- 所有重置与到期时间统一以北京时间（UTC+8）显示具体时刻：Codex 每周重置、Claude 5 小时/7 天窗口的估算重置（现在带完整日期）、会员日期与额度通知。
- 面板只保留进行中的工作：「最近完成」分组连同批量已查看、撤销和未读圆点一并移除；完成与失败改由系统通知送达。失败任务同样不再驻留面板，由通知与菜单栏红色数字提示。
- 右键菜单重排并对齐：所有命令配统一图标，模型子菜单行显示「待处理 · 运行」。
- 设置页说明文字移入规范的分区脚注，布局更整洁。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- Fixed clicking a Claude Code task creating an extra "General coding session" in the desktop app. The `claude://resume` deep link's semantics are "import a transcript copy", not "go to the session" — aimed at a session the desktop already owns, every click minted a duplicate, and the desktop's own session id is never written to disk, so nothing external can address the exact session. Clicking a Claude row now activates the desktop app, where the session already sits in its sidebar.
- Every reset and expiry now shows a concrete moment in Beijing time (UTC+8): the Codex weekly reset, the estimated 5-hour and 7-day resets for Claude (now with a full date), membership dates, and quota notifications.
- The panel focuses on work in progress: the Recently Completed group is gone, along with bulk mark-viewed, undo, and the unread dot. Completions and failures arrive as notifications instead; failed tasks likewise no longer sit in the panel, signalled by notifications and the red menu bar digit.
- The right-click menu is reordered and aligned, every command carries a consistent icon, and the model submenu rows read "waiting · running".
- Settings copy moves into proper section footers.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI or Anthropic.
