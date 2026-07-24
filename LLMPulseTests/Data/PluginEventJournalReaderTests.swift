import Foundation
import XCTest
@testable import LLMPulse

final class PluginEventJournalReaderTests: XCTestCase {
    func testPermissionWaitsAndPostToolUseClearsWaiting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("events.jsonl")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try write([
            journalEvent("UserPromptSubmit", timestamp: base),
            journalEvent("PermissionRequest", timestamp: base.addingTimeInterval(1)),
        ], to: journalURL)
        let reader = PluginEventJournalReader(journalURL: journalURL)
        var result = try await reader.load(now: base.addingTimeInterval(1))
        XCTAssertEqual(result.records.first?.status.state, .waitingForApproval)

        try write([
            journalEvent("UserPromptSubmit", timestamp: base),
            journalEvent("PermissionRequest", timestamp: base.addingTimeInterval(1)),
            journalEvent("PostToolUse", timestamp: base.addingTimeInterval(2)),
        ], to: journalURL)
        result = try await reader.load(now: base.addingTimeInterval(2))
        XCTAssertEqual(result.records.first?.status.state, .running)
    }

    func testStopRemainsFinalizingUntilRolloutConfirmsTerminal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("events.jsonl")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try write([
            journalEvent("UserPromptSubmit", timestamp: base),
            journalEvent("Stop", timestamp: base.addingTimeInterval(5)),
        ], to: journalURL)

        let result = try await PluginEventJournalReader(journalURL: journalURL)
            .load(now: base.addingTimeInterval(5))
        XCTAssertEqual(result.records.first?.status.state, .running)
        XCTAssertEqual(result.records.first?.status.lastStatus, "finalizing")
        XCTAssertNil(result.records.first?.status.completedAt)
    }

    func testOldJournalStateDoesNotCreatePhantomRunningTask() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("events.jsonl")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try write([journalEvent("UserPromptSubmit", timestamp: base)], to: journalURL)

        let result = try await PluginEventJournalReader(
            journalURL: journalURL,
            maximumEventAge: 60
        ).load(now: base.addingTimeInterval(61))
        XCTAssertTrue(result.records.isEmpty)
    }

    /// The reader must not adopt fields the plugin cannot write.
    ///
    /// `Plugin/hooks/record_event.js` composes every record from a closed
    /// whitelist, so a journal can never carry a project path. Reading one
    /// anyway would make the privacy notice true only by accident — and a
    /// journal planted by anything else would be trusted for it.
    func testJournalFieldsOutsideThePluginWhitelistAreIgnored() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("events.jsonl")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var event = journalEvent("UserPromptSubmit", timestamp: base)
        event["cwd"] = "/tmp/should-not-be-read"
        try write([event], to: journalURL)

        let result = try await PluginEventJournalReader(journalURL: journalURL)
            .load(now: base.addingTimeInterval(1))

        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.threadId, "thread-1")
        XCTAssertEqual(
            record.projectDirectory,
            "",
            "A project path must come from Codex's own records, never the journal."
        )
    }

    private func journalEvent(_ name: String, timestamp: Date) -> [String: Any] {
        [
            "session_id": "thread-1",
            "turn_id": "turn-1",
            "hook_event_name": name,
            "timestamp": timestamp.ISO8601Format(),
        ]
    }

    private func write(_ events: [[String: Any]], to url: URL) throws {
        let data = try events.reduce(into: Data()) { result, event in
            result.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            result.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
