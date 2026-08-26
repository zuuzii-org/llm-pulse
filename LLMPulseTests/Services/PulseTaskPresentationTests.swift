import Foundation
import XCTest
@testable import LLMPulse

final class PulseTaskPresentationTests: XCTestCase {
    func testAdapterHealthUsesModelNeutralDriftCopyAndZCodeSourceNames() {
        let drifted = AdapterHealth.degraded(
            .zcodeEventLog,
            message: "schema changed",
            reason: .formatDrift
        )

        XCTAssertEqual(
            drifted.displayMessage(language: .simplifiedChinese),
            "上游数据格式可能已更新，部分任务无法识别"
        )
        XCTAssertEqual(
            drifted.displayMessage(language: .english),
            "The upstream data format may have changed; some tasks cannot be recognized"
        )
        XCTAssertFalse(drifted.displayMessage.contains("Codex"))
        XCTAssertEqual(
            AdapterHealth.unavailable(
                .zcodeSQLite,
                message: "missing"
            ).displayMessage(language: .english),
            "Unable to read the local ZCode task index"
        )
        XCTAssertEqual(
            AdapterHealth.unavailable(
                .zcodeEventLog,
                message: "missing"
            ).displayMessage(language: .simplifiedChinese),
            "无法读取 ZCode 任务事件记录"
        )
        XCTAssertEqual(
            AdapterHealth.unavailable(
                .zcodeEntitlementCache,
                message: "missing"
            ).displayMessage(language: .english),
            "Unable to read the ZCode quota and membership cache"
        )
        let entitlementDrift = AdapterHealth.unavailable(
            .zcodeEntitlementCache,
            message: "schema changed",
            reason: .formatDrift
        )
        XCTAssertEqual(
            entitlementDrift.displayMessage(language: .simplifiedChinese),
            "GLM Coding Plan 数据格式可能已更新，额度与会员信息暂不可用"
        )
        XCTAssertTrue(entitlementDrift.isActionable)
    }

    func testProjectDisplayNameUsesNearestGitRoot() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let repository = temporaryRoot.appendingPathComponent("llm-pulse", isDirectory: true)
        let nestedDirectory = repository
            .appendingPathComponent("LLMPulse", isDirectory: true)
            .appendingPathComponent("UI", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )

        let task = makeTask(projectDirectory: nestedDirectory.path)
        XCTAssertEqual(task.projectDisplayName, "llm-pulse")
        XCTAssertEqual(task.projectIdentityDirectory, repository.path)
    }

    func testProjectDisplayNameFallsBackToWorkingDirectoryAndHandlesMissingPath() {
        XCTAssertEqual(
            makeTask(projectDirectory: "/a/nonexistent/path/中文项目/").projectDisplayName,
            "中文项目"
        )
        XCTAssertEqual(makeTask(projectDirectory: "").projectDisplayName, "未识别项目")
        XCTAssertEqual(makeTask(projectDirectory: "/").projectDisplayName, "未识别项目")
    }

    func testCompactTokenCountUsesStableUnitsWithoutDoubleCountingSubsets() {
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(nil), "—")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(-1), "0")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(999), "999")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(1_000), "1k")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(132_900), "132.9k")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(999_999), "1m")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(1_250_000), "1.3m")
    }

    func testRemainingPercentClampsAndExpiresAtReset() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(60)

        XCTAssertEqual(
            RateLimitWindowSnapshot(
                usedPercent: 12.5,
                windowMinutes: 300,
                resetsAt: future
            ).remainingPercent(asOf: now),
            87.5
        )
        XCTAssertEqual(
            RateLimitWindowSnapshot(
                usedPercent: 120,
                windowMinutes: 300,
                resetsAt: future
            ).remainingPercent(asOf: now),
            0
        )
        XCTAssertEqual(
            RateLimitWindowSnapshot(
                usedPercent: -5,
                windowMinutes: 300,
                resetsAt: future
            ).remainingPercent(asOf: now),
            100
        )
        XCTAssertNil(
            RateLimitWindowSnapshot(
                usedPercent: 12.5,
                windowMinutes: 300,
                resetsAt: now
            ).remainingPercent(asOf: now)
        )
    }

    func testQuotaResetDescriptionUsesConcreteDateAndTime() {
        let timeZone = try! XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 7,
            day: 11,
            hour: 22,
            minute: 0
        ))!
        let reset = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 7,
            day: 12,
            hour: 0,
            minute: 1
        ))!

        XCTAssertEqual(
            reset.pulseQuotaResetDescription(asOf: now, timeZone: timeZone),
            "重置 2026-07-12 00:01"
        )
    }

    func testQuotaResetDescriptionUsesRequestedSystemTimeZoneForDateBoundary() {
        let utc = try! XCTUnwrap(TimeZone(identifier: "UTC"))
        let shanghai = try! XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let reset = Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: utc,
            year: 2026,
            month: 7,
            day: 11,
            hour: 0,
            minute: 1
        ))!

        XCTAssertEqual(
            reset.pulseQuotaResetDescription(timeZone: utc),
            "重置 2026-07-11 00:01"
        )
        XCTAssertEqual(
            reset.pulseQuotaResetDescription(timeZone: shanghai),
            "重置 2026-07-11 08:01"
        )
    }

    func testEnglishPresentationLocalizesStatusRelativeTimeAndQuotaReset() {
        let task = makeTask(projectDirectory: "/tmp/project")
        XCTAssertEqual(task.displayStatusText(language: .english), "Running")

        let now = Date(timeIntervalSince1970: 1_700_000_120)
        let earlier = now.addingTimeInterval(-120)
        XCTAssertEqual(
            earlier.pulseRelativeDescription(asOf: now, language: .english),
            "2 minutes ago"
        )

        let timeZone = try! XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(
            now.pulseQuotaResetDescription(timeZone: timeZone, language: .english),
            "Resets 2023-11-14 22:15"
        )
    }

    private func makeTask(projectDirectory: String) -> PulseTask {
        PulseTask(
            threadId: UUID().uuidString,
            title: "Session",
            projectDirectory: projectDirectory,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            lastStatus: "running"
        )
    }
}
