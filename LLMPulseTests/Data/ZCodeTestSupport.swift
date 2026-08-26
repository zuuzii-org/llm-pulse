import Foundation
import SQLite3
@testable import LLMPulse

struct ZCodeTestTree {
    let root: URL
    let paths: ZCodePaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = ZCodePaths(zcodeHome: root)
        try FileManager.default.createDirectory(
            at: paths.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.eventLogDirectory,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func createDatabase() throws -> SQLiteConnection {
        let connection = try SQLiteConnection(
            url: paths.databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        try Self.createSchema(in: connection)
        return connection
    }

    static func createSchema(in connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                parent_id TEXT,
                title TEXT NOT NULL,
                directory TEXT NOT NULL,
                task_type TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE session_entry (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                type TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY,
                logical_request_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                variant TEXT,
                started_at INTEGER NOT NULL,
                completed_at INTEGER,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER NOT NULL,
                cache_creation_input_tokens INTEGER NOT NULL,
                cache_read_input_tokens INTEGER NOT NULL,
                computed_total_tokens INTEGER NOT NULL
            )
            """
        )
    }

    func insertSession(
        _ id: String,
        parentID: String? = nil,
        title: String = "GLM task",
        directory: String = "/tmp/glm-project",
        taskType: String = "interactive",
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let connection = try SQLiteConnection(
            url: paths.databaseURL,
            flags: SQLITE_OPEN_READWRITE
        )
        try connection.execute(
            """
            INSERT INTO session(
                id, parent_id, title, directory, task_type, time_created, time_updated
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(id),
                parentID.map(SQLiteValue.text) ?? .null,
                .text(title),
                .text(directory),
                .text(taskType),
                .integer(Self.milliseconds(createdAt)),
                .integer(Self.milliseconds(updatedAt)),
            ]
        )
    }

    func insertSelection(
        sessionID: String,
        providerID: String,
        modelID: String,
        thoughtLevel: String? = "max",
        at date: Date,
        id: String = UUID().uuidString
    ) throws {
        var payload: [String: Any] = [
            "providerId": providerID,
            "modelId": modelID,
        ]
        payload["thoughtLevel"] = thoughtLevel
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let connection = try SQLiteConnection(
            url: paths.databaseURL,
            flags: SQLITE_OPEN_READWRITE
        )
        try connection.execute(
            """
            INSERT INTO session_entry(
                id, session_id, type, time_created, time_updated, data
            ) VALUES (?, ?, 'runtime/model_selection', ?, ?, ?)
            """,
            bindings: [
                .text(id),
                .text(sessionID),
                .integer(Self.milliseconds(date)),
                .integer(Self.milliseconds(date)),
                .text(String(decoding: data, as: UTF8.self)),
            ]
        )
    }

    func insertUsage(
        sessionID: String,
        providerID: String = "builtin:bigmodel-coding-plan",
        modelID: String = "GLM-5.3",
        input: Int,
        output: Int,
        reasoning: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        at date: Date,
        requestID: String = UUID().uuidString
    ) throws {
        let connection = try SQLiteConnection(
            url: paths.databaseURL,
            flags: SQLITE_OPEN_READWRITE
        )
        try connection.execute(
            """
            INSERT INTO model_usage(
                id, logical_request_id, session_id, provider_id, model_id, variant,
                started_at, completed_at, input_tokens, output_tokens, reasoning_tokens,
                cache_creation_input_tokens, cache_read_input_tokens, computed_total_tokens
            ) VALUES (?, ?, ?, ?, ?, 'max', ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(UUID().uuidString),
                .text(requestID),
                .text(sessionID),
                .text(providerID),
                .text(modelID),
                .integer(Self.milliseconds(date)),
                .integer(Self.milliseconds(date.addingTimeInterval(1))),
                .integer(Int64(input)),
                .integer(Int64(output)),
                .integer(Int64(reasoning)),
                .integer(Int64(cacheCreation)),
                .integer(Int64(cacheRead)),
                .integer(Int64(input + output + reasoning)),
            ]
        )
    }

    @discardableResult
    func writeEvents(
        _ objects: [[String: Any]],
        filename: String = "zcode-2026-08-26.jsonl",
        trailingNewline: Bool = true
    ) throws -> URL {
        let url = paths.eventLogDirectory.appendingPathComponent(filename)
        var data = Data()
        for object in objects {
            data.append(try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ))
            data.append(0x0A)
        }
        if !trailingNewline, !data.isEmpty {
            data.removeLast()
        }
        try data.write(to: url)
        return url
    }

    static func event(
        _ event: String,
        sessionID: String? = "root",
        turnID: String? = "turn-1",
        at date: Date,
        status: String? = nil,
        toolCallID: String? = nil,
        agentID: String? = nil,
        decision: String? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: date),
            "event": event,
        ]
        object["sessionId"] = sessionID
        object["turnId"] = turnID
        object["status"] = status
        object["toolCallId"] = toolCallID
        var context: [String: Any] = [:]
        if let agentID {
            context["agentId"] = agentID
        }
        if let decision {
            context["decision"] = decision
        }
        if !context.isEmpty {
            object["context"] = context
        }
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
