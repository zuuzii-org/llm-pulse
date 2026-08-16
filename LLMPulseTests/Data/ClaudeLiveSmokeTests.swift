import Foundation
import XCTest
@testable import LLMPulse

/// Reads this machine's real `~/.claude` once, to catch upstream drift.
///
/// Every other Claude test builds its own tree from hand-written fixtures, so
/// the entire suite stays green if Claude Code changes its layout. This is the
/// only check that would notice, which is why it exists — and why it is opt-in
/// rather than part of CI: it reads a developer's actual sessions.
///
/// Run with `LLM_PULSE_RUN_LIVE_SMOKE=1`.
final class ClaudeLiveSmokeTests: XCTestCase {
    func testTheRealClaudeTreeIsStillReadable() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LLM_PULSE_RUN_LIVE_SMOKE"] == "1",
            "Opt-in: reads the developer's own Claude Code sessions."
        )

        let paths = ClaudePaths.live()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: paths.projectsDirectory.path),
            "Claude Code is not installed on this machine."
        )

        let repository = ClaudeTaskRepository(paths: paths)
        let snapshot = await repository.snapshot(now: .now)

        let unreadable = snapshot.health.filter { $0.status == .unavailable }
        XCTAssertTrue(
            unreadable.isEmpty,
            "Unreadable sources: \(unreadable.map(\.adapter))"
        )

        let drifted = snapshot.health.filter { $0.reason == .formatDrift }
        XCTAssertTrue(
            drifted.isEmpty,
            "Claude Code's on-disk layout no longer matches what this build "
                + "expects: \(drifted.map { $0.message ?? "" })"
        )

        for task in snapshot.tasks {
            XCTAssertEqual(task.identity, .claudeCode)
            XCTAssertFalse(task.sessionID.isEmpty)
            XCTAssertTrue(
                ClaudeDeepLink.isValidSessionIdentifier(task.sessionID),
                "A session id that is not a UUID cannot be deep-linked."
            )
            XCTAssertGreaterThan(task.updatedAt.timeIntervalSince1970, 0)
        }

        if let usage = snapshot.usage {
            XCTAssertGreaterThanOrEqual(usage.inputTokens, usage.cacheReadInputTokens)
            for window in [usage.fiveHourWindow, usage.sevenDayWindow].compactMap({ $0 }) {
                XCTAssertTrue((0...100).contains(window.usedPercent))
            }
        }

        for task in snapshot.tasks {
            print("""
            [claude-smoke] session=\(task.sessionID.prefix(8)) \
            state=\(task.state.rawValue) \
            title=\(task.title) \
            project=\(task.projectDirectory) \
            idleSeconds=\(Int(Date().timeIntervalSince(task.updatedAt)))
            """)
        }

        // Printed rather than asserted: an idle machine legitimately has none.
        print("""
        [claude-smoke] tasks=\(snapshot.tasks.count) \
        states=\(snapshot.tasks.map { $0.state.rawValue }) \
        tokens=\(snapshot.tasks.compactMap { $0.tokenUsage?.totalTokens }) \
        health=\(snapshot.health.map { "\($0.adapter):\($0.status)" })
        [claude-smoke] usage total=\(snapshot.usage?.totalTokens ?? -1) \
        requests=\(snapshot.usage?.observedRequestCount ?? -1) \
        cacheWrite=\(snapshot.usage?.cacheCreationInputTokens ?? -1) \
        cacheRead=\(snapshot.usage?.cacheReadInputTokens ?? -1) \
        5h=\(snapshot.usage?.fiveHourWindow?.usedPercent.description ?? "nil")% \
        7d=\(snapshot.usage?.sevenDayWindow?.usedPercent.description ?? "nil")%
        [claude-smoke] resets \
        5h=\(snapshot.usage?.fiveHourWindow?.estimatedResetsAt?.description ?? "nil") \
        7d=\(snapshot.usage?.sevenDayWindow?.estimatedResetsAt?.description ?? "nil")
        [claude-smoke] membership tier=\(snapshot.membership?.tierDisplayName ?? "nil") \
        anchor=\(snapshot.membership?.subscriptionAnchor?.description ?? "nil") \
        trial=\(snapshot.membership?.trialEndsAt?.description ?? "nil") \
        derivedRenewal=\(MembershipDisplay.resolve(
            observation: snapshot.membership,
            manualExpiry: nil,
            now: .now
        )?.date?.description ?? "nil")
        """)
    }
}
