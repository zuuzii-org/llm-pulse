import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @ObservedObject var settings: PulseSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginService

    let requestNotificationAuthorization: @MainActor () async -> Void

    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section("语言") {
                Picker("应用语言", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName(in: settings.appLanguage)).tag(language)
                    }
                }

                Text("切换后立即应用，无需重新启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Picker("提醒范围", selection: $settings.notificationAttentionLevel) {
                    ForEach(NotificationAttentionLevel.allCases) { level in
                        Text(level.title(language: settings.appLanguage)).tag(level)
                    }
                }
                .disabled(!settings.notificationsEnabled)

                Text(settings.notificationAttentionLevel.detail(language: settings.appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("隐私") {
                Text("V1 只读取本机 Codex 桌面版任务数据。LLM Pulse 仅写入自己的未查看状态与偏好设置，不修改 Codex 任务记录。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
