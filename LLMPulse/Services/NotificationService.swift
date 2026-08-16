import Combine
import Foundation
import UserNotifications

enum PulseNotificationKind: String {
    case waitingForApproval
    case waitingForAnswer
    case completed
    case failed
    case interrupted

    init?(state: PulseTaskState) {
        switch state {
        case .waitingForApproval:
            self = .waitingForApproval
        case .waitingForAnswer:
            self = .waitingForAnswer
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        case .interrupted:
            self = .interrupted
        case .running:
            return nil
        }
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .waitingForApproval:
            return PulseL10n.text("Codex 等待授权", language: language)
        case .waitingForAnswer:
            return PulseL10n.text("Codex 等待你的回答", language: language)
        case .completed:
            return PulseL10n.text("任务已完成", language: language)
        case .failed:
            return PulseL10n.text("任务执行失败", language: language)
        case .interrupted:
            return PulseL10n.text("任务已中断", language: language)
        }
    }

    var categoryIdentifier: String {
        switch self {
        case .waitingForApproval, .waitingForAnswer:
            return PulseNotificationCategory.actionableTask
        case .completed:
            return PulseNotificationCategory.completedTask
        case .failed, .interrupted:
            return PulseNotificationCategory.terminalTask
        }
    }
}

extension NotificationAttentionLevel {
    func allows(_ kind: PulseNotificationKind) -> Bool {
        switch self {
        case .attentionOnly:
            return kind == .waitingForApproval
                || kind == .waitingForAnswer
                || kind == .failed
        case .important:
            return kind != .interrupted
        case .all:
            return true
        }
    }
}

struct TaskNotificationRoute: Equatable, Sendable {
    let taskID: String
    let threadID: String
    let profileID: ModelProfileID
    let sessionID: String

    init(
        taskID: String,
        threadID: String,
        profileID: ModelProfileID = .codex,
        sessionID: String? = nil
    ) {
        self.taskID = taskID
        self.threadID = threadID
        self.profileID = profileID
        self.sessionID = sessionID ?? threadID
    }

    init(task: PulseTask) {
        self.init(
            taskID: task.id,
            threadID: task.threadId,
            profileID: task.profileID,
            sessionID: task.sessionID
        )
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let taskID = userInfo["taskID"] as? String,
              !taskID.isEmpty,
              let threadID = userInfo["threadID"] as? String,
              !threadID.isEmpty else {
            return nil
        }

        let rawProfileID = userInfo["profileID"]
        let rawSessionID = userInfo["sessionID"]
        switch (rawProfileID, rawSessionID) {
        case (nil, nil):
            self.init(taskID: taskID, threadID: threadID)
        case let (profileValue as String, sessionID as String):
            let profileID = ModelProfileID(rawValue: profileValue)
            guard !profileID.rawValue.isEmpty,
                  profileID.rawValue.utf8.count <= 512,
                  !sessionID.isEmpty,
                  sessionID.utf8.count <= 512,
                  !sessionID.unicodeScalars.contains(where: { $0.value == 0 }) else {
                return nil
            }
            self.init(
                taskID: taskID,
                threadID: threadID,
                profileID: profileID,
                sessionID: sessionID
            )
        default:
            return nil
        }
    }

    var userInfo: [String: String] {
        [
            "taskID": taskID,
            "threadID": threadID,
            "profileID": profileID.rawValue,
            "sessionID": sessionID,
        ]
    }

    func matches(_ task: PulseTask) -> Bool {
        task.id == taskID
            && task.threadId == threadID
            && task.profileID == profileID
            && task.sessionID == sessionID
    }

    var allowsCodexFallback: Bool {
        profileID == .codex && sessionID == threadID
    }
}

struct RateLimitNotificationAlert: Equatable, Sendable {
    let windowTitle: String
    let windowMinutes: Int
    let remainingPercent: Int
    let threshold: Int
    let resetsAt: Date
    let scopeKey: String
    let receiptKeys: Set<String>

    var identifier: String {
        let resetTimestamp = Int(resetsAt.timeIntervalSince1970)
        return "llm-pulse.quota.\(scopeKey).\(windowMinutes).\(resetTimestamp).\(threshold)"
    }
}

enum QuotaNotificationScope {
    static func key(for planType: String?) -> String {
        let value = planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return "unknown" }
        return value
            .lowercased()
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: ".", with: "_")
    }
}

struct CompletionNotificationSummary: Equatable, Sendable {
    let title: String
    let subtitle: String
    let body: String

    init(tasks: [PulseTask], language: AppLanguage = .simplifiedChinese) {
        let projectCount = Set(tasks.map(\.projectIdentityDirectory)).count
        let summaryTitles = tasks.prefix(3).map {
            "\($0.projectDisplayName(language: language)) · \($0.title)"
        }
        title = PulseL10n.text("%d 个任务已完成", language: language, tasks.count)
        subtitle = projectCount == 1
            ? PulseL10n.text("同一项目", language: language)
            : PulseL10n.text("来自 %d 个项目", language: language, projectCount)
        body = summaryTitles.joined(separator: " · ")
            + (tasks.count > summaryTitles.count ? " · …" : "")
    }
}

enum PulseNotificationAction {
    static let openTask = "LLM_PULSE_OPEN_TASK"
    static let openPanel = "LLM_PULSE_OPEN_PANEL"
    static let snooze15Minutes = "LLM_PULSE_SNOOZE_15_MINUTES"
    static let snoozeOneHour = "LLM_PULSE_SNOOZE_ONE_HOUR"
    static let markViewed = "LLM_PULSE_MARK_VIEWED"
}

enum PulseNotificationCategory {
    static let actionableTask = "LLM_PULSE_TASK_ACTIONABLE"
    static let completedTask = "LLM_PULSE_TASK_COMPLETED"
    static let terminalTask = "LLM_PULSE_TASK_TERMINAL"
    static let completionSummary = "LLM_PULSE_COMPLETION_SUMMARY"
    static let quota = "LLM_PULSE_QUOTA"
}

enum NotificationPostOutcome: Equatable {
    case delivered
    case suppressed
    case retryable
}

enum TaskNotificationSnapshotReliability {
    static func mayBeIncomplete(_ snapshot: TaskSnapshot) -> Bool {
        // Task existence and terminal state are rooted in rollout data. A
        // degraded rollout read may omit only some files, while receipts and
        // optional app/plugin sources do not define task-list completeness.
        snapshot.health.contains {
            $0.adapter == .rolloutJSONL && $0.status != .healthy
        }
    }
}

@MainActor
enum SnoozeNotificationPolicy {
    static func shouldKeep(
        userInfo: [AnyHashable: Any],
        snapshot: TaskSnapshot,
        settings: PulseSettings,
        asOf date: Date
    ) -> Bool {
        guard settings.notificationsEnabled else { return false }

        if let route = TaskNotificationRoute(userInfo: userInfo),
           let rawKind = userInfo["notificationKind"] as? String,
           let kind = PulseNotificationKind(rawValue: rawKind) {
            guard settings.notificationAttentionLevel.allows(kind) else {
                return false
            }
            guard let task = snapshot.tasks.first(where: route.matches) else {
                // A temporary source outage can make only part of the task list
                // disappear. Keep the snooze until a healthy snapshot can
                // authoritatively say that the task no longer exists.
                return TaskNotificationSnapshotReliability.mayBeIncomplete(snapshot)
            }
            guard
                  PulseNotificationKind(state: task.state) == kind,
                  !(kind == .completed && !task.isUnread),
                  !settings.isProjectMuted(task.projectIdentityDirectory, asOf: date) else {
                return false
            }
            return true
        }

        if userInfo["notificationType"] as? String == "quota" {
            guard let windowValue = userInfo["windowMinutes"] as? String,
                  let windowMinutes = Int(windowValue),
                  windowMinutes == RateLimitWindowDuration.weeklyMinutes,
                  let resetValue = userInfo["resetsAt"] as? String,
                  let resetTimestamp = Int(resetValue),
                  Date(timeIntervalSince1970: TimeInterval(resetTimestamp)) > date,
                  let thresholdValue = userInfo["threshold"] as? String,
                  let threshold = Double(thresholdValue)
            else {
                return false
            }
            guard let rateLimits = snapshot.rateLimits else {
                return snapshot.health.contains {
                    ($0.adapter == .appServer || $0.adapter == .rolloutJSONL)
                        && $0.status != .healthy
                }
            }
            if let originalScope = userInfo["quotaScope"] as? String,
               originalScope != QuotaNotificationScope.key(for: rateLimits.planType) {
                return false
            }
            let window = rateLimits.weekly
            guard let window,
                  RateLimitResetSemantics.representsSameWindow(
                      window.resetsAt,
                      Date(timeIntervalSince1970: TimeInterval(resetTimestamp))
                  ),
                  let remaining = window.remainingPercent(asOf: date),
                  remaining <= threshold else {
                return false
            }
            // Usage is monotonic inside one reset window. Once the threshold was
            // crossed, stale telemetry must not delete a one-hour snooze before
            // its trigger fires; a reset/window change still invalidates it.
            return true
        }

        return false
    }
}

/// Bridges `UNUserNotificationCenter` queries that hand back non-`Sendable`
/// values.
///
/// `notificationSettings()` and `pendingNotificationRequests()` return types
/// that cannot cross an isolation boundary, and whether the compiler accepts
/// awaiting them directly depends on how the SDK in use annotates them. Going
/// through the completion-handler form and projecting to `Sendable` values
/// inside the callback compiles the same way on every toolchain.
@MainActor
enum NotificationCenterBridge {
    /// Only the fields the snooze policy reads, all of them strings.
    struct PendingRequest: Sendable {
        let identifier: String
        let userInfo: [String: String]

        var policyUserInfo: [AnyHashable: Any] { userInfo }
    }

    static func authorizationStatus(
        of center: UNUserNotificationCenter
    ) async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    static func pendingRequests(
        in center: UNUserNotificationCenter
    ) async -> [PendingRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map { request in
                    PendingRequest(
                        identifier: request.identifier,
                        userInfo: request.content.userInfo.reduce(
                            into: [String: String]()
                        ) { result, entry in
                            guard let key = entry.key as? String,
                                  let value = entry.value as? String else { return }
                            result[key] = value
                        }
                    )
                })
            }
        }
    }
}

@MainActor
final class NotificationService {
    private let center: UNUserNotificationCenter
    private let settings: PulseSettings
    private let delegateBridge: NotificationDelegateBridge
    private let onOpenTask: @MainActor (TaskNotificationRoute) -> Void
    private let onMarkViewed: @MainActor (TaskNotificationRoute) async -> Void
    private let onOpenPanel: @MainActor () -> Void
    private var languageCancellable: AnyCancellable?

    var isEnabled: Bool { settings.notificationsEnabled }

    init(
        settings: PulseSettings,
        onOpenTask: @escaping @MainActor (TaskNotificationRoute) -> Void,
        onMarkViewed: @escaping @MainActor (TaskNotificationRoute) async -> Void,
        onOpenPanel: @escaping @MainActor () -> Void,
        center: UNUserNotificationCenter = .current()
    ) {
        self.settings = settings
        self.center = center
        self.onOpenTask = onOpenTask
        self.onMarkViewed = onMarkViewed
        self.onOpenPanel = onOpenPanel

        delegateBridge = NotificationDelegateBridge()
        delegateBridge.onResponse = { [weak self] response in
            await self?.handle(response)
        }
        center.delegate = delegateBridge
        registerCategories()
        languageCancellable = settings.$appLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.registerCategories()
            }
    }

    func requestAuthorizationIfNeeded() async {
        guard settings.notificationsEnabled else { return }

        let status = await NotificationCenterBridge.authorizationStatus(of: center)
        guard status == .notDetermined else { return }

        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    @discardableResult
    func post(
        task: PulseTask,
        kind: PulseNotificationKind
    ) async -> NotificationPostOutcome {
        guard settings.notificationsEnabled,
              settings.notificationAttentionLevel.allows(kind) else {
            return .suppressed
        }

        settings.cleanupExpiredProjectMutes()
        guard !settings.isProjectMuted(task.projectIdentityDirectory) else {
            return .suppressed
        }
        switch await notificationReadiness() {
        case .available:
            break
        case .awaitingAuthorization:
            return .retryable
        case .denied:
            return .suppressed
        }

        let content = UNMutableNotificationContent()
        let language = settings.appLanguage
        let notificationTitle = kind.title(language: language)
        content.title = notificationTitle
        content.subtitle = task.projectDisplayName(language: language)
        let localizedStatus = task.displayStatusText(language: language)
        let statusText = localizedStatus.isEmpty ? notificationTitle : localizedStatus
        content.body = "\(task.title) · \(statusText)"
        content.categoryIdentifier = kind.categoryIdentifier
        content.threadIdentifier = task.threadId
        content.userInfo = TaskNotificationRoute(task: task).userInfo
            .merging(["notificationKind": kind.rawValue]) { current, _ in current }
        content.sound = settings.notificationSoundEnabled ? .default : nil

        let timestamp = Int(task.updatedAt.timeIntervalSince1970 * 1_000)
        let request = UNNotificationRequest(
            identifier: "llm-pulse.\(kind.rawValue).\(task.id).\(timestamp)",
            content: content,
            trigger: nil
        )

        return await add(request) ? .delivered : .retryable
    }

    @discardableResult
    func postCompletionSummary(
        tasks: [PulseTask]
    ) async -> NotificationPostOutcome {
        guard settings.notificationsEnabled,
              settings.notificationAttentionLevel.allows(.completed) else {
            return .suppressed
        }

        settings.cleanupExpiredProjectMutes()
        let visibleTasks = tasks.filter {
            !settings.isProjectMuted($0.projectIdentityDirectory)
        }
        guard !visibleTasks.isEmpty else { return .suppressed }
        if visibleTasks.count == 1, let task = visibleTasks.first {
            return await post(task: task, kind: .completed)
        }
        switch await notificationReadiness() {
        case .available:
            break
        case .awaitingAuthorization:
            return .retryable
        case .denied:
            return .suppressed
        }

        let summary = CompletionNotificationSummary(
            tasks: visibleTasks,
            language: settings.appLanguage
        )

        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.subtitle = summary.subtitle
        content.body = summary.body
        content.categoryIdentifier = PulseNotificationCategory.completionSummary
        content.threadIdentifier = "llm-pulse.completed"
        content.userInfo = ["notificationType": "completionSummary"]
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "llm-pulse.completed-summary.\(Int(Date.now.timeIntervalSince1970 * 1_000))",
            content: content,
            trigger: nil
        )
        return await add(request) ? .delivered : .retryable
    }

    @discardableResult
    func postQuotaAlert(_ alert: RateLimitNotificationAlert) async -> Bool {
        guard settings.notificationsEnabled,
              alert.windowMinutes == RateLimitWindowDuration.weeklyMinutes else { return false }

        switch await notificationReadiness() {
        case .available:
            break
        case .awaitingAuthorization:
            return false
        case .denied:
            return false
        }

        let content = UNMutableNotificationContent()
        let language = settings.appLanguage
        let windowTitle = PulseL10n.text("本周", language: language)
        content.title = PulseL10n.text(
            "%@额度仅剩 %d%%",
            language: language,
            windowTitle,
            alert.remainingPercent
        )
        content.subtitle = PulseL10n.text(
            "低于 %d%% 提醒阈值",
            language: language,
            alert.threshold
        )
        let resetText = PulseDisplayClock.concrete(alert.resetsAt, language: language)
        content.body = PulseL10n.text("将在 %@ 重置。", language: language, resetText)
        content.categoryIdentifier = PulseNotificationCategory.quota
        content.threadIdentifier = "llm-pulse.quota.\(alert.windowMinutes)"
        content.userInfo = [
            "notificationType": "quota",
            "windowMinutes": String(alert.windowMinutes),
            "resetsAt": String(Int(alert.resetsAt.timeIntervalSince1970)),
            "threshold": String(alert.threshold),
            "quotaScope": alert.scopeKey,
        ]
        content.sound = settings.notificationSoundEnabled ? .default : nil

        return await add(UNNotificationRequest(
            identifier: alert.identifier,
            content: content,
            trigger: nil
        ))
    }

    func reconcilePendingSnoozes(
        in snapshot: TaskSnapshot,
        asOf date: Date = .now
    ) async {
        let requests = await NotificationCenterBridge.pendingRequests(in: center)
        let snoozedRequests = requests.filter {
            $0.identifier.hasPrefix("llm-pulse.snooze.")
        }
        guard !snoozedRequests.isEmpty else { return }

        settings.cleanupExpiredProjectMutes(asOf: date)
        let identifiersToRemove = snoozedRequests.compactMap { request in
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: request.policyUserInfo,
                snapshot: snapshot,
                settings: settings,
                asOf: date
            )
                ? nil
                : request.identifier
        }
        if !identifiersToRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
        }
    }

    private func notificationReadiness() async -> NotificationReadiness {
        let status = await NotificationCenterBridge.authorizationStatus(of: center)
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .available
        case .notDetermined:
            return .awaitingAuthorization
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private func add(_ request: UNNotificationRequest) async -> Bool {
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private func registerCategories() {
        let language = settings.appLanguage
        let openTask = UNNotificationAction(
            identifier: PulseNotificationAction.openTask,
            title: PulseL10n.text("在 Codex 中打开", language: language),
            options: [.foreground]
        )
        let openPanel = UNNotificationAction(
            identifier: PulseNotificationAction.openPanel,
            title: PulseL10n.text("打开 LLM Pulse", language: language),
            options: [.foreground]
        )
        let snooze15 = UNNotificationAction(
            identifier: PulseNotificationAction.snooze15Minutes,
            title: PulseL10n.text("15 分钟后提醒", language: language),
            options: []
        )
        let snoozeHour = UNNotificationAction(
            identifier: PulseNotificationAction.snoozeOneHour,
            title: PulseL10n.text("1 小时后提醒", language: language),
            options: []
        )
        let markViewed = UNNotificationAction(
            identifier: PulseNotificationAction.markViewed,
            title: PulseL10n.text("标记为已查看", language: language),
            options: []
        )

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: PulseNotificationCategory.actionableTask,
                actions: [openTask, snooze15, snoozeHour],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: PulseNotificationCategory.completedTask,
                actions: [openTask, markViewed],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: PulseNotificationCategory.terminalTask,
                actions: [openTask, snooze15, snoozeHour],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: PulseNotificationCategory.completionSummary,
                actions: [openPanel],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: PulseNotificationCategory.quota,
                actions: [openPanel, snoozeHour],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    private func handle(_ response: PulseNotificationResponse) async {
        switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            return
        case PulseNotificationAction.markViewed:
            if let route = response.route {
                await onMarkViewed(route)
            }
        case PulseNotificationAction.snooze15Minutes:
            await reschedule(response, after: 15 * 60)
        case PulseNotificationAction.snoozeOneHour:
            await reschedule(response, after: 60 * 60)
        case PulseNotificationAction.openPanel:
            onOpenPanel()
        case PulseNotificationAction.openTask, UNNotificationDefaultActionIdentifier:
            if let route = response.route {
                onOpenTask(route)
            } else {
                onOpenPanel()
            }
        default:
            break
        }
    }

    private func reschedule(
        _ response: PulseNotificationResponse,
        after interval: TimeInterval
    ) async {
        guard settings.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = response.title
        content.subtitle = response.subtitle
        content.body = response.body
        content.categoryIdentifier = response.categoryIdentifier
        content.threadIdentifier = response.threadIdentifier
        content.userInfo = response.userInfo
        content.sound = settings.notificationSoundEnabled ? .default : nil

        let request = UNNotificationRequest(
            identifier: "llm-pulse.snooze.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: interval,
                repeats: false
            )
        )
        _ = await NotificationDeliveryRetrier.deliver {
            await self.add(request)
        }
    }
}

private enum NotificationReadiness {
    case available
    case awaitingAuthorization
    case denied
}

@MainActor
final class TaskNotificationObserver {
    private let monitor: TaskMonitor
    private let notificationService: NotificationService
    private var transitionTracker = HubTaskNotificationTransitionTracker()
    private var quotaTracker: RateLimitNotificationTracker
    private var cancellable: AnyCancellable?
    private var deliveryTasks: [String: Task<Void, Never>] = [:]
    private var pendingCompletionTasks: [String: PulseTask] = [:]
    private var completionFlushTask: Task<Void, Never>?
    private var snoozeReconciliationTracker = SnoozeReconciliationTracker()
    private var quotaRetryNotBefore = Date.distantPast

    init(
        monitor: TaskMonitor,
        notificationService: NotificationService,
        quotaDefaults: UserDefaults = .standard
    ) {
        self.monitor = monitor
        self.notificationService = notificationService
        quotaTracker = RateLimitNotificationTracker(defaults: quotaDefaults)
    }

    func start() {
        guard cancellable == nil else { return }

        cancellable = monitor.$hubSnapshot
            .sink { [weak self] snapshot in
                self?.handle(snapshot)
            }
    }

    func stop() {
        cancellable = nil
        transitionTracker = HubTaskNotificationTransitionTracker()
        quotaTracker.resetPending()
        snoozeReconciliationTracker = SnoozeReconciliationTracker()
        completionFlushTask?.cancel()
        completionFlushTask = nil
        pendingCompletionTasks.removeAll()
        deliveryTasks.values.forEach { $0.cancel() }
        deliveryTasks.removeAll()
    }

    private func handle(_ hubSnapshot: PulseHubSnapshot) {
        let snapshot = hubSnapshot.codexTaskSnapshot ?? .empty
        let transitions = transitionTracker.notifications(in: hubSnapshot)
        let completedTasks = transitions.compactMap { notification in
            notification.kind == .completed ? notification.task : nil
        }

        if !completedTasks.isEmpty {
            enqueueCompletionSummary(completedTasks)
        }

        for notification in transitions where notification.kind != .completed {
            enqueueTaskNotification(notification.task, kind: notification.kind)
        }

        let now = Date.now
        if snoozeReconciliationTracker.shouldReconcile(snapshot: snapshot, asOf: now) {
            Task { [weak self] in
                guard let self else { return }
                await notificationService.reconcilePendingSnoozes(
                    in: monitor.snapshot,
                    asOf: .now
                )
            }
        }

        guard notificationService.isEnabled, now >= quotaRetryNotBefore else { return }
        for alert in quotaTracker.pendingAlerts(in: snapshot, asOf: now) {
            Task { [weak self] in
                guard let self else { return }
                let consumed = await notificationService.postQuotaAlert(alert)
                quotaTracker.resolve(alert, consumed: consumed, asOf: .now)
                if !consumed {
                    quotaRetryNotBefore = Date.now.addingTimeInterval(30)
                }
            }
        }
    }

    private func enqueueTaskNotification(
        _ task: PulseTask,
        kind: PulseNotificationKind
    ) {
        let key = "\(task.id)|\(kind.rawValue)"
        guard deliveryTasks[key] == nil else { return }

        deliveryTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { deliveryTasks[key] = nil }

            var retryIndex = 0

            while !Task.isCancelled {
                let modelSnapshot = monitor.hubSnapshot.model(for: task.profileID)
                let currentSnapshot = modelSnapshot?.taskSnapshot ?? .empty
                guard let currentTask = currentSnapshot.tasks.first(where: { $0.id == task.id }) else {
                    guard modelSnapshot != nil,
                          TaskNotificationSnapshotReliability.mayBeIncomplete(currentSnapshot) else {
                        return
                    }
                    let delay = NotificationRetryBackoff.delay(afterFailure: retryIndex)
                    retryIndex += 1
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                    continue
                }
                guard PulseNotificationKind(state: currentTask.state) == kind else {
                    return
                }

                switch await notificationService.post(task: currentTask, kind: kind) {
                case .delivered, .suppressed:
                    return
                case .retryable:
                    let delay = NotificationRetryBackoff.delay(afterFailure: retryIndex)
                    retryIndex += 1
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func enqueueCompletionSummary(_ tasks: [PulseTask]) {
        for task in tasks {
            pendingCompletionTasks[task.id] = task
        }
        completionFlushTask?.cancel()
        completionFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self else { return }

            let queuedTasks = pendingCompletionTasks.values.sorted {
                $0.updatedAt < $1.updatedAt
            }
            pendingCompletionTasks.removeAll()
            completionFlushTask = nil
            enqueueCompletionDelivery(queuedTasks)
        }
    }

    private func enqueueCompletionDelivery(_ tasks: [PulseTask]) {
        guard !tasks.isEmpty else { return }
        let key = "completed|" + tasks.map(\.id).sorted().joined(separator: "|")
        guard deliveryTasks[key] == nil else { return }

        deliveryTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { deliveryTasks[key] = nil }
            await deliverCompletionSummaryWithRetry(tasks)
        }
    }

    private func deliverCompletionSummaryWithRetry(_ tasks: [PulseTask]) async {
        var retryIndex = 0

        while !Task.isCancelled {
            let taskIDs = Set(tasks.map(\.id))
            let currentSnapshot = monitor.hubSnapshot.model(for: tasks[0].profileID)?
                .taskSnapshot ?? .empty
            let currentTasks = currentSnapshot.tasks.filter {
                taskIDs.contains($0.id) && $0.state == .completed && $0.isUnread
            }
            if TaskNotificationSnapshotReliability.mayBeIncomplete(currentSnapshot),
               currentTasks.count < taskIDs.count {
                let delay = NotificationRetryBackoff.delay(afterFailure: retryIndex)
                retryIndex += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                continue
            }
            guard !currentTasks.isEmpty else { return }

            switch await notificationService.postCompletionSummary(tasks: currentTasks) {
            case .delivered, .suppressed:
                return
            case .retryable:
                let delay = NotificationRetryBackoff.delay(afterFailure: retryIndex)
                retryIndex += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

}

struct SnoozeReconciliationTracker {
    private(set) var lastReconciledAt = Date.distantPast

    mutating func shouldReconcile(
        snapshot: TaskSnapshot,
        asOf date: Date,
        minimumInterval: TimeInterval = 30
    ) -> Bool {
        guard snapshot.refreshedAt != .distantPast,
              date.timeIntervalSince(lastReconciledAt) >= minimumInterval else {
            return false
        }
        lastReconciledAt = date
        return true
    }
}

enum NotificationRetryBackoff {
    private static let delays: [Duration] = [
        .seconds(2),
        .seconds(5),
        .seconds(15),
        .seconds(30),
        .seconds(60),
        .seconds(120),
        .seconds(300),
    ]

    static func delay(afterFailure failureIndex: Int) -> Duration {
        delays[min(max(0, failureIndex), delays.count - 1)]
    }
}

@MainActor
enum NotificationDeliveryRetrier {
    static let snoozeRetryDelays: [Duration] = [
        .milliseconds(250),
        .seconds(1),
    ]

    static func deliver(
        delays: [Duration] = snoozeRetryDelays,
        operation: () async -> Bool
    ) async -> Bool {
        if await operation() { return true }
        for delay in delays {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return false
            }
            if await operation() { return true }
        }
        return false
    }
}

struct TaskNotificationTransitionTracker {
    /// How long a provisional failure must persist before it is announced.
    ///
    /// A failure inferred from a quiet error event reverts the moment an
    /// automatic retry writes again, so announcing it immediately delivers a
    /// notification that the next poll contradicts — and a delivered
    /// notification cannot be recalled. Waiting is the asymmetric choice:
    /// a late failure notice costs a minute, a false one costs trust.
    ///
    /// The window is deliberately longer than the parser's 10 s freshness
    /// horizon so ordinary retry backoff resolves inside it.
    static let provisionalFailureConfirmation: TimeInterval = 60

    private var previousStates: [String: PulseTaskState] = [:]
    private var provisionalFailuresSince: [String: Date] = [:]
    private var hasSeededInitialSnapshot = false

    mutating func notifications(
        in snapshot: TaskSnapshot
    ) -> [(task: PulseTask, kind: PulseNotificationKind)] {
        guard snapshot.refreshedAt != .distantPast else { return [] }

        let currentStates = Dictionary(
            uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0.state) }
        )

        var nextStates = currentStates
        if TaskNotificationSnapshotReliability.mayBeIncomplete(snapshot) {
            for (taskID, state) in previousStates where nextStates[taskID] == nil {
                nextStates[taskID] = state
            }
        }

        guard hasSeededInitialSnapshot else {
            previousStates = nextStates
            hasSeededInitialSnapshot = true
            return []
        }

        var announced: [(task: PulseTask, kind: PulseNotificationKind)] = []
        var heldProvisionalFailures: [String: Date] = [:]

        for task in snapshot.tasks {
            guard let kind = PulseNotificationKind(state: task.state) else { continue }
            guard previousStates[task.id] != task.state else {
                // Already announced, or still held below.
                if let since = provisionalFailuresSince[task.id] {
                    heldProvisionalFailures[task.id] = since
                }
                continue
            }

            if task.isProvisionalFailure {
                // The clock is the snapshot's own refresh time, so the tracker
                // stays deterministic and needs no ambient date.
                let since = provisionalFailuresSince[task.id] ?? snapshot.refreshedAt
                if snapshot.refreshedAt.timeIntervalSince(since)
                    < Self.provisionalFailureConfirmation
                {
                    heldProvisionalFailures[task.id] = since
                    // Leaving the previous state in place keeps the transition
                    // unconsumed, so it announces exactly once when the window
                    // elapses — and never again on later refreshes.
                    nextStates[task.id] = previousStates[task.id]
                    continue
                }
            }

            announced.append((task, kind))
        }

        provisionalFailuresSince = heldProvisionalFailures
        previousStates = nextStates
        return announced
    }
}

struct HubTaskNotificationTransitionTracker {
    private var trackers: [ModelProfileID: TaskNotificationTransitionTracker] = [:]

    mutating func notifications(
        in snapshot: PulseHubSnapshot
    ) -> [(task: PulseTask, kind: PulseNotificationKind)] {
        var notifications: [(task: PulseTask, kind: PulseNotificationKind)] = []
        for model in snapshot.models {
            var tracker = trackers[model.identity.profileID]
                ?? TaskNotificationTransitionTracker()
            notifications.append(contentsOf: tracker.notifications(in: model.taskSnapshot))
            trackers[model.identity.profileID] = tracker
        }
        return notifications
    }
}

struct RateLimitNotificationTracker {
    static let thresholds = [20, 10, 5]
    static let freshnessInterval: TimeInterval = 15 * 60
    static let defaultsKey = "quotaNotificationReceiptKeys.v2"

    private var deliveredKeys: Set<String>
    private var pendingKeys: Set<String> = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        deliveredKeys = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    mutating func pendingAlerts(
        in snapshot: TaskSnapshot,
        asOf date: Date
    ) -> [RateLimitNotificationAlert] {
        guard let rateLimits = snapshot.rateLimits else {
            return []
        }

        var alerts: [RateLimitNotificationAlert] = []
        let windows: [(String, RateLimitWindowSnapshot?)] = [
            ("本周", rateLimits.weekly),
        ]

        for (title, window) in windows {
            guard let window,
                  let remaining = window.remainingPercent(asOf: date) else {
                continue
            }

            let observedAt = window.observedAt ?? rateLimits.updatedAt
            let age = date.timeIntervalSince(observedAt)
            guard age >= -60, age <= Self.freshnessInterval else { continue }

            let planKey = QuotaNotificationScope.key(for: rateLimits.planType)
            guard !containsReceipt(
                in: pendingKeys,
                window: window,
                planKey: planKey,
                threshold: nil
            ) else {
                continue
            }

            let matchingThresholds = Self.thresholds.filter { remaining <= Double($0) }
            let newThresholds = matchingThresholds.filter {
                return !containsReceipt(
                    in: deliveredKeys,
                    window: window,
                    planKey: planKey,
                    threshold: $0
                ) && !containsReceipt(
                    in: pendingKeys,
                    window: window,
                    planKey: planKey,
                    threshold: $0
                )
            }
            guard let mostUrgentThreshold = newThresholds.min() else { continue }

            let receiptKeys = Set(matchingThresholds.map {
                receiptKey(
                    window: window,
                    threshold: $0,
                    planType: rateLimits.planType
                )
            })
            pendingKeys.formUnion(receiptKeys)
            alerts.append(RateLimitNotificationAlert(
                windowTitle: title,
                windowMinutes: window.windowMinutes,
                remainingPercent: Int(floor(max(0, remaining))),
                threshold: mostUrgentThreshold,
                resetsAt: window.resetsAt,
                scopeKey: planKey,
                receiptKeys: receiptKeys
            ))
        }

        return alerts
    }

    mutating func resolve(
        _ alert: RateLimitNotificationAlert,
        consumed: Bool,
        asOf date: Date
    ) {
        pendingKeys.subtract(alert.receiptKeys)
        guard consumed else { return }
        deliveredKeys.formUnion(alert.receiptKeys)
        pruneAndPersist(asOf: date)
    }

    mutating func resetPending() {
        pendingKeys.removeAll()
    }

    private func receiptKey(
        window: RateLimitWindowSnapshot,
        threshold: Int,
        planType: String?
    ) -> String {
        "\(QuotaNotificationScope.key(for: planType))|\(window.windowMinutes)|\(Int(window.resetsAt.timeIntervalSince1970))|\(threshold)"
    }

    private func containsReceipt(
        in keys: Set<String>,
        window: RateLimitWindowSnapshot,
        planKey: String,
        threshold: Int?
    ) -> Bool {
        keys.contains { key in
            let components = key.split(separator: "|", omittingEmptySubsequences: false)
            guard components.count == 4,
                  String(components[0]) == planKey,
                  Int(components[1]) == window.windowMinutes,
                  let resetTimestamp = Int(components[2]),
                  threshold.map({ Int(components[3]) == $0 }) ?? true
            else {
                return false
            }
            return RateLimitResetSemantics.representsSameWindow(
                Date(timeIntervalSince1970: TimeInterval(resetTimestamp)),
                window.resetsAt
            )
        }
    }

    private mutating func pruneAndPersist(asOf date: Date) {
        let minimumResetTimestamp = Int(date.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970)
        deliveredKeys = Set(deliveredKeys.filter { key in
            let components = key.split(separator: "|")
            guard components.count == 4,
                  let resetTimestamp = Int(components[2]) else {
                return false
            }
            return resetTimestamp >= minimumResetTimestamp
        })
        defaults.set(deliveredKeys.sorted(), forKey: Self.defaultsKey)
    }
}

struct PulseNotificationResponse: Sendable {
    let actionIdentifier: String
    let route: TaskNotificationRoute?
    let title: String
    let subtitle: String
    let body: String
    let categoryIdentifier: String
    let threadIdentifier: String
    let userInfo: [String: String]
}

final class NotificationDelegateBridge: NSObject, UNUserNotificationCenterDelegate {
    var onResponse: (@Sendable (PulseNotificationResponse) async -> Void)?

    func dispatch(
        _ response: PulseNotificationResponse,
        completionHandler: @escaping () -> Void
    ) {
        guard let onResponse else {
            completionHandler()
            return
        }

        let completion = NotificationResponseCompletion(completionHandler)
        Task {
            await onResponse(response)
            completion.call()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let userInfo = content.userInfo.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String,
                  let value = item.value as? String else {
                return
            }
            result[key] = value
        }
        dispatch(PulseNotificationResponse(
            actionIdentifier: response.actionIdentifier,
            route: TaskNotificationRoute(userInfo: content.userInfo),
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            categoryIdentifier: content.categoryIdentifier,
            threadIdentifier: content.threadIdentifier,
            userInfo: userInfo
        ), completionHandler: completionHandler)
    }
}

private final class NotificationResponseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        lock.lock()
        let handler = handler
        self.handler = nil
        lock.unlock()
        handler?()
    }
}
