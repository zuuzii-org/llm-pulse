import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

enum SettingsMembershipPresentation {
    static let profiles: [ModelIdentity] = [
        .codex,
        .claudeCode,
        .glm,
    ]
}

struct SettingsView: View {
    @ObservedObject var settings: PulseSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginService

    let requestNotificationAuthorization: @MainActor () async -> Void

    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var didCopyBridgeSnippet = false

    var body: some View {
        Form {
            Section {
                Picker("应用语言", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName(in: settings.appLanguage)).tag(language)
                    }
                }
            } header: {
                Text("语言")
            } footer: {
                Text("切换后立即应用，无需重新启动。")
            }

            Section("触边") {
                Toggle("启用右侧边缘触发", isOn: $settings.edgeTriggerEnabled)
                Toggle("全屏应用和游戏中禁用", isOn: $settings.disableInFullScreen)

                LabeledContent(
                    "触发区域",
                    value: PulseL10n.text(
                        "鼠标所在屏幕右侧中间 60%",
                        language: settings.appLanguage
                    )
                )
                LabeledContent("停留时间", value: "200 ms")
                LabeledContent(
                    "侧边栏",
                    value: PulseL10n.text(
                        "%d px · 全高",
                        language: settings.appLanguage,
                        Int(settings.panelWidth)
                    )
                )
            }

            Section("通知") {
                Toggle("任务状态通知", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        Task {
                            await requestNotificationAuthorization()
                            await refreshNotificationAuthorizationStatus()
                        }
                    }

                if settings.notificationsEnabled,
                   notificationAuthorizationStatus == .denied {
                    HStack(alignment: .firstTextBaseline) {
                        Label("系统通知权限已关闭，当前不会收到提醒。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("打开系统通知设置") {
                            openSystemNotificationSettings()
                        }
                    }
                }

                Picker(selection: $settings.notificationAttentionLevel) {
                    ForEach(NotificationAttentionLevel.allCases) { level in
                        Text(level.title(language: settings.appLanguage)).tag(level)
                    }
                } label: {
                    Text("提醒范围")
                    Text(settings.notificationAttentionLevel.detail(language: settings.appLanguage))
                }
                .disabled(!settings.notificationsEnabled)

                Toggle("播放通知声音", isOn: $settings.notificationSoundEnabled)
                    .disabled(!settings.notificationsEnabled)

                if !settings.mutedProjectExpirations.isEmpty {
                    HStack {
                        LabeledContent(
                            "临时静音项目",
                            value: PulseL10n.text(
                                "%d 个",
                                language: settings.appLanguage,
                                settings.mutedProjectExpirations.count
                            )
                        )
                        Button("全部取消静音") {
                            settings.clearProjectMutes()
                        }
                    }
                }
            }

            Section {
                ForEach(SettingsMembershipPresentation.profiles, id: \.profileID) { identity in
                    membershipOverrideControls(
                        title: identity.displayName,
                        profileID: identity.profileID
                    )
                }
            } header: {
                Text("会员")
            } footer: {
                Text("填写后覆盖自动推导的续费日；读取到订阅起始日时会按月推算，GLM 到期日需手动填写。")
            }

            Section {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    LabeledContent(
                        PulseL10n.text("状态", language: settings.appLanguage),
                        value: bridgeStatus(asOf: context.date)
                    )
                }

                Text(bridgeSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Button(
                    didCopyBridgeSnippet
                        ? PulseL10n.text("已复制", language: settings.appLanguage)
                        : PulseL10n.text("复制配置", language: settings.appLanguage)
                ) {
                    copyBridgeSnippet()
                }
                .disabled(didCopyBridgeSnippet)
            } header: {
                Text("Claude Code 用量桥接")
            } footer: {
                Text("把上面这段加进 ~/.claude/settings.json 的顶层对象，即可让 5 小时和 7 天窗口显示 Claude Code 提供的准确重置时间。LLM Pulse 不会替你修改该文件；删掉这段即可恢复原状。")
            }

            Section("系统") {
                Toggle("登录时启动 LLM Pulse", isOn: launchAtLoginBinding)

                if launchAtLogin.requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Label("需要在系统设置中允许登录项。", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开系统设置") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Text("任务和使用数据只从本机读取")
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("隐私")
            } footer: {
                Text(PulseL10n.text(
                    "LLM Pulse 只读取本机任务和使用数据，仅写入自己的未查看状态与偏好设置，不修改被监控工具的任务记录。",
                    language: settings.appLanguage
                ))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 560, idealHeight: 600)
        .navigationTitle(PulseL10n.text(
            "LLM Pulse 设置",
            language: settings.appLanguage
        ))
        .environment(\.locale, settings.appLanguage.locale)
        .environment(\.pulseLanguage, settings.appLanguage)
        .onAppear {
            launchAtLogin.refresh()
        }
        .task {
            await refreshNotificationAuthorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationAuthorizationStatus() }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { enabled in
                Task { await launchAtLogin.setEnabled(enabled) }
            }
        )
    }

    @ViewBuilder
    private func membershipOverrideControls(
        title: String,
        profileID: ModelProfileID
    ) -> some View {
        Toggle(
            PulseL10n.text("手动指定 %@ 到期日", language: settings.appLanguage, title),
            isOn: Binding(
                get: { settings.membershipExpiryOverride(for: profileID) != nil },
                set: { enabled in
                    settings.setMembershipExpiryOverride(
                        enabled ? Self.defaultExpiryDate() : nil,
                        for: profileID
                    )
                }
            )
        )
        if settings.membershipExpiryOverride(for: profileID) != nil {
            DatePicker(
                PulseL10n.text("到期日", language: settings.appLanguage),
                selection: Binding(
                    get: {
                        settings.membershipExpiryOverride(for: profileID) ?? .now
                    },
                    set: { settings.setMembershipExpiryOverride($0, for: profileID) }
                ),
                displayedComponents: .date
            )
        }
    }

    /// A month out: the most common cycle, and visibly a placeholder rather
    /// than a claim about the real date.
    private static func defaultExpiryDate() -> Date {
        Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    }

    /// The path is taken from the running bundle rather than assumed to be
    /// in /Applications: a copy run from anywhere else would otherwise hand
    /// the user a snippet pointing at a script that is not there.
    private var bridgeCommand: String {
        let script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/usage-bridge.sh")
            .path
        return "/bin/sh '\(script)'"
    }

    private var bridgeSnippet: String {
        let escaped = bridgeCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        "statusLine": {
          "type": "command",
          "command": "\(escaped)",
          "refreshInterval": 30
        }
        """
    }

    /// Reports what the bridge has actually delivered, not merely whether the
    /// setting looks installed — a command that never runs and one that was
    /// never added are indistinguishable from the user's side otherwise.
    private func bridgeStatus(asOf now: Date) -> String {
        let url = ClaudeCLIUsageReader.defaultURL()
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate
        ] as? Date else {
            return PulseL10n.text("未接入", language: settings.appLanguage)
        }
        return PulseL10n.text(
            "已接入 · 更新于 %@",
            language: settings.appLanguage,
            modified.pulseRelativeDescription(asOf: now, language: settings.appLanguage)
        )
    }

    private func copyBridgeSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bridgeSnippet, forType: .string)
        didCopyBridgeSnippet = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyBridgeSnippet = false
        }
    }

    private func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await NotificationCenterBridge.authorizationStatus(
            of: .current()
        )
    }

    private func openSystemNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
