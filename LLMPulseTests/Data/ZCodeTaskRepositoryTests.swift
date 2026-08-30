import Foundation
import XCTest
@testable import LLMPulse

final class ZCodeTaskRepositoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_787_739_800)

    func testRepositoryBuildsGLMTaskUsageAgentAndCodingPlanMembership() async throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        try tree.createDatabase()
        try tree.insertSession(
            "root",
            title: "  Build GLM support  ",
            createdAt: base,
            updatedAt: base.addingTimeInterval(4)
        )
        try tree.insertSelection(
            sessionID: "root",
            providerID: "builtin:bigmodel-coding-plan",
            modelID: "GLM-5.3",
            at: base
        )
        try tree.insertUsage(
            sessionID: "root",
            input: 1_000,
            output: 100,
            reasoning: 20,
            cacheCreation: 100,
            cacheRead: 700,
            at: base.addingTimeInterval(1),
            requestID: "request-1"
        )
        try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event(
                "subagent.spawned",
                at: base.addingTimeInterval(2),
                agentID: "agent-1"
            ),
            ZCodeTestTree.event(
                "permission.requested",
                at: base.addingTimeInterval(3),
                toolCallID: "approval-1"
            ),
        ])

        let snapshot = await ZCodeTaskRepository(paths: tree.paths).snapshot(
            now: base.addingTimeInterval(5)
        )

        XCTAssertEqual(snapshot.identity, .glm)
        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(task.identity, .glm)
        XCTAssertEqual(task.title, "Build GLM support")
        XCTAssertEqual(task.state, .waitingForApproval)
        XCTAssertEqual(task.tokenUsage?.totalTokens, 1_120)
        XCTAssertEqual(task.tokenUsage?.inputTokens, 1_000)
        XCTAssertEqual(task.tokenUsage?.cachedInputTokens, 700)
        XCTAssertEqual(task.tokenUsage?.reasoningOutputTokens, 20)
        XCTAssertEqual(task.agentActivity?.activeCount, 2)
        XCTAssertEqual(task.agentActivity?.confidence, .exact)
        XCTAssertEqual(snapshot.usage?.totalTokens, 1_120)
        XCTAssertEqual(snapshot.usage?.observedRequestCount, 1)
        XCTAssertNil(snapshot.rateLimits)
        XCTAssertEqual(snapshot.membership?.tierDisplayName, "Coding Plan")
        XCTAssertNil(snapshot.membership?.subscriptionAnchor)
        XCTAssertNil(snapshot.membership?.trialEndsAt)
        XCTAssertEqual(snapshot.health.map(\.status), [.healthy, .healthy, .unavailable])
        XCTAssertFalse(
            try XCTUnwrap(
                snapshot.health.first { $0.adapter == .zcodeEntitlementCache }
            ).isActionable
        )
    }

    func testMatchingEntitlementAddsFiveHourWeeklyAndExactRenewal() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let cachedAt = base.addingTimeInterval(4)
        let renewal = base.addingTimeInterval(20 * 24 * 60 * 60)
        let reader = StubEntitlementReader(results: [
            "builtin:bigmodel-coding-plan": [.observed(observation(
                provider: .bigModelCodingPlan,
                cachedAt: cachedAt,
                fiveHour: limit(
                    usedPercent: 25,
                    reset: base.addingTimeInterval(2 * 60 * 60)
                ),
                weekly: limit(
                    unit: 6,
                    number: 7,
                    usedPercent: 40,
                    reset: base.addingTimeInterval(3 * 24 * 60 * 60)
                ),
                subscription: .init(
                    productName: "GLM Coding Plan Pro",
                    billingCycle: "MONTH",
                    renewsAt: renewal,
                    expiresAt: nil
                )
            ))],
            "builtin:zai-coding-plan": [.absent],
        ])

        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: reader
        ).snapshot(now: base.addingTimeInterval(5))

        XCTAssertEqual(snapshot.rateLimits?.fiveHour?.usedPercent, 25)
        XCTAssertEqual(
            snapshot.rateLimits?.fiveHour?.windowMinutes,
            RateLimitWindowDuration.legacyFiveHourMinutes
        )
        XCTAssertEqual(snapshot.rateLimits?.fiveHour?.observedAt, cachedAt)
        XCTAssertEqual(snapshot.rateLimits?.weekly?.usedPercent, 40)
        XCTAssertEqual(snapshot.rateLimits?.updatedAt, cachedAt)
        XCTAssertEqual(snapshot.membership?.tierDisplayName, "GLM Coding Plan Pro")
        XCTAssertEqual(snapshot.membership?.renewsAt, renewal)
        XCTAssertNil(snapshot.membership?.expiresAt)
        XCTAssertEqual(
            snapshot.health.first { $0.adapter == .zcodeEntitlementCache }?.status,
            .healthy
        )
    }

    func testFreshEntitlementWithoutSubscriptionDoesNotInventMembership() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let reader = StubEntitlementReader(results: [
            "builtin:bigmodel-coding-plan": [.observed(observation(
                provider: .bigModelCodingPlan,
                cachedAt: base,
                fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
            ))],
            "builtin:zai-coding-plan": [.absent],
        ])

        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: reader
        ).snapshot(now: base.addingTimeInterval(1))

        XCTAssertNil(snapshot.membership)
        XCTAssertNotNil(snapshot.rateLimits?.fiveHour)
    }

    func testEntitlementMapsConfirmedExpiryWithoutCallingItARenewal() async throws {
        let tree = try codingPlanTree(providerID: "builtin:zai-coding-plan")
        defer { tree.remove() }
        let expiry = base.addingTimeInterval(15 * 24 * 60 * 60)
        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:zai-coding-plan": [.observed(observation(
                    provider: .zaiCodingPlan,
                    cachedAt: base,
                    subscription: .init(
                        productName: "GLM Coding Plan",
                        billingCycle: "YEAR",
                        renewsAt: nil,
                        expiresAt: expiry
                    )
                ))],
                "builtin:bigmodel-coding-plan": [.absent],
            ])
        ).snapshot(now: base)

        XCTAssertEqual(snapshot.membership?.expiresAt, expiry)
        XCTAssertNil(snapshot.membership?.renewsAt)
    }

    func testAmbiguousMembershipDoesNotDiscardValidQuota() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let details = [
            ZCodeEntitlementCacheReader.SubscriptionDetail(
                productName: "Plan A",
                billingCycle: "MONTH",
                renewsAt: base.addingTimeInterval(10 * 24 * 60 * 60),
                expiresAt: nil
            ),
            ZCodeEntitlementCacheReader.SubscriptionDetail(
                productName: "Plan B",
                billingCycle: "YEAR",
                renewsAt: nil,
                expiresAt: base.addingTimeInterval(20 * 24 * 60 * 60)
            ),
        ]
        let observation = ZCodeEntitlementCacheReader.Observation(
            provider: .bigModelCodingPlan,
            cachedAt: base,
            level: "Pro",
            fiveHour: limit(reset: base.addingTimeInterval(60 * 60)),
            weekly: nil,
            subscriptionDetails: details
        )

        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.observed(observation)],
            ])
        ).snapshot(now: base)

        XCTAssertNotNil(snapshot.rateLimits?.fiveHour)
        XCTAssertNil(snapshot.membership)
        XCTAssertEqual(
            snapshot.health.first { $0.adapter == .zcodeEntitlementCache }?.status,
            .degraded
        )
    }

    func testMissingSourcePercentageDropsWindowInsteadOfGuessingFromDuration() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let noPercentage = ZCodeEntitlementCacheReader.Limit(
            type: "TOKENS_LIMIT",
            unit: 3,
            number: 5,
            remaining: 4,
            usedPercent: nil,
            nextResetTime: base.addingTimeInterval(60 * 60)
        )

        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.observed(observation(
                    provider: .bigModelCodingPlan,
                    cachedAt: base,
                    fiveHour: noPercentage
                ))],
            ])
        ).snapshot(now: base)

        XCTAssertNil(snapshot.rateLimits)
    }

    func testReaderCannotReturnAnObservationForAnotherProvider() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.observed(observation(
                    provider: .zaiCodingPlan,
                    cachedAt: base,
                    fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
                ))],
            ])
        ).snapshot(now: base)

        XCTAssertNil(snapshot.rateLimits)
        let health = try XCTUnwrap(
            snapshot.health.first { $0.adapter == .zcodeEntitlementCache }
        )
        XCTAssertEqual(health.reason, .formatDrift)
    }

    func testProviderMismatchIsIgnoredAndVisibleRootDisambiguatesFreshProviders() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let zai = observation(
            provider: .zaiCodingPlan,
            cachedAt: base,
            fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
        )
        let mismatchReader = StubEntitlementReader(results: [
            "builtin:bigmodel-coding-plan": [.absent],
            "builtin:zai-coding-plan": [.observed(zai)],
        ])
        let mismatch = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: mismatchReader
        ).snapshot(now: base.addingTimeInterval(1))
        XCTAssertNil(mismatch.rateLimits)
        XCTAssertEqual(mismatch.membership?.tierDisplayName, "Coding Plan")

        let bothReader = StubEntitlementReader(results: [
            "builtin:bigmodel-coding-plan": [.observed(observation(
                provider: .bigModelCodingPlan,
                cachedAt: base,
                fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
            ))],
            "builtin:zai-coding-plan": [.observed(zai)],
        ])
        let both = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: bothReader
        ).snapshot(now: base.addingTimeInterval(1))
        XCTAssertNotNil(both.rateLimits?.fiveHour)
        XCTAssertNil(both.membership)
        XCTAssertEqual(
            both.health.first { $0.adapter == .zcodeEntitlementCache }?.status,
            .healthy
        )
    }

    func testIdleRepositoryUsesOneFreshProviderButNotTwo() async throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        try tree.createDatabase()
        try tree.writeEvents([])
        let bigModel = observation(
            provider: .bigModelCodingPlan,
            cachedAt: base,
            fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
        )
        let zai = observation(
            provider: .zaiCodingPlan,
            cachedAt: base,
            fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
        )

        let unique = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.observed(bigModel)],
                "builtin:zai-coding-plan": [.absent],
            ])
        ).snapshot(now: base)
        XCTAssertTrue(unique.tasks.isEmpty)
        XCTAssertNotNil(unique.rateLimits?.fiveHour)

        let ambiguous = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.observed(bigModel)],
                "builtin:zai-coding-plan": [.observed(zai)],
            ])
        ).snapshot(now: base)
        XCTAssertNil(ambiguous.rateLimits)
        XCTAssertNil(ambiguous.membership)
        XCTAssertEqual(
            ambiguous.health.first { $0.adapter == .zcodeEntitlementCache }?.status,
            .unavailable
        )
    }

    func testVisibleRootsUsingDifferentCodingPlanProvidersFailClosed() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        try tree.insertSession(
            "root-zai",
            createdAt: base,
            updatedAt: base.addingTimeInterval(1)
        )
        try tree.insertSelection(
            sessionID: "root-zai",
            providerID: "builtin:zai-coding-plan",
            modelID: "GLM-5.3",
            at: base.addingTimeInterval(1)
        )
        try tree.writeEvents([
            ZCodeTestTree.event("turn.started", sessionID: "root", at: base),
            ZCodeTestTree.event(
                "turn.started",
                sessionID: "root-zai",
                at: base.addingTimeInterval(1)
            ),
        ])

        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.observed(observation(
                    provider: .bigModelCodingPlan,
                    cachedAt: base,
                    fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
                ))],
                "builtin:zai-coding-plan": [.observed(observation(
                    provider: .zaiCodingPlan,
                    cachedAt: base,
                    fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
                ))],
            ])
        ).snapshot(now: base.addingTimeInterval(2))

        XCTAssertEqual(snapshot.tasks.count, 2)
        XCTAssertNil(snapshot.rateLimits)
        XCTAssertNil(snapshot.membership)
        XCTAssertEqual(
            snapshot.health.first { $0.adapter == .zcodeEntitlementCache }?.status,
            .unavailable
        )
    }

    func testExpiredWindowIsDroppedWithoutInvalidatingCurrentWindow() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let reader = StubEntitlementReader(results: [
            "builtin:bigmodel-coding-plan": [.observed(observation(
                provider: .bigModelCodingPlan,
                cachedAt: base,
                fiveHour: limit(reset: base.addingTimeInterval(-1)),
                weekly: limit(
                    unit: 6,
                    number: 7,
                    reset: base.addingTimeInterval(2 * 24 * 60 * 60)
                )
            ))],
            "builtin:zai-coding-plan": [.absent],
        ])

        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: reader
        ).snapshot(now: base)

        XCTAssertNil(snapshot.rateLimits?.fiveHour)
        XCTAssertNotNil(snapshot.rateLimits?.weekly)
    }

    func testTransientUnreadableRetainsFreshObservationThenExpiresIt() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let reader = StubEntitlementReader(results: [
            "builtin:bigmodel-coding-plan": [
                .observed(observation(
                    provider: .bigModelCodingPlan,
                    cachedAt: base,
                    fiveHour: limit(reset: base.addingTimeInterval(2 * 60 * 60)),
                    subscription: .init(
                        productName: "GLM Coding Plan Pro",
                        billingCycle: "MONTH",
                        renewsAt: base.addingTimeInterval(20 * 24 * 60 * 60),
                        expiresAt: nil
                    )
                )),
                .unreadable,
                .unreadable,
            ],
            "builtin:zai-coding-plan": [.absent],
        ])
        let repository = ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: reader
        )

        let initial = await repository.snapshot(now: base)
        for url in tree.paths.recentEventLogURLs() {
            try FileManager.default.removeItem(at: url)
        }
        let retained = await repository.snapshot(now: base.addingTimeInterval(5 * 60))
        let expired = await repository.snapshot(now: base.addingTimeInterval(11 * 60))

        XCTAssertNotNil(initial.rateLimits)
        XCTAssertTrue(retained.tasks.isEmpty)
        XCTAssertNotNil(retained.rateLimits)
        XCTAssertEqual(retained.membership?.tierDisplayName, "GLM Coding Plan Pro")
        XCTAssertNotNil(retained.membership?.renewsAt)
        XCTAssertEqual(
            retained.health.first { $0.adapter == .zcodeEntitlementCache }?.status,
            .degraded
        )
        XCTAssertEqual(
            retained.health.first { $0.adapter == .zcodeEntitlementCache }?.lastSuccessAt,
            base
        )
        XCTAssertNil(expired.rateLimits)
        XCTAssertEqual(expired.membership?.tierDisplayName, "Coding Plan")
    }

    func testEntitlementFormatDriftIsActionableButDoesNotEraseKnownProvider() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.formatDrift],
            ])
        ).snapshot(now: base)

        XCTAssertNil(snapshot.rateLimits)
        XCTAssertEqual(snapshot.membership?.tierDisplayName, "Coding Plan")
        let health = try XCTUnwrap(
            snapshot.health.first { $0.adapter == .zcodeEntitlementCache }
        )
        XCTAssertEqual(health.reason, .formatDrift)
        XCTAssertTrue(health.isActionable)
    }

    func testStaleEntitlementFallsBackToKnownPlanWithoutShowingQuota() async throws {
        let tree = try codingPlanTree(providerID: "builtin:bigmodel-coding-plan")
        defer { tree.remove() }
        let cachedAt = base.addingTimeInterval(-11 * 60)
        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.stale(cachedAt: cachedAt)],
            ])
        ).snapshot(now: base)

        XCTAssertNil(snapshot.rateLimits)
        XCTAssertEqual(snapshot.membership?.tierDisplayName, "Coding Plan")
        let health = try XCTUnwrap(
            snapshot.health.first { $0.adapter == .zcodeEntitlementCache }
        )
        XCTAssertEqual(health.status, .unavailable)
        XCTAssertFalse(health.isActionable)
    }

    func testAPIKeyProviderDoesNotInventMembershipOrQuota() async throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        try tree.createDatabase()
        try tree.insertSession("root", createdAt: base, updatedAt: base)
        try tree.insertSelection(
            sessionID: "root",
            providerID: "builtin:bigmodel",
            modelID: "GLM-5.3",
            at: base
        )
        try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event("turn.completed", at: base.addingTimeInterval(1)),
        ])

        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [
                "builtin:bigmodel-coding-plan": [.observed(observation(
                    provider: .bigModelCodingPlan,
                    cachedAt: base,
                    fiveHour: limit(reset: base.addingTimeInterval(60 * 60))
                ))],
            ])
        ).snapshot(now: base.addingTimeInterval(2))

        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertNil(snapshot.membership)
        XCTAssertNil(snapshot.rateLimits)
    }

    func testUnknownVisibleCodingPlanProviderFailsClosedAsFormatDrift() async throws {
        let tree = try codingPlanTree(
            providerID: "builtin:bigmodel-enterprise-coding-plan"
        )
        defer { tree.remove() }

        let snapshot = await ZCodeTaskRepository(
            paths: tree.paths,
            entitlementReader: StubEntitlementReader(results: [:])
        ).snapshot(now: base)

        XCTAssertNil(snapshot.rateLimits)
        XCTAssertNil(snapshot.membership)
        let health = try XCTUnwrap(
            snapshot.health.first { $0.adapter == .zcodeEntitlementCache }
        )
        XCTAssertEqual(health.reason, .formatDrift)
        XCTAssertTrue(health.isActionable)
    }

    func testMissingInstallationReportsBothZCodeAdaptersUnavailable() async throws {
        let tree = try ZCodeTestTree()
        tree.remove()

        let snapshot = await ZCodeTaskRepository(paths: tree.paths).snapshot(now: base)

        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertEqual(
            Set(snapshot.health.map(\.adapter)),
            [.zcodeSQLite, .zcodeEventLog]
        )
        XCTAssertTrue(snapshot.health.allSatisfy { $0.status == .unavailable })
    }

    func testMalformedLifecycleEventProducesActionableFormatDrift() async throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        try tree.createDatabase()
        try tree.insertSession("root", createdAt: base, updatedAt: base)
        try tree.insertSelection(
            sessionID: "root",
            providerID: "builtin:zai-coding-plan",
            modelID: "GLM-5.3",
            at: base
        )
        try tree.insertUsage(
            sessionID: "root",
            providerID: "builtin:zai-coding-plan",
            input: 10,
            output: 2,
            at: base
        )
        try tree.writeEvents([
            ZCodeTestTree.event("turn.started", turnID: nil, at: base),
        ])

        let snapshot = await ZCodeTaskRepository(paths: tree.paths).snapshot(
            now: base.addingTimeInterval(1)
        )

        let health = try XCTUnwrap(
            snapshot.health.first { $0.adapter == .zcodeEventLog }
        )
        XCTAssertEqual(health.status, .degraded)
        XCTAssertEqual(health.reason, .formatDrift)
        XCTAssertTrue(health.isActionable)
    }

    func testSourceRepositoryExposesTheGLMProfile() async throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        try tree.createDatabase()
        try tree.writeEvents([])

        let source = ZCodeSourceRepository(paths: tree.paths)
        let snapshot = await source.snapshot(now: base)

        XCTAssertEqual(source.identity, .glm)
        XCTAssertEqual(snapshot.identity, .glm)
    }

    private func codingPlanTree(providerID: String) throws -> ZCodeTestTree {
        let tree = try ZCodeTestTree()
        try tree.createDatabase()
        try tree.insertSession("root", createdAt: base, updatedAt: base)
        try tree.insertSelection(
            sessionID: "root",
            providerID: providerID,
            modelID: "GLM-5.3",
            at: base
        )
        try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
        ])
        return tree
    }

    private func observation(
        provider: ZCodeEntitlementCacheReader.ProviderID,
        cachedAt: Date,
        fiveHour: ZCodeEntitlementCacheReader.Limit? = nil,
        weekly: ZCodeEntitlementCacheReader.Limit? = nil,
        subscription: ZCodeEntitlementCacheReader.SubscriptionDetail? = nil
    ) -> ZCodeEntitlementCacheReader.Observation {
        ZCodeEntitlementCacheReader.Observation(
            provider: provider,
            cachedAt: cachedAt,
            level: "Pro",
            fiveHour: fiveHour,
            weekly: weekly,
            subscriptionDetails: subscription.map { [$0] } ?? []
        )
    }

    private func limit(
        unit: Int = 3,
        number: Double = 5,
        usedPercent: Double? = 20,
        reset: Date
    ) -> ZCodeEntitlementCacheReader.Limit {
        ZCodeEntitlementCacheReader.Limit(
            type: "TOKENS_LIMIT",
            unit: unit,
            number: number,
            remaining: nil,
            usedPercent: usedPercent,
            nextResetTime: reset
        )
    }
}

private final class StubEntitlementReader: ZCodeEntitlementReading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: [ZCodeEntitlementCacheReader.ReadResult]]

    init(results: [String: [ZCodeEntitlementCacheReader.ReadResult]]) {
        self.results = results
    }

    func read(
        provider: ZCodeEntitlementCacheReader.ProviderID,
        now _: Date
    ) -> ZCodeEntitlementCacheReader.ReadResult {
        lock.lock()
        defer { lock.unlock() }
        guard var queued = results[provider.rawValue], !queued.isEmpty else {
            return .absent
        }
        let result = queued.removeFirst()
        results[provider.rawValue] = queued
        return result
    }
}
