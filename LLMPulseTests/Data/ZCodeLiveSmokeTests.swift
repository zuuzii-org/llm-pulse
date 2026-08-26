import Foundation
import XCTest
@testable import LLMPulse

/// Opt-in, read-only validation against the developer machine's real ZCode
/// SQLite ledger and lifecycle event log.
///
/// Run with `LLM_PULSE_RUN_LIVE_SMOKE=1`. Diagnostics intentionally contain
/// only aggregate counters and adapter health; they never include a title,
/// path, session identifier, or source payload.
final class ZCodeLiveSmokeTests: XCTestCase {
    private static let optInEnvironmentKey = "LLM_PULSE_RUN_LIVE_SMOKE"

    func testTheRealZCodeSourcesStillMatchTheGLMAdapter() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment[Self.optInEnvironmentKey] == "1",
            "Opt-in: reads aggregate metadata from the developer's ZCode sources."
        )

        let paths = ZCodePaths.live(environment: environment)
        let appIsInstalled = FileManager.default.fileExists(atPath: "/Applications/ZCode.app")
        let sourceIsInstalled = FileManager.default.fileExists(atPath: paths.databaseURL.path)
        try XCTSkipUnless(
            appIsInstalled || sourceIsInstalled,
            "ZCode is not installed on this machine."
        )

        let snapshot = await ZCodeTaskRepository(paths: paths).snapshot(now: .now)
        let requiredAdapters: Set<AdapterHealth.Adapter> = [
            .zcodeSQLite,
            .zcodeEventLog,
        ]
        let requiredHealth = snapshot.health.filter {
            requiredAdapters.contains($0.adapter)
        }

        XCTAssertEqual(
            Set(requiredHealth.map(\.adapter)),
            requiredAdapters,
            "The ZCode snapshot omitted a required adapter health observation."
        )
        XCTAssertTrue(
            requiredHealth.allSatisfy { $0.status != .unavailable },
            "A required ZCode source is unreadable."
        )
        XCTAssertTrue(
            requiredHealth.allSatisfy { $0.reason != .formatDrift },
            "The installed ZCode schema or lifecycle event format has drifted."
        )
        XCTAssertEqual(snapshot.identity, .glm)
        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.identity == .glm })

        if let usage = snapshot.usage {
            XCTAssertGreaterThanOrEqual(usage.inputTokens, 0)
            XCTAssertGreaterThanOrEqual(usage.outputTokens, 0)
            XCTAssertGreaterThanOrEqual(usage.cacheCreationInputTokens, 0)
            XCTAssertGreaterThanOrEqual(usage.cacheReadInputTokens, 0)
            XCTAssertGreaterThanOrEqual(usage.observedRequestCount, 0)
            XCTAssertLessThanOrEqual(usage.cacheCreationInputTokens, usage.inputTokens)
            XCTAssertLessThanOrEqual(usage.cacheReadInputTokens, usage.inputTokens)
        }

        for tokens in snapshot.tasks.compactMap(\.tokenUsage) {
            let input = try XCTUnwrap(tokens.inputTokens)
            let output = try XCTUnwrap(tokens.outputTokens)
            let reasoning = try XCTUnwrap(tokens.reasoningOutputTokens)
            let cached = try XCTUnwrap(tokens.cachedInputTokens)
            XCTAssertGreaterThanOrEqual(input, 0)
            XCTAssertGreaterThanOrEqual(output, 0)
            XCTAssertGreaterThanOrEqual(reasoning, 0)
            XCTAssertGreaterThanOrEqual(cached, 0)
            XCTAssertLessThanOrEqual(cached, input)
            let expectedTotal = checkedSum([input, output, reasoning])
            XCTAssertNotNil(expectedTotal, "ZCode token totals overflow Int.")
            XCTAssertEqual(
                tokens.totalTokens,
                expectedTotal
            )
        }

        let healthSummary = requiredHealth
            .map {
                "\($0.adapter.rawValue):\(statusName($0.status))"
            }
            .sorted()
            .joined(separator: ",")
        print(
            "ZCODE_LIVE_SMOKE "
                + "tasks=\(snapshot.tasks.count) "
                + "tokens=\(snapshot.usage?.totalTokens ?? 0) "
                + "requests=\(snapshot.usage?.observedRequestCount ?? 0) "
                + "health=\(healthSummary)"
        )
    }

    private func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private func statusName(_ status: AdapterHealth.Status) -> String {
        switch status {
        case .healthy: "healthy"
        case .degraded: "degraded"
        case .unavailable: "unavailable"
        }
    }

}
