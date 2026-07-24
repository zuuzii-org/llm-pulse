import Foundation
import SQLite3

struct CodexSQLiteTaskAdapter: Sendable {
    private let configuredDatabaseCandidates: [URL]?
    private let codexHome: URL?
    private let metadataReader: RolloutMetadataReader

    init(
        databaseCandidates: [URL],
        metadataReader: RolloutMetadataReader = RolloutMetadataReader()
    ) {
        configuredDatabaseCandidates = databaseCandidates
        codexHome = nil
        self.metadataReader = metadataReader
    }

    init(
        codexHome: URL,
        metadataReader: RolloutMetadataReader = RolloutMetadataReader()
    ) {
        configuredDatabaseCandidates = nil
        self.codexHome = codexHome
        self.metadataReader = metadataReader
    }

    func loadDesktopRootThreads() throws -> SQLiteTaskReadResult {
        let databaseCandidates: [URL]
        if let codexHome {
            databaseCandidates = CodexPaths.discoverStateDatabases(in: codexHome)
        } else {
            databaseCandidates = configuredDatabaseCandidates ?? []
        }
        guard !databaseCandidates.isEmpty else {
            throw DataAdapterError.sqlite("No state_*.sqlite database was found")
        }

        var lastError: Error?
        for databaseURL in databaseCandidates {
            do {
                return try loadDesktopRootThreads(from: databaseURL)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? DataAdapterError.sqlite("No compatible state database was found")
    }

    private func loadDesktopRootThreads(from databaseURL: URL) throws -> SQLiteTaskReadResult {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw DataAdapterError.missingFile(databaseURL)
        }

        let connection = try SQLiteConnection(
            url: databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        )
        try connection.execute("PRAGMA query_only = ON")

        let tables = try tableNames(in: connection)
        guard tables.contains("threads") else {
            throw DataAdapterError.sqlite("The selected state database has no threads table")
        }

        let columns = try columnNames(in: "threads", connection: connection)
        let requiredColumns: Set<String> = [
            "id", "rollout_path", "created_at", "updated_at", "source", "cwd", "title", "archived",
        ]
        let missingColumns = requiredColumns.subtracting(columns)
        guard missingColumns.isEmpty else {
            throw DataAdapterError.sqlite(
                "Unsupported threads schema; missing: \(missingColumns.sorted().joined(separator: ", "))"
            )
        }

        let createdAtExpression = columns.contains("created_at_ms")
            ? "COALESCE(t.created_at_ms, t.created_at * 1000)"
            : "t.created_at * 1000"
        let updatedAtExpression = columns.contains("updated_at_ms")
            ? "COALESCE(t.updated_at_ms, t.updated_at * 1000)"
            : "t.updated_at * 1000"
        let threadSourcePredicate = columns.contains("thread_source")
            ? "AND COALESCE(t.thread_source, 'user') = 'user'"
            : ""
        let rootPredicate = tables.contains("thread_spawn_edges")
            ? "AND NOT EXISTS (SELECT 1 FROM thread_spawn_edges e WHERE e.child_thread_id = t.id)"
            : ""
        let tokensUsedExpression = columns.contains("tokens_used")
            ? "t.tokens_used"
            : "NULL"

        let sql = """
            SELECT
                t.id,
                t.rollout_path,
                t.title,
                t.cwd,
                \(createdAtExpression) AS created_at_ms,
                \(updatedAtExpression) AS updated_at_ms,
                \(tokensUsedExpression) AS tokens_used
            FROM threads t
            WHERE t.archived = 0
              AND t.source = 'vscode'
              \(threadSourcePredicate)
              \(rootPredicate)
            ORDER BY updated_at_ms DESC
            LIMIT 500
            """

        var records: [CodexThreadRecord] = []
        var unverifiedCandidateCount = 0
        var declinedCandidateCount = 0

        try connection.withStatement(sql) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw DataAdapterError.sqlite("Failed while reading threads")
                }

                guard
                    let threadId = connection.string(at: 0, in: statement),
                    let rolloutPath = connection.string(at: 1, in: statement)
                else {
                    unverifiedCandidateCount += 1
                    continue
                }

                let rolloutURL = URL(fileURLWithPath: rolloutPath)
                let verifiedMetadata: RolloutMetadata?
                // A `nil` return means the rollout was read and parsed, and
                // the desktop root filter declined it anyway. A throw means
                // it could not be read at all. Only the former contradicts
                // the SQL predicate that selected this row.
                var wasDeclinedByFilter = false
                do {
                    verifiedMetadata = try metadataReader.readDesktopRoot(from: rolloutURL)
                    wasDeclinedByFilter = verifiedMetadata == nil
                } catch {
                    verifiedMetadata = nil
                }

                guard let verifiedMetadata, verifiedMetadata.threadId == threadId else {
                    unverifiedCandidateCount += 1
                    if wasDeclinedByFilter {
                        declinedCandidateCount += 1
                    }
                    continue
                }

                let createdMilliseconds = connection.int64(at: 4, in: statement) ?? 0
                let updatedMilliseconds = connection.int64(at: 5, in: statement) ?? createdMilliseconds
                let tokenUsage: TokenUsageSnapshot?
                if let value = connection.int64(at: 6, in: statement),
                   value >= 0,
                   let totalTokens = Int(exactly: value)
                {
                    tokenUsage = TokenUsageSnapshot(totalTokens: totalTokens)
                } else {
                    tokenUsage = nil
                }
                records.append(CodexThreadRecord(
                    threadId: threadId,
                    rolloutURL: rolloutURL,
                    title: connection.string(at: 2, in: statement) ?? "",
                    projectDirectory: connection.string(at: 3, in: statement)
                        ?? verifiedMetadata.projectDirectory,
                    createdAt: Date(timeIntervalSince1970: Double(createdMilliseconds) / 1_000),
                    updatedAt: Date(timeIntervalSince1970: Double(updatedMilliseconds) / 1_000),
                    tokenUsage: tokenUsage
                ))
            }
        }

        return SQLiteTaskReadResult(
            records: records,
            unverifiedCandidateCount: unverifiedCandidateCount,
            declinedCandidateCount: declinedCandidateCount
        )
    }

    private func tableNames(in connection: SQLiteConnection) throws -> Set<String> {
        var names: Set<String> = []
        try connection.withStatement(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
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
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = connection.string(at: 1, in: statement) {
                    names.insert(name)
                }
            }
        }
        return names
    }
}
