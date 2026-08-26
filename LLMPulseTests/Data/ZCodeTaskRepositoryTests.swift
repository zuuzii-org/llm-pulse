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
        XCTAssertEqual(snapshot.health.map(\.status), [.healthy, .healthy])
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

        let snapshot = await ZCodeTaskRepository(paths: tree.paths).snapshot(
            now: base.addingTimeInterval(2)
        )

        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertNil(snapshot.membership)
        XCTAssertNil(snapshot.rateLimits)
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
}
