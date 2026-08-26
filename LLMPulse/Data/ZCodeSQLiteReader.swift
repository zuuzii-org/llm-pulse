import Foundation
import SQLite3

/// Reads ZCode's normalized session and usage ledger without touching message,
/// part, model-I/O, or credential payloads.
struct ZCodeSQLiteReader: Sendable {
    private enum SelectionRead {
        case absent
        case malformed
        case value(ZCodeModelSelection)
    }

    private struct SelectionPayload: Decodable {
        let providerId: String
        let modelId: String
        let thoughtLevel: String?
    }

    let databaseURL: URL
    private let maximumRootSessionCount: Int

    init(databaseURL: URL, maximumRootSessionCount: Int = 500) {
        self.databaseURL = databaseURL
        self.maximumRootSessionCount = min(max(1, maximumRootSessionCount), 500)
    }

    func read() throws -> ZCodeSQLiteReadResult {
        try validateSourceFile(databaseURL)
        let connection = try SQLiteConnection(
            url: databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        )
        try connection.execute("PRAGMA query_only = ON")
        try validateSchema(connection)

        var records: [ZCodeSessionRecord] = []
        var driftedRootCount = 0
        try connection.withStatement(
            """
            SELECT id, title, directory, time_created, time_updated
            FROM session
            WHERE parent_id IS NULL AND task_type = 'interactive'
            ORDER BY time_updated DESC, id ASC
            LIMIT ?
            """,
            bindings: [.integer(Int64(maximumRootSessionCount))]
        ) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw DataAdapterError.sqlite("Unable to read ZCode sessions")
                }
                guard let sessionID = connection.string(at: 0, in: statement),
                      let createdMilliseconds = connection.int64(at: 3, in: statement),
                      let updatedMilliseconds = connection.int64(at: 4, in: statement),
                      let createdAt = Self.date(milliseconds: createdMilliseconds),
                      let updatedAt = Self.date(milliseconds: updatedMilliseconds)
                else {
                    driftedRootCount += 1
                    continue
                }

                let storedSelection = try latestStoredSelection(
                    sessionID: sessionID,
                    connection: connection
                )
                let selection: ZCodeModelSelection?
                switch storedSelection {
                case let .value(value):
                    selection = value
                case .malformed:
                    driftedRootCount += 1
                    selection = try latestUsageSelection(
                        sessionID: sessionID,
                        connection: connection
                    )
                case .absent:
                    selection = try latestUsageSelection(
                        sessionID: sessionID,
                        connection: connection
                    )
                    if selection == nil {
                        driftedRootCount += 1
                    }
                }

                guard let selection, selection.isGLM else { continue }
                let usage = try usageTotals(
                    rootSessionID: sessionID,
                    connection: connection
                )
                records.append(ZCodeSessionRecord(
                    sessionID: sessionID,
                    title: connection.string(at: 1, in: statement) ?? "",
                    projectDirectory: connection.string(at: 2, in: statement) ?? "",
                    createdAt: createdAt,
                    updatedAt: max(updatedAt, usage.latestUsageAt ?? .distantPast),
                    selection: selection,
                    usage: usage
                ))
            }
        }

        return ZCodeSQLiteReadResult(
            records: records,
            driftedRootCount: driftedRootCount
        )
    }

    private func latestStoredSelection(
        sessionID: String,
        connection: SQLiteConnection
    ) throws -> SelectionRead {
        try connection.withStatement(
            """
            SELECT data
            FROM session_entry
            WHERE session_id = ? AND type = 'runtime/model_selection'
            ORDER BY time_updated DESC, time_created DESC, id DESC
            LIMIT 1
            """,
            bindings: [.text(sessionID)]
        ) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return .absent }
            guard result == SQLITE_ROW else {
                throw DataAdapterError.sqlite("Unable to read ZCode model selection")
            }
            guard let raw = connection.string(at: 0, in: statement),
                  let payload = try? JSONDecoder().decode(
                      SelectionPayload.self,
                      from: Data(raw.utf8)
                  ),
                  !payload.providerId.isEmpty,
                  !payload.modelId.isEmpty
            else {
                return .malformed
            }
            return .value(ZCodeModelSelection(
                providerID: payload.providerId,
                modelID: payload.modelId,
                thoughtLevel: payload.thoughtLevel
            ))
        }
    }

    private func latestUsageSelection(
        sessionID: String,
        connection: SQLiteConnection
    ) throws -> ZCodeModelSelection? {
        try connection.withStatement(
            """
            SELECT provider_id, model_id, variant
            FROM model_usage
            WHERE session_id = ?
            ORDER BY started_at DESC, id DESC
            LIMIT 1
            """,
            bindings: [.text(sessionID)]
        ) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw DataAdapterError.sqlite("Unable to read ZCode usage selection")
            }
            guard let providerID = connection.string(at: 0, in: statement),
                  let modelID = connection.string(at: 1, in: statement),
                  !providerID.isEmpty,
                  !modelID.isEmpty
            else {
                return nil
            }
            return ZCodeModelSelection(
                providerID: providerID,
                modelID: modelID,
                thoughtLevel: connection.string(at: 2, in: statement)
            )
        }
    }

    private func usageTotals(
        rootSessionID: String,
        connection: SQLiteConnection
    ) throws -> ZCodeUsageTotals {
        try connection.withStatement(
            """
            WITH RECURSIVE descendants(id) AS (
                SELECT id FROM session WHERE id = ?
                UNION
                SELECT child.id
                FROM session AS child
                JOIN descendants AS parent ON child.parent_id = parent.id
            )
            SELECT
                COUNT(DISTINCT usage.logical_request_id),
                COALESCE(SUM(usage.input_tokens), 0),
                COALESCE(SUM(usage.output_tokens), 0),
                COALESCE(SUM(usage.reasoning_tokens), 0),
                COALESCE(SUM(usage.cache_creation_input_tokens), 0),
                COALESCE(SUM(usage.cache_read_input_tokens), 0),
                COALESCE(SUM(usage.computed_total_tokens), 0),
                MAX(COALESCE(usage.completed_at, usage.started_at))
            FROM model_usage AS usage
            JOIN descendants ON descendants.id = usage.session_id
            WHERE (
                usage.provider_id = 'builtin:bigmodel'
                OR usage.provider_id LIKE 'builtin:bigmodel-%'
                OR usage.provider_id = 'builtin:zai'
                OR usage.provider_id LIKE 'builtin:zai-%'
            ) AND UPPER(usage.model_id) LIKE 'GLM%'
            """,
            bindings: [.text(rootSessionID)]
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DataAdapterError.sqlite("Unable to aggregate ZCode usage")
            }
            guard let requestCount = Self.nonnegativeInt(connection.int64(at: 0, in: statement)),
                  let input = Self.nonnegativeInt(connection.int64(at: 1, in: statement)),
                  let output = Self.nonnegativeInt(connection.int64(at: 2, in: statement)),
                  let reasoning = Self.nonnegativeInt(connection.int64(at: 3, in: statement)),
                  let cacheCreation = Self.nonnegativeInt(
                      connection.int64(at: 4, in: statement)
                  ),
                  let cacheRead = Self.nonnegativeInt(connection.int64(at: 5, in: statement)),
                  let recordedTotal = Self.nonnegativeInt(
                      connection.int64(at: 6, in: statement)
                  )
            else {
                throw DataAdapterError.invalidFormat(
                    databaseURL,
                    "usage counters are missing, negative, or too large"
                )
            }
            let totals = ZCodeUsageTotals(
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: reasoning,
                cacheCreationInputTokens: cacheCreation,
                cacheReadInputTokens: cacheRead,
                requestCount: requestCount,
                latestUsageAt: connection.int64(at: 7, in: statement).flatMap(Self.date)
            )
            guard totals.totalTokens == recordedTotal,
                  cacheRead <= input,
                  cacheCreation <= input
            else {
                throw DataAdapterError.invalidFormat(
                    databaseURL,
                    "usage counter semantics changed"
                )
            }
            return totals
        }
    }

    private func validateSchema(_ connection: SQLiteConnection) throws {
        let required: [String: Set<String>] = [
            "session": [
                "id", "parent_id", "title", "directory", "task_type",
                "time_created", "time_updated",
            ],
            "session_entry": [
                "id", "session_id", "type", "time_created", "time_updated", "data",
            ],
            "model_usage": [
                "id", "logical_request_id", "session_id", "provider_id", "model_id",
                "variant", "started_at", "completed_at", "input_tokens", "output_tokens",
                "reasoning_tokens", "cache_creation_input_tokens",
                "cache_read_input_tokens", "computed_total_tokens",
            ],
        ]
        let tables = try tableNames(in: connection)
        for (table, columns) in required {
            guard tables.contains(table) else {
                throw DataAdapterError.invalidFormat(
                    databaseURL,
                    "missing required table \(table)"
                )
            }
            let actual = try columnNames(in: table, connection: connection)
            guard columns.isSubset(of: actual) else {
                throw DataAdapterError.invalidFormat(
                    databaseURL,
                    "required columns changed in \(table)"
                )
            }
        }
    }

    private func tableNames(in connection: SQLiteConnection) throws -> Set<String> {
        var names: Set<String> = []
        try connection.withStatement(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw DataAdapterError.sqlite("Unable to inspect ZCode tables")
                }
                if let name = connection.string(at: 0, in: statement) {
                    names.insert(name)
                }
            }
        }
        return names
    }

    private func columnNames(
        in table: String,
        connection: SQLiteConnection
    ) throws -> Set<String> {
        var names: Set<String> = []
        try connection.withStatement("PRAGMA table_info(\(table))") { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw DataAdapterError.sqlite("Unable to inspect ZCode columns")
                }
                if let name = connection.string(at: 1, in: statement) {
                    names.insert(name)
                }
            }
        }
        return names
    }

    private func validateSourceFile(_ url: URL) throws {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw DataAdapterError.missingFile(url)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            throw DataAdapterError.invalidFormat(
                url,
                "source type, owner, links, or permissions are unsafe"
            )
        }
    }

    private static func nonnegativeInt(_ value: Int64?) -> Int? {
        guard let value, value >= 0, value <= Int64(Int.max) else { return nil }
        return Int(value)
    }

    private static func date(milliseconds: Int64) -> Date? {
        guard milliseconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
