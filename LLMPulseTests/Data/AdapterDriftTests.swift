import Foundation
import SQLite3
import XCTest
@testable import LLMPulse

/// Cover for upstream format drift becoming visible instead of silent.
///
/// Every adapter declines input it does not recognize, which is correct: a
/// normal machine is full of CLI sessions and child threads that are not
/// Codex Desktop roots. The failure mode is that a *changed* upstream format
/// looks exactly the same as an empty machine — v2.0.2 shipped that way, with
/// a blank panel reporting perfect health. These tests pin the signals that
/// tell the two apart.
final class AdapterDriftTests: XCTestCase {
    func testSQLiteThreadsWithNoMatchingRolloutRootReportFormatDrift() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rollout = sessions.appendingPathComponent("drifted.jsonl")
        // Same shape as today's rollouts, but an originator this build has
        // never heard of — exactly how the last upstream rename presented.
        try writeRollout(
            to: rollout,
            threadId: "drifted-thread",
            startedAt: now.addingTimeInterval(-30),
            originator: "codex_something_new"
        )

        let database = root.appendingPathComponent("state_1.sqlite")
        try createStateDatabase(at: database, threadId: "drifted-thread", rollout: rollout)

        let snapshot = try await snapshot(
            root: root,
            sessions: sessions,
            sqliteCandidates: [database],
            now: now
        )

        XCTAssertTrue(snapshot.tasks.isEmpty, "The rollout filter still declines it.")

        let rolloutHealth = try XCTUnwrap(
            snapshot.health.first { $0.adapter == .rolloutJSONL }
        )
        XCTAssertEqual(rolloutHealth.reason, .formatDrift)
        XCTAssertTrue(
            rolloutHealth.isActionable,
            "Drift the user cannot see is the whole defect."
        )
    }

    func testAThreadWhoseRolloutIsMissingReportsNoDrift() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // A stale row pointing at a rollout the user deleted. Nothing was
        // declined — the file simply is not there — so this must not be
        // mistaken for the format having moved.
        let database = root.appendingPathComponent("state_1.sqlite")
        try createStateDatabase(
            at: database,
            threadId: "vanished-thread",
            rollout: sessions.appendingPathComponent("vanished.jsonl")
        )

        let snapshot = try await snapshot(
            root: root,
            sessions: sessions,
            sqliteCandidates: [database],
            now: now
        )

        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertFalse(
            snapshot.health.contains { $0.reason == .formatDrift },
            "An unreadable rollout is not evidence about the format."
        )
    }

    func testAMachineWithoutDesktopSessionsReportsNoDrift() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // A CLI-only user: rollouts exist and are declined, but nothing else
        // claims those sessions are Desktop roots. Warning here would fire on
        // every such machine.
        try writeRollout(
            to: sessions.appendingPathComponent("cli.jsonl"),
            threadId: "cli-thread",
            startedAt: now.addingTimeInterval(-30),
            originator: "codex_cli"
        )

        let snapshot = try await snapshot(
            root: root,
            sessions: sessions,
            sqliteCandidates: [],
            now: now
        )

        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertFalse(
            snapshot.health.contains { $0.reason == .formatDrift },
            "Declining a non-desktop rollout is routine, not drift."
        )
    }

    func testRecognizedDesktopRolloutsReportNoDrift() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rollout = sessions.appendingPathComponent("desktop.jsonl")
        try writeRollout(
            to: rollout,
            threadId: "desktop-thread",
            startedAt: now.addingTimeInterval(-30),
            originator: "Codex Desktop"
        )
        // A declined sibling must not poison an otherwise healthy read.
        try writeRollout(
            to: sessions.appendingPathComponent("cli.jsonl"),
            threadId: "cli-thread",
            startedAt: now.addingTimeInterval(-30),
            originator: "codex_cli"
        )

        let database = root.appendingPathComponent("state_1.sqlite")
        try createStateDatabase(at: database, threadId: "desktop-thread", rollout: rollout)

        let snapshot = try await snapshot(
            root: root,
            sessions: sessions,
            sqliteCandidates: [database],
            now: now
        )

        XCTAssertEqual(snapshot.tasks.map(\.threadId), ["desktop-thread"])
        XCTAssertFalse(snapshot.health.contains { $0.reason == .formatDrift })
    }

    func testFormatDriftStaysActionableOnOtherwiseSuppressedAdapters() {
        for adapter in [
            AdapterHealth.Adapter.appServer,
            .pluginJournal,
            .zcodeEntitlementCache,
        ] {
            XCTAssertFalse(
                AdapterHealth.unavailable(adapter, message: "offline").isActionable,
                "An optional source being absent is a normal configuration."
            )
            XCTAssertTrue(
                AdapterHealth.unavailable(
                    adapter,
                    message: "unknown window",
                    reason: .formatDrift
                ).isActionable,
                "It answered, and this build no longer understands it."
            )
        }
    }

    func testDriftHealthDescribesDriftRatherThanUnreadableData() {
        let drift = AdapterHealth.degraded(
            .rolloutJSONL,
            message: "diagnostic",
            reason: .formatDrift
        )
        let unreadable = AdapterHealth.degraded(.rolloutJSONL, message: "diagnostic")

        XCTAssertNotEqual(
            drift.displayMessage(language: .english),
            unreadable.displayMessage(language: .english),
            "Saying data is unreadable when it read fine misdirects the user."
        )
        for language in [AppLanguage.english, .simplifiedChinese] {
            XCTAssertFalse(drift.displayMessage(language: language).isEmpty)
        }
    }

    func testUnexpectedWeeklyWindowIsReportedAsDriftNotAbsence() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observer = CodexAccountRateLimitObserver(
            loader: FixedRateLimitLoader(
                snapshot: RateLimitSnapshot(
                    fiveHour: nil,
                    weekly: RateLimitWindowSnapshot(
                        usedPercent: 30,
                        // A window this build does not model, such as a
                        // monthly allowance replacing the weekly one.
                        windowMinutes: 30 * 24 * 60,
                        resetsAt: now.addingTimeInterval(10 * 24 * 60 * 60)
                    ),
                    updatedAt: now
                )
            ),
            refreshInterval: 0
        )

        _ = await observer.observation(now: now)
        await observer.waitForCurrentRefreshForTesting()
        let observation = await observer.observation(now: now)

        XCTAssertNil(observation.snapshot)
        XCTAssertEqual(observation.health.reason, .formatDrift)
        XCTAssertTrue(
            observation.health.isActionable,
            "Otherwise the quota card just goes blank forever with no reason."
        )
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snapshot(
        root: URL,
        sessions: URL,
        sqliteCandidates: [URL],
        now: Date
    ) async throws -> TaskSnapshot {
        let receipts = ReceiptStore(
            databaseURL: root.appendingPathComponent("receipts.sqlite")
        )
        _ = try await receipts.snapshot(now: now.addingTimeInterval(-60))

        let repository = TaskRepository(
            appServerProbe: AppServerCapabilityProbe(
                controlSocketURL: root.appendingPathComponent("missing.sock")
            ),
            sqliteAdapter: CodexSQLiteTaskAdapter(databaseCandidates: sqliteCandidates),
            rolloutAdapter: CodexRolloutAdapter(
                sessionsDirectory: sessions,
                sessionIndexURL: root.appendingPathComponent("missing-index.jsonl"),
                lookback: 10_000 * 24 * 60 * 60,
                discoveryInterval: 0
            ),
            journalReader: PluginEventJournalReader(
                journalURL: root.appendingPathComponent("missing-events.jsonl")
            ),
            receiptStore: receipts
        )
        return await repository.snapshot(now: now)
    }

    private func writeRollout(
        to url: URL,
        threadId: String,
        startedAt: Date,
        originator: String
    ) throws {
        let lines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": startedAt.ISO8601Format(),
                "payload": [
                    "id": threadId,
                    "session_id": threadId,
                    "originator": originator,
                    "source": "vscode",
                    "cwd": "/tmp/project",
                    "timestamp": startedAt.ISO8601Format(),
                ] as [String: Any],
            ],
            [
                "type": "event_msg",
                "timestamp": startedAt.ISO8601Format(),
                "payload": [
                    "type": "task_started",
                    "turn_id": "turn-\(threadId)",
                    "started_at": startedAt.timeIntervalSince1970,
                ] as [String: Any],
            ],
        ]
        let encoded = try lines
            .map { try JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        try (encoded + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func createStateDatabase(
        at url: URL,
        threadId: String,
        rollout: URL
    ) throws {
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        try connection.execute(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                created_at_ms INTEGER,
                updated_at_ms INTEGER,
                source TEXT NOT NULL,
                thread_source TEXT,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                archived INTEGER NOT NULL
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT PRIMARY KEY NOT NULL,
                status TEXT NOT NULL
            )
            """
        )
        try connection.execute(
            """
            INSERT INTO threads(
                id, rollout_path, created_at, updated_at,
                created_at_ms, updated_at_ms, source, thread_source,
                cwd, title, archived
            ) VALUES (?, ?, 1700000000, 1700000010, 1700000000000, 1700000010000,
                      'vscode', 'user', '/tmp/project', 'Task', 0)
            """,
            bindings: [.text(threadId), .text(rollout.path)]
        )
    }
}

private struct FixedRateLimitLoader: CodexAccountRateLimitLoading {
    let snapshot: RateLimitSnapshot

    func loadRateLimits() async throws -> RateLimitSnapshot { snapshot }
}
