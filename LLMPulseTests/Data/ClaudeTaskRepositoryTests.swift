import Foundation
import XCTest
@testable import LLMPulse

/// End-to-end cover for the Claude source, over a synthetic `~/.claude`.
final class ClaudeTaskRepositoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_784_918_000)
    private let sessionID = "86343497-3a6c-4bc3-84ba-3383c8b5696a"

    func testALiveSessionBecomesARunningTask() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeRegistry(pid: 4_242, sessionID: sessionID, startedAt: base)
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
            assistantRecord(at: base.addingTimeInterval(1)),
        ])

        let snapshot = await tree.repository(livePIDs: [4_242: base])
            .snapshot(now: base.addingTimeInterval(10))

        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(task.state, .running)
        XCTAssertEqual(task.identity, .claudeCode)
        XCTAssertEqual(task.sessionID, sessionID)
        XCTAssertEqual(task.projectDirectory, "/tmp/llm-pulse")
        XCTAssertEqual(task.title, "session-name")
    }

    func testASessionWhoseProcessDiedIsClampedToCompleted() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        // A registry file left behind by a crash, with no matching process.
        try tree.writeRegistry(pid: 4_242, sessionID: sessionID, startedAt: base)
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
            assistantRecord(
                at: base.addingTimeInterval(1),
                content: [[
                    "type": "tool_use",
                    "id": "tool-1",
                    "name": "Bash",
                    "input": [:] as [String: Any],
                ]]
            ),
        ])

        let snapshot = await tree.repository(livePIDs: [:])
            .snapshot(now: base.addingTimeInterval(10))

        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(
            task.state,
            .completed,
            "A transcript stuck mid-tool would otherwise claim to run forever."
        )
    }

    func testAnInterruptedSessionKeepsItsTerminalStateWhenTheProcessIsGone() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
            [
                "type": "assistant",
                "timestamp": iso(base.addingTimeInterval(1)),
                "isApiErrorMessage": true,
                "message": ["role": "assistant", "content": []] as [String: Any],
            ],
        ])

        let snapshot = await tree.repository(livePIDs: [:])
            .snapshot(now: base.addingTimeInterval(10))

        XCTAssertEqual(
            snapshot.tasks.first?.state,
            .failed,
            "A recorded failure is evidence, not an absence of it."
        )
    }

    func testNoQuotaCardIsClaimedForClaude() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
        ])

        let snapshot = await tree.repository(livePIDs: [:])
            .snapshot(now: base.addingTimeInterval(10))

        XCTAssertNil(
            snapshot.rateLimits,
            "A reset time is not obtainable read-only, and a window without "
                + "one would read as if it had Codex's semantics."
        )
    }

    func testAMissingClaudeInstallationDegradesRatherThanFailing() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = ClaudeTaskRepository(
            paths: ClaudePaths(claudeHome: empty),
            probe: FakeProcessProbe(livePIDs: [:]),
            cliUsageURL: empty.appendingPathComponent("claude-cli-usage.json")
        )

        let snapshot = await repository.snapshot(now: base)

        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertFalse(snapshot.health.isEmpty, "Silence would look like an idle machine.")
    }

    func testTerminalRowsOlderThanTheRetentionWindowAreDropped() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
            assistantRecord(at: base.addingTimeInterval(1)),
        ])

        let snapshot = await tree.repository(livePIDs: [:]).snapshot(
            now: base.addingTimeInterval(TaskRetentionPolicy.terminalRetention + 60)
        )

        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testTheBridgeOutranksTheDesktopHistoryWhenItSawUsageMoreRecently() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
        ])
        try tree.writeDesktopUsage(samples: [(base.addingTimeInterval(-3 * 60 * 60), 21, 14)])
        try tree.writeBridgeUsage(
            observedAt: base.addingTimeInterval(-30),
            fiveHour: (75, base.addingTimeInterval(90 * 60)),
            sevenDay: (29, base.addingTimeInterval(3 * 24 * 60 * 60))
        )

        let snapshot = await tree.repository(livePIDs: [:]).snapshot(now: base)
        let usage = try XCTUnwrap(snapshot.usage)

        XCTAssertEqual(usage.fiveHourWindow?.usedPercent, 75)
        XCTAssertEqual(
            usage.fiveHourWindow?.resetSource,
            .reported,
            "The vendor's own reset must not be downgraded to a bracketed guess."
        )
        XCTAssertEqual(usage.sevenDayWindow?.usedPercent, 29)
    }

    /// A reset time is an absolute moment, so it stays true even when the
    /// other source happens to hold the fresher percentage. Dropping it would
    /// make the row claim ignorance about something already known.
    func testAReportedResetSurvivesEvenWhenTheDesktopHistoryIsFresher() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
        ])
        try tree.writeDesktopUsage(samples: [(base.addingTimeInterval(-60), 40, 18)])
        try tree.writeBridgeUsage(
            observedAt: base.addingTimeInterval(-20 * 60),
            fiveHour: (33, base.addingTimeInterval(2 * 60 * 60)),
            sevenDay: nil
        )

        let snapshot = await tree.repository(livePIDs: [:]).snapshot(now: base)
        let usage = try XCTUnwrap(snapshot.usage)

        XCTAssertEqual(
            usage.fiveHourWindow?.usedPercent,
            40,
            "The percentage comes from whichever source saw it last."
        )
        XCTAssertEqual(usage.fiveHourWindow?.resetSource, .reported)
        XCTAssertEqual(
            usage.fiveHourWindow?.resetsAt,
            base.addingTimeInterval(2 * 60 * 60)
        )
    }

    func testWithoutTheBridgeTheDesktopHistoryStillDrivesTheCard() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
        ])
        try tree.writeDesktopUsage(samples: [(base.addingTimeInterval(-60), 40, 18)])

        let snapshot = await tree.repository(livePIDs: [:]).snapshot(now: base)
        let usage = try XCTUnwrap(snapshot.usage)

        XCTAssertEqual(usage.fiveHourWindow?.usedPercent, 40)
        XCTAssertEqual(usage.sevenDayWindow?.usedPercent, 18)
    }

    func testTheSourceAdapterPresentsTheClaudeProfile() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeRegistry(pid: 4_242, sessionID: sessionID, startedAt: base)
        try tree.writeTranscript(sessionID: sessionID, project: "llm-pulse", records: [
            userRecord(at: base),
        ])

        let source = ClaudeSourceRepository(
            repository: tree.repository(livePIDs: [4_242: base])
        )
        let model = await source.snapshot(now: base.addingTimeInterval(10))

        XCTAssertEqual(model.identity, .claudeCode)
        XCTAssertEqual(model.identity.profileID, .claudeCode)
        XCTAssertEqual(model.tasks.count, 1)
    }

    func testCodexAndClaudeTasksNeverShareAnIdentifier() {
        let claude = PulseTask(
            threadId: sessionID,
            identity: .claudeCode,
            sessionID: sessionID,
            title: "x",
            projectDirectory: "/tmp/p",
            state: .running,
            startedAt: base,
            updatedAt: base,
            lastStatus: "running"
        )
        let codex = PulseTask(
            threadId: sessionID,
            title: "x",
            projectDirectory: "/tmp/p",
            state: .running,
            startedAt: base,
            updatedAt: base,
            lastStatus: "running"
        )

        XCTAssertNotEqual(
            claude.id,
            codex.id,
            "Receipts are keyed by id; a collision would mark the wrong row read."
        )
    }

    // MARK: - Fixtures

    /// The registry's name is a generated slug unless it says otherwise, and
    /// showing it means the session cannot be found by the title Claude itself
    /// displays.
    func testTheTitleClaudeShowsWinsOverAGeneratedSlug() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeRegistry(
            pid: 4_242,
            sessionID: sessionID,
            startedAt: base,
            nameSource: "derived"
        )
        try tree.writeTranscript(sessionID: sessionID, project: "mc-mods", records: [
            userRecord(at: base),
            assistantRecord(at: base.addingTimeInterval(1)),
            ["type": "ai-title", "aiTitle": "暮色森林迁移进度检查"],
            ["type": "custom-title", "customTitle": "暮色森林迁移"],
        ])

        let snapshot = await tree.repository(livePIDs: [4_242: base])
            .snapshot(now: base.addingTimeInterval(10))

        XCTAssertEqual(try XCTUnwrap(snapshot.tasks.first).title, "暮色森林迁移")
    }

    func testAGeneratedTitleIsUsedWhenTheUserSetNone() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try tree.writeRegistry(
            pid: 4_242,
            sessionID: sessionID,
            startedAt: base,
            nameSource: "derived"
        )
        try tree.writeTranscript(sessionID: sessionID, project: "mc-mods", records: [
            userRecord(at: base),
            assistantRecord(at: base.addingTimeInterval(1)),
            ["type": "ai-title", "aiTitle": "暮色森林迁移进度检查"],
        ])

        let snapshot = await tree.repository(livePIDs: [4_242: base])
            .snapshot(now: base.addingTimeInterval(10))

        XCTAssertEqual(
            try XCTUnwrap(snapshot.tasks.first).title,
            "暮色森林迁移进度检查"
        )
    }

    private func makeTree() throws -> Tree {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tree = Tree(root: root)
        try tree.create()
        return tree
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func userRecord(at date: Date) -> [String: Any] {
        ["type": "user", "timestamp": iso(date)]
    }

    private func assistantRecord(
        at date: Date,
        content: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": iso(date),
            "message": [
                "role": "assistant",
                "id": "msg-a",
                "stop_reason": "end_turn",
                "content": content,
            ] as [String: Any],
        ]
    }

    private struct Tree {
        let root: URL

        var paths: ClaudePaths { ClaudePaths(claudeHome: root) }

        func create() throws {
            for directory in [paths.sessionsDirectory, paths.projectsDirectory] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// The bridge file lives in this app's own directory, so a test that
        /// let it default would read whatever the developer's machine holds.
        var cliUsageURL: URL { root.appendingPathComponent("claude-cli-usage.json") }

        func repository(livePIDs: [Int32: Date]) -> ClaudeTaskRepository {
            ClaudeTaskRepository(
                paths: paths,
                probe: FakeProcessProbe(livePIDs: livePIDs),
                discoveryInterval: 0,
                cliUsageURL: cliUsageURL
            )
        }

        func writeDesktopUsage(samples: [(Date, Int, Int)]) throws {
            let rows = samples.map { sample in
                "{\"t\":\(Int(sample.0.timeIntervalSince1970 * 1_000)),"
                    + "\"org\":\"org-1\","
                    + "\"u\":{\"fh\":\(sample.1),\"sd\":\(sample.2)}}"
            }
            let document = "{\"version\":2,\"samples\":[\(rows.joined(separator: ","))]}"
            try Data(document.utf8).write(to: paths.planUsageHistoryURL)
        }

        func writeBridgeUsage(
            observedAt: Date,
            fiveHour: (Int, Date)?,
            sevenDay: (Int, Date)?
        ) throws {
            func window(_ value: (Int, Date)?) -> String? {
                guard let value else { return nil }
                return "{\"used_percentage\":\(value.0),"
                    + "\"resets_at\":\(Int(value.1.timeIntervalSince1970))}"
            }
            var limits: [String] = []
            if let five = window(fiveHour) { limits.append("\"five_hour\":\(five)") }
            if let seven = window(sevenDay) { limits.append("\"seven_day\":\(seven)") }
            let document = "{\"observedAt\":\(Int(observedAt.timeIntervalSince1970)),"
                + "\"rateLimits\":{\(limits.joined(separator: ","))}}"
            try Data(document.utf8).write(to: cliUsageURL)
        }

        func writeRegistry(
            pid: Int32,
            sessionID: String,
            startedAt: Date,
            nameSource: String = "user"
        ) throws {
            let payload: [String: Any] = [
                "pid": Int(pid),
                "sessionId": sessionID,
                "cwd": "/tmp/llm-pulse",
                "startedAt": startedAt.timeIntervalSince1970 * 1_000,
                "kind": "interactive",
                "entrypoint": "claude-desktop",
                "name": "session-name",
                "nameSource": nameSource,
            ]
            try JSONSerialization.data(withJSONObject: payload).write(
                to: paths.sessionsDirectory.appendingPathComponent("\(pid).json")
            )
        }

        func writeTranscript(
            sessionID: String,
            project: String,
            records: [[String: Any]]
        ) throws {
            let directory = paths.projectsDirectory
                .appendingPathComponent("-tmp-\(project)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try records.reduce(into: Data()) { result, record in
                result.append(try JSONSerialization.data(withJSONObject: record))
                result.append(0x0A)
            }
            try data.write(to: directory.appendingPathComponent("\(sessionID).jsonl"))
        }
    }
}

private struct FakeProcessProbe: ClaudeProcessProbing {
    let livePIDs: [Int32: Date]

    func facts(forProcessID processID: Int32) -> ClaudeProcessFacts? {
        guard let startedAt = livePIDs[processID] else { return nil }
        return ClaudeProcessFacts(
            startedAt: Int(startedAt.timeIntervalSince1970),
            isZombie: false,
            executablePath: "/Applications/Claude.app/Contents/MacOS/claude"
        )
    }
}
