# LLM Pulse v2.9.0

## 中文

### 本次更新

- **GLM 额度持续可见。** ZCode 不再按固定节奏刷新本机 entitlement 缓存，v2.8.0 的 10 分钟新鲜度阈值会把整段工作日的额度都隐藏。现在快照在 24 小时内持续显示，卡片继续标注「更新于」的观测时间；重置时间已过去的窗口仍会自行隐藏，不会对着过期时刻倒计时。打开 ZCode 桌面端即可触发一次新的快照。
- **诚实的新鲜度语义。** 读取竞态的短暂保留仍固定为 10 分钟，与显示窗口解耦；陈旧百分比不会被冒充为当前值，多 provider/account 无法消歧时依旧隐藏，不做推测。

### 已知边界

- ZCode / GLM 仍是针对本机 ZCode 私有数据布局验证的个人适配，不是通用 provider/API 集成；上游快照超过 24 小时、或某窗口的重置时间已过时，对应额度会隐藏。
- ZCode 仍没有已验证的单任务 deep link；点击 GLM 任务只会激活已运行的 ZCode。GLM quota 当前不生成额度通知。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- **GLM quota stays visible.** ZCode no longer refreshes its local entitlement cache on a schedule, so v2.8.0's 10-minute freshness threshold hid the quota for most of the working day. A snapshot now stays displayable for 24 hours while the card keeps its "updated at" observation label; a window whose reset time has passed still hides itself instead of counting down. Opening the ZCode desktop app triggers a fresh snapshot.
- **Honest freshness semantics.** Mid-read race retention stays fixed at 10 minutes, decoupled from the display window; an aged percentage is never presented as current, and multiple unresolvable providers or accounts remain hidden rather than inferred.

### Known boundaries

- ZCode / GLM remains a personal-machine adapter validated against ZCode's private local data layout, not a general provider/API integration. Quota hides when the upstream snapshot is older than 24 hours or a window's reset time has passed.
- ZCode still has no verified per-task deep link; clicking a GLM task only activates a running ZCode app. GLM quota does not currently produce usage notifications.

### Install

Requires macOS 14 or later and supports both Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep the legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI, Anthropic, or Zhipu AI.
