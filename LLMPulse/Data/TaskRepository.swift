import Foundation

protocol ReceiptRepositoryProtocol: Sendable {
    func receiptSnapshot(now: Date) async throws -> ReceiptSnapshot
    func markViewed(_ task: PulseTask, at date: Date) async throws
    func markViewed(_ tasks: [PulseTask], at date: Date) async throws
    func unmarkViewed(_ task: PulseTask) async throws
    func unmarkViewed(_ tasks: [PulseTask]) async throws
}

protocol TaskRepositoryProtocol: ReceiptRepositoryProtocol {
    func snapshot(now: Date) async -> TaskSnapshot
}

actor TaskRepository: TaskRepositoryProtocol {
    private struct MergedMetadata: Sendable {
        let threadId: String
        var title: String
        var projectDirectory: String
        var createdAt: Date
        var updatedAt: Date
    }

    private let appServerProbe: AppServerCapabilityProbe
    private let sqliteAdapter: CodexSQLiteTaskAdapter
    private let rolloutAdapter: CodexRolloutAdapter
    private let journalReaders: [PluginEventJournalReader]
    private let receiptStore: ReceiptStore
    private let accountRateLimitObserver: (any CodexAccountRateLimitObserving)?
    private let agentActivityObserver: (any CodexAgentActivityObserving)?
    private let sqliteRefreshInterval: TimeInterval
    private let runningStaleInterval: TimeInterval
    private let terminalRetentionInterval: TimeInterval
    private let terminalLimit: Int
    private var cachedSQLiteResult: SQLiteTaskReadResult?
    private var lastSQLiteRefreshAt: Date = .distantPast

    init(
        appServerProbe: AppServerCapabilityProbe,
        sqliteAdapter: CodexSQLiteTaskAdapter,
        rolloutAdapter: CodexRolloutAdapter,
        journalReader: PluginEventJournalReader,
        additionalJournalReaders: [PluginEventJournalReader] = [],
        receiptStore: ReceiptStore,
        accountRateLimitObserver: (any CodexAccountRateLimitObserving)? = nil,
        agentActivityObserver: (any CodexAgentActivityObserving)? = nil,
        sqliteRefreshInterval: TimeInterval = 30,
        runningStaleInterval: TimeInterval = TaskRetentionPolicy.runningStale,
        terminalRetentionInterval: TimeInterval = TaskRetentionPolicy.terminalRetention,
        terminalLimit: Int = TaskRetentionPolicy.maximumTerminalTasks
    ) {
        self.appServerProbe = appServerProbe
        self.sqliteAdapter = sqliteAdapter
        self.rolloutAdapter = rolloutAdapter
        journalReaders = [journalReader] + additionalJournalReaders
        self.receiptStore = receiptStore
        self.accountRateLimitObserver = accountRateLimitObserver
        self.agentActivityObserver = agentActivityObserver
        self.sqliteRefreshInterval = sqliteRefreshInterval
        self.runningStaleInterval = runningStaleInterval
        self.terminalRetentionInterval = terminalRetentionInterval
        self.terminalLimit = terminalLimit
    }

    static func live(paths: CodexPaths = .live()) -> TaskRepository {
        TaskRepository(
            appServerProbe: AppServerCapabilityProbe(
                controlSocketURL: paths.appServerControlSocketURL
            ),
            sqliteAdapter: CodexSQLiteTaskAdapter(
                codexHome: paths.codexHome
            ),
            rolloutAdapter: CodexRolloutAdapter(
                sessionsDirectory: paths.sessionsDirectory,
                sessionIndexURL: paths.sessionIndexURL
            ),
            journalReader: PluginEventJournalReader(
                journalURL: paths.pluginJournalURL
            ),
            additionalJournalReaders: paths.compatibilityPluginJournalURLs.map {
                PluginEventJournalReader(journalURL: $0)
            },
            receiptStore: ReceiptStore(databaseURL: paths.receiptsDatabaseURL),
            accountRateLimitObserver: CodexAccountRateLimitObserver(
                loader: CodexAppServerRateLimitClient()
            ),
            agentActivityObserver: CodexAgentActivityObserver(codexHome: paths.codexHome)
        )
    }

    func snapshot(now: Date = .now) async -> TaskSnapshot {
        let accountRateLimitObservation: CodexAccountRateLimitObservation? = if let accountRateLimitObserver {
            await accountRateLimitObserver.observation(now: now)
        } else {
            nil
        }
        var health: [AdapterHealth] = [
            accountRateLimitObservation?.health ?? appServerProbe.health(now: now),
        ]

        let receipts: ReceiptSnapshot
        do {
            receipts = try await receiptStore.snapshot(now: now)
            health.append(.healthy(.receipts, at: now))
        } catch {
            receipts = ReceiptSnapshot(baselineAt: now, viewedTaskIDs: [])
            health.append(.unavailable(.receipts, message: safeMessage(for: error)))
        }

        let sqliteResult: SQLiteTaskReadResult
        if let cachedSQLiteResult,
           now.timeIntervalSince(lastSQLiteRefreshAt) < sqliteRefreshInterval
        {
            sqliteResult = cachedSQLiteResult
            health.append(.healthy(.sqlite, at: lastSQLiteRefreshAt))
        } else {
            do {
                let freshResult = try sqliteAdapter.loadDesktopRootThreads()
                sqliteResult = freshResult
                cachedSQLiteResult = freshResult
                lastSQLiteRefreshAt = now
                health.append(.healthy(.sqlite, at: now))
            } catch {
                if let cachedSQLiteResult {
                    sqliteResult = cachedSQLiteResult
                    health.append(.degraded(
                        .sqlite,
                        message: safeMessage(for: error),
                        lastSuccessAt: lastSQLiteRefreshAt
                    ))
                } else {
                    sqliteResult = SQLiteTaskReadResult(
                        records: [],
                        unverifiedCandidateCount: 0
                    )
                    health.append(.unavailable(.sqlite, message: safeMessage(for: error)))
                }
            }
        }

        let rolloutResult: RolloutTaskReadResult
        do {
            rolloutResult = try await rolloutAdapter.loadDesktopRootTasks(
                additionalRolloutURLs: sqliteResult.records.map(\.rolloutURL),
                now: now
            )
            if rolloutResult.invalidFileCount > 0 {
                health.append(.degraded(
                    .rolloutJSONL,
                    message: "Rollout data is readable with partial metadata",
                    lastSuccessAt: now
                ))
            } else {
                health.append(.healthy(.rolloutJSONL, at: now))
            }
        } catch {
            rolloutResult = RolloutTaskReadResult(
                records: [],
                invalidFileCount: 0,
                sessionIndexAvailable: false
            )
            health.append(.unavailable(.rolloutJSONL, message: safeMessage(for: error)))
        }

        let (journalResult, journalHealth) = await loadPluginJournals(now: now)
        health.append(journalHealth)

        // Both adapters ask `RolloutMetadataReader` what counts as a Codex
        // Desktop root, so they blind together and cannot cross-check each
        // other. The genuinely independent criterion is the SQL predicate:
        // `threads.source = 'vscode'` already established these rows are
        // desktop threads. When every one of those rows then has its rollout
        // read successfully and declined, the two criteria contradict, which
        // only an upstream format change explains. That is precisely the
        // v2.0.2 signature — an empty panel reporting perfect health.
        //
        // Rollouts the sweep declines are deliberately not counted here. A
        // machine is full of CLI sessions and child threads, so declining
        // them is routine and says nothing.
        if sqliteResult.declinedCandidateCount > 0,
           sqliteResult.records.isEmpty,
           rolloutResult.records.isEmpty
        {
            replaceHealth(
                in: &health,
                with: .degraded(
                    .rolloutJSONL,
                    message: "\(sqliteResult.declinedCandidateCount) desktop thread(s) "
                        + "in Codex state SQLite had a readable rollout that no "
                        + "longer matches the desktop root filter",
                    lastSuccessAt: now,
                    reason: .formatDrift
                )
            )
        }

        if let sqliteNewest = sqliteResult.records.map(\.updatedAt).max(),
           let rolloutNewest = rolloutResult.records.map(\.status.updatedAt).max(),
           rolloutNewest.timeIntervalSince(sqliteNewest) > 60 * 60
        {
            replaceHealth(
                in: &health,
                with: .degraded(
                    .sqlite,
                    message: "Codex state SQLite is behind current rollout data",
                    lastSuccessAt: sqliteNewest
                )
            )
        }

        var metadataByThread: [String: MergedMetadata] = [:]
        var sqliteTokenUsageByThread: [String: TokenUsageSnapshot] = [:]
        for record in sqliteResult.records {
            metadataByThread[record.threadId] = MergedMetadata(
                threadId: record.threadId,
                title: record.title,
                projectDirectory: record.projectDirectory,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            if let tokenUsage = record.tokenUsage {
                sqliteTokenUsageByThread[record.threadId] = tokenUsage
            }
        }

        var statusByThread: [String: TaskStatusRecord] = [:]
        var rolloutTokenUsageByThread: [String: TokenUsageSnapshot] = [:]
        for record in rolloutResult.records {
            var metadata = metadataByThread[record.metadata.threadId] ?? MergedMetadata(
                threadId: record.metadata.threadId,
                title: "",
                projectDirectory: record.metadata.projectDirectory,
                createdAt: record.metadata.createdAt,
                updatedAt: record.status.updatedAt
            )
            if let title = record.title, !title.isEmpty {
                metadata.title = title
            }
            if metadata.projectDirectory.isEmpty {
                metadata.projectDirectory = record.metadata.projectDirectory
            }
            metadata.createdAt = min(metadata.createdAt, record.metadata.createdAt)
            metadata.updatedAt = max(metadata.updatedAt, record.status.updatedAt)
            metadataByThread[record.metadata.threadId] = metadata
            statusByThread[record.metadata.threadId] = mergedStatus(
                current: statusByThread[record.metadata.threadId],
                incoming: record.status
            )
            if let tokenUsage = record.status.tokenUsage {
                let existing = rolloutTokenUsageByThread[record.metadata.threadId]
                if existing == nil || tokenUsage.totalTokens >= (existing?.totalTokens ?? 0) {
                    rolloutTokenUsageByThread[record.metadata.threadId] = tokenUsage
                }
            }
        }

        let rolloutRateLimits = RolloutRateLimitSelector.select(
            rolloutResult.records.compactMap(\.status.rateLimits),
            now: now
        )
        let rateLimits: RateLimitSnapshot?
        if let accountRateLimitObservation {
            rateLimits = accountRateLimitObservation.snapshot
                ?? (accountRateLimitObservation.fallbackAllowed ? rolloutRateLimits : nil)
        } else {
            rateLimits = rolloutRateLimits
        }

        let verifiedThreadIDs = Set(metadataByThread.keys)
        for record in journalResult.records where verifiedThreadIDs.contains(record.threadId) {
            if var metadata = metadataByThread[record.threadId] {
                if metadata.projectDirectory.isEmpty {
                    metadata.projectDirectory = record.projectDirectory
                }
                metadata.updatedAt = max(metadata.updatedAt, record.status.updatedAt)
                metadataByThread[record.threadId] = metadata
            }
            statusByThread[record.threadId] = mergedJournalStatus(
                current: statusByThread[record.threadId],
                incoming: record.status
            )
        }

        let agentActivityByThread: [String: AgentActivityObservation]
        if let agentActivityObserver {
            let observableRootStates = statusByThread.compactMapValues { status -> PulseTaskState? in
                guard metadataByThread[status.threadId] != nil,
                      !status.isStaleRunning(at: now, cutoff: runningStaleInterval)
                else {
                    return nil
                }
                return status.state
            }
            let observed = await agentActivityObserver.observations(
                rootStates: observableRootStates,
                now: now
            )
            agentActivityByThread = Dictionary(uniqueKeysWithValues: observableRootStates.keys.map {
                threadId in
                (
                    threadId,
                    observed[threadId] ?? AgentActivityObservation(
                        activeCount: nil,
                        confidence: .unavailable,
                        observedAt: now
                    )
                )
            })
        } else {
            agentActivityByThread = [:]
        }

        var tasks: [PulseTask] = []
        for (threadId, status) in statusByThread {
            guard let metadata = metadataByThread[threadId] else { continue }
            if status.isStaleRunning(at: now, cutoff: runningStaleInterval) {
                continue
            }
            let agentActivity = agentActivityByThread[threadId]
            let hasActiveAgents = (agentActivity?.activeCount ?? 0) > 0
            let completionDate = status.completedAt ?? status.updatedAt
            if status.state.isTerminal,
               now.timeIntervalSince(completionDate) > terminalRetentionInterval,
               !hasActiveAgents
            {
                continue
            }
            let taskID = PulseTask.makeID(threadId: threadId, turnId: status.turnId)
            let isUnread = status.state == .completed
                && completionDate >= receipts.baselineAt
                && !receipts.viewedTaskIDs.contains(taskID)

            let fallbackTitle = URL(fileURLWithPath: metadata.projectDirectory)
                .lastPathComponent
            let title = metadata.title.isEmpty
                ? (fallbackTitle.isEmpty ? "Codex task" : fallbackTitle)
                : metadata.title

            tasks.append(PulseTask(
                threadId: threadId,
                turnId: status.turnId,
                title: title,
                projectDirectory: metadata.projectDirectory,
                state: status.state,
                startedAt: status.startedAt,
                updatedAt: status.updatedAt,
                completedAt: status.completedAt,
                lastStatus: status.lastStatus,
                isUnread: isUnread,
                tokenUsage: rolloutTokenUsageByThread[threadId]
                    ?? sqliteTokenUsageByThread[threadId],
                agentActivity: agentActivity,
                isProvisionalFailure: status.failedFromError
            ))
        }

        let protectedTerminalIDs = Set(
            tasks.lazy
                .filter {
                    $0.state.isTerminal && ($0.agentActivity?.activeCount ?? 0) > 0
                }
                .map(\.id)
        )
        let retainedTerminalIDs = Set(
            tasks.lazy
                .filter {
                    $0.state.isTerminal && !protectedTerminalIDs.contains($0.id)
                }
                .sorted { lhs, rhs in
                    if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
                    let leftDate = lhs.completedAt ?? lhs.updatedAt
                    let rightDate = rhs.completedAt ?? rhs.updatedAt
                    if leftDate != rightDate { return leftDate > rightDate }
                    return lhs.id < rhs.id
                }
                .prefix(max(0, terminalLimit))
                .map(\.id)
        ).union(protectedTerminalIDs)
        tasks.removeAll { task in
            task.state.isTerminal && !retainedTerminalIDs.contains(task.id)
        }

        tasks.sort { lhs, rhs in
            let leftPriority = groupPriority(lhs.state.group)
            let rightPriority = groupPriority(rhs.state.group)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }

        return TaskSnapshot(
            tasks: tasks,
            refreshedAt: now,
            health: health,
            rateLimits: rateLimits
        )
    }

    func markViewed(_ task: PulseTask, at date: Date = .now) async throws {
        try await receiptStore.markViewed(task, at: date)
    }

    private func loadPluginJournals(
        now: Date
    ) async -> (PluginJournalReadResult, AdapterHealth) {
        var recordsByThread: [String: JournalTaskRecord] = [:]
        var invalidLineCount = 0
        var loadedJournalCount = 0
        var unexpectedError: Error?

        for reader in journalReaders {
            do {
                let result = try await reader.load(now: now)
                loadedJournalCount += 1
                invalidLineCount = Self.saturatingAdd(
                    invalidLineCount,
                    result.invalidLineCount
                )
                for record in result.records {
                    guard let existing = recordsByThread[record.threadId] else {
                        recordsByThread[record.threadId] = record
                        continue
                    }
                    if record.status.updatedAt > existing.status.updatedAt {
                        recordsByThread[record.threadId] = record
                    }
                }
            } catch DataAdapterError.missingFile(_) {
                // Both current and upgrade-only journal paths are optional.
                continue
            } catch {
                unexpectedError = unexpectedError ?? error
            }
        }

        let result = PluginJournalReadResult(
            records: recordsByThread.values.sorted { $0.threadId < $1.threadId },
            invalidLineCount: invalidLineCount
        )
        if loadedJournalCount == 0 {
            let error = unexpectedError ?? DataAdapterError.missingFile(
                URL(fileURLWithPath: "events.jsonl")
            )
            return (result, .unavailable(.pluginJournal, message: safeMessage(for: error)))
        }
        if invalidLineCount > 0 || unexpectedError != nil {
            return (result, .degraded(
                .pluginJournal,
                message: unexpectedError.map { safeMessage(for: $0) }
                    ?? "Plugin journal contains ignored invalid events",
                lastSuccessAt: now
            ))
        }
        return (result, .healthy(.pluginJournal, at: now))
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    func receiptSnapshot(now: Date = .now) async throws -> ReceiptSnapshot {
        try await receiptStore.snapshot(now: now)
    }

    func markViewed(_ tasks: [PulseTask], at date: Date = .now) async throws {
        try await receiptStore.markViewed(tasks, at: date)
    }

    func unmarkViewed(_ task: PulseTask) async throws {
        try await receiptStore.unmarkViewed(task)
    }

    func unmarkViewed(_ tasks: [PulseTask]) async throws {
        try await receiptStore.unmarkViewed(tasks)
    }

    private func mergedStatus(
        current: TaskStatusRecord?,
        incoming: TaskStatusRecord
    ) -> TaskStatusRecord {
        guard let current else { return incoming }

        let sameTurn = current.turnId == incoming.turnId
            || current.turnId == nil
            || incoming.turnId == nil
        if sameTurn,
           incoming.state == .completed,
           current.state.isTerminal
        {
            return current
        }
        if sameTurn,
           current.state == .completed,
           incoming.state.isTerminal
        {
            return incoming
        }
        return incoming.updatedAt >= current.updatedAt ? incoming : current
    }

    private func mergedJournalStatus(
        current: TaskStatusRecord?,
        incoming: TaskStatusRecord
    ) -> TaskStatusRecord {
        guard let current else { return incoming }
        let sameTurn = current.turnId == incoming.turnId
            || current.turnId == nil
            || incoming.turnId == nil
        if sameTurn, current.state.isTerminal {
            return current
        }
        return incoming.updatedAt >= current.updatedAt ? incoming : current
    }

    private func groupPriority(_ group: PulseTaskGroup) -> Int {
        PulseTaskGroup.displayOrder.firstIndex(of: group) ?? Int.max
    }

    private func replaceHealth(
        in health: inout [AdapterHealth],
        with replacement: AdapterHealth
    ) {
        health.removeAll { $0.adapter == replacement.adapter }
        health.append(replacement)
    }

    private func safeMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return "Adapter unavailable"
    }
}
