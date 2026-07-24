import AppKit
import Foundation
import XCTest
@testable import LLMPulse

final class StatusItemPresentationTests: XCTestCase {
    func testUsesSnapshotActiveAndRecentCompletedCounts() {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "waiting", state: .waitingForAnswer),
                makeTask(id: "completed-unread", state: .completed, isUnread: true),
                makeTask(id: "completed-viewed", state: .completed, isUnread: false),
                makeTask(id: "failed", state: .failed),
                makeTask(id: "interrupted", state: .interrupted),
            ],
            refreshedAt: .now,
            health: []
        )

        let presentation = StatusItemPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.activeCount, 2)
        XCTAssertEqual(presentation.recentCompletedCount, 4)
        XCTAssertEqual(presentation.waitingActionCount, 1)
        XCTAssertTrue(presentation.hasWaitingAction)
        XCTAssertEqual(presentation.indicatorState, .failure)
        XCTAssertEqual(presentation.title, "2\n4")
        XCTAssertTrue(presentation.hasFailures)
    }

    func testCompactCountsCapAt99PlusWithoutChangingAccessibilityCounts() {
        let tasks = (0..<100).map {
            makeTask(id: "running-\($0)", state: .running)
        } + (0..<100).map {
            makeTask(id: "completed-\($0)", state: .completed)
        }
        let presentation = StatusItemPresentation(
            snapshot: TaskSnapshot(tasks: tasks, refreshedAt: .now, health: [])
        )

        XCTAssertEqual(presentation.title, "99+\n99+")
        XCTAssertTrue(presentation.accessibilityLabel.contains("正在运行 100 个任务"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("最近完成 100 个任务"))
    }

    func testCompactCountsKeepZeroOneAndTwoDigitValuesUnpadded() {
        let empty = StatusItemPresentation(
            snapshot: TaskSnapshot(tasks: [], refreshedAt: .now, health: [])
        )
        let one = StatusItemPresentation(
            snapshot: TaskSnapshot(
                tasks: [
                    makeTask(id: "running-one", state: .running),
                    makeTask(id: "completed-one", state: .completed),
                ],
                refreshedAt: .now,
                health: []
            )
        )
        let twoDigits = StatusItemPresentation(
            snapshot: TaskSnapshot(
                tasks: (0..<12).map {
                    makeTask(id: "running-two-digits-\($0)", state: .running)
                } + (0..<34).map {
                    makeTask(id: "completed-two-digits-\($0)", state: .completed)
                },
                refreshedAt: .now,
                health: []
            )
        )

        XCTAssertEqual(empty.title, "0\n0")
        XCTAssertEqual(one.title, "1\n1")
        XCTAssertEqual(twoDigits.title, "12\n34")
    }

    func testEnglishAccessibilityAndTooltipCopy() {
        let snapshot = TaskSnapshot(
            tasks: [makeTask(id: "running", state: .running)],
            refreshedAt: .now,
            health: []
        )
        let presentation = StatusItemPresentation(snapshot: snapshot, language: .english)

        XCTAssertTrue(presentation.accessibilityLabel.contains("Running tasks: 1"))
        XCTAssertTrue(presentation.toolTip.contains("1 running"))
    }

    @MainActor
    func testMenuBarIconIsAn18PointTemplateImage() {
        let image = NSImage.statusMenuIcon

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
    }

    func testSparkleUsesStableReleaseFeedAndValidEdDSAKey() throws {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            PulseBrand.displayName
        )
        XCTAssertEqual(Bundle.main.bundleIdentifier, PulseBrand.bundleIdentifier)
        XCTAssertEqual(PulseBrand.repositorySlug, "zuuzii-org/llm-pulse")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            PulseBrand.updateFeedURL.absoluteString
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool,
            true
        )
        let publicKey = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
        let decodedKey = try XCTUnwrap(Data(base64Encoded: publicKey))
        XCTAssertEqual(decodedKey.count, 32)
    }

    @MainActor
    func testStatusItemRendersFixedIconAndMetricLayout() throws {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "completed", state: .completed),
            ],
            refreshedAt: .now,
            health: []
        )
        let monitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: snapshot),
            initialSnapshot: snapshot
        )
        let controller = StatusItemController(monitor: monitor)
        let button = try XCTUnwrap(controller.button)
        let contentView = try XCTUnwrap(
            button.subviews.compactMap { $0 as? StatusItemContentView }.first
        )
        button.layoutSubtreeIfNeeded()

        XCTAssertEqual(button.frame.width, 42, accuracy: 0.01)
        XCTAssertNil(button.image)
        XCTAssertEqual(button.imagePosition, .noImage)
        XCTAssertTrue(button.title.isEmpty)
        XCTAssertEqual(button.attributedTitle.length, 0)
        XCTAssertEqual(contentView.activeTitle, "1")
        XCTAssertEqual(contentView.recentCompletedTitle, "1")
        XCTAssertEqual(contentView.iconFrameForTesting.width, 18, accuracy: 0.01)
        XCTAssertEqual(contentView.iconFrameForTesting.height, 18, accuracy: 0.01)
        XCTAssertEqual(contentView.metricsFrameForTesting.width, 18, accuracy: 0.01)
        XCTAssertLessThanOrEqual(contentView.metricsFrameForTesting.maxX, button.bounds.maxX)
        XCTAssertNil(contentView.hitTest(NSPoint(x: 1, y: 1)))

        let outputBasePath = ProcessInfo.processInfo.environment["LLM_PULSE_STATUS_ITEM_QA_PATH"]
            ?? "/tmp/llm-pulse-status-item-fixture"
        func render(_ button: NSStatusBarButton, variant: String) throws {
            let contentView = try XCTUnwrap(
                button.subviews.compactMap { $0 as? StatusItemContentView }.first
            )
            for (suffix, appearanceName) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua),
            ] {
                button.appearance = NSAppearance(named: appearanceName)
                button.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(
                    button.bitmapImageRepForCachingDisplay(in: button.bounds)
                )
                button.cacheDisplay(in: button.bounds, to: bitmap)
                let metricsFrame = contentView.metricsFrameForTesting
                let iconFrame = contentView.iconFrameForTesting
                XCTAssertFalse(
                    iconFrame.intersects(metricsFrame),
                    "Icon and metric regions must not overlap for \(variant)-\(suffix)"
                )
                let iconPixelBounds = pixelBounds(
                    for: iconFrame,
                    in: bitmap,
                    pointBounds: button.bounds
                )
                let iconInkCount = nontransparentPixelCount(
                    in: bitmap,
                    pixelBounds: iconPixelBounds
                )
                let iconPixelArea = iconPixelBounds.width * iconPixelBounds.height
                XCTAssertGreaterThan(
                    iconInkCount,
                    max(32, iconPixelArea / 20),
                    "Missing rendered icon ink for \(variant)-\(suffix)"
                )
                XCTAssertEqual(
                    metricInkCount(
                        in: bitmap,
                        channel: .blue,
                        pixelBounds: iconPixelBounds
                    ),
                    0,
                    "Running count leaked into icon region for \(variant)-\(suffix)"
                )
                XCTAssertEqual(
                    metricInkCount(
                        in: bitmap,
                        channel: .green,
                        pixelBounds: iconPixelBounds
                    ),
                    0,
                    "Completed count leaked into icon region for \(variant)-\(suffix)"
                )
                let blueRows = try metricInkRows(
                    in: bitmap,
                    channel: .blue,
                    pointFrame: metricsFrame,
                    pointBounds: button.bounds
                )
                let greenRows = try metricInkRows(
                    in: bitmap,
                    channel: .green,
                    pointFrame: metricsFrame,
                    pointBounds: button.bounds
                )
                assertMetricInkHasVerticalPadding(blueRows, in: bitmap)
                assertMetricInkHasVerticalPadding(greenRows, in: bitmap)
                // NSBitmapImageRep row zero is the visual top edge. The blue
                // running count must therefore end above the first green row.
                XCTAssertLessThan(
                    try XCTUnwrap(blueRows.max()),
                    try XCTUnwrap(greenRows.min()),
                    "Metric rows must remain visibly separated"
                )
                let pngData = try XCTUnwrap(
                    bitmap.representation(using: .png, properties: [:])
                )
                XCTAssertGreaterThan(pngData.count, 500)

                let outputURL = URL(
                    fileURLWithPath: "\(outputBasePath)-\(variant)-\(suffix).png"
                )
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try pngData.write(to: outputURL, options: .atomic)
            }
        }
        try render(button, variant: "normal")

        let zeroSnapshot = TaskSnapshot(tasks: [], refreshedAt: .now, health: [])
        let zeroMonitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: zeroSnapshot),
            initialSnapshot: zeroSnapshot
        )
        let zeroController = StatusItemController(monitor: zeroMonitor)
        let zeroButton = try XCTUnwrap(zeroController.button)
        let zeroContentView = try XCTUnwrap(
            zeroButton.subviews.compactMap { $0 as? StatusItemContentView }.first
        )
        XCTAssertEqual(zeroContentView.activeTitle, "0")
        XCTAssertEqual(zeroContentView.recentCompletedTitle, "0")
        try render(zeroButton, variant: "zero")

        let twoDigitTasks = (0..<12).map {
            makeTask(id: "render-running-two-digit-\($0)", state: .running)
        } + (0..<34).map {
            makeTask(id: "render-completed-two-digit-\($0)", state: .completed)
        }
        let twoDigitSnapshot = TaskSnapshot(
            tasks: twoDigitTasks,
            refreshedAt: .now,
            health: []
        )
        let twoDigitMonitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: twoDigitSnapshot),
            initialSnapshot: twoDigitSnapshot
        )
        let twoDigitController = StatusItemController(monitor: twoDigitMonitor)
        let twoDigitButton = try XCTUnwrap(twoDigitController.button)
        let twoDigitContentView = try XCTUnwrap(
            twoDigitButton.subviews.compactMap { $0 as? StatusItemContentView }.first
        )
        XCTAssertEqual(twoDigitContentView.activeTitle, "12")
        XCTAssertEqual(twoDigitContentView.recentCompletedTitle, "34")
        try render(twoDigitButton, variant: "two-digit")

        let maxTasks = (0..<100).map {
            makeTask(id: "render-running-\($0)", state: .running)
        } + (0..<100).map {
            makeTask(id: "render-completed-\($0)", state: .completed)
        }
        let maxSnapshot = TaskSnapshot(tasks: maxTasks, refreshedAt: .now, health: [])
        let maxMonitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: maxSnapshot),
            initialSnapshot: maxSnapshot
        )
        let maxController = StatusItemController(monitor: maxMonitor)
        let maxButton = try XCTUnwrap(maxController.button)
        let maxContentView = try XCTUnwrap(
            maxButton.subviews.compactMap { $0 as? StatusItemContentView }.first
        )

        XCTAssertEqual(maxButton.frame.width, 42, accuracy: 0.01)
        XCTAssertTrue(maxButton.title.isEmpty)
        XCTAssertEqual(maxButton.attributedTitle.length, 0)
        XCTAssertEqual(maxContentView.activeTitle, "99+")
        XCTAssertEqual(maxContentView.recentCompletedTitle, "99+")
        try render(maxButton, variant: "max")
    }

    @MainActor
    func testAccessibleMenuActionUsesRightClickMenuWithoutChangingLeftClick() throws {
        let snapshot = TaskSnapshot(tasks: [], refreshedAt: .now, health: [])
        let monitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: snapshot),
            initialSnapshot: snapshot
        )
        var presentedMenus: [NSMenu] = []
        let controller = StatusItemController(
            monitor: monitor,
            menuPresenter: { menu, _ in
                presentedMenus.append(menu)
            }
        )
        let button = try XCTUnwrap(controller.button)
        var toggleCount = 0
        controller.onTogglePanel = { toggleCount += 1 }

        // Compared against the catalog rather than a literal: AppKit resolves
        // this copy through the running system's language, so a hardcoded
        // string only passes on a machine set to that language.
        XCTAssertEqual(
            button.accessibilityHelp(),
            Self.systemCopy("左键显示或隐藏任务面板；右键或“打开更多选项”操作显示菜单。")
        )
        let customAction = try XCTUnwrap(button.accessibilityCustomActions()?.first)
        XCTAssertEqual(customAction.name, Self.systemCopy("打开更多选项"))
        XCTAssertTrue(customAction.target === controller)
        XCTAssertEqual(customAction.selector, #selector(StatusItemController.openMenuFromAccessibility))

        controller.handleStatusItemActivation(eventType: .leftMouseUp, sender: button)
        XCTAssertEqual(toggleCount, 1)
        XCTAssertTrue(presentedMenus.isEmpty)

        controller.handleStatusItemActivation(eventType: .rightMouseUp, sender: button)
        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(presentedMenus.count, 1)

        XCTAssertTrue(controller.openMenuFromAccessibility())
        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(presentedMenus.count, 2)
        XCTAssertTrue(presentedMenus[0] === presentedMenus[1])
    }

    @MainActor
    func testRightClickMenuOffersCheckForUpdatesAndInvokesCallback() throws {
        let snapshot = TaskSnapshot(tasks: [], refreshedAt: .now, health: [])
        let monitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: snapshot),
            initialSnapshot: snapshot
        )
        var presentedMenu: NSMenu?
        let controller = StatusItemController(
            monitor: monitor,
            menuPresenter: { menu, _ in presentedMenu = menu }
        )
        let button = try XCTUnwrap(controller.button)
        var checkForUpdatesCount = 0
        controller.onCheckForUpdates = { checkForUpdatesCount += 1 }

        controller.handleStatusItemActivation(eventType: .rightMouseUp, sender: button)

        let menu = try XCTUnwrap(presentedMenu)
        let updateItem = try XCTUnwrap(
            menu.items.first { $0.title == Self.systemCopy("检查更新…") }
        )
        XCTAssertTrue(updateItem.target === controller)
        XCTAssertNotNil(updateItem.action)
        let updateItemIndex = try XCTUnwrap(menu.items.firstIndex(of: updateItem))
        menu.performActionForItem(at: updateItemIndex)
        XCTAssertEqual(checkForUpdatesCount, 1)
    }

    /// The catalog entry AppKit would resolve for the running system.
    ///
    /// Simplified Chinese is the key itself, so a machine set to it gets the
    /// key back; every other language gets its translation.
    private static func systemCopy(_ key: String) -> String {
        PulseL10n.text(key, language: AppLanguage.system.effectiveInterfaceLanguage)
    }

    private func metricInkRows(
        in bitmap: NSBitmapImageRep,
        channel: StatusItemMetricChannel,
        pointFrame: NSRect,
        pointBounds: NSRect
    ) throws -> [Int] {
        let scaleX = CGFloat(bitmap.pixelsWide) / pointBounds.width
        let minimumX = max(0, Int(floor(pointFrame.minX * scaleX)))
        let maximumX = min(
            bitmap.pixelsWide - 1,
            Int(ceil(pointFrame.maxX * scaleX)) - 1
        )
        var matchingRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in minimumX...maximumX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.05 else {
                    continue
                }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let isMatch: Bool
                switch channel {
                case .blue:
                    isMatch = blue > 0.25 && blue > green + 0.08 && blue > red + 0.15
                case .green:
                    isMatch = green > 0.25 && green > blue + 0.08 && green > red + 0.08
                }
                if isMatch {
                    matchingRows.append(y)
                }
            }
        }

        XCTAssertFalse(matchingRows.isEmpty, "Missing \(channel) metric ink")
        return matchingRows
    }

    private func pixelBounds(
        for pointFrame: NSRect,
        in bitmap: NSBitmapImageRep,
        pointBounds: NSRect
    ) -> (x: ClosedRange<Int>, y: ClosedRange<Int>, width: Int, height: Int) {
        let scaleX = CGFloat(bitmap.pixelsWide) / pointBounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / pointBounds.height
        let minimumX = max(0, Int(floor(pointFrame.minX * scaleX)))
        let maximumX = min(
            bitmap.pixelsWide - 1,
            Int(ceil(pointFrame.maxX * scaleX)) - 1
        )
        // NSBitmapImageRep row zero is the visual top edge, while NSView
        // geometry starts at the bottom edge.
        let minimumY = max(
            0,
            Int(floor((pointBounds.maxY - pointFrame.maxY) * scaleY))
        )
        let maximumY = min(
            bitmap.pixelsHigh - 1,
            Int(ceil((pointBounds.maxY - pointFrame.minY) * scaleY)) - 1
        )
        return (
            minimumX...maximumX,
            minimumY...maximumY,
            maximumX - minimumX + 1,
            maximumY - minimumY + 1
        )
    }

    private func nontransparentPixelCount(
        in bitmap: NSBitmapImageRep,
        pixelBounds: (x: ClosedRange<Int>, y: ClosedRange<Int>, width: Int, height: Int)
    ) -> Int {
        var count = 0
        for y in pixelBounds.y {
            for x in pixelBounds.x where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                count += 1
            }
        }
        return count
    }

    private func metricInkCount(
        in bitmap: NSBitmapImageRep,
        channel: StatusItemMetricChannel,
        pixelBounds: (x: ClosedRange<Int>, y: ClosedRange<Int>, width: Int, height: Int)
    ) -> Int {
        var count = 0
        for y in pixelBounds.y {
            for x in pixelBounds.x {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.05 else {
                    continue
                }
                let isMatch: Bool
                switch channel {
                case .blue:
                    isMatch = color.blueComponent > 0.25
                        && color.blueComponent > color.greenComponent + 0.08
                        && color.blueComponent > color.redComponent + 0.15
                case .green:
                    isMatch = color.greenComponent > 0.25
                        && color.greenComponent > color.blueComponent + 0.08
                        && color.greenComponent > color.redComponent + 0.08
                }
                if isMatch { count += 1 }
            }
        }
        return count
    }

    private func assertMetricInkHasVerticalPadding(
        _ matchingRows: [Int],
        in bitmap: NSBitmapImageRep,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let minimumRow = matchingRows.min(),
              let maximumRow = matchingRows.max() else { return }
        XCTAssertGreaterThanOrEqual(
            minimumRow,
            1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            maximumRow,
            bitmap.pixelsHigh - 2,
            file: file,
            line: line
        )
    }

    func testWaitingActionUsesOrangePriorityAndExpandedChineseLabels() {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "approval", state: .waitingForApproval),
                makeTask(id: "answer", state: .waitingForAnswer),
                makeTask(id: "completed", state: .completed),
            ],
            refreshedAt: .now,
            health: []
        )

        let presentation = StatusItemPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.waitingActionCount, 2)
        XCTAssertTrue(presentation.hasWaitingAction)
        XCTAssertEqual(presentation.indicatorState, .waitingAction)
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "LLM Pulse，正在运行 3 个任务，最近完成 1 个任务，需要你处理 2 个任务"
        )
        XCTAssertEqual(
            presentation.toolTip,
            "LLM Pulse · 正在运行 3 · 最近完成 1 · 需要你处理 2"
        )
    }

    func testNormalStateHasNoAttentionMessage() {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "completed", state: .completed),
            ],
            refreshedAt: .now,
            health: []
        )

        let presentation = StatusItemPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.waitingActionCount, 0)
        XCTAssertFalse(presentation.hasWaitingAction)
        XCTAssertEqual(presentation.indicatorState, .normal)
        XCTAssertFalse(presentation.accessibilityLabel.contains("需要你处理"))
        XCTAssertFalse(presentation.toolTip.contains("需要你处理"))
    }

    func testAttentionSelectorPrioritizesApprovalThenNewestAnswer() throws {
        let tasks = [
            makeTask(id: "answer-old", state: .waitingForAnswer, updatedAt: 100),
            makeTask(id: "approval-old", state: .waitingForApproval, updatedAt: 90),
            makeTask(id: "approval-new", state: .waitingForApproval, updatedAt: 110),
            makeTask(id: "running", state: .running, updatedAt: 120),
        ]

        XCTAssertEqual(try XCTUnwrap(AttentionTaskSelector.next(in: tasks)).id, "approval-new:turn-approval-new")
        XCTAssertNil(AttentionTaskSelector.next(in: [makeTask(id: "running", state: .running)]))
    }

    private func makeTask(
        id: String,
        state: PulseTaskState,
        isUnread: Bool = false,
        updatedAt timestamp: TimeInterval = 1_700_000_000
    ) -> PulseTask {
        let now = Date(timeIntervalSince1970: timestamp)
        return PulseTask(
            threadId: id,
            turnId: "turn-\(id)",
            title: id,
            projectDirectory: "/tmp/\(id)",
            state: state,
            startedAt: now,
            updatedAt: now,
            completedAt: state == .completed ? now : nil,
            lastStatus: state.rawValue,
            isUnread: isUnread
        )
    }
}

private enum StatusItemMetricChannel {
    case blue
    case green
}

private actor StatusItemRenderRepository: TaskRepositoryProtocol {
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
