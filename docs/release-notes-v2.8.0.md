# LLM Pulse v2.8.0

## 中文

### 本次更新

- **GLM Coding Plan 额度。** GLM 页面现在显示 ZCode 上游报告的 5 小时和 7 天剩余百分比、准确重置时间，以及数据新鲜度；两个窗口按是否存在及重置时间是否有效分别展示，缺失的窗口不会留下假 loading 状态。
- **精确的套餐日期。** 单条可信 subscription 会显示套餐名和厂商确认的续费日或到期日。设置中手动填写的日期仍拥有最高优先级；已经过去的 renewal 会提示刷新，而不会误报成到期异常。
- **只读本机 entitlement。** LLM Pulse 只将 ZCode 最多 10 分钟新的本机 Chromium Local Storage 快照用于显示，不复用凭据、不调用计费 API，也不主动联网刷新。读取器仅保留显示所需的 provider、quota 与 subscription 白名单字段。
- **安全降级。** 多 provider/account 无法消歧、percentage 缺失、窗口已过期、并发写入或格式漂移时，会隐藏不可信数据而不是推测。短暂读取竞态只会在同一 provider 和有效 TTL 内保留最后一次可信观测。
- **LevelDB 兼容与边界。** 原地只读解析 active MANIFEST、WAL 和 SST，支持 sequence、tombstone、raw/Snappy block，并对文件大小、目录项、CRC、owner、权限、链接和读取前后 stamp 设置 fail-closed 边界。

### 已知边界

- ZCode / GLM 仍是针对本机 ZCode 3.8.1 私有数据布局验证的个人适配，不是通用 provider/API 集成；上游快照超过 10 分钟时，额度与厂商日期会暂时隐藏。
- ZCode 仍没有已验证的单任务 deep link；点击 GLM 任务只会激活已运行的 ZCode。GLM quota 当前不生成额度通知。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- **GLM Coding Plan limits.** The GLM page now shows the 5-hour and 7-day remaining percentages reported by ZCode, their exact reset times, and data freshness. Each window is presented separately when present and current, and a missing window no longer leaves a fake loading state.
- **Exact plan dates.** One trusted subscription record supplies the plan name and vendor-confirmed renewal or expiry date. A manual date in Settings still has the highest priority; a renewal date that has passed asks for refreshed data instead of being mislabeled as an expiry failure.
- **Read-only local entitlement data.** LLM Pulse uses a ZCode Chromium Local Storage snapshot for display only when it is no more than 10 minutes old. It never reuses credentials, calls a billing API, or refreshes the snapshot over the network. The reader retains only allowlisted provider, quota, and subscription fields required for display.
- **Safe degradation.** When multiple providers or accounts cannot be disambiguated, a percentage is missing, a window has expired, a file changes during the read, or the format drifts, untrusted data is hidden instead of inferred. A transient read race can retain the last trusted observation only for the same provider and within its TTL.
- **Bounded LevelDB compatibility.** The in-place read-only parser follows active MANIFEST, WAL, and SST state, including sequence numbers, tombstones, and raw/Snappy blocks, with fail-closed bounds for file size, directory entries, CRCs, ownership, permissions, links, and before/after file stamps.

### Known boundaries

- ZCode / GLM remains a personal-machine adapter validated against ZCode 3.8.1's private local data layout, not a general provider/API integration. Quota and vendor dates are temporarily hidden when the upstream snapshot is more than 10 minutes old.
- ZCode still has no verified per-task deep link; clicking a GLM task only activates a running ZCode app. GLM quota does not currently produce usage notifications.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI, Anthropic, or Zhipu AI.
