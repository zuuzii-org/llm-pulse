import Foundation
import XCTest
@testable import LLMPulse

final class ZCodeEventLogReaderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_787_739_800)

    func testActualToolPermissionEventProducesWaitingForApproval() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event(
                "tool.permission.evaluated",
                at: base.addingTimeInterval(1),
                status: "waiting",
                toolCallID: "approval-1",
                decision: "ask",
                extra: [
                    "message": "must remain unread",
                ]
            ),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.observations["root"]?.status.state, .waitingForApproval)
        XCTAssertEqual(result.observations["root"]?.status.lastStatus, "waitingForApproval")
        XCTAssertEqual(result.invalidLineCount, 0)
        XCTAssertEqual(result.malformedRelevantEventCount, 0)
    }

    func testResolvedAndDeniedPermissionsReturnTheTurnToRunning() throws {
        for terminalPermissionEvent in [
            "tool.permission.resolved",
            "tool.permission.denied",
        ] {
            let tree = try ZCodeTestTree()
            defer { tree.remove() }
            let url = try tree.writeEvents([
                ZCodeTestTree.event("turn.started", at: base),
                ZCodeTestTree.event(
                    "tool.permission.evaluated",
                    at: base.addingTimeInterval(1),
                    status: "waiting",
                    toolCallID: "approval-1",
                    decision: "ask"
                ),
                ZCodeTestTree.event(
                    terminalPermissionEvent,
                    at: base.addingTimeInterval(2),
                    toolCallID: "approval-1"
                ),
            ])

            let result = try ZCodeEventLogReader().read(
                urls: [url],
                rootSessionIDs: ["root"]
            )

            XCTAssertEqual(
                result.observations["root"]?.status.state,
                .running,
                terminalPermissionEvent
            )
        }
    }

    func testProtocolPermissionAliasesRemainSupported() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event(
                "permission.requested",
                at: base.addingTimeInterval(1),
                toolCallID: "approval-1"
            ),
            ZCodeTestTree.event(
                "permission.resolved",
                at: base.addingTimeInterval(2),
                toolCallID: "approval-1"
            ),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.observations["root"]?.status.state, .running)
        XCTAssertEqual(result.malformedRelevantEventCount, 0)
    }

    func testPermissionFromAnotherTurnCannotChangeCurrentState() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", turnID: "current", at: base),
            ZCodeTestTree.event(
                "tool.permission.evaluated",
                turnID: "previous",
                at: base.addingTimeInterval(1),
                status: "waiting",
                toolCallID: "approval-1",
                decision: "ask"
            ),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.observations["root"]?.status.state, .running)
        XCTAssertEqual(result.malformedRelevantEventCount, 0)
    }

    func testMalformedPermissionResolutionCannotLeaveATrustedWaitingState() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event(
                "tool.permission.evaluated",
                at: base.addingTimeInterval(1),
                status: "waiting",
                toolCallID: "approval-1",
                decision: "ask"
            ),
            ZCodeTestTree.event(
                "tool.permission.resolved",
                at: base.addingTimeInterval(2),
                toolCallID: nil
            ),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.malformedRelevantEventCount, 1)
        XCTAssertNil(result.observations["root"])
    }

    func testAgentEventsAreFoldedByIdentifier() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event(
                "subagent.spawned",
                at: base.addingTimeInterval(1),
                agentID: "agent-1"
            ),
            ZCodeTestTree.event(
                "subagent.spawned",
                at: base.addingTimeInterval(2),
                agentID: "agent-2"
            ),
            ZCodeTestTree.event(
                "subagent.completed",
                at: base.addingTimeInterval(3),
                agentID: "agent-1"
            ),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.observations["root"]?.activeAgentCount, 2)
        XCTAssertEqual(result.observations["root"]?.agentActivityConfidence, .exact)
    }

    func testRunningRootCountsAsOneAgentWithoutSubagents() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.observations["root"]?.activeAgentCount, 1)
        XCTAssertEqual(result.observations["root"]?.agentActivityConfidence, .exact)
    }

    func testMalformedSubagentCompletionCannotLeaveAnExactCount() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event(
                "subagent.spawned",
                at: base.addingTimeInterval(1),
                agentID: "agent-1"
            ),
            ZCodeTestTree.event(
                "subagent.completed",
                at: base.addingTimeInterval(2)
            ),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.malformedRelevantEventCount, 1)
        XCTAssertNil(result.observations["root"]?.activeAgentCount)
        XCTAssertEqual(
            result.observations["root"]?.agentActivityConfidence,
            .unavailable
        )
    }

    func testCancelledTurnFailureMapsToInterrupted() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event(
                "turn.failed",
                at: base.addingTimeInterval(2),
                status: "cancelled"
            ),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.observations["root"]?.status.state, .interrupted)
        XCTAssertEqual(result.observations["root"]?.status.completedAt, base.addingTimeInterval(2))
    }

    func testMalformedKnownEventIsReportedAsDriftEvidence() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", turnID: nil, at: base),
        ])

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.malformedRelevantEventCount, 1)
        XCTAssertNil(result.observations["root"])
    }

    func testTrailingPartialLineIsDeferredRatherThanCalledInvalid() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let url = try tree.writeEvents([
            ZCodeTestTree.event("turn.started", at: base),
            ZCodeTestTree.event("turn.completed", at: base.addingTimeInterval(1)),
        ], trailingNewline: false)

        let result = try ZCodeEventLogReader().read(
            urls: [url],
            rootSessionIDs: ["root"]
        )

        XCTAssertEqual(result.invalidLineCount, 0)
        XCTAssertEqual(result.observations["root"]?.status.state, .running)
    }
}
