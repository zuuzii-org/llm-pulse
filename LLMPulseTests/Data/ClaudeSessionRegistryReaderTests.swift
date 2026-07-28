import Foundation
import XCTest
@testable import LLMPulse

/// Cover for the liveness gate.
///
/// A session exists exactly while its process does. Process ids are recycled
/// within minutes on a busy machine, and the app leaves registry files behind
/// when it is killed, so "the file is there" is never enough on its own.
final class ClaudeSessionRegistryReaderTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_784_918_060)

    func testALiveInteractiveSessionIsReported() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(pid: 4_242, to: directory)

        let result = try reader(directory, probe: FakeProbe(facts: [
            4_242: facts(startedAt: startedAt),
        ])).read()

        XCTAssertEqual(result.entries.map(\.sessionID), [Self.sessionID])
        XCTAssertEqual(result.entries.first?.workingDirectory, "/tmp/project")
        XCTAssertTrue(result.entries.first?.isDesktopEntrypoint == true)
        XCTAssertEqual(result.unreadableFileCount, 0)
    }

    func testASessionWhoseProcessExitedIsDropped() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(pid: 4_242, to: directory)

        let result = try reader(directory, probe: FakeProbe(facts: [:])).read()

        XCTAssertTrue(
            result.entries.isEmpty,
            "The file outlives the process; only the process proves the session."
        )
    }

    func testARecycledProcessIDIsRejectedByItsStartTime() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(pid: 4_242, to: directory)

        // Same pid, but this process began long after the session did.
        let result = try reader(directory, probe: FakeProbe(facts: [
            4_242: facts(startedAt: startedAt.addingTimeInterval(9_000)),
        ])).read()

        XCTAssertTrue(result.entries.isEmpty)
    }

    func testAProcessRunningSomethingElseIsRejected() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(pid: 4_242, to: directory)

        // A launcher that merely passes the Claude path as an argument looks
        // identical in a command line; the executable path does not.
        let result = try reader(directory, probe: FakeProbe(facts: [
            4_242: ClaudeProcessFacts(
                startedAt: Int(startedAt.timeIntervalSince1970),
                isZombie: false,
                executablePath: "/usr/bin/disclaimer"
            ),
        ])).read()

        XCTAssertTrue(result.entries.isEmpty)
    }

    func testANonInteractiveSessionIsIgnored() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(pid: 4_242, to: directory, kind: "background")

        let result = try reader(directory, probe: FakeProbe(facts: [
            4_242: facts(startedAt: startedAt),
        ])).read()

        XCTAssertTrue(result.entries.isEmpty)
    }

    func testAFileWhoseNameDisagreesWithItsContentsIsIgnored() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Named for one pid, describing another — the pid cannot be trusted.
        try write(pid: 9_999, to: directory, filenameProcessID: 4_242)

        let result = try reader(directory, probe: FakeProbe(facts: [
            4_242: facts(startedAt: startedAt),
            9_999: facts(startedAt: startedAt),
        ])).read()

        XCTAssertTrue(result.entries.isEmpty)
    }

    func testATornReadIsReportedRatherThanTreatedAsAnEndedSession() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The app rewrites these in place, so a read can catch one empty.
        try Data("{".utf8).write(to: directory.appendingPathComponent("4242.json"))

        let result = try reader(directory, probe: FakeProbe(facts: [
            4_242: facts(startedAt: startedAt),
        ])).read()

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(
            result.unreadableFileCount,
            1,
            "Silence here would make live rows blink out at random."
        )
    }

    func testFilesThatAreNotProcessRegistryEntriesAreSkipped() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("notes.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("4242.txt"))

        let result = try reader(directory, probe: FakeProbe(facts: [:])).read()

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.unreadableFileCount, 0)
    }

    func testAMissingDirectoryThrowsRatherThanReportingNoSessions() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(
            try reader(missing, probe: FakeProbe(facts: [:])).read(),
            "An unreadable source is not the same as an idle machine."
        )
    }

    // MARK: - Fixtures

    private static let sessionID = "86343497-3a6c-4bc3-84ba-3383c8b5696a"

    private func reader(
        _ directory: URL,
        probe: FakeProbe
    ) -> ClaudeSessionRegistryReader {
        ClaudeSessionRegistryReader(sessionsDirectory: directory, probe: probe)
    }

    private func facts(startedAt: Date) -> ClaudeProcessFacts {
        ClaudeProcessFacts(
            startedAt: Int(startedAt.timeIntervalSince1970),
            isZombie: false,
            executablePath: "/Users/x/Library/Application Support/Claude"
                + "/claude-code/2.1.219/claude.app/Contents/MacOS/claude"
        )
    }

    private func makeSessionsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session is created after its process starts, and how long that takes
    /// varies with load. A symmetric window treated a slow start as pid reuse
    /// and dropped a live session, which then rendered as a finished task with
    /// no project and no working deep link.
    func testASessionRecordedAfterItsProcessStartedIsKept() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(pid: 4444, to: directory, sessionStartOffset: 9)

        let result = try ClaudeSessionRegistryReader(
            sessionsDirectory: directory,
            probe: FakeProbe(facts: [4444: facts(startedAt: startedAt)])
        ).read()

        XCTAssertEqual(result.entries.map { $0.processID }, [4444])
    }

    /// The genuine reuse signature: the file was written by a process that
    /// started earlier than the one now holding the pid.
    func testASessionRecordedBeforeItsProcessStartedIsRejected() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(pid: 4444, to: directory, sessionStartOffset: -600)

        let result = try ClaudeSessionRegistryReader(
            sessionsDirectory: directory,
            probe: FakeProbe(facts: [4444: facts(startedAt: startedAt)])
        ).read()

        XCTAssertTrue(result.entries.isEmpty)
    }

    func testADerivedNameIsReportedAsSuch() throws {
        let directory = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(pid: 4444, to: directory)

        let entry = try XCTUnwrap(ClaudeSessionRegistryReader(
            sessionsDirectory: directory,
            probe: FakeProbe(facts: [4444: facts(startedAt: startedAt)])
        ).read().entries.first)

        XCTAssertTrue(
            entry.hasDerivedName,
            "A slug must lose to the title the transcript carries."
        )
    }

    private func write(
        pid: Int,
        to directory: URL,
        kind: String = "interactive",
        filenameProcessID: Int? = nil,
        sessionStartOffset: TimeInterval = 0
    ) throws {
        let payload: [String: Any] = [
            "pid": pid,
            "sessionId": Self.sessionID,
            "cwd": "/tmp/project",
            "startedAt": startedAt.addingTimeInterval(sessionStartOffset)
                .timeIntervalSince1970 * 1_000,
            "version": "2.1.219",
            "kind": kind,
            "entrypoint": "claude-desktop",
            "name": "project-3f",
            "nameSource": "derived",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(
            to: directory.appendingPathComponent("\(filenameProcessID ?? pid).json")
        )
    }
}

private struct FakeProbe: ClaudeProcessProbing {
    let facts: [Int32: ClaudeProcessFacts]

    func facts(forProcessID processID: Int32) -> ClaudeProcessFacts? {
        facts[processID]
    }
}
