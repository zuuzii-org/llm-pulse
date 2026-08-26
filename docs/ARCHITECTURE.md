# LLM Pulse 架构

## 目标与产品边界

LLM Pulse 面向单机、单用户的本机编码 agent 任务。核心约束是：状态尽可能及时且可解释，所有任务数据留在本机，并且绝不修改任何被观测工具的持久化数据。

当前注册三个运行时 source：**Codex Desktop**、**Claude Code** 与 **ZCode / GLM**。三者各自独立超时，一个不可用不会拖住其余 source。用户通过双指左右滑动或 `Control+←/→` 在模型页之间切换（`HorizontalModelSwipeState` + `ModelSelectionStore`），菜单栏计数始终是全局汇总。

## 数据流

1. `TaskMonitor` 定时请求 `PulseHubRepository` 刷新已注册的物理 source。
2. Codex source 组合本机 App Server、可选 Codex plugin journal、read-only SQLite、rollout JSONL 与 Agent 观察器；Claude source 组合会话注册表、转录 JSONL 与 workflow journal；ZCode source 组合 read-only SQLite 与最小字段白名单事件日志。
3. source 先形成经过一致性验证的任务与用量快照，Hub 再应用已查看回执、保留策略和全局汇总。
4. `ReceiptStore` 只在 LLM Pulse 自有数据库中保存已查看回执，并执行 owner、文件类型、link count 与 `SQLITE_OPEN_NOFOLLOW` 校验。
5. UI、通知和导航只依赖领域快照，不直接读取 SQLite、JSONL 或 journal。

单次刷新必须原子发布：不允许把不同刷新代次的任务、Agent 或用量字段拼成一个看似完整的结果。任一 adapter 暂时失败时，按其健康状态降级或保留仍可信的最近值，不写入或修复任何被观测工具的文件。

## Codex 数据源

### 什么算一个 Codex Desktop 根任务

这是整个 Codex 侧最关键、也最容易随上游变动的判定，由 `RolloutMetadataReader.readDesktopRoot` 单点持有。rollout 首行必须是 `session_meta`，且其 payload 满足全部条件：

- `originator` ∈ {`Codex Desktop`, `codex_work_desktop`}
- `source == "vscode"`
- 若存在 `thread_source`，则必须为 `user`（字段缺失是允许的）
- `parent_thread_id` 为空（排除子线程）

不满足时读取器返回 `nil` 而非报错——绝大多数被拒绝的 rollout 是正常的 CLI 会话或子线程。

**漂移检测。** 由于 `CodexSQLiteTaskAdapter` 复用同一个读取器做行校验，两个适配器会同时失明，因此它们无法互为佐证。真正独立的判据是 SQL 谓词 `threads.source = 'vscode'`：当 SQL 认定存在 desktop 线程、其 rollout 文件读取成功却全部被根过滤器拒绝、且最终没有产出任何任务时，二者矛盾，只能用上游格式变更解释。此时发出 `AdapterHealth.Reason.formatDrift`，该 reason 豁免可选数据源的静默抑制，必定对用户可见。这正是 v2.0.2 那个「空面板 + 全部健康」缺陷的形态。

### App Server

LLM Pulse 通过本机 Codex bundled App Server 的 `account/rateLimits/read` 读取 Codex 账户用量。连接、请求和解析都设有超时；调用失败不会阻塞任务列表。

### SQLite

Codex state SQLite 使用 read-only 模式，并启用 SQLite `query_only`。读取器拒绝符号链接、不安全权限、非当前用户文件和异常文件类型。SQLite 主要提供 thread 元数据与兼容 token 总量，不作为“正在运行”的单一证据。

### Rollout JSONL

rollout parser 只提取状态、时间、Agent 生命周期、token 数值和兼容用量字段。读取从文件尾部开始，证据不足时有界扩展；size/mtime 未变时复用缓存。半行、损坏行和未知事件不会清空整份任务快照。

### 可选 Codex plugin journal

Codex plugin journal 只写 `session_id`、`turn_id`、`hook_event_name` 和 `timestamp`。写入发生在 LLM Pulse 自有目录的 owner-only 互斥边界内；journal 事件必须先与已验证的 Codex Desktop thread 对齐，不能仅凭陌生 ID 创建任务。

## Claude Code 数据源

### 存活判定

Claude 侧的证据比 Codex 更硬：`~/.claude/sessions/<pid>.json` 以进程号为文件名，会话存在等价于进程存在。判定按序进行，任一失败即视为「未运行」：

1. 文件名匹配 `^\d+\.json$`，且内容中的 `pid` 与文件名一致
2. `kind == "interactive"`（后台与守护会话不在产品范围内）
3. `kill(pid, 0)` 成功——`EPERM` 也判定为死，同 uid 下 0700 目录里出现权限拒绝只能意味着 pid 已被复用
4. `proc_pidinfo` 可读且 `pbi_status != SZOMB`——僵尸进程的启动时间按定义与注册表一致，只有状态位能识别它
5. `proc_pidpath` 指向 claude 可执行文件本身。**不使用命令行匹配**：把 claude 路径作为参数传入的包装进程在 `ps` 下看起来完全一样
6. 注册表 `startedAt` 与内核报告的进程启动时间一致（防 pid 复用）

全程不 fork `ps`：libproc 快数个量级，且彻底消除了解析本地化时间字符串这一整类缺陷。

**撕裂读取。** 该文件被原地重写且无 temp+rename，因此读到空内容是常态而非会话结束。读取器单独上报 `unreadableFileCount`，连续 3 次失败后才移除行，避免运行中的行随机闪断。

### 转录与状态

转录位于 `~/.claude/projects/<encoded-cwd>/<sessionID>.jsonl`。目录名是工作目录的**有损**编码（分隔符、下划线、点与字面量连字符都塌缩为 `-`），因此**绝不反解**；改为枚举 `projects/` 建立 sessionID → 文件 的精确索引，同一次扫描也顺带发现进程已退出的历史会话。

状态按优先级：显式失败 > 待回答（未完成的 `AskUserQuestion`）> 待授权（未完成的 `ExitPlanMode`）> 存在未完成 `tool_use` > 队列中有待处理提示 > 距最近活动不足 `idleGrace`（90s）> 已完成。

三点值得注意：

- **`idleGrace` 必须足够长。** 整条 assistant 消息只在完成后一次性落盘，单个工具调用可以让文件静默很久。窗口过短会让工作中的会话在消息中途反复闪烁。
- **待授权对话框与长时间运行的工具在磁盘上完全无法区分**，对话框打开期间不写入任何内容。安全方向是报告为运行中。
- **时间戳不单调**，最近活动取解析到的最大值，而非最后一行的值；「最后一条记录」由物理位置决定，时间戳只用于计算年龄。

无对应存活进程的转录被钳制为终态：运行中/等待类一律转 `completed`，而 `interrupted`/`failed` 予以保留——后者是真实证据，前者只是证据缺失。否则每个被强杀的会话都会变成永久的幽灵行。

**因此注册表匹配失败的代价是复合的**：一次错误丢弃会同时让该会话被钳成终态、失去 cwd、标题退化、并关闭深链——四个症状，一个根因。存活判定的容差必须往「宁可保留」的方向倾斜。

### 会话标题

行标题优先级：转录的 `custom-title` > 转录的 `ai-title` > 注册表 `name`（仅当 `nameSource != "derived"`）> 项目目录名。

注册表的 `name` 默认是应用生成的短 slug（`mc-mods-1c`），把它当标题会导致**用户在面板里找不到自己的会话**——Claude 自己的侧边栏显示的是 `custom-title`。`nameSource` 字段就是注册表在声明该名字有没有意义，据此取舍。

标题是**转录里唯一被读取的自然语言**，属于刻意豁免。理由：它是厂商界面本就展示的标签，与注册表 `name` 同类；Codex 侧一直在读 `session_index.jsonl` 的 `thread_name` 做同一件事；且只停留在本机、只展示给写下它的人。禁读范围不变——prompt、thinking、tool input、tool output 一概不取，`ParsedField` 枚举与其测试是该契约的可执行形式。

### 用量与额度

Claude 模型页的用量卡片分两部分，二者的保证强度不同，因此在视觉上也不同。

**本机观测（强）**：LLM Pulse 自己从转录里折叠出的 token 累计与请求数，口径与 Codex 一致——缓存计入 input，`cachedInputTokens` 是 input 的子集——所以 Claude 与 Codex 的这组数字可直接比较。统计范围是当前列表中的会话，随保留窗口滚动，不声称是应用无从获知的历史总量。

**账户额度（弱）**：读 `~/Library/Application Support/Claude/plan-usage-history.json` 的最新样本，得到 5 小时窗与 7 天窗的已用百分比。

后者有三条硬限制，卡片必须如实呈现：

- **重置时间是推算的，不是读到的。** 桌面应用把 `resets_at` 保存在内存里（`persist: false`），只读方式无从获得。但重置发生的时刻会在历史样本里留下无法掩盖的痕迹——百分比在相邻两个样本之间坍缩。周窗口的重置是固定锚点：观测到一次坍缩（括号到采样间隔内），即可按整周外推，实测与官方显示分钟级吻合；5 小时窗口在上一窗口过期后的第一次请求时开启、5 小时整重置，样本里 `0% → 正` 的转变把开启时刻括在采样间隔内。两者误差都以采样间隔为界（上限 ±10 分钟），界面一律标注「约」，坍缩括号过宽（应用当时关着）或推算已过期时宁可不显示。括号上限为 32 分钟：15 分钟节奏下容忍一次丢样，误差棒因此为 ±16 分钟——这已是「估算」二字能诚实承载的上限。跨组织的样本边界与限额调整造成的比例重标定都会被排除，不会被误认成重置。因此它仍**不能**用 `RateLimitSnapshot` 承载——那个类型的 `resetsAt` 是权威值，放宽它会削弱 Codex 侧的保证。改用独立的 `PlanUsageWindow.estimatedResetsAt`，并画成细进度条而非 Codex 那张额度卡：外观相同会诱导读者假定相同的窗口语义。
- **账户级而非运行时级。** 桌面对话、Cowork 与 Claude Code 共用同一个数字，无法拆分。
- **只在桌面应用运行时前进。** 仅 Electron 应用写这个文件，CLI 不写。2026 年 8 月中旬上游把采样节奏从 5 分钟改为 15 分钟（实测 3779 个样本），日样本量从 ~280 跌到 12~51，因此在以 CLI 为主的机器上，最新样本常年落后数小时。

**陈旧样本的处理是分窗口的，不是一刀切隐藏。** 原先「超过 6 小时一律不显示」会让卡片每天整块消失 0.5~5 小时，把「桌面应用没开」和「没有账户」混为一谈。现在：
  - 外层边界 12 小时（`maximumUsableAge`）。实测覆盖曲线在此处走平：从 6 小时放宽到 12 小时能补回应用开过的日子里所有被隐藏的时间，再放宽则一无所获——剩下的空档是整天没开应用。
  - **5 小时窗**必须有正面证据才显示：样本是刚采的（≤30 分钟，`liveInterval`），或者样本落在一个可证明尚未过期的已观测窗口内。否则隐去。这条比放宽阈值本身更重要——5 小时窗一天翻好几次，本机就记录过 21% → 十小时盲区 → 7%，期间显示 21% 不是「旧」，是**错**。
  - **7 天窗**用周锚点判断样本是否早于最近一次重置：早于则隐去（那是上周的预算），否则百分比在同一周内只增不减，旧值仍是有效下界。无锚点时按 12 小时边界接受——万一漏掉一次周重置，结果是高估用量，是安全的错误方向。
  - 幸存的旧值一律带「数据截至 HH:mm」标注（北京时间），不伪装成当前值。
- **重置时间是上游主动丢弃的，不是采不到。** 桌面应用收到的是 `{resets_at, utilization}`（asar 内 `kdn=P({resets_at:...,utilization:...})`），但落盘 `plan-usage-history.json` 时只留 `{fh, sd}` 整数。所以沿这条路径永远拿不到真实重置时间——这是上游的设计取舍，不是本应用的解析缺陷。

### 可选：Claude Code 用量桥接

CLI 侧从响应头 `anthropic-ratelimit-unified-{five_hour,seven_day}-{utilization,reset}` 解析出完整值，并通过 statusLine 契约以 JSON 喂给用户配置的命令。`LLMPulse/Resources/usage-bridge.sh` 就是那个命令：纯 `/bin/sh` + `/usr/bin/plutil`（均为基础系统自带，不引入嵌套可执行文件、不影响签名与公证），只抽 `rate_limits` 子树，加一个观测时刻，原子写入 `~/Library/Application Support/LLM Pulse/claude-cli-usage.json`（0600）。payload 里的 session id、工作目录、模型、转录一概不取，测试对脚本正文（剥除注释后）断言这一点。

**安装由用户自己完成，LLM Pulse 绝不写 `~/.claude/settings.json`。** 设置页提供配置片段、复制按钮和实时接入状态；状态读的是桥接文件的 mtime，而不是配置看起来装没装——命令装了却从不执行和压根没装，从用户视角无法区分。

两个源的取舍在 `ClaudeTaskRepository.accountUsage(now:)`：

- **整卡取观测时刻更新的那一源**，不逐窗口混用——把几分钟前的百分比和今早的百分比并排画成一次观测，比少显示一行更糟。
- **例外：重置时间是绝对时刻，与谁的百分比更新无关。** 若领先源没有重置时间（或只有推算值），而另一源持有尚未过去的上游真值，则保留该真值。
- 有真实 `resets_at` 后，陈旧判定从推理变成算术：百分比仍描述当前窗口，当且仅当该窗口尚未重置。
- `PlanUsageWindow.resetSource` 区分 `.reported` 与 `.inferred`，界面据此措辞：真值直接写「8月27日 20:59 重置」，推算值保留「约」。两者共用一套措辞会让「约」失去意义。

`plan-usage-history.json` 位于 Application Support 而非 `~/.claude`，因此 `CLAUDE_CONFIG_DIR` 不能重定向它，另有 `CLAUDE_APP_SUPPORT_DIR` 作为注入点。

### 会员行

三个模型页各有一行会员状态，数据来源与保证强度逐项标明：

- **套餐名（强）**：Claude 读 `~/.claude.json` 的 `oauthAccount.organizationRateLimitTier`（`ClaudeAccountReader` 只取该对象的三个字段，绝不触碰 `mcpServers` 等可能含密钥的部分）；Codex 用遥测里已有的 `planType`；ZCode 只在当前 GLM selection 的 provider 明确为 `*-coding-plan` 时显示 `Coding Plan`。
- **到期/续费日（分层）**：设置里手动填写的日期最优先、精确显示；其次是 `claudeCodeTrialEndsAt` 记录的试用截止（官方值，精确）；最后按 `subscriptionCreatedAt` 以整月为周期推导下一次续费——这是「Apple 订阅按购买日按月续费」的假设，年付或已取消续订时会错，因此始终标「约」，且推导永远从原始锚点出发以免被短月拖偏。ZCode 没有可信的本地到期日或 subscription anchor，因此 GLM 到期日只能手动填写，绝不推测。
- `.claude.json` 与用量历史同样按文件 stamp 缓存解析，750ms 轮询不重复读。

## ZCode / GLM 数据源

该 source 针对本机已验证的 ZCode 数据布局，只展示**当前 selection 使用 GLM 的 ZCode 根任务**。它不会把通过 Claude Code 或其他兼容 endpoint 调用 GLM 的会话误归到 GLM 页面。

### 根任务与模型判定

- SQLite 固定读取 `~/.zcode/cli/db/db.sqlite`，以 `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` 打开并启用 `PRAGMA query_only = ON`；活跃 WAL 会被 SQLite 正常合并读取。
- 根任务必须满足 `session.parent_id IS NULL AND task_type = 'interactive'`。查询按 `time_updated` 倒序并限制最近 500 条，避免 750ms 轮询随历史无界增长；子 session 从不生成独立任务行。
- 当前模型优先取根 session 最新的 `runtime/model_selection`，仅解码 `providerId`、`modelId`、`thoughtLevel`；该记录缺失时才回退到最新 `model_usage`。provider 必须属于 `builtin:bigmodel*` 或 `builtin:zai*`，且 model 必须以 `GLM` 开头。
- schema、文件 owner、硬链接数、文件类型或权限不满足合同即 fail closed。读取器从不迁移、修复或写回 ZCode 数据库。

### 状态、等待授权与 Agent

ZCode 的诊断日志位于 `~/.zcode/cli/log/zcode-YYYY-MM-DD.jsonl`。只扫描最近三个合法日期文件，并对白名单字段解码：`timestamp`、`event`、`status`、`sessionId`、`turnId`、`toolCallId`，以及 `context` 中的 `agentId`、permission id 和 `decision`。`message`、`error`、prompt、tool payload、response 与其他 context 一概不进入领域对象。

- `turn.started/completed/failed` 决定当前 turn 的运行与终态。
- ZCode 3.8.1 logger 的 `tool.permission.evaluated` 仅在 `decision == "ask" && status == "waiting"` 时进入 `waitingForApproval`；`tool.permission.resolved/denied` 以 `turnId + toolCallId` 配对后回到运行态。内部 protocol 的 `permission.*` 名称仅保留为兼容 alias。
- `subagent.spawned/completed` 按 `agentId` 折叠到根任务，子 Agent 不单列；非终态主 Agent 计为 1，最终显示值为主 Agent 加全部活跃子 Agent。事件缺字段或跨 turn 时不会伪造状态；permission 异常会丢弃该 session 的不可信状态，subagent 异常会把 Agent 可信度降为 unavailable。
- 未换行的尾部半行延后到下一轮；单文件 64 MiB、单行 4 MiB 为硬上限。日志 stamp 和根 session 集未变化时复用缓存，避免每 750ms 重放整份文件。

### Token、会员与导航

- 根任务 token 通过 recursive CTE 聚合自身及全部 descendant session，但只统计受支持 GLM provider/model 的 `model_usage`。`computed_total_tokens = input + output + reasoning`；cache read/create 都是 input 子集，展示时不得重复相加。
- ZCode 本地数据没有可信的账户 quota、重置时刻或订阅到期日，因此 `rateLimits` 始终为空；`Coding Plan` 只表示 provider 类型。GLM 到期日由用户在设置中手动填写。
- 已验证的 ZCode URL scheme 没有 task/session 路由。点击 GLM 行只激活运行中的 `dev.zcode.app`，不猜测 deep link、不创建或修改会话。

## 状态归并

| 输入证据 | LLM Pulse 状态 |
| --- | --- |
| `PermissionRequest` | `waitingForApproval` |
| 未匹配的 `request_user_input` call/output | `waitingForAnswer` |
| `UserPromptSubmit`、`task_started`、`PostToolUse` | `running` |
| `task_complete` | `completed` |
| `error` 且没有后续恢复或完成 | `failed` |
| `turn_aborted` | `interrupted`（终态，只参与通知，不再渲染行） |

新证据覆盖旧证据。SQLite 中仍为 `open` 不能单独证明任务正在运行；运行态必须由 rollout 生命周期、有效 plugin 事件或其他受支持的当前证据确认。

Codex hooks 暂无单独的 approval-resolved 事件。`PermissionRequest` 后只能等待 `PostToolUse` 确认工具已继续，因此“批准后、工具结束前”可能短暂显示 `waitingForApproval`。

ZCode 不复用上述 Codex hook 语义：它以同一 root/current turn 下配对的 `tool.permission.evaluated/resolved/denied` 为准。没有 `decision == "ask"` 的 evaluated 事件不能生成等待授权。

## Agent 活跃观测

- 界面展示“活跃 Agent 总数”，包含非终态主 Agent 与其全部层级的非终态子 Agent；等待授权或回答仍计为活跃。
- `thread_spawn_edges` 只用于建立递归父子图。`closed` 可直接排除，`open` 仅表示关系未被显式关闭，不能等同于正在运行。
- 子 Agent 状态取 rollout 中最后一个明确生命周期：`task_started` 激活，`task_complete`、`task_failed`、`turn_failed`、`turn_aborted` 或 `shutdown_complete` 终止；后续新的 `task_started` 可再次激活。
- 通用 `error` 先等待短暂静默窗口，期间没有新活动才视为停止；后续活动可恢复运行。
- 观察器先读相关文件尾部并按 size/mtime 缓存，证据不足时最多扩到既定上限，避免冷启动扫描全部历史 rollout。
- 精确状态显示 `Agent N`；尚待验证时显示 `~N`；短暂读取失败时保留上次成功值并标记过期；没有可信证据时显示 `Agent —`，绝不把未知伪装为 `0`。
- 子 Agent 只参与聚合，不生成独立任务行，也不提供停止、重试或其他写操作。

## 终态任务与回执语义

- 面板不再展示终态任务：完成、失败与中断只通过系统通知送达，通知的「标记已查看」动作仍写入回执。
- 回执机制在数据层完整保留（`ReceiptStore`、`thread_id + turn_id` 主键、首启基线），供通知去重与可能的未来界面使用；保留策略（24h / 20 条 / 未读优先）继续在快照层生效，只是不再有对应的列表渲染。
- Claude 行激活刻意不使用 `claude://resume`：该深链的语义是把 CLI 转录**导入**为一个新的桌面会话，其去重只认自己导入过的会话（前缀 + CLI id），对桌面原生会话每点一次就复制一个「General coding session」。桌面自身的会话 id 不落盘，无法从外部精确定位，因此点击 Claude 行只激活桌面应用。
- GLM 行同样不猜测 session deep link：当前已验证的 ZCode scheme 只覆盖 OAuth、支付和 workspace 打开，没有 task/session 路由，因此点击只激活运行中的 ZCode。

## Token 与每周额度语义

### Token

- session 累计总量优先取 rollout 最后一个非空 `total_token_usage`；SQLite `threads.tokens_used` 仅在缺少明细时作为只读降级来源。
- Codex/Claude 的 `total_tokens = input_tokens + output_tokens`；`cached_input_tokens` 是 input 子集，`reasoning_output_tokens` 是 output 子集。ZCode 原始 ledger 把 reasoning 作为独立 bucket，因而先按 `input + output + reasoning` 验证 `computed_total_tokens`，再映射到通用用量快照。界面不得重复相加 cache 或 reasoning。
- Codex rollout parser 只提取 `token_count` 的数值字段；Claude 与 ZCode parser 也各自使用字段白名单。三者都不缓存 prompt、tool input、tool output 或正文。

### Weekly

- 当前 UI 和通知只展示 Codex weekly 窗口。weekly 通过 `windowDurationMins == 10080` 识别，不依赖 `primary` 或 `secondary` 的固定顺序。
- 用量卡显示 `100 - used_percent` 的剩余百分比、数据新鲜度，以及以北京时间（`PulseDisplayClock`，Asia/Shanghai）格式化的准确重置日期和时间。全部绝对时间展示统一走该时钟。
- 通知只针对 weekly 产生阈值提醒；5 小时窗口不会渲染、不会生成通知，也不会替代 weekly。
- App Server 首次连接期间显示“额度待刷新”。刷新失败时可保留尚未 reset 的最近可信 weekly；没有仍有效的官方值时，兼容 rollout 数据才作为兜底。
- rollout 兜底只接受目标 Codex pool 中完整、未过期且来源一致的快照。存在互相冲突的有效 reset tuple 时返回“额度待刷新”，禁止按最高用量猜测。
- 底层兼容层继续识别并保留 `windowDurationMins == 300` 的旧 5 小时字段，以读取旧缓存和兼容历史数据；该字段不属于当前用户界面或通知合同。

## 注意力与通知策略

- 菜单栏显示全局“活跃 / 最近”双行计数；运行圆点按“失败红 > 等待用户橙 > 正常蓝”决定颜色。
- “打开下一条需处理任务”按等待授权、等待回答和更新时间排序；Codex 使用只读 deep link，Claude Code 与 ZCode 仅激活对应的运行中应用。
- 通知档位默认为“仅需我处理”；“重要状态”增加完成通知，“全部”再增加中断通知。
- 项目聚焦和静音使用最近 Git 根目录；无 Git 时使用规范化工作目录。静音只过滤任务通知，不影响采集、右栏或菜单栏计数。
- `UserDefaults` 只保存项目身份的 SHA-256 与到期时间；旧版明文路径 key 在启动时迁移为哈希。
- 相邻刷新中的完成事件先短暂聚合，再合并为无声摘要，避免通知风暴。
- weekly 使用自己的 `observedAt` 判断新鲜度；阈值提醒以 `plan + weekly window + resets_at + threshold` 去重并持久化。
- 通知权限请求期间或 Notification Center 临时投递失败时，只要任务状态仍有效，就按封顶退避重试。
- “稍后提醒”定期与任务状态、通知档位、项目静音和 weekly reset window 对账；条件失效后删除。
- 通知动作只允许打开/激活任务所属应用、打开 LLM Pulse、稍后提醒或写入 LLM Pulse 自有已查看回执。任务 route、snooze 对账与完成摘要均按 `ModelProfileID` 隔离；quota 通知仍只属于 Codex weekly。

## macOS 宿主

- `NSStatusItem` 承载固定图标区与双行计数；右键菜单的“检查更新…”只调用 Sparkle 标准 updater，不改变任务状态。
- 自定义 `NSPanel` 承载 400px 侧边栏，内容由 SwiftUI 构建。
- 面板只渲染非终态任务（“正在运行”单一分组，含等待授权/回答）；完成与失败只通过通知送达。分组折叠状态写入 LLM Pulse 自有 `UserDefaults`，折叠时不进入键盘焦点顺序。
- 面板展示来源分为 `statusItemClick`、`edgeHover` 与 `programmatic`。状态栏点击提供移入保护；进入面板后转为 hover hold，离开后使用短暂防抖。
- 轻量轮询 `NSEvent.mouseLocation`，仅在右侧中间 60% 连续停留约 200ms 后触发。
- 触边计算使用显示器全局几何；相邻显示器覆盖的右边缘不视为可触发边缘。
- 全屏检测只在指针进入触发带时执行，避免持续扫描窗口列表。
- 动画遵守 `accessibilityDisplayShouldReduceMotion`；键盘焦点和 VoiceOver 标签覆盖所有可操作控件。

## 更新与兼容边界

- Sparkle 2 通过 Swift Package Manager 精确锁定。`SUFeedURL` 指向 GitHub Release 的公开 `appcast.xml`；`SUPublicEDKey` 只包含公开 EdDSA key，private key 保存在发布机仓库外。
- 更新包在解压前校验 EdDSA，App 与 DMG 同时要求 Developer ID 签名、公证与 staple。appcast 从最终 DMG 生成。
- 更新检查不附加 Codex 任务、项目路径或 transcript，也不启用 Sparkle system profiling。
- v1.1.0 是更新通道 bootstrap。v2 feed 保留 build 6 bridge；build 1–5 必须先更新并启动 build 6，再检查一次更新。
- 当前技术身份统一使用 `LLMPulse` / `llm-pulse`。旧身份只允许出现在 `LegacyCompatibility`，用于一次性迁移偏好、回执和 plugin journal。
- 重复 App、冲突数据根、符号链接、owner 或权限异常均 fail closed；迁移不得写入或修复 Codex 自身数据。

## 通用领域底座

`ModelIdentity`、`ModelTaskSnapshot`、`PulseHubSnapshot` 和 source-set 协议保持来源无关，以便测试隔离、故障边界和未来维护。当前配置注册 Codex、Claude Code 与本机 ZCode/GLM 三个 source。新增任何其他 source 必须重新经过明确的产品决策、隐私审查、真实数据验证和发布门禁，不能仅凭底座存在而自动启用。

## 本地开发

应用的全部数据来自三个工具的私有目录，没有 mock 后端，空数据下就是一个空面板。以下是全仓**仅有的**运行时注入点：

| 开关 | 作用 |
| --- | --- |
| `CODEX_HOME` | 改写 Codex 数据根（`CodexPaths.live(environment:)`） |
| `CLAUDE_CONFIG_DIR` | 改写 Claude 数据根（`ClaudePaths.live(environment:)`） |
| `ZCODE_HOME` | 改写 ZCode 数据根（`ZCodePaths.live(environment:)`） |
| `--show-panel-for-ui-test` | DEBUG 构建：直接展开面板并关闭自动消失（`AppCoordinator`） |
| `LLM_PULSE_RUN_LIVE_SMOKE=1` | 打开 Codex/Claude/ZCode 真机烟测；它们只输出 aggregate/health，Hub 烟测把回执重定向到临时目录 |
| `LLM_PULSE_RENDER_QA_PATH` / `LLM_PULSE_STATUS_ITEM_QA_PATH` | 两个渲染测试输出 PNG 的位置 |

造假数据树的配方可直接抄测试：Codex 侧见 `CodexSQLiteTaskAdapterTests`（DDL，库名必须匹配 `state_<Int>.sqlite`）与 `TaskRepositoryTests.writeRunningRollout`（`session_meta` 最小形状；`originator` 与 `source` 不对会被静默拒绝）；Claude 侧见 `ClaudeTaskRepositoryTests.Tree`；ZCode 侧见 `ZCodeTestTree`。

```bash
CODEX_HOME=/tmp/fake-codex CLAUDE_CONFIG_DIR=/tmp/fake-claude ZCODE_HOME=/tmp/fake-zcode \
  open ".build/DerivedData/Build/Products/Debug/LLM Pulse.app" --args --show-panel-for-ui-test
```

真机烟测（只读，不污染已读状态）：

```bash
TEST_RUNNER_LLM_PULSE_RUN_LIVE_SMOKE=1 make test-swift
```
