import AppKit
import Combine
import SwiftUI

enum ModelPageAccessibility {
    static func shouldAnnouncePageChange(
        previousProfileID: ModelProfileID?,
        origin: ModelSelectionOrigin,
        isPanelVisible: Bool
    ) -> Bool {
        previousProfileID != nil
            && origin == .userInitiated
            && isPanelVisible
    }
}

enum ModelTabPresentation {
    static func systemImageName(for profileID: ModelProfileID) -> String {
        switch profileID {
        case .codex:
            return "terminal"
        case .claudeCode:
            return "sparkles"
        case .glm:
            return "brain.head.profile"
        default:
            return "cpu"
        }
    }
}

enum ModelUsageCardPresentation {
    static func showsPlanUsage(
        identity: ModelIdentity,
        usage: ModelUsageSnapshot?
    ) -> Bool {
        identity.profileID == .claudeCode && usage?.hasPlanUsage == true
    }
}

struct TaskSidebarView: View {
    @ObservedObject var monitor: TaskMonitor
    @ObservedObject var settings: PulseSettings
    @ObservedObject var modelSelection: ModelSelectionStore
    let panelVisibilityState: TaskPanelVisibilityState

    let onOpenTask: (PulseTask) -> Bool
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    @FocusState private var focusedTaskID: String?
    @State private var openErrorMessage: String?
    @State private var expandedTaskIDs: Set<String> = []
    @State private var selectedProjectDirectory: String?
    @State private var muteStateDate = Date.now
    @State private var hasAttemptedInitialTaskFocus = false

    private let muteStateTimer = Timer.publish(
        every: 30,
        on: .main,
        in: .common
    ).autoconnect()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        monitor: TaskMonitor,
        settings: PulseSettings,
        modelSelection: ModelSelectionStore = ModelSelectionStore(),
        panelVisibilityState: TaskPanelVisibilityState = TaskPanelVisibilityState(),
        onOpenTask: @escaping (PulseTask) -> Bool,
        onDismiss: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.settings = settings
        self.modelSelection = modelSelection
        self.panelVisibilityState = panelVisibilityState
        self.onOpenTask = onOpenTask
        self.onDismiss = onDismiss
        self.onOpenSettings = onOpenSettings
    }

    private var hubSnapshot: PulseHubSnapshot { monitor.hubSnapshot }

    private var selectedModel: ModelTaskSnapshot? {
        if let selectedProfileID = modelSelection.selectedProfileID,
           let model = hubSnapshot.model(for: selectedProfileID) {
            return model
        }
        return hubSnapshot.model(for: .codex) ?? hubSnapshot.models.first
    }

    private var selectedModelDisplayName: String {
        selectedModel?.identity.displayName ?? "AI"
    }

    private var snapshot: TaskSnapshot {
        selectedModel?.taskSnapshot ?? .empty
    }

    private var shouldShowModelSwitcher: Bool {
        hubSnapshot.models.count > 1
    }

    private var allRunningTasks: [PulseTask] {
        snapshot.tasks
            .filter { !$0.state.isTerminal }
            .sorted(by: runningTaskSort)
    }

    private var runningTasks: [PulseTask] {
        filterToSelectedProject(allRunningTasks)
    }

    private var attentionTasks: [PulseTask] {
        allRunningTasks.filter {
            $0.state == .waitingForApproval || $0.state == .waitingForAnswer
        }
    }

    private var visibleAttentionTasks: [PulseTask] {
        runningTasks.filter {
            $0.state == .waitingForApproval || $0.state == .waitingForAnswer
        }
    }

    private var relevantTaskCount: Int {
        allRunningTasks.count
    }

    private var projectOptions: [ProjectScopeOption] {
        var taskByDirectory: [String: PulseTask] = [:]
        for task in snapshot.tasks where !task.projectIdentityDirectory.isEmpty {
            let identity = task.projectIdentityDirectory
            taskByDirectory[identity] = taskByDirectory[identity] ?? task
        }

        let nameCounts = Dictionary(
            grouping: taskByDirectory.values,
            by: { $0.projectDisplayName(language: settings.appLanguage) }
        ).mapValues(\.count)

        return taskByDirectory.values.map { task in
            let displayName = task.projectDisplayName(language: settings.appLanguage)
            let identity = task.projectIdentityDirectory
            let parentName = URL(fileURLWithPath: identity)
                .deletingLastPathComponent()
                .lastPathComponent
            let menuTitle = nameCounts[displayName, default: 0] > 1 && !parentName.isEmpty
                ? "\(displayName) — \(parentName)"
                : displayName
            return ProjectScopeOption(
                directory: identity,
                displayName: displayName,
                menuTitle: menuTitle
            )
        }
        .sorted {
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.directory < $1.directory
        }
    }

    private var selectedProject: ProjectScopeOption? {
        guard let selectedProjectDirectory else { return nil }
        return projectOptions.first { $0.directory == selectedProjectDirectory }
    }

    private var isInitialLoading: Bool {
        snapshot.refreshedAt == .distantPast && snapshot.health.isEmpty
    }

    private var unavailableHealth: [AdapterHealth] {
        snapshot.actionableHealth.filter { $0.status == .unavailable }
    }

    private var degradedHealth: [AdapterHealth] {
        snapshot.actionableHealth.filter { $0.status == .degraded }
    }

    private var hasHealthyStatusAdapter: Bool {
        TaskStatusSourceAvailability.hasHealthyAdapter(in: snapshot.health)
    }

    private var shouldShowHealthNotice: Bool {
        (!degradedHealth.isEmpty || !unavailableHealth.isEmpty)
            && (relevantTaskCount > 0 || hasHealthyStatusAdapter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)

            if shouldShowModelSwitcher {
                modelSwitcher
                Divider().opacity(0.45)
            }

            if let openErrorMessage {
                openErrorBanner(openErrorMessage)
                Divider().opacity(0.45)
            }

            modelTelemetry

            if let selectedProject {
                ProjectScopeBar(
                    project: selectedProject,
                    isMuted: settings.isProjectMuted(
                        selectedProject.directory,
                        asOf: muteStateDate
                    ),
                    onMuteForOneHour: {
                        muteProject(selectedProject.directory, duration: 60 * 60)
                    },
                    onMuteUntilTomorrow: {
                        muteProjectUntilTomorrow(selectedProject.directory)
                    },
                    onUnmute: {
                        settings.unmuteProject(selectedProject.directory)
                    },
                    onClear: {
                        selectedProjectDirectory = nil
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if shouldShowHealthNotice {
                healthNotice
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Group {
                if isInitialLoading {
                    loadingState
                } else if relevantTaskCount == 0
                    && !unavailableHealth.isEmpty
                    && !hasHealthyStatusAdapter {
                    errorState
                } else if relevantTaskCount == 0 {
                    emptyState
                } else {
                    taskContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.45)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.34)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, settings.appLanguage.locale)
        .environment(\.pulseLanguage, settings.appLanguage)
        .onAppear {
            modelSelection.reconcile(with: hubSnapshot)
            focusFirstTask()
        }
        .onChange(of: hubSnapshot.models.map(\.identity.profileID)) { _, _ in
            modelSelection.reconcile(with: hubSnapshot)
        }
        .onChange(of: modelSelection.selectedProfileID) { oldValue, newValue in
            selectedProjectDirectory = nil
            openErrorMessage = nil
            expandedTaskIDs.removeAll()
            focusFirstTask()
            announceModelPageChange(previousProfileID: oldValue, profileID: newValue)
        }
        .onChange(of: snapshot.tasks) { _, _ in
            preserveValidFocusAndExpansion()
            focusFirstTask()
        }
        .onChange(of: visibleAttentionTasks.map(\.id)) { _, taskIDs in
            guard let currentFocusedTaskID = focusedTaskID else { return }
            let visibleTaskIDs = Set(visibleFocusableTaskIDs)
            guard !visibleTaskIDs.contains(currentFocusedTaskID) else { return }
            focusedTaskID = settings.runningSectionExpanded
                ? taskIDs.first ?? firstVisibleTaskID
                : firstVisibleTaskID
        }
        .onChange(of: selectedProjectDirectory) { _, _ in
            focusFirstVisibleTask()
        }
        .onChange(of: settings.runningSectionExpanded) { _, _ in
            preserveVisibleFocus()
        }
        .onReceive(muteStateTimer) { date in
            muteStateDate = date
            settings.cleanupExpiredProjectMutes(asOf: date)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PulseBrand.displayName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(-0.35)

                Text(statusSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(minWidth: 92, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if let attentionTask = attentionTasks.first {
                Button {
                    openTask(attentionTask)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .accessibilityHidden(true)
                        Text("\(attentionTasks.count)")
                            .monospacedDigit()
                    }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .frame(height: 30)
                        .background(Color.orange.opacity(0.11), in: Capsule())
                        .contentShape(Capsule())
                        .layoutPriority(2)
                }
                .buttonStyle(.plain)
                .help("处理下一条等待授权或回答的任务")
                .accessibilityLabel(PulseL10n.text(
                    "需要你处理 %d 个任务，打开下一条",
                    language: settings.appLanguage,
                    attentionTasks.count
                ))
            }

            if !projectOptions.isEmpty {
                projectFilterMenu
            }

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("立即刷新")
            .accessibilityLabel("刷新任务和使用数据")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("关闭侧边栏")
            .accessibilityLabel("关闭侧边栏")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var modelTelemetry: some View {
        if let selectedModel, selectedModel.identity.profileID == .glm {
            let manualExpiry = settings.membershipExpiryOverride(for: .glm)
            VStack(spacing: 8) {
                ModelUsageCard(
                    identity: selectedModel.identity,
                    usage: selectedModel.usage,
                    membership: nil,
                    manualExpiry: nil
                )
                if RateLimitCardPresentation.shouldShowCard(
                    profileID: .glm,
                    rateLimits: selectedModel.rateLimits,
                    membership: selectedModel.membership,
                    manualExpiry: manualExpiry
                ) {
                    RateLimitCard(
                        profileID: .glm,
                        rateLimits: selectedModel.rateLimits,
                        membership: selectedModel.membership,
                        manualExpiry: manualExpiry
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        } else if let selectedModel, selectedModel.identity.profileID != .codex {
            ModelUsageCard(
                identity: selectedModel.identity,
                usage: selectedModel.usage,
                membership: selectedModel.membership,
                manualExpiry: settings.membershipExpiryOverride(
                    for: selectedModel.identity.profileID
                )
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        } else {
            RateLimitCard(
                profileID: .codex,
                rateLimits: snapshot.rateLimits,
                membership: selectedModel?.membership,
                manualExpiry: settings.membershipExpiryOverride(for: .codex)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }

    private var modelSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(hubSnapshot.models, id: \.identity.profileID) { model in
                let isSelected = model.identity.profileID == selectedModel?.identity.profileID
                let position = (hubSnapshot.models.firstIndex {
                    $0.identity.profileID == model.identity.profileID
                } ?? 0) + 1
                Button {
                    _ = modelSelection.select(model.identity.profileID)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: ModelTabPresentation.systemImageName(
                            for: model.identity.profileID
                        ))
                            .accessibilityHidden(true)
                        Text(model.identity.displayName)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        isSelected ? TaskSidebarPalette.selectedModelInk : Color.secondary
                    )
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                    .background(
                        isSelected
                            ? TaskSidebarPalette.selectedModelInk.opacity(0.15)
                            : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(modelSelection.isSelectionLocked)
                .accessibilityLabel(PulseL10n.text(
                    "%@ 模型标签，第 %d 个，共 %d 个",
                    language: settings.appLanguage,
                    model.identity.displayName,
                    position,
                    hubSnapshot.models.count
                ))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PulseL10n.text("模型", language: settings.appLanguage))
        // A trackpad gesture is invisible until someone tries it, and the
        // keyboard route is the only one available without a trackpad.
        .help(PulseL10n.text(
            "双指左右滑动，或按 Control+←/→ 切换模型",
            language: settings.appLanguage
        ))
        .accessibilityHint(PulseL10n.text(
            "双指左右滑动，或按 Control 加左右方向键切换模型",
            language: settings.appLanguage
        ))
    }

    private func announceModelPageChange(
        previousProfileID: ModelProfileID?,
        profileID: ModelProfileID?
    ) {
        guard ModelPageAccessibility.shouldAnnouncePageChange(
            previousProfileID: previousProfileID,
            origin: modelSelection.lastChangeOrigin,
            isPanelVisible: panelVisibilityState.isVisible
        ), let profileID,
           let index = hubSnapshot.models.firstIndex(where: {
               $0.identity.profileID == profileID
           }) else {
            return
        }
        let model = hubSnapshot.models[index]
        let message = PulseL10n.text(
            "已切换到 %@ 模型页面，第 %d 个，共 %d 个",
            language: settings.appLanguage,
            model.identity.displayName,
            index + 1,
            hubSnapshot.models.count
        )
        NSAccessibility.post(
            element: NSApp,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private var projectFilterMenu: some View {
        Menu {
            Button {
                selectedProjectDirectory = nil
            } label: {
                Label("全部项目", systemImage: selectedProjectDirectory == nil ? "checkmark" : "folder")
            }

            Divider()

            ForEach(projectOptions) { project in
                Button {
                    selectedProjectDirectory = project.directory
                } label: {
                    Label(
                        project.menuTitle,
                        systemImage: selectedProjectDirectory == project.directory
                            ? "checkmark"
                            : "folder"
                    )
                }
            }
        } label: {
            Image(systemName: selectedProjectDirectory == nil ? "folder" : "folder.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selectedProjectDirectory == nil ? Color.secondary : Color.accentColor)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selectedProject == nil
            ? PulseL10n.text("按项目筛选", language: settings.appLanguage)
            : PulseL10n.text(
                "当前仅显示 %@",
                language: settings.appLanguage,
                selectedProject?.menuTitle ?? ""
            ))
        .accessibilityLabel(selectedProject == nil
            ? PulseL10n.text("按项目筛选，当前显示全部项目", language: settings.appLanguage)
            : PulseL10n.text(
                "按项目筛选，当前仅显示 %@",
                language: settings.appLanguage,
                selectedProject?.menuTitle ?? ""
            ))
    }

    private func openErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                openErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("关闭错误提示")
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.09))
        .accessibilityElement(children: .contain)
    }

    private var taskContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 15) {
                runningSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 18)
        }
    }

    private var runningSection: some View {
        TaskGroupSection(
            descriptor: .running,
            tasks: runningTasks,
            isExpanded: $settings.runningSectionExpanded,
            focusedTaskID: $focusedTaskID,
            expandedTaskIDs: expandedTaskIDs,
            onOpenTask: openTask,
            onToggleExpanded: toggleExpanded,
            onFocusProject: focusProject,
            projectAccessibilityName: projectAccessibilityName,
            isProjectMuted: isProjectMuted,
            onMuteProjectForOneHour: { task in
                muteProject(task.projectIdentityDirectory, duration: 60 * 60)
            },
            onMuteProjectUntilTomorrow: { task in
                muteProjectUntilTomorrow(task.projectIdentityDirectory)
            },
            onUnmuteProject: { task in
                settings.unmuteProject(task.projectIdentityDirectory)
            }
        )
    }

    private var healthNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("部分数据源暂不可用")
                    .font(.caption.weight(.semibold))
                Text(healthSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yellow.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text(PulseL10n.text(
                "正在读取 %@ 任务…",
                language: settings.appLanguage,
                selectedModelDisplayName
            ))
                .font(.subheadline.weight(.medium))
            Text(PulseL10n.text(
                "任务和使用数据只从本机读取",
                language: settings.appLanguage
            ))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PulseL10n.text(
            "正在读取 %@ 的本机任务和使用数据",
            language: settings.appLanguage,
            selectedModelDisplayName
        ))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂时没有任务", systemImage: "checkmark.circle")
        } description: {
            Text("正在运行和等待操作的任务会显示在这里。")
        } actions: {
            Button("重新检查") {
                monitor.refresh()
            }
        }
    }

    private var errorState: some View {
        ContentUnavailableView {
            Label("暂时无法读取任务", systemImage: "exclamationmark.triangle")
        } description: {
            Text(healthSummary)
        } actions: {
            Button("重试") {
                monitor.refresh()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(footerHealthColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(footerStatusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(action: onOpenSettings) {
                Label("设置", systemImage: "gearshape")
                    .font(.caption.weight(.medium))
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开 LLM Pulse 设置")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var statusSummary: String {
        let waiting = snapshot.tasks.lazy.filter {
            $0.state == .waitingForApproval || $0.state == .waitingForAnswer
        }.count
        return PulseL10n.text(
            "待处理 %d · 运行 %d",
            language: settings.appLanguage,
            waiting,
            max(0, snapshot.activeCount - waiting)
        )
    }

    private var healthSummary: String {
        let messages = (unavailableHealth + degradedHealth).map {
            $0.displayMessage(language: settings.appLanguage)
        }
        return messages.isEmpty
            ? PulseL10n.text(
                "%@ 数据源没有响应，请稍后重试。",
                language: settings.appLanguage,
                selectedModelDisplayName
            )
            : messages.joined(separator: " · ")
    }

    private var footerHealthColor: Color {
        if !unavailableHealth.isEmpty { return .red }
        if !degradedHealth.isEmpty { return .yellow }
        return .green
    }

    private var footerStatusText: String {
        let healthText: String
        if !unavailableHealth.isEmpty {
            healthText = PulseL10n.text("数据异常", language: settings.appLanguage)
        } else if !degradedHealth.isEmpty {
            healthText = PulseL10n.text("数据降级", language: settings.appLanguage)
        } else {
            healthText = PulseL10n.text("数据健康", language: settings.appLanguage)
        }

        guard snapshot.refreshedAt != .distantPast else {
            return healthText + " · "
                + PulseL10n.text("待刷新", language: settings.appLanguage)
        }
        return healthText + " · " + PulseL10n.text(
            "更新于 %@",
            language: settings.appLanguage,
            snapshot.refreshedAt.pulseRelativeDescription(language: settings.appLanguage)
        )
    }

    private func runningTaskSort(_ lhs: PulseTask, _ rhs: PulseTask) -> Bool {
        let leftPriority = lhs.state.activeSortPriority
        let rightPriority = rhs.state.activeSortPriority
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func focusFirstTask() {
        guard !hasAttemptedInitialTaskFocus else { return }
        guard focusedTaskID == nil else { return }
        guard let firstTaskID = firstVisibleTaskID else { return }
        hasAttemptedInitialTaskFocus = true
        focusedTaskID = firstTaskID
    }

    private func focusFirstVisibleTask() {
        focusedTaskID = firstVisibleTaskID
    }

    private var firstVisibleTaskID: String? {
        visibleFocusableTaskIDs.first
    }

    private var visibleFocusableTaskIDs: [String] {
        TaskSidebarSectionState.visibleTaskIDs(
            runningTaskIDs: runningTasks.map(\.id),
            runningSectionExpanded: settings.runningSectionExpanded
        )
    }

    private func preserveVisibleFocus() {
        guard let focusedTaskID else { return }
        let visibleTaskIDs = Set(visibleFocusableTaskIDs)
        guard !visibleTaskIDs.contains(focusedTaskID) else { return }
        self.focusedTaskID = firstVisibleTaskID
    }

    private func preserveValidFocusAndExpansion() {
        if let selectedProjectDirectory,
           !projectOptions.contains(where: { $0.directory == selectedProjectDirectory }) {
            self.selectedProjectDirectory = nil
        }

        let taskIDs = Set(runningTasks.map(\.id))
        if let focusedTaskID, !taskIDs.contains(focusedTaskID) {
            self.focusedTaskID = firstVisibleTaskID
        } else {
            preserveVisibleFocus()
        }
        expandedTaskIDs = TaskSidebarSectionState.preservedExpandedTaskIDs(
            expandedTaskIDs,
            existingTaskIDs: taskIDs
        )
    }

    private func toggleExpanded(_ task: PulseTask) {
        let update = {
            if expandedTaskIDs.contains(task.id) {
                expandedTaskIDs.remove(task.id)
            } else {
                expandedTaskIDs.insert(task.id)
            }
        }

        if reduceMotion {
            update()
        } else {
            withAnimation(.easeOut(duration: 0.18), update)
        }
    }

    private func filterToSelectedProject(_ tasks: [PulseTask]) -> [PulseTask] {
        guard let selectedProjectDirectory else { return tasks }
        return tasks.filter { $0.projectIdentityDirectory == selectedProjectDirectory }
    }

    private func focusProject(_ task: PulseTask) {
        guard !task.projectIdentityDirectory.isEmpty else { return }
        selectedProjectDirectory = task.projectIdentityDirectory
    }

    private func projectAccessibilityName(_ task: PulseTask) -> String {
        let displayName = task.projectDisplayName(language: settings.appLanguage)
        let identity = task.projectIdentityDirectory
        guard !identity.isEmpty else { return displayName }

        let parentName = URL(fileURLWithPath: identity)
            .deletingLastPathComponent()
            .lastPathComponent
        return parentName.isEmpty
            ? displayName
            : PulseL10n.text(
                "%@，位于 %@",
                language: settings.appLanguage,
                displayName,
                parentName
            )
    }

    private func isProjectMuted(_ task: PulseTask) -> Bool {
        guard !task.projectIdentityDirectory.isEmpty else { return false }
        return settings.isProjectMuted(task.projectIdentityDirectory, asOf: muteStateDate)
    }

    private func muteProject(_ directory: String, duration: TimeInterval) {
        guard !directory.isEmpty else { return }
        settings.muteProject(directory, until: Date.now.addingTimeInterval(duration))
    }

    private func muteProjectUntilTomorrow(_ directory: String) {
        guard !directory.isEmpty else { return }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return
        }
        settings.muteProject(directory, until: tomorrow)
    }

    private func openTask(_ task: PulseTask) {
        if onOpenTask(task) {
            openErrorMessage = nil
        } else {
            openErrorMessage = PulseL10n.text(
                "无法打开“%@”。请确认对应应用已安装；Claude Code 和 ZCode 还需保持运行。",
                language: settings.appLanguage,
                task.title
            )
        }
    }
}

enum TaskSidebarSectionState {
    static func visibleTaskIDs(
        runningTaskIDs: [String],
        runningSectionExpanded: Bool
    ) -> [String] {
        runningSectionExpanded ? runningTaskIDs : []
    }

    static func preservedExpandedTaskIDs(
        _ expandedTaskIDs: Set<String>,
        existingTaskIDs: Set<String>
    ) -> Set<String> {
        expandedTaskIDs.intersection(existingTaskIDs)
    }
}

private struct ProjectScopeOption: Identifiable, Equatable {
    let directory: String
    let displayName: String
    let menuTitle: String

    var id: String { directory }
}

private struct ProjectScopeBar: View {
    let project: ProjectScopeOption
    let isMuted: Bool
    let onMuteForOneHour: () -> Void
    let onMuteUntilTomorrow: () -> Void
    let onUnmute: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("仅看 \(project.displayName)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(project.directory)
                .accessibilityLabel("仅看 \(project.menuTitle)")

            Spacer(minLength: 6)

            if isMuted {
                Label("已静音", systemImage: "bell.slash.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            Menu {
                if isMuted {
                    Button("取消项目静音", action: onUnmute)
                } else {
                    Button("通知静音 1 小时", action: onMuteForOneHour)
                    Button("通知静音到明天", action: onMuteUntilTomorrow)
                }
            } label: {
                Image(systemName: isMuted ? "bell.slash.fill" : "bell")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(isMuted ? "管理项目静音" : "临时静音此项目的通知")
            .accessibilityLabel(isMuted ? "管理项目静音" : "临时静音此项目通知")

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("显示全部项目")
            .accessibilityLabel("清除项目筛选，显示全部项目")
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(Color.accentColor.opacity(0.085), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ModelUsageCard: View {
    @Environment(\.pulseLanguage) private var language

    let identity: ModelIdentity
    let usage: ModelUsageSnapshot?
    let membership: MembershipObservation?
    let manualExpiry: Date?

    private var membershipDisplay: MembershipDisplay? {
        MembershipDisplay.resolve(
            observation: membership,
            manualExpiry: manualExpiry,
            now: .now
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(identity.displayName)
                        .font(.caption.weight(.semibold))
                    Text(PulseL10n.text("本机观测", language: language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let usage {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(PulseL10n.text(
                            "共 %@ tokens",
                            language: language,
                            Self.tokenFormatter.string(
                                from: NSNumber(value: usage.totalTokens)
                            ) ?? "\(usage.totalTokens)"
                        ))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        Text(PulseL10n.text(
                            "已观测 %d 次请求",
                            language: language,
                            usage.observedRequestCount
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(PulseL10n.text("待刷新", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if ModelUsageCardPresentation.showsPlanUsage(
                identity: identity,
                usage: usage
            ), let usage {
                Divider().opacity(0.32)
                planUsage(usage)
            } else if membershipDisplay != nil {
                Divider().opacity(0.32)
            }
            if let membershipDisplay {
                MembershipRowView(display: membershipDisplay, now: .now)
            }
            if ModelUsageCardPresentation.showsPlanUsage(
                identity: identity,
                usage: usage
            ), let usage {
                Text(planUsageFootnote(usage))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain)
    }

    /// Account-level windows, drawn as plain bars rather than as the quota
    /// card Codex uses.
    ///
    /// The two carry different guarantees: Codex reports a window with an
    /// exact reset time, while these have none and also span the whole
    /// account. Making them look alike would invite reading one as the other,
    /// so the footnote states both limits rather than leaving them implied.
    @ViewBuilder
    private func planUsage(_ usage: ModelUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let window = usage.fiveHourWindow {
                planUsageRow(
                    title: PulseL10n.text("5 小时窗口", language: language),
                    window: window
                )
            }
            if let window = usage.sevenDayWindow {
                planUsageRow(
                    title: PulseL10n.text("7 天窗口", language: language),
                    window: window
                )
            }
        }
    }

    private func planUsageRow(title: String, window: PlanUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(planUsageResetText(window))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(planUsageResetHelp(window))
                Text(PulseL10n.text(
                    "已用 %d%%",
                    language: language,
                    window.usedPercent
                ))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(TaskSidebarPalette.selectedModelInk.opacity(0.75))
                        .frame(
                            width: max(
                                0,
                                proxy.size.width * CGFloat(window.usedPercent) / 100
                            )
                        )
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(planUsageAccessibilityText(title: title, window: window))
    }

    /// The caveat that matters most, which is not always the same one.
    ///
    /// Only the desktop app writes these percentages, and only while it is
    /// open, so on a CLI-first machine they routinely sit hours behind. When
    /// that happens the age is the dominant caveat and displaces the usual
    /// note about estimated resets: a weekly figure from this morning is
    /// still a useful lower bound, but only if the reader can see that is
    /// what it is.
    private func planUsageFootnote(_ usage: ModelUsageSnapshot) -> String {
        let now = Date.now
        if usage.planUsageIsStale(asOf: now), let observedAt = usage.planUsageObservedAt {
            return PulseL10n.text(
                "账户级用量 · 数据截至 %@",
                language: language,
                PulseDisplayClock.concrete(observedAt, language: language)
            )
        }
        if usage.hasInferredResets {
            return PulseL10n.text("账户级用量 · 重置时间为估算", language: language)
        }
        if usage.hasReportedResets {
            return PulseL10n.text("账户级用量 · 重置时间来自 Claude Code", language: language)
        }
        return PulseL10n.text("账户级用量 · 无重置时间", language: language)
    }

    /// "约 8月23日 20:59 重置" — a full date and clock time on the product's
    /// display timezone, the same for both windows so the two rows read as
    /// one system.
    ///
    /// When the reset cannot be inferred the row says so rather than going
    /// blank. A window that opened while the desktop app was closed has no
    /// sampled opening to bracket, which is now the ordinary case rather than
    /// the exception — and a silent gap where a time belongs reads as a
    /// broken app, which is exactly how it was reported.
    ///
    /// Nothing is offered in its place on purpose. The window containing the
    /// newest sample opened somewhere in the five hours before it, and every
    /// tighter bound available here rests on a run of non-decreasing
    /// percentages being one window — which a reset hides whenever usage
    /// before it was lower than usage after, the `0 → 5` case the opening
    /// detector itself is built to catch. A ceiling that can sit earlier than
    /// the real reset would have the user waiting on quota that has not
    /// returned, so the honest answer is that it is unknown.
    private func planUsageResetText(_ window: PlanUsageWindow) -> String {
        guard let resetsAt = window.resetsAt else {
            // A five-hour window at zero has not started rather than gone
            // missing: it opens on the first request after the previous one
            // expired, which is why the history is full of 0 → 6 jumps. That
            // is a third of the recorded time on a real machine, so calling
            // it "unknown" would spend a third of the product's life implying
            // its own data is broken.
            return window.hasNotStarted
                ? PulseL10n.text("尚未开始", language: language)
                : PulseL10n.text("重置时间未知", language: language)
        }
        let moment = PulseDisplayClock.concrete(resetsAt, language: language)
        // The vendor's own value gets stated; a bracketed one keeps its "约".
        // Wearing the same words would make the hedge meaningless on the rows
        // that actually need it.
        return window.resetSource == .reported
            ? PulseL10n.text("%@ 重置", language: language, moment)
            : PulseL10n.text("约 %@ 重置", language: language, moment)
    }

    private func planUsageResetHelp(_ window: PlanUsageWindow) -> String {
        switch window.resetSource {
        case .reported:
            return PulseL10n.text("由 Claude Code 提供的准确时间", language: language)
        case .inferred:
            return PulseL10n.text("由用量记录推算，误差在采样间隔以内", language: language)
        case nil where window.hasNotStarted:
            return PulseL10n.text(
                "5 小时窗口在下一次请求时开始计时，届时按 5 小时整重置",
                language: language
            )
        case nil:
            return PulseL10n.text(
                "该窗口开启时桌面应用未在采样，无法推算重置时间；接入 Claude Code 可获得准确时间",
                language: language
            )
        }
    }

    private func planUsageAccessibilityText(
        title: String,
        window: PlanUsageWindow
    ) -> String {
        let base = PulseL10n.text(
            "%@已用 %d%%",
            language: language,
            title,
            window.usedPercent
        )
        return PulseL10n.text(
            "%@，%@",
            language: language,
            base,
            planUsageResetText(window)
        )
    }

    private static let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

enum MembershipRowPresentation {
    static func dateText(
        for display: MembershipDisplay,
        asOf now: Date,
        language: AppLanguage
    ) -> String? {
        guard let date = display.date, let kind = display.kind else { return nil }
        if date <= now {
            switch kind {
            case .manualExpiry, .vendorExpiry, .trialEnd:
                return PulseL10n.text("已到期", language: language)
            case .vendorRenewal:
                return PulseL10n.text("续费信息待刷新", language: language)
            case .derivedRenewal:
                return nil
            }
        }

        let formatted = PulseDisplayClock.day(date, language: language)
        switch kind {
        case .manualExpiry, .vendorExpiry:
            return PulseL10n.text("%@ 到期", language: language, formatted)
        case .vendorRenewal:
            return PulseL10n.text("%@ 续费", language: language, formatted)
        case .trialEnd:
            return PulseL10n.text("试用至 %@", language: language, formatted)
        case .derivedRenewal:
            return PulseL10n.text("约 %@ 续费", language: language, formatted)
        }
    }
}

/// One line of membership state, shared by the usage and quota cards.
///
/// The date's provenance decides its wording and verb. A derived renewal keeps
/// its "约"; an observed auto-renew says "续费"; a confirmed cancellation says
/// "到期". Expiry urgency is color — orange within a week and red once past;
/// a stale renewal instead asks for refreshed data in neutral text.
private struct MembershipRowView: View {
    @Environment(\.pulseLanguage) private var language

    let display: MembershipDisplay
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(PulseL10n.text("会员", language: language))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            if let tier = display.tierDisplayName {
                Text(tier)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let dateText {
                Text(dateText)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(dateColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var dateText: String? {
        MembershipRowPresentation.dateText(
            for: display,
            asOf: now,
            language: language
        )
    }

    private var dateColor: Color {
        guard let date = display.date else { return .secondary }
        if date <= now {
            switch display.kind {
            case .manualExpiry, .vendorExpiry, .trialEnd:
                return .red
            case .vendorRenewal, .derivedRenewal, nil:
                return .secondary
            }
        }
        if date.timeIntervalSince(now) <= 7 * 24 * 60 * 60 {
            return TaskSidebarPalette.selectedModelInk
        }
        return .secondary
    }

    private var accessibilityText: String {
        var parts = [PulseL10n.text("会员", language: language)]
        if let tier = display.tierDisplayName { parts.append(tier) }
        if let dateText { parts.append(dateText) }
        return parts.dropFirst().reduce(parts[0]) { joined, part in
            PulseL10n.text("%@，%@", language: language, joined, part)
        }
    }
}

enum RateLimitCardPresentation {
    enum WindowID: Hashable {
        case fiveHour
        case sevenDay
    }

    struct Window: Identifiable {
        let id: WindowID
        let titleKey: String
        let helpTextKey: String
        let window: RateLimitWindowSnapshot?
    }

    static func windows(
        profileID: ModelProfileID,
        rateLimits: RateLimitSnapshot?
    ) -> [Window] {
        if profileID == .codex {
            return [Window(
                id: .sevenDay,
                titleKey: "本周余额",
                helpTextKey: "本周额度的剩余比例",
                window: rateLimits?.weekly
            )]
        }
        if profileID == .glm, let rateLimits {
            var windows: [Window] = []
            if let fiveHour = rateLimits.fiveHour {
                windows.append(Window(
                    id: .fiveHour,
                    titleKey: "5h 余额",
                    helpTextKey: "最近 5 小时额度的剩余比例",
                    window: fiveHour
                ))
            }
            if let weekly = rateLimits.weekly {
                windows.append(Window(
                    id: .sevenDay,
                    titleKey: "7 天余额",
                    helpTextKey: "7 天额度的剩余比例",
                    window: weekly
                ))
            }
            return windows
        }
        return []
    }

    static func shouldShowCard(
        profileID: ModelProfileID,
        rateLimits: RateLimitSnapshot?,
        membership: MembershipObservation?,
        manualExpiry: Date?
    ) -> Bool {
        guard profileID == .glm else { return true }
        return !windows(profileID: profileID, rateLimits: rateLimits).isEmpty
            || membership?.isEmpty == false
            || manualExpiry != nil
    }

    static func displayedWindowMinutes(_ rateLimits: RateLimitSnapshot?) -> [Int] {
        displayedWindowMinutes(profileID: .codex, rateLimits: rateLimits)
    }

    static func displayedWindowMinutes(
        profileID: ModelProfileID,
        rateLimits: RateLimitSnapshot?
    ) -> [Int] {
        windows(profileID: profileID, rateLimits: rateLimits).compactMap {
            $0.window?.windowMinutes
        }
    }

    static func hasCurrentWeeklyWindow(
        _ rateLimits: RateLimitSnapshot?,
        asOf date: Date
    ) -> Bool {
        rateLimits?.weekly?.remainingPercent(asOf: date) != nil
    }

    static func hasCurrentDisplayedWindow(
        profileID: ModelProfileID,
        rateLimits: RateLimitSnapshot?,
        asOf date: Date
    ) -> Bool {
        windows(profileID: profileID, rateLimits: rateLimits).contains {
            $0.window?.remainingPercent(asOf: date) != nil
        }
    }
}

private struct RateLimitCard: View {
    @Environment(\.pulseLanguage) private var language

    let profileID: ModelProfileID
    let rateLimits: RateLimitSnapshot?
    let membership: MembershipObservation?
    let manualExpiry: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let windows = RateLimitCardPresentation.windows(
                profileID: profileID,
                rateLimits: rateLimits
            )
            let membershipDisplay = MembershipDisplay.resolve(
                observation: membership,
                manualExpiry: manualExpiry,
                now: context.date
            )
            VStack(spacing: 0) {
                ForEach(windows) { presentation in
                    if presentation.id != windows.first?.id {
                        Divider()
                            .opacity(0.24)
                            .padding(.horizontal, 14)
                    }
                    QuotaWindowRow(
                        title: PulseL10n.text(presentation.titleKey, language: language),
                        helpText: PulseL10n.text(
                            presentation.helpTextKey,
                            language: language
                        ),
                        window: presentation.window,
                        asOf: context.date
                    )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }

                if let membershipDisplay {
                    MembershipRowView(display: membershipDisplay, now: context.date)
                        .padding(.horizontal, 14)
                        .padding(.top, windows.isEmpty ? 7 : 0)
                        .padding(.bottom, 7)
                }

                if !windows.isEmpty {
                    Divider().opacity(0.38)

                    Text(freshnessText(asOf: context.date))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                }
            }
        }
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func freshnessText(asOf date: Date) -> String {
        guard let rateLimits else {
            return PulseL10n.text("额度待刷新", language: language)
        }
        guard RateLimitCardPresentation.hasCurrentDisplayedWindow(
            profileID: profileID,
            rateLimits: rateLimits,
            asOf: date
        ) else {
            return PulseL10n.text("额度待刷新", language: language)
        }
        return PulseL10n.text(
            "更新于 %@",
            language: language,
            rateLimits.updatedAt.pulseRelativeDescription(asOf: date, language: language)
        )
    }
}

private struct QuotaWindowRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pulseLanguage) private var language

    let title: String
    let helpText: String
    let window: RateLimitWindowSnapshot?
    let asOf: Date

    private var remainingPercent: Double? {
        window?.remainingPercent(asOf: asOf)
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Image(systemName: "info.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help(helpText)
                    .accessibilityHidden(true)
            }
            .frame(width: 72, alignment: .leading)

            Group {
                if let remainingPercent {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.13))

                            Capsule()
                                .fill(quotaAccent)
                                .frame(
                                    width: proxy.size.width
                                        * min(max(remainingPercent / 100, 0), 1)
                                )
                                .shadow(color: quotaAccent.opacity(0.28), radius: 1)
                        }
                    }
                    .frame(height: 6)
                } else {
                    ProgressView()
                        .tint(Color.secondary)
                        .opacity(0.7)
                        .progressViewStyle(.linear)
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(balanceText)

            Text(balanceText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(remainingPercent == nil ? Color.secondary : quotaAccent)
                .frame(width: 66, alignment: .trailing)

            Text(resetText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .frame(width: 128, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var quotaAccent: Color {
        colorScheme == .dark
            ? Color(red: 0.28, green: 0.68, blue: 1.0)
            : Color(red: 0.0, green: 0.36, blue: 0.78)
    }

    private var balanceText: String {
        guard let remainingPercent else {
            return PulseL10n.text("待刷新", language: language)
        }
        return PulseL10n.text(
            "%d%% 剩余",
            language: language,
            Int(remainingPercent.rounded())
        )
    }

    private var resetText: String {
        guard remainingPercent != nil, let window else { return "—" }
        return window.resetsAt.pulseQuotaResetDescription(
            asOf: asOf,
            language: language
        )
    }
}

enum TaskStatusSourceAvailability {
    static func hasHealthyAdapter(in health: [AdapterHealth]) -> Bool {
        health.contains {
            guard $0.status == .healthy else { return false }
            switch $0.adapter {
            case .rolloutJSONL,
                 .pluginJournal,
                 .claudeSessionRegistry,
                 .claudeTranscript,
                 .zcodeSQLite,
                 .zcodeEventLog:
                return true
            case .appServer,
                 .sqlite,
                 .receipts,
                 .runtimeSource,
                 .claudeAgentJournal,
                 .zcodeEntitlementCache:
                return false
            }
        }
    }
}

private struct TaskGroupSection: View {
    @Environment(\.pulseLanguage) private var language

    let descriptor: TaskGroupDescriptor
    let tasks: [PulseTask]
    @Binding var isExpanded: Bool
    let focusedTaskID: FocusState<String?>.Binding
    let expandedTaskIDs: Set<String>
    let onOpenTask: (PulseTask) -> Void
    let onToggleExpanded: (PulseTask) -> Void
    let onFocusProject: (PulseTask) -> Void
    let projectAccessibilityName: (PulseTask) -> String
    let isProjectMuted: (PulseTask) -> Bool
    let onMuteProjectForOneHour: (PulseTask) -> Void
    let onMuteProjectUntilTomorrow: (PulseTask) -> Void
    let onUnmuteProject: (PulseTask) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DisclosureGroup(isExpanded: disclosureBinding) {
                    EmptyView()
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(descriptor.color)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)

                        Text(PulseL10n.text(descriptor.title, language: language))
                            .font(.caption.weight(.semibold))

                        Text("\(tasks.count)")
                            .font(.caption.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .disclosureGroupStyle(.automatic)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("task-group-\(descriptor.id)-disclosure")

            }
            .padding(.horizontal, 2)

            if isExpanded {
                VStack(spacing: 0) {
                    if tasks.isEmpty {
                        Text(PulseL10n.text(descriptor.emptyMessage, language: language))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                            TaskListItem(
                                task: task,
                                isExpanded: expandedTaskIDs.contains(task.id),
                                focusedTaskID: focusedTaskID,
                                isProjectMuted: isProjectMuted(task),
                                projectAccessibilityName: projectAccessibilityName(task),
                                onOpenTask: { onOpenTask(task) },
                                onToggleExpanded: { onToggleExpanded(task) },
                                onFocusProject: { onFocusProject(task) },
                                onMuteProjectForOneHour: { onMuteProjectForOneHour(task) },
                                onMuteProjectUntilTomorrow: { onMuteProjectUntilTomorrow(task) },
                                onUnmuteProject: { onUnmuteProject(task) }
                            )

                            if index < tasks.index(before: tasks.endIndex) {
                                Divider()
                                    .opacity(0.42)
                                    .padding(.leading, 50)
                            }
                        }
                    }
                }
                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var disclosureBinding: Binding<Bool> {
        Binding(
            get: { isExpanded },
            set: { expanded in
                var transaction = Transaction()
                transaction.animation = reduceMotion ? nil : .easeOut(duration: 0.18)
                withTransaction(transaction) {
                    isExpanded = expanded
                }
            }
        )
    }
}

private struct TaskListItem: View {
    @Environment(\.pulseLanguage) private var language

    let task: PulseTask
    let isExpanded: Bool
    let focusedTaskID: FocusState<String?>.Binding
    let isProjectMuted: Bool
    let projectAccessibilityName: String
    let onOpenTask: () -> Void
    let onToggleExpanded: () -> Void
    let onFocusProject: () -> Void
    let onMuteProjectForOneHour: () -> Void
    let onMuteProjectUntilTomorrow: () -> Void
    let onUnmuteProject: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var canExpand: Bool {
        task.tokenUsage?.hasBreakdown == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onOpenTask) {
                    TaskRowSummary(task: task, isProjectMuted: isProjectMuted)
                        .padding(.leading, 10)
                        .padding(.vertical, 8)
                        .padding(.trailing, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .focused(focusedTaskID, equals: task.id)
                .accessibilityLabel(
                    task.accessibilityLabel(
                        projectName: projectAccessibilityName,
                        language: language
                    ) + (isProjectMuted
                        ? PulseL10n.text("，此项目通知已静音", language: language)
                        : "")
                )
                .accessibilityHint(PulseL10n.text(
                    "打开对应应用；支持时定位到此任务",
                    language: language
                ))

                if canExpand {
                    Button(action: onToggleExpanded) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 32, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isExpanded ? "收起 token 明细" : "展开 token 明细")
                    .accessibilityLabel(isExpanded ? "收起 token 明细" : "展开 token 明细")
                }

            }

            if isExpanded, let tokenUsage = task.tokenUsage {
                TokenBreakdownView(tokenUsage: tokenUsage)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(reduceMotion
                        ? .identity
                        : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            ZStack {
                if isExpanded {
                    Color.accentColor.opacity(0.085)
                }
                if isHovering {
                    Color.white.opacity(0.035)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    focusedTaskID.wrappedValue == task.id
                        ? Color.accentColor.opacity(0.82)
                        : Color.clear,
                    lineWidth: 1.5
                )
                .padding(2)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            if !task.projectIdentityDirectory.isEmpty {
                Button {
                    onFocusProject()
                } label: {
                    Label("仅看此项目", systemImage: "line.3.horizontal.decrease.circle")
                }

                Divider()

                if isProjectMuted {
                    Button {
                        onUnmuteProject()
                    } label: {
                        Label("取消项目静音", systemImage: "bell")
                    }
                } else {
                    Button {
                        onMuteProjectForOneHour()
                    } label: {
                        Label("通知静音 1 小时", systemImage: "bell.slash")
                    }

                    Button {
                        onMuteProjectUntilTomorrow()
                    } label: {
                        Label("通知静音到明天", systemImage: "moon")
                    }
                }
            }
        }
    }
}

private struct TaskRowSummary: View {
    @Environment(\.pulseLanguage) private var language

    let task: PulseTask
    let isProjectMuted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            stateIcon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(task.projectDisplayName(language: language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(task.state.tintColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isProjectMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("此项目通知已静音")
                    }
                }
                .help(task.projectDirectory.isEmpty ? "未识别项目路径" : task.projectDirectory)

                Text(task.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(task.state.tintColor)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)

                        Text(task.rowStatusText(language: language))
                            .foregroundStyle(task.state.tintColor)

                        Text("·")

                        Text(task.activityDate.pulseRelativeDescription(
                            asOf: context.date,
                            language: language
                        ))
                            .lineLimit(1)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if task.hasTrailingMetrics {
                TaskMetricRail(task: task)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(task.state.tintColor.opacity(0.13))
            Image(systemName: task.state.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(task.state.tintColor)
        }
        .frame(width: 28, height: 28)
        .symbolEffect(
            .pulse,
            options: .repeating,
            isActive: task.state == .running && !reduceMotion
        )
        .accessibilityHidden(true)
    }
}

private struct TaskMetricRail: View {
    let task: PulseTask

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let tokenUsage = task.tokenUsage {
                Text(tokenUsage.totalTokens > 0 ? tokenUsage.compactTotalText + " tokens" : "—")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let observation = task.agentActivity {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    AgentActivityBadge(
                        observation: observation,
                        taskState: task.state,
                        now: context.date
                    )
                }
            }
        }
        .frame(width: 96, alignment: .trailing)
    }
}

private struct TokenBreakdownView: View {
    @Environment(\.pulseLanguage) private var language

    let tokenUsage: TokenUsageSnapshot

    private var items: [TokenBreakdownItem] {
        [
            TokenBreakdownItem(
                title: "输入",
                value: tokenUsage.inputTokens,
                subsetLabel: nil
            ),
            TokenBreakdownItem(
                title: "缓存命中",
                value: tokenUsage.cachedInputTokens,
                subsetLabel: "输入子集"
            ),
            TokenBreakdownItem(
                title: "输出",
                value: tokenUsage.outputTokens,
                subsetLabel: nil
            ),
            TokenBreakdownItem(
                title: "推理",
                value: tokenUsage.reasoningOutputTokens,
                subsetLabel: "输出子集"
            ),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                VStack(spacing: 3) {
                    Text(PulseL10n.text(item.title, language: language))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(TokenUsageSnapshot.compactTokenCount(item.value))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()

                    Text(item.subsetLabel.map {
                        PulseL10n.text($0, language: language)
                    } ?? " ")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)

                if index < items.index(before: items.endIndex) {
                    Divider()
                        .frame(height: 38)
                        .opacity(0.5)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        PulseL10n.text(
            "Token 明细，输入 %@，缓存命中 %@，缓存命中属于输入子集，输出 %@，推理 %@，推理属于输出子集",
            language: language,
            TokenUsageSnapshot.compactTokenCount(tokenUsage.inputTokens),
            TokenUsageSnapshot.compactTokenCount(tokenUsage.cachedInputTokens),
            TokenUsageSnapshot.compactTokenCount(tokenUsage.outputTokens),
            TokenUsageSnapshot.compactTokenCount(tokenUsage.reasoningOutputTokens)
        )
    }
}

private struct TokenBreakdownItem {
    let title: String
    let value: Int?
    let subsetLabel: String?
}

private struct TaskGroupDescriptor {
    let id: String
    let title: String
    let color: Color
    let emptyMessage: String

    static let running = TaskGroupDescriptor(
        id: "running",
        title: "正在运行",
        color: TaskSidebarPalette.runningInk,
        emptyMessage: "没有正在运行或等待操作的任务"
    )

}

private enum TaskSidebarPalette {
    // `Color.blue` is close to the minimum readable contrast on the sidebar's
    // dark material. This brighter ink preserves the running-state blue while
    // keeping project names and status text legible at caption sizes.
    static let runningInk = Color(red: 0.32, green: 0.72, blue: 1.0)

    // The selected model tab. Deliberately not the accent color: the accent
    // marks things the user acts on inside the current model — unread rows,
    // the project filter — while this marks which model is being looked at.
    static let selectedModelInk = Color(red: 1.0, green: 0.62, blue: 0.16)
}

private extension PulseTaskState {
    var activeSortPriority: Int {
        switch self {
        case .waitingForApproval:
            return 0
        case .waitingForAnswer:
            return 1
        case .running:
            return 2
        case .failed, .interrupted, .completed:
            return 3
        }
    }

    var tintColor: Color {
        switch self {
        case .running:
            return TaskSidebarPalette.runningInk
        case .waitingForApproval, .waitingForAnswer:
            return .orange
        case .completed:
            return .green
        case .failed, .interrupted:
            return .red
        }
    }

    var symbol: String {
        switch self {
        case .running:
            return "bolt.fill"
        case .waitingForApproval:
            return "clock.fill"
        case .waitingForAnswer:
            return "questionmark.bubble.fill"
        case .completed:
            return "checkmark"
        case .failed:
            return "xmark"
        case .interrupted:
            return "exclamationmark"
        }
    }

    func accessibilityDescription(language: AppLanguage) -> String {
        switch self {
        case .running:
            return PulseL10n.text("正在执行", language: language)
        case .waitingForApproval:
            return PulseL10n.text("等待授权", language: language)
        case .waitingForAnswer:
            return PulseL10n.text("等待回答", language: language)
        case .completed:
            return PulseL10n.text("已完成", language: language)
        case .failed:
            return PulseL10n.text("失败", language: language)
        case .interrupted:
            return PulseL10n.text("已中断", language: language)
        }
    }
}

private extension PulseTask {
    var activityDate: Date {
        completedAt ?? updatedAt
    }

    func rowStatusText(language: AppLanguage) -> String {
        let localizedStatus = displayStatusText(language: language)
        return localizedStatus.isEmpty
            ? state.accessibilityDescription(language: language)
            : localizedStatus
    }

    func accessibilityLabel(projectName: String, language: AppLanguage) -> String {
        var components = [
            PulseL10n.text("项目 %@", language: language, projectName),
            PulseL10n.text("任务 %@", language: language, title),
            state.accessibilityDescription(language: language),
            activityDate.pulseRelativeDescription(language: language),
        ]
        if let tokenUsage {
            components.append(PulseL10n.text(
                "共 %@ tokens",
                language: language,
                tokenUsage.compactTotalText
            ))
        }
        if let agentActivity {
            let presentation = AgentActivityBadgePresentation(
                observation: agentActivity,
                taskState: state,
                now: .now,
                language: language
            )
            if presentation.isVisible {
                components.append(presentation.accessibilityLabel)
            }
        }
        return components.joined(separator: " · ")
    }

    var hasTrailingMetrics: Bool {
        if tokenUsage != nil { return true }
        guard let agentActivity else { return false }
        return AgentActivityBadgePresentation(
            observation: agentActivity,
            taskState: state,
            now: .now
        ).isVisible
    }
}
