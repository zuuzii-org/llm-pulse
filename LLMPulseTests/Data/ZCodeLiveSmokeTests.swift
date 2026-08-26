import Foundation
import XCTest
@testable import LLMPulse

/// Opt-in, read-only validation against the developer machine's real ZCode
/// SQLite ledger, lifecycle event log, and renderer entitlement cache.
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

        let entitlementHealth = snapshot.health.first {
            $0.adapter == .zcodeEntitlementCache
        }
        XCTAssertNotEqual(
            entitlementHealth?.reason,
            .formatDrift,
            "The installed ZCode entitlement cache format has drifted."
        )
        if let rateLimits = snapshot.rateLimits {
            for window in [rateLimits.fiveHour, rateLimits.weekly].compactMap({ $0 }) {
                XCTAssertTrue((0...100).contains(window.usedPercent))
                XCTAssertGreaterThan(window.resetsAt, snapshot.refreshedAt)
                if let observedAt = window.observedAt {
                    XCTAssertLessThanOrEqual(
                        observedAt,
                        snapshot.refreshedAt.addingTimeInterval(60)
                    )
                }
            }
        }

        // The product TTL intentionally hides old values. A second read with an
        // unbounded age verifies the installed LevelDB shape even when ZCode has
        // not refreshed its renderer-owned entitlement snapshot recently.
        let entitlementReader = ZCodeEntitlementCacheReader(
            entitlementLocalStorageDirectory: paths.entitlementLocalStorageDirectory,
            maximumCacheAge: .greatestFiniteMagnitude
        )
        let entitlementResults = ZCodeEntitlementCacheReader.ProviderID.allCases.map {
            entitlementReader.read(provider: $0, now: .now)
        }
        XCTAssertFalse(entitlementResults.contains { result in
            if case .formatDrift = result { return true }
            return false
        })
        XCTAssertFalse(entitlementResults.contains { result in
            if case .unreadable = result { return true }
            return false
        })
        for observation in entitlementResults.compactMap({ result in
            if case let .observed(observation) = result { return observation }
            return nil
        }) {
            for limit in [observation.fiveHour, observation.weekly].compactMap({ $0 }) {
                if let usedPercent = limit.usedPercent {
                    XCTAssertTrue((0...100).contains(usedPercent))
                }
                XCTAssertTrue(limit.number?.isFinite ?? true)
                XCTAssertTrue(limit.remaining?.isFinite ?? true)
            }
        }

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
                + "health=\(healthSummary) "
                + "entitlement=\(entitlementResults.map(entitlementStatusName).joined(separator: ","))"
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

    private func entitlementStatusName(
        _ result: ZCodeEntitlementCacheReader.ReadResult
    ) -> String {
        switch result {
        case .observed: "observed"
        case .absent: "absent"
        case .stale: "stale"
        case .unreadable: "unreadable"
        case .formatDrift: "formatDrift"
        case .ambiguous: "ambiguous"
        }
    }

}
