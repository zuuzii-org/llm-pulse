import XCTest
import UserNotifications
@testable import LLMPulse

final class NotificationServiceTests: XCTestCase {
    func testDelegateCompletionWaitsForAsyncResponseHandling() async {
        let bridge = NotificationDelegateBridge()
        let events = AsyncStream<String>.makeStream()
        bridge.onResponse = { _ in
            try? await Task.sleep(for: .milliseconds(40))
            events.continuation.yield("response")
        }

        bridge.dispatch(
            PulseNotificationResponse(
                actionIdentifier: PulseNotificationAction.markViewed,
                route: nil,
                title: "",
                subtitle: "",
                body: "",
                categoryIdentifier: "",
                threadIdentifier: "",
                userInfo: [:]
            )
        ) {
            events.continuation.yield("completion")
            events.continuation.finish()
        }

        var observed: [String] = []
        for await event in events.stream {
            observed.append(event)
        }

        XCTAssertEqual(observed, ["response", "completion"])
    }

    func testDelegateCompletesImmediatelyWithoutResponseHandler() async {
        let bridge = NotificationDelegateBridge()
        let events = AsyncStream<Void>.makeStream()

        bridge.dispatch(
            PulseNotificationResponse(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                route: nil,
                title: "",
                subtitle: "",
                body: "",
                categoryIdentifier: "",
                threadIdentifier: "",
                userInfo: [:]
            )
        ) {
            events.continuation.yield()
            events.continuation.finish()
        }

        var completionCount = 0
        for await _ in events.stream {
            completionCount += 1
        }

        XCTAssertEqual(completionCount, 1)
    }

    func testNotificationRouteRoundTripsTaskAndThreadIdentifiers() throws {
        let route = TaskNotificationRoute(
            taskID: "thread-1:turn-4",
            threadID: "thread-1"
        )

        let decoded = try XCTUnwrap(TaskNotificationRoute(userInfo: route.userInfo))
        XCTAssertEqual(decoded, route)
    }

    func testNotificationThreadIdentifiersAreNamespacedByProfileAndSession() {
        let codex = TaskNotificationRoute(
            taskID: "shared-task",
            threadID: "shared-thread",
            profileID: .codex,
            sessionID: "shared-session"
        )
        let claude = TaskNotificationRoute(
            taskID: "shared-task",
            threadID: "shared-thread",
            profileID: .claudeCode,
            sessionID: "shared-session"
        )
        let glm = TaskNotificationRoute(
            taskID: "shared-task",
            threadID: "shared-thread",
            profileID: .glm,
            sessionID: "shared-session"
        )
        let nextCodexTurn = TaskNotificationRoute(
            taskID: "another-task",
            threadID: "shared-thread",
            profileID: .codex,
            sessionID: "shared-session"
        )

        XCTAssertEqual(codex.notificationThreadIdentifier, nextCodexTurn.notificationThreadIdentifier)
        XCTAssertEqual(
            Set([
                codex.notificationThreadIdentifier,
                claude.notificationThreadIdentifier,
                glm.notificationThreadIdentifier,
            ]).count,
            3
        )
    }

    func testNotificationRouteRejectsIncompletePayload() {
        XCTAssertNil(TaskNotificationRoute(userInfo: ["threadID": "thread-1"]))
        XCTAssertNil(TaskNotificationRoute(userInfo: ["taskID": "task-1"]))
        XCTAssertNil(TaskNotificationRoute(userInfo: ["taskID": "", "threadID": "thread-1"]))
    }

    func testInitialPlaceholderAndFirstRealSnapshotDoNotSendNotifications() {
        var tracker = TaskNotificationTransitionTracker()
        let existingTask = makeTask(state: .completed)

        XCTAssertTrue(tracker.notifications(in: .empty).isEmpty)
        XCTAssertTrue(
            tracker.notifications(
                in: TaskSnapshot(
                    tasks: [existingTask],
                    refreshedAt: Date(timeIntervalSince1970: 200),
                    health: []
                )
            ).isEmpty
        )
    }

    func testStateChangeAfterInitialSnapshotProducesNotification() throws {
        var tracker = TaskNotificationTransitionTracker()
        let runningTask = makeTask(state: .running)
        let initialSnapshot = TaskSnapshot(
            tasks: [runningTask],
            refreshedAt: Date(timeIntervalSince1970: 200),
            health: []
        )
        XCTAssertTrue(tracker.notifications(in: initialSnapshot).isEmpty)

        let completedTask = makeTask(state: .completed)
        let notifications = tracker.notifications(
            in: TaskSnapshot(
                tasks: [completedTask],
                refreshedAt: Date(timeIntervalSince1970: 210),
                health: []
            )
        )

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(try XCTUnwrap(notifications.first).task.id, completedTask.id)
        XCTAssertEqual(try XCTUnwrap(notifications.first).kind.rawValue, "completed")
    }

    func testTransientEmptySnapshotDuringAdapterFailureDoesNotRepeatTerminalNotification() {
        var tracker = TaskNotificationTransitionTracker()
        let now = Date(timeIntervalSince1970: 200)
        let completed = makeTask(state: .completed)

        XCTAssertTrue(
            tracker.notifications(
                in: TaskSnapshot(tasks: [completed], refreshedAt: now, health: [])
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.notifications(
                in: TaskSnapshot(
                    tasks: [],
                    refreshedAt: now.addingTimeInterval(1),
                    health: [.unavailable(.rolloutJSONL, message: "temporary")]
                )
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.notifications(
                in: TaskSnapshot(
                    tasks: [completed],
                    refreshedAt: now.addingTimeInterval(2),
                    health: [.healthy(.rolloutJSONL, at: now.addingTimeInterval(2))]
                )
            ).isEmpty
        )
    }

    func testPartialSnapshotDuringAdapterFailurePreservesMissingTaskState() {
        var tracker = TaskNotificationTransitionTracker()
        let now = Date(timeIntervalSince1970: 200)
        let completed = makeTask(state: .completed, id: "completed")
        let running = makeTask(state: .running, id: "running")

        XCTAssertTrue(
            tracker.notifications(
                in: TaskSnapshot(tasks: [completed, running], refreshedAt: now, health: [])
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.notifications(
                in: TaskSnapshot(
                    tasks: [running],
                    refreshedAt: now.addingTimeInterval(1),
                    health: [.degraded(.rolloutJSONL, message: "partial")]
                )
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.notifications(
                in: TaskSnapshot(
                    tasks: [completed, running],
                    refreshedAt: now.addingTimeInterval(2),
                    health: [.healthy(.rolloutJSONL, at: now.addingTimeInterval(2))]
                )
            ).isEmpty
        )
    }

    func testTaskSnapshotReliabilityCoversEveryAuthoritativeRuntimeSource() {
        let now = Date(timeIntervalSince1970: 200)

        for adapter in [
            AdapterHealth.Adapter.rolloutJSONL,
            .claudeSessionRegistry,
            .claudeTranscript,
            .zcodeSQLite,
            .zcodeEventLog,
            .runtimeSource,
        ] {
            XCTAssertTrue(
                TaskNotificationSnapshotReliability.mayBeIncomplete(
                    TaskSnapshot(
                        tasks: [],
                        refreshedAt: now,
                        health: [.degraded(adapter, message: "partial")]
                    )
                ),
                "Expected \(adapter.rawValue) degradation to preserve notification state"
            )
        }

        XCTAssertFalse(
            TaskNotificationSnapshotReliability.mayBeIncomplete(
                TaskSnapshot(
                    tasks: [],
                    refreshedAt: now,
                    health: [.unavailable(.receipts, message: "unrelated")]
                )
            )
        )
    }

    func testAttentionLevelsKeepDefaultNotificationsLowNoise() {
        XCTAssertTrue(NotificationAttentionLevel.attentionOnly.allows(.waitingForApproval))
        XCTAssertTrue(NotificationAttentionLevel.attentionOnly.allows(.waitingForAnswer))
        XCTAssertTrue(NotificationAttentionLevel.attentionOnly.allows(.failed))
        XCTAssertFalse(NotificationAttentionLevel.attentionOnly.allows(.completed))
        XCTAssertFalse(NotificationAttentionLevel.attentionOnly.allows(.interrupted))

        XCTAssertTrue(NotificationAttentionLevel.important.allows(.completed))
        XCTAssertFalse(NotificationAttentionLevel.important.allows(.interrupted))
        XCTAssertTrue(NotificationAttentionLevel.all.allows(.interrupted))
    }

    func testTaskKindsUseSafeActionCategories() {
        XCTAssertEqual(
            PulseNotificationKind.waitingForApproval.categoryIdentifier,
            PulseNotificationCategory.actionableTask
        )
        XCTAssertEqual(
            PulseNotificationKind.completed.categoryIdentifier,
            PulseNotificationCategory.completedTask
        )
        XCTAssertEqual(
            PulseNotificationKind.failed.categoryIdentifier,
            PulseNotificationCategory.terminalTask
        )
        XCTAssertFalse(PulseNotificationAction.openTask.isEmpty)
        XCTAssertFalse(PulseNotificationAction.markViewed.isEmpty)
        XCTAssertFalse(PulseNotificationAction.snooze15Minutes.isEmpty)
        XCTAssertFalse(PulseNotificationAction.snoozeOneHour.isEmpty)
    }

    func testTaskNotificationTitlesAndOpenActionAreModelAgnostic() {
        XCTAssertEqual(
            PulseNotificationKind.waitingForApproval.title(
                modelDisplayName: "Codex",
                language: .simplifiedChinese
            ),
            "Codex · 等待授权"
        )
        XCTAssertEqual(
            PulseNotificationKind.waitingForAnswer.title(
                modelDisplayName: "Claude Code",
                language: .english
            ),
            "Claude Code · Waiting for Your Answer"
        )
        XCTAssertEqual(
            PulseNotificationKind.completed.title(
                modelDisplayName: "GLM",
                language: .simplifiedChinese
            ),
            "GLM · 任务已完成"
        )
        XCTAssertEqual(
            PulseNotificationAction.openTaskTitle(language: .simplifiedChinese),
            "打开任务"
        )
        XCTAssertEqual(
            PulseNotificationAction.openTaskTitle(language: .english),
            "Open Task"
        )
    }

    func testNotificationRetryBackoffSaturatesInsteadOfGivingUp() {
        XCTAssertEqual(NotificationRetryBackoff.delay(afterFailure: 0), .seconds(2))
        XCTAssertEqual(NotificationRetryBackoff.delay(afterFailure: 6), .seconds(300))
        XCTAssertEqual(NotificationRetryBackoff.delay(afterFailure: 100), .seconds(300))
    }

    func testSnoozeDeliveryRetriesTransientFailures() async {
        let attempts = NotificationDeliveryAttemptCounter(successAt: 3)

        let delivered = await NotificationDeliveryRetrier.deliver(
            delays: [.zero, .zero]
        ) {
            await attempts.attempt()
        }

        XCTAssertTrue(delivered)
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 3)
    }

    func testSnoozeDeliveryStopsAfterRetryBudget() async {
        let attempts = NotificationDeliveryAttemptCounter(successAt: nil)

        let delivered = await NotificationDeliveryRetrier.deliver(
            delays: [.zero, .zero]
        ) {
            await attempts.attempt()
        }

        XCTAssertFalse(delivered)
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 3)
    }

    func testSnoozeReconciliationWaitsForFirstRealSnapshot() {
        var tracker = SnoozeReconciliationTracker()
        let now = Date(timeIntervalSince1970: 200)

        XCTAssertFalse(tracker.shouldReconcile(snapshot: TaskSnapshot.empty, asOf: now))
        XCTAssertEqual(tracker.lastReconciledAt, .distantPast)

        let realSnapshot = TaskSnapshot(tasks: [], refreshedAt: now, health: [])
        XCTAssertTrue(tracker.shouldReconcile(snapshot: realSnapshot, asOf: now))
        XCTAssertFalse(
            tracker.shouldReconcile(
                snapshot: realSnapshot,
                asOf: now.addingTimeInterval(29)
            )
        )
        XCTAssertTrue(
            tracker.shouldReconcile(
                snapshot: realSnapshot,
                asOf: now.addingTimeInterval(30)
            )
        )
    }

    func testSnoozeReconciliationUsesHubRefreshInsteadOfCodexProjection() {
        var tracker = SnoozeReconciliationTracker()
        let now = Date(timeIntervalSince1970: 200)
        let glmOnlyHub = PulseHubSnapshot(
            models: [
                ModelTaskSnapshot(
                    identity: .glm,
                    tasks: [],
                    health: [.healthy(.zcodeEventLog, at: now)],
                    refreshedAt: now
                ),
            ],
            refreshedAt: now
        )

        XCTAssertFalse(tracker.shouldReconcile(snapshot: PulseHubSnapshot.empty, asOf: now))
        XCTAssertTrue(tracker.shouldReconcile(snapshot: glmOnlyHub, asOf: now))
    }

    @MainActor
    func testSnoozedTaskIsCancelledAfterStateChangeOrProjectMute() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = PulseSettings(defaults: defaults)
        settings.notificationAttentionLevel = .all
        let now = Date.now
        let waitingTask = makeTask(state: .waitingForApproval)
        let userInfo: [AnyHashable: Any] = [
            "taskID": waitingTask.id,
            "threadID": waitingTask.threadId,
            "notificationKind": PulseNotificationKind.waitingForApproval.rawValue,
        ]

        XCTAssertTrue(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: TaskSnapshot(tasks: [waitingTask], refreshedAt: now, health: []),
                settings: settings,
                asOf: now
            )
        )

        let completedTask = makeTask(state: .completed)
        XCTAssertFalse(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: TaskSnapshot(tasks: [completedTask], refreshedAt: now, health: []),
                settings: settings,
                asOf: now
            )
        )

        settings.muteProject(waitingTask.projectIdentityDirectory, until: now.addingTimeInterval(60))
        XCTAssertFalse(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: TaskSnapshot(tasks: [waitingTask], refreshedAt: now, health: []),
                settings: settings,
                asOf: now
            )
        )
    }

    @MainActor
    func testSnoozedTaskSurvivesTemporarySourceOutageButNotHealthyRemoval() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = PulseSettings(defaults: defaults)
        settings.notificationAttentionLevel = .all
        let now = Date.now
        let waitingTask = makeTask(state: .waitingForApproval)
        let userInfo: [AnyHashable: Any] = [
            "taskID": waitingTask.id,
            "threadID": waitingTask.threadId,
            "notificationKind": PulseNotificationKind.waitingForApproval.rawValue,
        ]

        XCTAssertTrue(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: TaskSnapshot(
                    tasks: [],
                    refreshedAt: now,
                    health: [.degraded(.rolloutJSONL, message: "partial")]
                ),
                settings: settings,
                asOf: now
            )
        )
        XCTAssertFalse(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: TaskSnapshot(
                    tasks: [],
                    refreshedAt: now.addingTimeInterval(1),
                    health: [.healthy(.rolloutJSONL, at: now.addingTimeInterval(1))]
                ),
                settings: settings,
                asOf: now.addingTimeInterval(1)
            )
        )
        XCTAssertFalse(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: TaskSnapshot(
                    tasks: [],
                    refreshedAt: now.addingTimeInterval(2),
                    health: [.unavailable(.receipts, message: "unrelated")]
                ),
                settings: settings,
                asOf: now.addingTimeInterval(2)
            )
        )
    }

    @MainActor
    func testSnoozedGLMTaskReconcilesAgainstItsOwnProfileSnapshot() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = PulseSettings(defaults: defaults)
        settings.notificationAttentionLevel = .all
        let now = Date(timeIntervalSince1970: 200)
        let waitingGLMTask = makeTask(
            state: .waitingForAnswer,
            id: "shared-thread",
            identity: .glm,
            sessionID: "glm-session"
        )
        var userInfo: [AnyHashable: Any] = TaskNotificationRoute(task: waitingGLMTask).userInfo
        userInfo["notificationKind"] = PulseNotificationKind.waitingForAnswer.rawValue

        let healthyGLMHub = PulseHubSnapshot(
            models: [
                ModelTaskSnapshot(
                    identity: .codex,
                    tasks: [],
                    health: [.healthy(.rolloutJSONL, at: now)],
                    refreshedAt: now
                ),
                ModelTaskSnapshot(
                    identity: .glm,
                    tasks: [waitingGLMTask],
                    health: [.healthy(.zcodeEventLog, at: now)],
                    refreshedAt: now
                ),
            ],
            refreshedAt: now
        )

        XCTAssertTrue(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                hubSnapshot: healthyGLMHub,
                settings: settings,
                asOf: now
            )
        )

        let degradedGLMHub = PulseHubSnapshot(
            models: [
                ModelTaskSnapshot(
                    identity: .codex,
                    tasks: [],
                    health: [.healthy(.rolloutJSONL, at: now)],
                    refreshedAt: now
                ),
                ModelTaskSnapshot(
                    identity: .glm,
                    tasks: [],
                    health: [.degraded(.zcodeEventLog, message: "partial")],
                    refreshedAt: now
                ),
            ],
            refreshedAt: now
        )
        XCTAssertTrue(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                hubSnapshot: degradedGLMHub,
                settings: settings,
                asOf: now
            )
        )

        let completedGLMTask = makeTask(
            state: .completed,
            id: "shared-thread",
            identity: .glm,
            sessionID: "glm-session"
        )
        let completedGLMHub = PulseHubSnapshot(
            models: [
                ModelTaskSnapshot(
                    identity: .codex,
                    tasks: [],
                    health: [.healthy(.rolloutJSONL, at: now)],
                    refreshedAt: now
                ),
                ModelTaskSnapshot(
                    identity: .glm,
                    tasks: [completedGLMTask],
                    health: [.healthy(.zcodeEventLog, at: now)],
                    refreshedAt: now
                ),
            ],
            refreshedAt: now
        )

        XCTAssertFalse(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                hubSnapshot: completedGLMHub,
                settings: settings,
                asOf: now
            )
        )
    }

    @MainActor
    func testSnoozedQuotaIsCancelledAfterResetWindowChanges() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = PulseSettings(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60 * 60)
        let userInfo: [AnyHashable: Any] = [
            "notificationType": "quota",
            "windowMinutes": String(RateLimitWindowDuration.weeklyMinutes),
            "resetsAt": String(Int(reset.timeIntervalSince1970)),
            "threshold": "20",
            "quotaScope": "unknown",
        ]

        XCTAssertTrue(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: quotaSnapshot(usedPercent: 85, updatedAt: now, resetsAt: reset),
                settings: settings,
                asOf: now
            )
        )
        XCTAssertTrue(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: quotaSnapshot(usedPercent: 85, updatedAt: now, resetsAt: reset),
                settings: settings,
                asOf: now.addingTimeInterval(30 * 60)
            )
        )
        XCTAssertTrue(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: quotaSnapshot(
                    usedPercent: 85,
                    updatedAt: now,
                    resetsAt: reset.addingTimeInterval(59)
                ),
                settings: settings,
                asOf: now
            )
        )
        XCTAssertFalse(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: quotaSnapshot(
                    usedPercent: 85,
                    updatedAt: now,
                    resetsAt: reset.addingTimeInterval(60 * 60)
                ),
                settings: settings,
                asOf: now
            )
        )
    }

    @MainActor
    func testLegacyFiveHourSnoozeFailsClosed() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = PulseSettings(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60 * 60)

        XCTAssertFalse(SnoozeNotificationPolicy.shouldKeep(
            userInfo: [
                "notificationType": "quota",
                "windowMinutes": "300",
                "resetsAt": String(Int(reset.timeIntervalSince1970)),
                "threshold": "20",
                "quotaScope": "unknown",
            ],
            snapshot: TaskSnapshot(
                tasks: [],
                refreshedAt: now,
                health: [.unavailable(.appServer, message: "refreshing")],
                rateLimits: RateLimitSnapshot(
                    fiveHour: RateLimitWindowSnapshot(
                        usedPercent: 85,
                        windowMinutes: 300,
                        resetsAt: reset
                    ),
                    weekly: nil,
                    updatedAt: now
                )
            ),
            settings: settings,
            asOf: now
        ))
    }

    @MainActor
    func testSnoozedQuotaSurvivesTransientAccountLimitRefreshFailure() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = PulseSettings(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60 * 60)
        let userInfo: [AnyHashable: Any] = [
            "notificationType": "quota",
            "windowMinutes": String(RateLimitWindowDuration.weeklyMinutes),
            "resetsAt": String(Int(reset.timeIntervalSince1970)),
            "threshold": "20",
            "quotaScope": "unknown",
        ]
        let unavailableSnapshot = TaskSnapshot(
            tasks: [],
            refreshedAt: now,
            health: [.unavailable(.appServer, message: "refreshing")]
        )

        XCTAssertTrue(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: unavailableSnapshot,
                settings: settings,
                asOf: now
            )
        )
        XCTAssertFalse(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: unavailableSnapshot,
                settings: settings,
                asOf: reset
            )
        )
    }

    @MainActor
    func testSnoozedQuotaIsCancelledWhenPlanScopeChanges() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = PulseSettings(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60 * 60)
        let userInfo: [AnyHashable: Any] = [
            "notificationType": "quota",
            "windowMinutes": String(RateLimitWindowDuration.weeklyMinutes),
            "resetsAt": String(Int(reset.timeIntervalSince1970)),
            "threshold": "20",
            "quotaScope": "pro",
        ]

        XCTAssertFalse(
            SnoozeNotificationPolicy.shouldKeep(
                userInfo: userInfo,
                snapshot: quotaSnapshot(
                    usedPercent: 85,
                    updatedAt: now,
                    resetsAt: reset,
                    planType: "business"
                ),
                settings: settings,
                asOf: now
            )
        )
    }

    func testCompletionSummaryCombinesMultipleProjectsWithoutNotificationStorm() {
        let tasks = [
            makeTask(
                state: .completed,
                id: "thread-1",
                title: "完成一",
                projectDirectory: "/tmp/alpha"
            ),
            makeTask(
                state: .completed,
                id: "thread-2",
                title: "完成二",
                projectDirectory: "/tmp/beta"
            ),
        ]

        let summary = CompletionNotificationSummary(tasks: tasks)

        XCTAssertEqual(summary.title, "Codex · 2 个任务已完成")
        XCTAssertEqual(summary.subtitle, "来自 2 个项目")
        XCTAssertTrue(summary.body.contains("alpha · 完成一"))
        XCTAssertTrue(summary.body.contains("beta · 完成二"))
    }

    func testCompletionBatchingNeverCombinesDifferentProfiles() {
        let tasks = [
            makeTask(state: .completed, id: "shared", identity: .codex),
            makeTask(state: .completed, id: "shared", identity: .claudeCode),
            makeTask(state: .completed, id: "shared", identity: .glm),
            makeTask(state: .completed, id: "codex-second", identity: .codex),
        ]

        let groups = CompletionNotificationBatching.groupsByProfile(tasks)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.flatMap { $0 }.count, tasks.count)
        XCTAssertTrue(groups.allSatisfy { group in
            Set(group.map(\.profileID)).count == 1
        })
        XCTAssertEqual(
            groups.first(where: { $0.first?.profileID == .codex })?.count,
            2
        )
    }

    func testQuotaAlertsProgressThroughThresholdsAndPersistPerResetWindow() throws {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(2 * 60 * 60)
        var tracker = RateLimitNotificationTracker(defaults: defaults)

        var alerts = tracker.pendingAlerts(
            in: quotaSnapshot(usedPercent: 81, updatedAt: now, resetsAt: resetsAt),
            asOf: now
        )
        XCTAssertEqual(alerts.map(\.threshold), [20])
        tracker.resolve(try XCTUnwrap(alerts.first), consumed: true, asOf: now)
        XCTAssertTrue(
            tracker.pendingAlerts(
                in: quotaSnapshot(usedPercent: 81, updatedAt: now, resetsAt: resetsAt),
                asOf: now
            ).isEmpty
        )

        alerts = tracker.pendingAlerts(
            in: quotaSnapshot(usedPercent: 91, updatedAt: now, resetsAt: resetsAt),
            asOf: now
        )
        XCTAssertEqual(alerts.map(\.threshold), [10])
        tracker.resolve(try XCTUnwrap(alerts.first), consumed: true, asOf: now)

        alerts = tracker.pendingAlerts(
            in: quotaSnapshot(usedPercent: 96, updatedAt: now, resetsAt: resetsAt),
            asOf: now
        )
        XCTAssertEqual(alerts.map(\.threshold), [5])
        tracker.resolve(try XCTUnwrap(alerts.first), consumed: true, asOf: now)

        var reloaded = RateLimitNotificationTracker(defaults: defaults)
        XCTAssertTrue(
            reloaded.pendingAlerts(
                in: quotaSnapshot(usedPercent: 99, updatedAt: now, resetsAt: resetsAt),
                asOf: now
            ).isEmpty
        )
    }

    func testQuotaAlertAtCriticalBalanceEmitsOnlyMostUrgentThreshold() throws {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(60 * 60)
        var tracker = RateLimitNotificationTracker(defaults: defaults)
        let alerts = tracker.pendingAlerts(
            in: quotaSnapshot(usedPercent: 96, updatedAt: now, resetsAt: resetsAt),
            asOf: now
        )

        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alert.threshold, 5)
        XCTAssertEqual(alert.remainingPercent, 4)
        XCTAssertEqual(alert.receiptKeys.count, 3)
        tracker.resolve(alert, consumed: true, asOf: now)

        var reloaded = RateLimitNotificationTracker(defaults: defaults)
        XCTAssertTrue(
            reloaded.pendingAlerts(
                in: quotaSnapshot(usedPercent: 96, updatedAt: now, resetsAt: resetsAt),
                asOf: now
            ).isEmpty
        )
    }

    func testQuotaResetJitterSharesPendingAndDeliveredReceipts() throws {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60 * 60)
        var tracker = RateLimitNotificationTracker(defaults: defaults)
        let alert = try XCTUnwrap(
            tracker.pendingAlerts(
                in: quotaSnapshot(usedPercent: 85, updatedAt: now, resetsAt: reset),
                asOf: now
            ).first
        )

        XCTAssertTrue(
            tracker.pendingAlerts(
                in: quotaSnapshot(
                    usedPercent: 85,
                    updatedAt: now,
                    resetsAt: reset.addingTimeInterval(59)
                ),
                asOf: now
            ).isEmpty
        )

        tracker.resolve(alert, consumed: true, asOf: now)
        var reloaded = RateLimitNotificationTracker(defaults: defaults)
        XCTAssertTrue(
            reloaded.pendingAlerts(
                in: quotaSnapshot(
                    usedPercent: 85,
                    updatedAt: now,
                    resetsAt: reset.addingTimeInterval(-59)
                ),
                asOf: now
            ).isEmpty
        )
        XCTAssertEqual(
            reloaded.pendingAlerts(
                in: quotaSnapshot(
                    usedPercent: 85,
                    updatedAt: now,
                    resetsAt: reset.addingTimeInterval(61)
                ),
                asOf: now
            ).count,
            1
        )
    }

    func testQuotaAlertsIgnoreStaleAndExpiredSnapshots() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = RateLimitNotificationTracker(defaults: defaults)

        XCTAssertTrue(
            tracker.pendingAlerts(
                in: quotaSnapshot(
                    usedPercent: 95,
                    updatedAt: now.addingTimeInterval(-16 * 60),
                    resetsAt: now.addingTimeInterval(60 * 60)
                ),
                asOf: now
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.pendingAlerts(
                in: quotaSnapshot(
                    usedPercent: 95,
                    updatedAt: now,
                    resetsAt: now.addingTimeInterval(-1)
                ),
                asOf: now
            ).isEmpty
        )
    }

    func testQuotaAlertsIgnoreFiveHourAndTrackWeeklyOnly() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = TaskSnapshot(
            tasks: [],
            refreshedAt: now,
            health: [],
            rateLimits: RateLimitSnapshot(
                fiveHour: RateLimitWindowSnapshot(
                    usedPercent: 82,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60 * 60)
                ),
                weekly: RateLimitWindowSnapshot(
                    usedPercent: 92,
                    windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                    resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60)
                ),
                updatedAt: now
            )
        )
        var tracker = RateLimitNotificationTracker(defaults: defaults)

        let alerts = tracker.pendingAlerts(in: snapshot, asOf: now)

        XCTAssertEqual(alerts.map(\.windowMinutes), [RateLimitWindowDuration.weeklyMinutes])
        XCTAssertEqual(alerts.map(\.threshold), [10])
    }

    func testQuotaFreshnessUsesWeeklyWindowOnly() {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = TaskSnapshot(
            tasks: [],
            refreshedAt: now,
            health: [],
            rateLimits: RateLimitSnapshot(
                fiveHour: RateLimitWindowSnapshot(
                    usedPercent: 85,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60 * 60),
                    observedAt: now
                ),
                weekly: RateLimitWindowSnapshot(
                    usedPercent: 95,
                    windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                    resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                    observedAt: now.addingTimeInterval(-20 * 60)
                ),
                updatedAt: now.addingTimeInterval(-20 * 60),
                planType: "pro"
            )
        )
        var tracker = RateLimitNotificationTracker(defaults: defaults)

        let alerts = tracker.pendingAlerts(in: snapshot, asOf: now)

        XCTAssertTrue(alerts.isEmpty)
    }

    func testQuotaReceiptsAndIdentifiersAreScopedByPlan() throws {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60 * 60)
        var tracker = RateLimitNotificationTracker(defaults: defaults)

        let proAlert = try XCTUnwrap(
            tracker.pendingAlerts(
                in: quotaSnapshot(
                    usedPercent: 85,
                    updatedAt: now,
                    resetsAt: reset,
                    planType: "Pro"
                ),
                asOf: now
            ).first
        )
        tracker.resolve(proAlert, consumed: true, asOf: now)
        let businessAlert = try XCTUnwrap(
            tracker.pendingAlerts(
                in: quotaSnapshot(
                    usedPercent: 85,
                    updatedAt: now,
                    resetsAt: reset,
                    planType: "Business"
                ),
                asOf: now
            ).first
        )

        XCTAssertEqual(proAlert.scopeKey, "pro")
        XCTAssertEqual(businessAlert.scopeKey, "business")
        XCTAssertNotEqual(proAlert.identifier, businessAlert.identifier)
    }

    private func makeTask(
        state: PulseTaskState,
        id: String = "thread-1",
        title: String = "测试任务",
        projectDirectory: String = "/tmp/project",
        identity: ModelIdentity = .codex,
        sessionID: String? = nil
    ) -> PulseTask {
        PulseTask(
            threadId: id,
            turnId: "turn-1",
            identity: identity,
            sessionID: sessionID,
            title: title,
            projectDirectory: projectDirectory,
            state: state,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            completedAt: state.isTerminal ? Date(timeIntervalSince1970: 110) : nil,
            lastStatus: state.rawValue,
            isUnread: state == .completed
        )
    }

    private func quotaSnapshot(
        usedPercent: Double,
        updatedAt: Date,
        resetsAt: Date,
        planType: String? = nil
    ) -> TaskSnapshot {
        TaskSnapshot(
            tasks: [],
            refreshedAt: updatedAt,
            health: [],
            rateLimits: RateLimitSnapshot(
                fiveHour: nil,
                weekly: RateLimitWindowSnapshot(
                    usedPercent: usedPercent,
                    windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                    resetsAt: resetsAt
                ),
                updatedAt: updatedAt,
                planType: planType
            )
        )
    }
}

private actor NotificationDeliveryAttemptCounter {
    private(set) var count = 0
    let successAt: Int?

    init(successAt: Int?) {
        self.successAt = successAt
    }

    func attempt() -> Bool {
        count += 1
        return count == successAt
    }
}
