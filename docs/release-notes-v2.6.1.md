# LLM Pulse v2.6.1

## 中文

### 本次更新

- 5 小时窗口用量为 0 时，改为显示「尚未开始」而不是「重置时间未知」。5 小时窗口在上一个窗口过期后的**第一次请求**时才开始计时，此前既无消耗也无重置时刻。实测这个状态占了三分之一的时间，此前那句措辞会让人以为应用丢了数据。7 天窗口不适用——它锚定在日历上，用量为 0 只是新的一周。
- 修正随包发布的 `usage-bridge.sh` 权限：此前为 0700（仅属主可读），现为 0755。发版脚本以 `umask 077` 运行，Xcode 继承了它——这对构建目录是对的，对一个「由某个账号安装、可能由另一个账号运行」的应用包则不对。同时增加守卫：桥接脚本一旦未进入产物，发版立即失败。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- A five-hour window at 0% now reads "Not started" instead of "Reset time unknown". That window opens on the **first request** after the previous one expired, so until then nothing is consumed and no reset exists. Measured on a live machine, that state covers a third of all recorded time, where the old wording implied the app had lost track of its own data. The weekly window is excluded: it is anchored to the calendar, so a weekly zero is simply a fresh week.
- Fixes the permissions of the bundled `usage-bridge.sh`, which shipped as 0700 (owner-only) and is now 0755. The release script runs under `umask 077` and Xcode inherited it — right for a build directory, wrong for a bundle one account installs and another may run. The release now also fails outright if the bridge is missing from the built app.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI or Anthropic.
