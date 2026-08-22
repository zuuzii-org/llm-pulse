<p align="center">
  <img src="Assets/Brand/LLMPulse-AppIcon-Rendered-512.png" width="128" height="128" alt="LLM Pulse app icon">
</p>

# LLM Pulse — Codex Task Monitor for macOS

<p align="center"><strong>Codex tasks, always in sight.</strong></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/zuuzii-org/llm-pulse/releases/latest">Download</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture</a> ·
  <a href="LICENSE">MIT License</a>
</p>

**LLM Pulse is an open-source native macOS menu bar monitor for local Codex Desktop tasks.** It keeps running work, tasks waiting for approval or an answer, recent completions, active agent totals, token usage, and the Codex weekly usage limit visible without changing the underlying task records.

The interface supports English and Simplified Chinese. Choose Follow System, 简体中文, or English in Settings; changes apply immediately without restarting.

## Product facts

| | |
|---|---|
| **Product** | LLM Pulse 2.6.0 |
| **Developer** | Zuuzii |
| **Platform** | macOS 14 or later; Apple Silicon and Intel |
| **Category** | Local Codex task monitor and menu bar utility |
| **Task scope** | Local root tasks created by Codex Desktop |
| **Data model** | Local, read-only adapters; no task analytics service |
| **Network use** | GitHub Releases for optional update checks and downloads |
| **License** | MIT |
| **Affiliation** | Independent project; not an OpenAI product |

## Download

[Download the latest signed and notarized DMG](https://github.com/zuuzii-org/llm-pulse/releases/latest). LLM Pulse 2.6.0 requires macOS 14 or later and ships as a Universal App for Apple Silicon and Intel Macs.

The v2.6.0 release assets are:

- `LLM-Pulse-2.6.0.dmg`
- `LLM-Pulse-2.6.0.dmg.sha256`

Place both files in the same folder and verify the download with:

```bash
shasum -a 256 -c LLM-Pulse-2.6.0.dmg.sha256
```

Users on v1.0.0 must install v1.1.0 manually once because v1.0.0 did not include in-app updates. Users on v1.1–v1.3 should install and launch v1.4 before updating to v2.6.0.

## What LLM Pulse shows

- **A compact menu bar status.** The top number counts tasks waiting on you, in orange; the bottom number counts tasks actually running, in blue. A failure turns the top indicator red, and a zero renders dimmed instead of colored.
- **A full-height task sidebar.** Hold the pointer at the middle 60% of the current display’s right edge for about 200 ms. The 400 px panel opens on the display under the pointer and avoids internal seams between adjacent displays.
- **Clear task groups.** Running, waiting for approval, waiting for an answer, and recent tasks remain visually distinct. Running and recent sections can be folded independently, and their state is restored at the next launch.
- **Useful task context.** Each row shows the project, session, elapsed time, latest state, cumulative token use, and the active total for the main agent plus descendant agents.
- **Exact Claude limits, optionally.** Claude Code knows its own reset times; the desktop app receives them and keeps only the percentages. Install the bundled `usage-bridge.sh` as your Claude Code status line and LLM Pulse shows the reported reset times instead of inferring them. LLM Pulse never edits `~/.claude/settings.json` — Settings hands you the snippet to paste.
- **Codex weekly usage.** The usage card shows the remaining weekly percentage, an exact reset date and time in Beijing time (UTC+8), and data freshness.
- **Direct task navigation.** Clicking a row opens the matching task through `codex://threads/<thread-id>`. A completion is marked viewed automatically only after the task opens successfully.
- **Native notifications.** Choose attention-only, important, or all recognizable states. Notifications support task actions, 15-minute or 1-hour snooze, quiet completion summaries, and weekly usage warnings.
- **Two runtimes, one panel.** Codex Desktop tasks and Claude Code sessions are observed side by side. Swipe left or right with two fingers, or press Control+Left/Right, to switch model pages. Menu bar totals stay global across both.
- **Project controls.** Focus the panel on one Git project or mute that project’s notifications for an hour or until the next day. Menu bar totals remain global.
- **macOS behavior.** Launch at login, multiple displays, reduced-motion support, configurable edge triggering in full-screen apps, and instant English/Simplified Chinese switching are built in.

The panel shows active work only — running tasks and tasks waiting on you. Completions and failures are delivered as notifications rather than kept in a list.

## How it works

LLM Pulse combines narrow local adapters instead of treating any private Codex format as permanent:

1. The optional Codex plugin writes minimized lifecycle events for timely running and approval-waiting updates.
2. Codex state SQLite databases are opened read-only with SQLite `query_only` enabled.
3. Rollout JSONL is parsed for task state, timestamps, agent lifecycle, token summaries, and compatible usage snapshots.
4. The bundled Codex App Server is queried locally with `account/rateLimits/read`; the current interface and notifications use the weekly window.
5. Viewed receipts and LLM Pulse preferences stay under `~/Library/Application Support/LLM Pulse/`. Upgrade-only path aliases are isolated in centralized `LegacyCompatibility` definitions.

Only local root tasks created by Codex Desktop appear as rows. Descendant agents are rolled into the active `Agent N` total of their root task rather than displayed separately. See [the architecture notes](docs/ARCHITECTURE.md) for state precedence, retention, weekly-usage selection, and adapter failure behavior.

## Privacy and network access

LLM Pulse is designed as a read-only observer:

- It does not write to Codex databases, rollouts, task records, or App Server state.
- It does not extract, retain, or upload prompts, tool input, tool output, or transcript content.
- The optional Codex journal keeps only `session_id`, `turn_id`, the event name, and a timestamp. It does not record project paths, prompts, messages, tool payloads, or responses.
- Viewed receipts, notification settings, and weekly-warning deduplication keys stay on the Mac. Muted projects are stored as SHA-256 identifiers rather than plain-text paths.
- No OpenAI API key is required. LLM Pulse includes no task analytics or task-data upload service.

An optional update check reads public release information hosted on GitHub. It does not attach Codex task data or a generated system profile. Normal task monitoring remains local.

## Install

1. Download the DMG and matching SHA-256 file from [GitHub Releases](https://github.com/zuuzii-org/llm-pulse/releases/latest).
2. Verify the checksum with the command above.
3. Open the DMG and drag `LLM Pulse.app` to `Applications`.
4. Launch the app from `Applications`. Notification permission is optional; local task monitoring works without it.
5. Enable launch at login in LLM Pulse Settings if desired.

## In-app updates

In-app updates have been available since v1.1.0. Right-click the menu bar item and choose `检查更新…` (“Check for Updates…”) to check the public GitHub Release feed and install a newer version.

v1.1.0 is the bootstrap release for this update channel. Users on v1.0.0 must install v1.1.0 manually once. When moving to v2, users on v1.1–v1.3 must install and launch v1.4 first, then check for updates again.

For a manual v2 installation, quit the installed version and remove its previous wrapper before dragging `LLM Pulse.app` into `Applications`; do not keep both copies. Because v2 uses a new macOS application identity, macOS may ask for notification permission again. Check Launch at Login in LLM Pulse Settings after upgrading.

## Optional Codex plugin

The app works without the plugin by falling back to read-only SQLite and rollout JSONL. Installing the bundled lifecycle hooks improves the timeliness of running and approval-waiting states.

```bash
codex plugin marketplace add zuuzii-org/llm-pulse
codex plugin add llm-pulse@llm-pulse
```

Review and trust the hooks when Codex asks. The plugin writes minimized events to:

```text
~/Library/Application Support/LLM Pulse/events/events.jsonl
```

The hooks depend only on `/bin/sh` and JXA included with macOS. They do not require Python, Node.js, or an external runtime.

## FAQ

### What is LLM Pulse?

LLM Pulse is a native macOS menu bar monitor for local Codex Desktop tasks. It summarizes task state and weekly usage in a right-edge sidebar so you do not need to keep every task window open.

### How can I monitor multiple Codex Desktop tasks on macOS?

Run LLM Pulse alongside Codex Desktop. Its menu bar status summarizes active and recent work, while the right-edge sidebar lists every local root task with its state, project, elapsed time, token usage, and active agent total.

### Does LLM Pulse modify or control Codex tasks?

No. It reads Codex data and can open an existing task through a deep link, but it does not approve, answer, stop, retry, create, archive, or edit tasks.

### Does LLM Pulse upload prompts or task data?

No. Task monitoring stays on the Mac. LLM Pulse does not extract, retain, or upload prompts, tool input, tool output, or transcripts, and no OpenAI API key is required.

### Does it work without the Codex plugin?

Yes. The plugin is optional. Without it, LLM Pulse uses read-only SQLite and rollout JSONL; some running or approval-waiting transitions may appear later.

### Does it show subagents?

Subagents do not appear as separate rows. LLM Pulse aggregates the active main agent and all active descendants into the root task’s `Agent N` value. If local evidence is incomplete, it shows an unknown or stale value instead of inventing zero.

### What does the weekly percentage mean?

It is the remaining percentage calculated from the Codex-reported used percentage, together with the weekly reset time. It is not an absolute token balance. Reset dates and times are shown in Beijing time (UTC+8).

### How does LLM Pulse read the Codex weekly usage limit?

It asks the bundled local Codex App Server for the weekly limit reported to Codex Desktop. Compatible local rollout data is used only as a fallback. The current interface and notifications use only the weekly window.

### Can LLM Pulse open a task directly in Codex Desktop?

Yes. Clicking a row opens the matching task through a local `codex://threads/<thread-id>` link. If navigation fails, LLM Pulse keeps the task unread and reports the error instead of silently acknowledging it.

### Why is a viewed task still under recent tasks?

“Viewed” clears the unread state; it does not delete the history row. Completed, failed, and interrupted tasks remain in the recent list for up to 24 hours, subject to the 20-item cap.

### Does LLM Pulse support Codex CLI, IDE tasks, cloud tasks, or other AI coding tools?

LLM Pulse observes two runtimes: local root tasks created by Codex Desktop, and local Claude Code sessions. Swipe horizontally with two fingers, or press Control+Left/Right, to switch between them.

### Is LLM Pulse an official OpenAI product?

No. LLM Pulse is an independent open-source project by Zuuzii and is not affiliated with, endorsed by, or maintained by OpenAI.

## Known limitations

- Codex local schemas, rollout events, and deep links are private compatibility surfaces and may change. Each adapter degrades independently when a source becomes unavailable.
- `codex://threads/<thread-id>` works with the Codex Desktop builds tested for this release but is not a documented stable contract.
- Opening a task directly inside Codex Desktop cannot be detected reliably. Open it from LLM Pulse or acknowledge it manually to clear its unread state.
- Codex hooks have no separate approval-resolved event. A task may remain in the approval-waiting state until the related tool emits `PostToolUse`.
- Weekly usage data provides a percentage and reset time, not a reliable absolute token allowance.
- App-generated interface text supports English and Simplified Chinese. User task titles, project paths, and raw Codex content remain unchanged.

## Build from source

Requirements: macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/zuuzii-org/llm-pulse.git
cd llm-pulse
make check
open ".build/DerivedData/Build/Products/Debug/LLM Pulse.app"
```

`make check` runs the brand-residual gate, generates the Xcode project, runs the Swift, Codex plugin, and release test suites, and builds the Debug app without code signing. For Xcode development, run `make open` and use the `LLMPulse` scheme and module.

## License and attribution

LLM Pulse is released under the [MIT License](LICENSE). Product attribution belongs to **Zuuzii**.

LLM Pulse is an independent project. It is not affiliated with, endorsed by, or maintained by OpenAI. Product and company names are used only to describe compatibility.
