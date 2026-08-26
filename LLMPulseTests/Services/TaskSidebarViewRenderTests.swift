import AppKit
import SwiftUI
import XCTest
@testable import LLMPulse

@MainActor
final class TaskSidebarViewRenderTests: XCTestCase {
    func testRateLimitCardPresentsWeeklyOnlyAndUsesWeeklyFreshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = RateLimitSnapshot(
            fiveHour: RateLimitWindowSnapshot(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(60 * 60)
            ),
            weekly: RateLimitWindowSnapshot(
                usedPercent: 40,
                windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60)
            ),
            updatedAt: now
        )

        XCTAssertEqual(
            RateLimitCardPresentation.displayedWindowMinutes(snapshot),
            [RateLimitWindowDuration.weeklyMinutes]
        )
        XCTAssertTrue(RateLimitCardPresentation.hasCurrentWeeklyWindow(snapshot, asOf: now))

        let weeklyExpired = RateLimitSnapshot(
            fiveHour: snapshot.fiveHour,
            weekly: RateLimitWindowSnapshot(
                usedPercent: 40,
                windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                resetsAt: now.addingTimeInterval(-1)
            ),
            updatedAt: now
        )
        XCTAssertFalse(
            RateLimitCardPresentation.hasCurrentWeeklyWindow(weeklyExpired, asOf: now)
        )
    }

    func testGLMRateLimitCardPresentsFiveHourAndSevenDayWithoutWeeklyCopy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = RateLimitSnapshot(
            fiveHour: RateLimitWindowSnapshot(
                usedPercent: 10,
                windowMinutes: RateLimitWindowDuration.legacyFiveHourMinutes,
                resetsAt: now.addingTimeInterval(60 * 60)
            ),
            weekly: RateLimitWindowSnapshot(
                usedPercent: 40,
                windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60)
            ),
            updatedAt: now
        )

        let windows = RateLimitCardPresentation.windows(
            profileID: .glm,
            rateLimits: snapshot
        )
        XCTAssertEqual(windows.map(\.titleKey), ["5h 余额", "7 天余额"])
        XCTAssertEqual(
            windows.map(\.helpTextKey),
            ["最近 5 小时额度的剩余比例", "7 天额度的剩余比例"]
        )
        XCTAssertFalse(windows.flatMap { [$0.titleKey, $0.helpTextKey] }.contains {
            $0.contains("本周")
        })
        XCTAssertEqual(
            RateLimitCardPresentation.displayedWindowMinutes(
                profileID: .glm,
                rateLimits: snapshot
            ),
            [
                RateLimitWindowDuration.legacyFiveHourMinutes,
                RateLimitWindowDuration.weeklyMinutes,
            ]
        )
        XCTAssertTrue(RateLimitCardPresentation.hasCurrentDisplayedWindow(
            profileID: .glm,
            rateLimits: snapshot,
            asOf: now
        ))
    }

    func testGLMRateLimitCardNeedsEntitlementMembershipOrManualExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let emptyRateLimits = RateLimitSnapshot(
            fiveHour: nil,
            weekly: nil,
            updatedAt: now
        )
        XCTAssertFalse(RateLimitCardPresentation.shouldShowCard(
            profileID: .glm,
            rateLimits: nil,
            membership: nil,
            manualExpiry: nil
        ))
        XCTAssertFalse(RateLimitCardPresentation.shouldShowCard(
            profileID: .glm,
            rateLimits: emptyRateLimits,
            membership: MembershipObservation(),
            manualExpiry: nil
        ))
        XCTAssertTrue(RateLimitCardPresentation.shouldShowCard(
            profileID: .glm,
            rateLimits: nil,
            membership: MembershipObservation(tierDisplayName: "Coding Plan"),
            manualExpiry: nil
        ))
        XCTAssertTrue(RateLimitCardPresentation.shouldShowCard(
            profileID: .glm,
            rateLimits: nil,
            membership: nil,
            manualExpiry: now
        ))
    }

    func testGLMRateLimitCardOnlyPresentsWindowsThatActuallyExist() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = RateLimitWindowSnapshot(
            usedPercent: 40,
            windowMinutes: RateLimitWindowDuration.weeklyMinutes,
            resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60)
        )

        let weeklyOnly = RateLimitSnapshot(
            fiveHour: nil,
            weekly: weekly,
            updatedAt: now
        )
        XCTAssertEqual(
            RateLimitCardPresentation.windows(
                profileID: .glm,
                rateLimits: weeklyOnly
            ).map(\.id),
            [.sevenDay]
        )
        XCTAssertTrue(RateLimitCardPresentation.shouldShowCard(
            profileID: .glm,
            rateLimits: weeklyOnly,
            membership: nil,
            manualExpiry: nil
        ))
    }

    func testExactMembershipDatesUseRenewalAndExpiryCopy() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = now.addingTimeInterval(5 * 24 * 60 * 60)
        let formatted = PulseDisplayClock.day(date, language: .simplifiedChinese)
        let renewal = try XCTUnwrap(MembershipDisplay.resolve(
            observation: MembershipObservation(renewsAt: date),
            manualExpiry: nil,
            now: now
        ))
        let expiry = try XCTUnwrap(MembershipDisplay.resolve(
            observation: MembershipObservation(expiresAt: date),
            manualExpiry: nil,
            now: now
        ))

        XCTAssertEqual(
            MembershipRowPresentation.dateText(
                for: renewal,
                asOf: now,
                language: .simplifiedChinese
            ),
            "\(formatted) 续费"
        )
        XCTAssertEqual(
            MembershipRowPresentation.dateText(
                for: expiry,
                asOf: now,
                language: .simplifiedChinese
            ),
            "\(formatted) 到期"
        )
        XCTAssertTrue(
            MembershipRowPresentation.dateText(
                for: renewal,
                asOf: now,
                language: .english
            )?.contains("Renews") == true
        )
        XCTAssertTrue(
            MembershipRowPresentation.dateText(
                for: expiry,
                asOf: now,
                language: .english
            )?.contains("Expires") == true
        )
    }

    func testPastVendorRenewalAsksForRefreshInsteadOfClaimingHistoricalRenewal() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let renewal = try XCTUnwrap(MembershipDisplay.resolve(
            observation: MembershipObservation(
                renewsAt: now.addingTimeInterval(-60)
            ),
            manualExpiry: nil,
            now: now
        ))

        XCTAssertEqual(
            MembershipRowPresentation.dateText(
                for: renewal,
                asOf: now,
                language: .simplifiedChinese
            ),
            "续费信息待刷新"
        )
        XCTAssertEqual(
            MembershipRowPresentation.dateText(
                for: renewal,
                asOf: now,
                language: .english
            ),
            "Renewal details awaiting refresh"
        )
    }

    func testAttentionProjectControlsAndBulkActionRenderAtPanelWidth() throws {
        let suiteName = "TaskSidebarViewRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_783_908_000)
        let snapshot = fixtureSnapshot(now: now)
        let monitor = TaskMonitor(
            repository: RenderTaskRepository(snapshot: snapshot),
            initialSnapshot: snapshot
        )
        let settings = PulseSettings(defaults: defaults)
        settings.muteProject("/tmp/alpha", until: now.addingTimeInterval(60 * 60))

        let view = TaskSidebarView(
            monitor: monitor,
            settings: settings,
            onOpenTask: { _ in true },
            onDismiss: {},
            onOpenSettings: {}
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 400, height: 900)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        XCTAssertTrue(window.isVisible)

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 400)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 900)
        XCTAssertEqual(bitmap.pixelsHigh / bitmap.pixelsWide, 2)
        XCTAssertGreaterThan(pngData.count, 20_000)
        assertPaintedPanel(in: bitmap)

        let outputPath = ProcessInfo.processInfo.environment["LLM_PULSE_RENDER_QA_PATH"]
            ?? "/tmp/llm-pulse-panel-v02-fixture.png"
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL, options: .atomic)
    }

    func testAppServerQuotaHealthIsNotAHealthyTaskStatusSource() {
        XCTAssertFalse(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.healthy(.appServer)]
            )
        )
        XCTAssertTrue(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.healthy(.rolloutJSONL)]
            )
        )
        XCTAssertTrue(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.healthy(.pluginJournal)]
            )
        )
        XCTAssertTrue(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.healthy(.claudeSessionRegistry)]
            )
        )
        XCTAssertTrue(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.healthy(.claudeTranscript)]
            )
        )
        XCTAssertTrue(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.healthy(.zcodeSQLite)]
            )
        )
        XCTAssertTrue(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.healthy(.zcodeEventLog)]
            )
        )
        XCTAssertFalse(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.degraded(.zcodeEventLog, message: "stale")]
            )
        )
        XCTAssertFalse(
            TaskStatusSourceAvailability.hasHealthyAdapter(
                in: [.healthy(.zcodeEntitlementCache)]
            ),
            "Quota metadata cannot establish task lifecycle availability."
        )
    }

    func testGLMUsesLocalUsageWithoutClaudePlanWindows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let planWindow = try XCTUnwrap(PlanUsageWindow(
            usedPercent: 25,
            windowMinutes: 5 * 60,
            resetsAt: now.addingTimeInterval(60 * 60),
            resetSource: .reported
        ))
        let usage = ModelUsageSnapshot(
            inputTokens: 1_200,
            outputTokens: 300,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 100,
            observedRequestCount: 4,
            observedAt: now,
            fiveHourWindow: planWindow,
            planUsageObservedAt: now
        )

        XCTAssertTrue(ModelUsageCardPresentation.showsPlanUsage(
            identity: .claudeCode,
            usage: usage
        ))
        XCTAssertFalse(ModelUsageCardPresentation.showsPlanUsage(
            identity: .glm,
            usage: usage
        ))
    }

    func testThreeModelSwitcherRendersAtFourHundredPointsWithDistinctIcons() throws {
        let suiteName = "TaskSidebarViewRenderTests.three-models.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codexSnapshot = fixtureSnapshot(now: now)
        let glmUsage = ModelUsageSnapshot(
            inputTokens: 12_000,
            outputTokens: 2_400,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 4_000,
            observedRequestCount: 8,
            observedAt: now
        )
        let hubSnapshot = PulseHubSnapshot(
            models: [
                ModelTaskSnapshot(codex: codexSnapshot),
                ModelTaskSnapshot(
                    identity: .claudeCode,
                    tasks: [],
                    health: [
                        .healthy(.claudeSessionRegistry, at: now),
                        .healthy(.claudeTranscript, at: now),
                    ],
                    refreshedAt: now
                ),
                ModelTaskSnapshot(
                    identity: .glm,
                    tasks: [task(
                        id: "glm-waiting",
                        title: "等待 GLM 工具调用确认",
                        project: "/tmp/glm",
                        state: .waitingForApproval,
                        updatedAt: now,
                        identity: .glm,
                        tokenTotal: 14_400,
                        agentCount: 2,
                        agentConfidence: .exact
                    )],
                    usage: glmUsage,
                    rateLimits: RateLimitSnapshot(
                        fiveHour: RateLimitWindowSnapshot(
                            usedPercent: 24,
                            windowMinutes: RateLimitWindowDuration.legacyFiveHourMinutes,
                            resetsAt: now.addingTimeInterval(3 * 60 * 60),
                            observedAt: now
                        ),
                        weekly: RateLimitWindowSnapshot(
                            usedPercent: 41,
                            windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
                            observedAt: now
                        ),
                        updatedAt: now,
                        planType: "coding-plan",
                        limitID: "glm-coding-plan"
                    ),
                    membership: MembershipObservation(
                        tierDisplayName: "Coding Plan",
                        renewsAt: now.addingTimeInterval(12 * 24 * 60 * 60)
                    ),
                    health: [
                        .healthy(.zcodeSQLite, at: now),
                        .healthy(.zcodeEventLog, at: now),
                    ],
                    refreshedAt: now
                ),
            ],
            refreshedAt: now
        )
        let settings = PulseSettings(defaults: defaults)
        let selection = ModelSelectionStore(
            defaults: defaults,
            preferenceKey: "threeModelSelection"
        )
        selection.reconcile(with: hubSnapshot)
        XCTAssertTrue(selection.select(.glm))

        let (hostingView, window) = makeHostedSidebar(
            snapshot: hubSnapshot,
            settings: settings,
            modelSelection: selection
        )
        defer { tearDownHostedSidebar(hostingView, window: window) }
        settle(hostingView, in: window)
        let bitmap = try renderBitmap(of: hostingView)

        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 400)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 900)
        assertPaintedPanel(in: bitmap)

        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let outputPath = ProcessInfo.processInfo.environment["LLM_PULSE_GLM_RENDER_QA_PATH"]
            ?? "/tmp/llm-pulse-glm-fixture.png"
        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

        let iconNames = [
            ModelTabPresentation.systemImageName(for: .codex),
            ModelTabPresentation.systemImageName(for: .claudeCode),
            ModelTabPresentation.systemImageName(for: .glm),
        ]
        XCTAssertEqual(Set(iconNames).count, 3)
    }

    func testRunningSectionCollapsesInRenderedPanel() throws {
        let suiteName = "TaskSidebarViewRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = fixtureSnapshot(now: now)
        let settings = PulseSettings(defaults: defaults)
        let (hostingView, window) = makeHostedSidebar(snapshot: snapshot, settings: settings)
        defer { tearDownHostedSidebar(hostingView, window: window) }
        settle(hostingView, in: window)
        let expanded = try renderBitmap(of: hostingView)

        settings.runningSectionExpanded = false
        settle(hostingView, in: window)
        let collapsed = try renderBitmap(of: hostingView)

        XCTAssertGreaterThan(pixelDifference(expanded, collapsed), 800)
    }

    func testCollapsedSectionLeavesHiddenTasksOutOfFocusOrderAndPreservesRowExpansion() {
        let runningIDs = ["waiting", "running"]

        XCTAssertEqual(
            TaskSidebarSectionState.visibleTaskIDs(
                runningTaskIDs: runningIDs,
                runningSectionExpanded: true
            ),
            runningIDs
        )
        XCTAssertTrue(
            TaskSidebarSectionState.visibleTaskIDs(
                runningTaskIDs: runningIDs,
                runningSectionExpanded: false
            ).isEmpty
        )
        XCTAssertEqual(
            TaskSidebarSectionState.preservedExpandedTaskIDs(
                ["running", "removed"],
                existingTaskIDs: Set(runningIDs)
            ),
            ["running"]
        )
    }

    private func assertPaintedPanel(
        in bitmap: NSBitmapImageRep,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let xStride = max(1, bitmap.pixelsWide / 400)
        let yStride = max(1, bitmap.pixelsHigh / 900)
        var sampleCount = 0
        var opaqueCount = 0
        var blueCount = 0
        var orangeCount = 0
        var chromaticRows = Set<Int>()

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
                sampleCount += 1
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let alpha = color.alphaComponent
                guard alpha > 0.9 else { continue }
                opaqueCount += 1

                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let isBlue = blue > 0.42 && blue > red + 0.12 && blue > green + 0.04
                let isOrange = red > 0.58 && green > 0.22
                    && red > green + 0.10 && green > blue + 0.10

                if isBlue { blueCount += 1 }
                if isOrange { orangeCount += 1 }
                if isBlue || isOrange {
                    chromaticRows.insert(y)
                }
            }
        }

        XCTAssertGreaterThan(Double(opaqueCount) / Double(sampleCount), 0.97, file: file, line: line)
        XCTAssertGreaterThan(blueCount, 40, file: file, line: line)
        XCTAssertGreaterThan(orangeCount, 20, file: file, line: line)
        XCTAssertGreaterThan(chromaticRows.count, 20, file: file, line: line)
    }

    private func makeHostedSidebar(
        snapshot: TaskSnapshot,
        settings: PulseSettings
    ) -> (NSHostingView<TaskSidebarView>, NSWindow) {
        let monitor = TaskMonitor(
            repository: RenderTaskRepository(snapshot: snapshot),
            initialSnapshot: snapshot
        )
        let view = TaskSidebarView(
            monitor: monitor,
            settings: settings,
            onOpenTask: { _ in true },
            onDismiss: {},
            onOpenSettings: {}
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 400, height: 900)
        return (hostingView, makeWindow(hosting: hostingView))
    }

    private func makeHostedSidebar(
        snapshot: PulseHubSnapshot,
        settings: PulseSettings,
        modelSelection: ModelSelectionStore
    ) -> (NSHostingView<TaskSidebarView>, NSWindow) {
        let monitor = TaskMonitor(
            hubRepository: RenderHubRepository(snapshot: snapshot),
            initialHubSnapshot: snapshot
        )
        let view = TaskSidebarView(
            monitor: monitor,
            settings: settings,
            modelSelection: modelSelection,
            onOpenTask: { _ in true },
            onDismiss: {},
            onOpenSettings: {}
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 400, height: 900)
        return (hostingView, makeWindow(hosting: hostingView))
    }

    private func makeWindow<Content: View>(hosting hostingView: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFront(nil)
        return window
    }

    private func settle<Content: View>(
        _ hostingView: NSHostingView<Content>,
        in window: NSWindow
    ) {
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func tearDownHostedSidebar<Content: View>(
        _ hostingView: NSHostingView<Content>,
        window: NSWindow
    ) {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func renderBitmap<Content: View>(
        of hostingView: NSHostingView<Content>
    ) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    private func pixelDifference(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep
    ) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else {
            return .max
        }
        let xStride = max(1, lhs.pixelsWide / 400)
        let yStride = max(1, lhs.pixelsHigh / 900)
        var difference = 0
        for y in stride(from: 0, to: lhs.pixelsHigh, by: yStride) {
            for x in stride(from: 0, to: lhs.pixelsWide, by: xStride) {
                guard let left = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let right = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let delta = abs(left.redComponent - right.redComponent)
                    + abs(left.greenComponent - right.greenComponent)
                    + abs(left.blueComponent - right.blueComponent)
                    + abs(left.alphaComponent - right.alphaComponent)
                if delta > 0.08 { difference += 1 }
            }
        }
        return difference
    }

    private func fixtureSnapshot(now: Date) -> TaskSnapshot {
        TaskSnapshot(
            tasks: [
                task(
                    id: "waiting",
                    title: "等待数据库迁移确认",
                    project: "/tmp/alpha",
                    state: .waitingForApproval,
                    updatedAt: now.addingTimeInterval(-12),
                    tokenTotal: 48_200,
                    agentCount: 3,
                    agentConfidence: .exact
                ),
                task(
                    id: "running",
                    title: "实现通知分级与额度预警",
                    project: "/tmp/beta",
                    state: .running,
                    updatedAt: now.addingTimeInterval(-28),
                    tokenTotal: 126_400,
                    agentCount: 12,
                    agentConfidence: .provisional
                ),
                task(
                    id: "complete-a",
                    title: "完成界面重构",
                    project: "/tmp/alpha",
                    state: .completed,
                    updatedAt: now.addingTimeInterval(-90),
                    isUnread: true,
                    tokenTotal: 83_100,
                    agentCount: 0,
                    agentConfidence: .exact
                ),
                task(
                    id: "complete-b",
                    title: "补齐额度解析测试",
                    project: "/tmp/beta",
                    state: .completed,
                    updatedAt: now.addingTimeInterval(-180),
                    isUnread: true,
                    tokenTotal: 39_800,
                    agentCount: 2,
                    agentConfidence: .exact
                ),
                task(
                    id: "complete-c",
                    title: "验证发布构建",
                    project: "/tmp/gamma",
                    state: .completed,
                    updatedAt: now.addingTimeInterval(-260),
                    isUnread: true,
                    tokenTotal: 15_600,
                    agentCount: nil,
                    agentConfidence: .unavailable
                ),
            ],
            refreshedAt: now,
            health: [
                .healthy(.rolloutJSONL, at: now),
                .healthy(.sqlite, at: now),
            ],
            rateLimits: RateLimitSnapshot(
                fiveHour: RateLimitWindowSnapshot(
                    usedPercent: 82,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(72 * 60)
                ),
                weekly: RateLimitWindowSnapshot(
                    usedPercent: 38,
                    windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                    resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60)
                ),
                updatedAt: now,
                planType: "pro"
            )
        )
    }

    private func task(
        id: String,
        title: String,
        project: String,
        state: PulseTaskState,
        updatedAt: Date,
        isUnread: Bool = false,
        identity: ModelIdentity = .codex,
        tokenTotal: Int,
        agentCount: Int? = nil,
        agentConfidence: AgentActivityObservation.Confidence? = nil
    ) -> PulseTask {
        PulseTask(
            threadId: id,
            turnId: "turn-\(id)",
            identity: identity,
            title: title,
            projectDirectory: project,
            state: state,
            startedAt: updatedAt.addingTimeInterval(-12 * 60),
            updatedAt: updatedAt,
            completedAt: state.isTerminal ? updatedAt : nil,
            lastStatus: state.rawValue,
            isUnread: isUnread,
            tokenUsage: TokenUsageSnapshot(
                totalTokens: tokenTotal,
                inputTokens: tokenTotal * 3 / 4,
                cachedInputTokens: tokenTotal / 3,
                outputTokens: tokenTotal / 4,
                reasoningOutputTokens: tokenTotal / 12
            ),
            agentActivity: agentConfidence.map {
                AgentActivityObservation(
                    activeCount: agentCount,
                    confidence: $0,
                    observedAt: updatedAt
                )
            }
        )
    }
}

private actor RenderTaskRepository: TaskRepositoryProtocol {
    let snapshotValue: TaskSnapshot

    init(snapshot: TaskSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot(now: Date) async -> TaskSnapshot {
        snapshotValue
    }

    func receiptSnapshot(now: Date) async throws -> ReceiptSnapshot {
        ReceiptSnapshot(baselineAt: .distantPast, viewedTaskIDs: [])
    }

    func markViewed(_ task: PulseTask, at date: Date) async throws {}
    func markViewed(_ tasks: [PulseTask], at date: Date) async throws {}
    func unmarkViewed(_ task: PulseTask) async throws {}
    func unmarkViewed(_ tasks: [PulseTask]) async throws {}
}

private actor RenderHubRepository: PulseHubRepositoryProtocol {
    let snapshotValue: PulseHubSnapshot

    init(snapshot: PulseHubSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot(now: Date) async -> PulseHubSnapshot {
        snapshotValue
    }

    func markViewed(_ tasks: [PulseTask], at date: Date) async throws {}
    func unmarkViewed(_ tasks: [PulseTask]) async throws {}
}
