# LLM Pulse v2.4.0

## 中文

### 本次更新

- 两个模型页在重置行下方新增会员行：显示套餐名（如 `Max 20x`、`Plus`）与到期/续费时间。
- 日期分三层：设置中手动填写的到期日精确显示；试用账户显示官方记录的试用截止；其余按订阅起始日按月推导下一次续费并标「约」——年付或已取消续订时该推导会不准，可随时在设置中手动覆盖。距期 7 天内转橙色，已过转红色。
- 套餐名为只读获取：Claude 来自本机账户配置（仅读取三个字段，不触碰其余内容），Codex 来自既有遥测。
- 菜单栏数字语义调整：上方橙色数字为等待你确认的任务数，下方蓝色数字为正在执行的任务数。失败仍以红色覆盖上方指示；数字为 0 时置灰，避免误读为催促。
- 设置页新增「会员」区，可为每个运行时手动指定到期日。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- Both model pages gain a membership line under the reset rows: the plan's name (such as `Max 20x` or `Plus`) and when it ends.
- The date has three tiers: an expiry entered in Settings is shown exactly; trial accounts show the vendor-recorded trial end; otherwise the next renewal is projected monthly from the subscription start and marked "around" — annual billing or a cancelled renewal makes that projection wrong, and Settings can override it at any time. It turns orange within seven days and red once past.
- Plan names are obtained read-only: Claude's from the local account config (exactly three fields are read, nothing else is touched), Codex's from existing telemetry.
- The menu bar digits change meaning: the top number, in orange, counts tasks waiting on you; the bottom number, in blue, counts tasks actually running. A failure still turns the top indicator red, and zeros render dimmed rather than colored.
- Settings gains a Membership section for entering a manual expiry date per runtime.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI or Anthropic.
