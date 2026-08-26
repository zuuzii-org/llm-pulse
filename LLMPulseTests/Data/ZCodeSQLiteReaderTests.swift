import Foundation
import SQLite3
import XCTest
@testable import LLMPulse

final class ZCodeSQLiteReaderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_787_739_800)

    func testReadsOnlyCurrentGLMRootsAndAggregatesDescendantUsage() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        try tree.createDatabase()

        try tree.insertSession("root", createdAt: base, updatedAt: base.addingTimeInterval(20))
        try tree.insertSelection(
            sessionID: "root",
            providerID: "builtin:bigmodel-coding-plan",
            modelID: "GLM-5.3",
            at: base
        )
        try tree.insertUsage(
            sessionID: "root",
            input: 100,
            output: 20,
            reasoning: 5,
            cacheCreation: 10,
            cacheRead: 70,
            at: base.addingTimeInterval(1),
            requestID: "request-root"
        )

        try tree.insertSession(
            "child",
            parentID: "root",
            taskType: "subagent_child",
            createdAt: base.addingTimeInterval(2),
            updatedAt: base.addingTimeInterval(10)
        )
        try tree.insertUsage(
            sessionID: "child",
            input: 200,
            output: 30,
            cacheRead: 150,
            at: base.addingTimeInterval(3),
            requestID: "request-child"
        )

        try tree.insertSession("other", createdAt: base, updatedAt: base)
        try tree.insertSelection(
            sessionID: "other",
            providerID: "builtin:bigmodel-coding-plan",
            modelID: "NOT-GLM",
            at: base
        )

        let bytesBefore = try Data(contentsOf: tree.paths.databaseURL)
        let result = try ZCodeSQLiteReader(databaseURL: tree.paths.databaseURL).read()

        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(result.records.map(\.sessionID), ["root"])
        XCTAssertEqual(result.driftedRootCount, 0)
        XCTAssertEqual(record.selection.modelID, "GLM-5.3")
        XCTAssertEqual(record.usage.inputTokens, 300)
        XCTAssertEqual(record.usage.outputTokens, 50)
        XCTAssertEqual(record.usage.reasoningTokens, 5)
        XCTAssertEqual(record.usage.cacheCreationInputTokens, 10)
        XCTAssertEqual(record.usage.cacheReadInputTokens, 220)
        XCTAssertEqual(record.usage.requestCount, 2)
        XCTAssertEqual(record.usage.totalTokens, 355)
        XCTAssertEqual(try Data(contentsOf: tree.paths.databaseURL), bytesBefore)
    }

    func testLatestStoredSelectionControlsWhetherARootBelongsToGLM() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        try tree.createDatabase()
        try tree.insertSession("root", createdAt: base, updatedAt: base)
        try tree.insertSelection(
            sessionID: "root",
            providerID: "builtin:bigmodel-coding-plan",
            modelID: "GLM-5.3",
            at: base,
            id: "old"
        )
        try tree.insertSelection(
            sessionID: "root",
            providerID: "builtin:other",
            modelID: "OTHER-1",
            at: base.addingTimeInterval(1),
            id: "new"
        )

        let result = try ZCodeSQLiteReader(databaseURL: tree.paths.databaseURL).read()

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.driftedRootCount, 0)
    }

    func testRootScanIsBoundedBeforePerSessionReads() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        try tree.createDatabase()

        for index in 0..<3 {
            let sessionID = "root-\(index)"
            let date = base.addingTimeInterval(TimeInterval(index))
            try tree.insertSession(sessionID, createdAt: date, updatedAt: date)
            try tree.insertSelection(
                sessionID: sessionID,
                providerID: "builtin:bigmodel-coding-plan",
                modelID: "GLM-5.3",
                at: date
            )
        }

        let result = try ZCodeSQLiteReader(
            databaseURL: tree.paths.databaseURL,
            maximumRootSessionCount: 2
        ).read()

        XCTAssertEqual(result.records.map(\.sessionID), ["root-2", "root-1"])
    }

    func testReadsCommittedRowsFromAnActiveWALDatabase() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let writer = try SQLiteConnection(
            url: tree.paths.databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        try writer.withStatement("PRAGMA journal_mode = WAL") { statement in
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        }
        try writer.withStatement("PRAGMA wal_autocheckpoint = 0") { statement in
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        }
        try ZCodeTestTree.createSchema(in: writer)
        try writer.execute(
            """
            INSERT INTO session VALUES (?, NULL, 'Task', '/tmp/project',
                                        'interactive', ?, ?)
            """,
            bindings: [
                .text("root"),
                .integer(ZCodeTestTree.milliseconds(base)),
                .integer(ZCodeTestTree.milliseconds(base)),
            ]
        )
        try writer.execute(
            """
            INSERT INTO session_entry VALUES(
                'selection', 'root', 'runtime/model_selection', ?, ?,
                '{"providerId":"builtin:bigmodel-coding-plan","modelId":"GLM-5.3"}'
            )
            """,
            bindings: [
                .integer(ZCodeTestTree.milliseconds(base)),
                .integer(ZCodeTestTree.milliseconds(base)),
            ]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.paths.databaseURL.path + "-wal"))
        XCTAssertEqual(
            try ZCodeSQLiteReader(databaseURL: tree.paths.databaseURL).read()
                .records.map(\.sessionID),
            ["root"]
        )
        _ = writer
    }

    func testRejectsSchemaDriftWithoutMigratingTheDatabase() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        let connection = try SQLiteConnection(
            url: tree.paths.databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        try connection.execute("CREATE TABLE session(id TEXT PRIMARY KEY)")
        let bytesBefore = try Data(contentsOf: tree.paths.databaseURL)

        XCTAssertThrowsError(
            try ZCodeSQLiteReader(databaseURL: tree.paths.databaseURL).read()
        )
        XCTAssertEqual(try Data(contentsOf: tree.paths.databaseURL), bytesBefore)
    }
}
