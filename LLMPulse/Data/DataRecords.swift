import Foundation

struct CodexThreadRecord: Equatable, Sendable {
    let threadId: String
    let rolloutURL: URL
    let title: String
    let projectDirectory: String
    let createdAt: Date
    let updatedAt: Date
    let tokenUsage: TokenUsageSnapshot?
}

struct RolloutMetadata: Equatable, Sendable {
    let threadId: String
    let rolloutURL: URL
    let projectDirectory: String
    let createdAt: Date
}

struct TaskStatusRecord: Equatable, Sendable {
    let threadId: String
    let turnId: String?
    let state: PulseTaskState
    let startedAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let lastStatus: String
    let pendingInputCallIDs: Set<String>
    let lastErrorAt: Date?
    let latestActivityAt: Date?
    let isFreshActivityFallback: Bool
    let failedFromError: Bool
    let tokenUsage: TokenUsageSnapshot?
    let rateLimits: RateLimitSnapshot?

    init(
        threadId: String,
        turnId: String?,
        state: PulseTaskState,
        startedAt: Date,
        updatedAt: Date,
        completedAt: Date?,
        lastStatus: String,
        pendingInputCallIDs: Set<String> = [],
        lastErrorAt: Date? = nil,
        latestActivityAt: Date? = nil,
        isFreshActivityFallback: Bool = false,
        failedFromError: Bool = false,
        tokenUsage: TokenUsageSnapshot? = nil,
        rateLimits: RateLimitSnapshot? = nil
    ) {
        self.threadId = threadId
        self.turnId = turnId
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastStatus = lastStatus
        self.pendingInputCallIDs = pendingInputCallIDs
        self.lastErrorAt = lastErrorAt
        self.latestActivityAt = latestActivityAt
        self.isFreshActivityFallback = isFreshActivityFallback
        self.failedFromError = failedFromError
        self.tokenUsage = tokenUsage
        self.rateLimits = rateLimits
    }

    func isStaleRunning(at now: Date, cutoff: TimeInterval) -> Bool {
        guard state == .running else { return false }
        let activityAt = latestActivityAt ?? updatedAt
        return now.timeIntervalSince(activityAt) > cutoff
    }
}

struct RolloutTaskRecord: Equatable, Sendable {
    let metadata: RolloutMetadata
    let title: String?
    let status: TaskStatusRecord
}

struct SQLiteTaskReadResult: Sendable {
    let records: [CodexThreadRecord]
    let unverifiedCandidateCount: Int

    /// Candidates whose rollout was read and parsed successfully, and which
    /// the Codex Desktop root filter nevertheless declined.
    ///
    /// This is narrower than `unverifiedCandidateCount`, which also covers
    /// rollouts that are missing or unreadable. Only the declined ones carry
    /// a contradiction: the SQL predicate already established the row is a
    /// `vscode` desktop thread, so the two criteria disagree.
    let declinedCandidateCount: Int

    init(
        records: [CodexThreadRecord],
        unverifiedCandidateCount: Int,
        declinedCandidateCount: Int = 0
    ) {
        self.records = records
        self.unverifiedCandidateCount = unverifiedCandidateCount
        self.declinedCandidateCount = declinedCandidateCount
    }
}

struct RolloutTaskReadResult: Sendable {
    let records: [RolloutTaskRecord]
    let invalidFileCount: Int
    let sessionIndexAvailable: Bool
}

struct JournalTaskRecord: Equatable, Sendable {
    let threadId: String
    let projectDirectory: String
    let status: TaskStatusRecord
}

struct PluginJournalReadResult: Sendable {
    let records: [JournalTaskRecord]
    let invalidLineCount: Int
}

struct ReceiptSnapshot: Sendable {
    let baselineAt: Date
    let viewedTaskIDs: Set<String>
}

enum DataAdapterError: Error, LocalizedError, Sendable {
    case missingFile(URL)
    case invalidFormat(URL, String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            return "Missing file: \(url.lastPathComponent)"
        case let .invalidFormat(url, reason):
            return "Invalid \(url.lastPathComponent): \(reason)"
        case let .sqlite(message):
            return "SQLite: \(message)"
        }
    }
}
