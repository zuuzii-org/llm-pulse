import Foundation

/// Composes ZCode's normalized SQLite ledger and its narrow lifecycle event
/// stream. Both sources are read-only and fail independently.
actor ZCodeTaskRepository {
    private let paths: ZCodePaths
    private let sqliteReader: ZCodeSQLiteReader
    private let eventLogReader: ZCodeEventLogReader
    private let runningStaleInterval: TimeInterval
    private let terminalRetentionInterval: TimeInterval
    private var cachedLogStamps: [EventLogStamp]?
    private var cachedLogRootSessionIDs: Set<String>?
    private var cachedEventResult: ZCodeEventLogReadResult?

    init(
        paths: ZCodePaths,
        eventLogReader: ZCodeEventLogReader = ZCodeEventLogReader(),
        runningStaleInterval: TimeInterval = TaskRetentionPolicy.runningStale,
        terminalRetentionInterval: TimeInterval = TaskRetentionPolicy.terminalRetention
    ) {
        self.paths = paths
        sqliteReader = ZCodeSQLiteReader(databaseURL: paths.databaseURL)
        self.eventLogReader = eventLogReader
        self.runningStaleInterval = runningStaleInterval
        self.terminalRetentionInterval = terminalRetentionInterval
    }

    func snapshot(now: Date = .now) -> ModelTaskSnapshot {
        var health: [AdapterHealth] = []
        let sqliteResult: ZCodeSQLiteReadResult
        do {
            sqliteResult = try sqliteReader.read()
            if sqliteResult.driftedRootCount > 0 {
                health.append(.degraded(
                    .zcodeSQLite,
                    message: "\(sqliteResult.driftedRootCount) ZCode root session(s) "
                        + "have no readable current model selection",
                    lastSuccessAt: now,
                    reason: .formatDrift
                ))
            } else {
                health.append(.healthy(.zcodeSQLite, at: now))
            }
        } catch {
            sqliteResult = ZCodeSQLiteReadResult(records: [], driftedRootCount: 0)
            health.append(.unavailable(
                .zcodeSQLite,
                message: safeMessage(for: error, fallback: "ZCode SQLite data is unavailable"),
                reason: reason(for: error)
            ))
        }

        let rootSessionIDs = Set(sqliteResult.records.map(\.sessionID))
        let logURLs = paths.recentEventLogURLs()
        let eventResult: ZCodeEventLogReadResult
        if logURLs.isEmpty {
            eventResult = Self.emptyEventResult
            health.append(.unavailable(
                .zcodeEventLog,
                message: "ZCode event logs are unavailable"
            ))
        } else {
            do {
                eventResult = try readEventLogs(
                    urls: logURLs,
                    rootSessionIDs: rootSessionIDs
                )
                let usageWithoutEvents = sqliteResult.records.contains {
                    $0.usage.requestCount > 0
                        && eventResult.observations[$0.sessionID] == nil
                        && now.timeIntervalSince($0.updatedAt) <= runningStaleInterval
                }
                if eventResult.malformedRelevantEventCount > 0 || usageWithoutEvents {
                    health.append(.degraded(
                        .zcodeEventLog,
                        message: "ZCode lifecycle events no longer match the expected format",
                        lastSuccessAt: now,
                        reason: .formatDrift
                    ))
                } else if eventResult.invalidLineCount > 0 {
                    health.append(.degraded(
                        .zcodeEventLog,
                        message: "\(eventResult.invalidLineCount) ZCode event line(s) "
                            + "could not be read",
                        lastSuccessAt: now
                    ))
                } else {
                    health.append(.healthy(.zcodeEventLog, at: now))
                }
            } catch {
                eventResult = Self.emptyEventResult
                health.append(.unavailable(
                    .zcodeEventLog,
                    message: safeMessage(
                        for: error,
                        fallback: "ZCode event logs are unavailable"
                    ),
                    reason: reason(for: error)
                ))
            }
        }

        let tasks = makeTasks(
            records: sqliteResult.records,
            eventResult: eventResult,
            now: now
        )
        let visibleSessionIDs = Set(tasks.map(\.sessionID))
        let visibleTotals = ZCodeUsageTotals.combined(
            sqliteResult.records.lazy
                .filter { visibleSessionIDs.contains($0.sessionID) }
                .map(\.usage)
        )
        let usage: ModelUsageSnapshot?
        if let visibleTotals,
           let totalTokens = visibleTotals.totalTokens,
           visibleTotals.requestCount > 0 || totalTokens != 0
        {
            usage = ModelUsageSnapshot(
                inputTokens: visibleTotals.inputTokens,
                // ZCode reports reasoning as a separate output bucket and
                // includes it in computed total tokens.
                outputTokens: totalTokens - visibleTotals.inputTokens,
                cacheCreationInputTokens: visibleTotals.cacheCreationInputTokens,
                cacheReadInputTokens: visibleTotals.cacheReadInputTokens,
                observedRequestCount: visibleTotals.requestCount,
                observedAt: now
            )
        } else {
            usage = nil
            if !tasks.isEmpty,
               visibleTotals == nil || visibleTotals?.totalTokens == nil
            {
                health.removeAll { $0.adapter == .zcodeSQLite }
                health.append(.degraded(
                    .zcodeSQLite,
                    message: "ZCode usage totals exceed the supported range",
                    lastSuccessAt: now,
                    reason: .formatDrift
                ))
            }
        }

        let membership = sqliteResult.records.max(by: { $0.updatedAt < $1.updatedAt })?
            .selection.isCodingPlan == true
            ? MembershipObservation(tierDisplayName: "Coding Plan")
            : nil

        return ModelTaskSnapshot(
            identity: .glm,
            tasks: tasks,
            usage: usage,
            rateLimits: nil,
            membership: membership,
            health: health,
            refreshedAt: now
        )
    }

    private func makeTasks(
        records: [ZCodeSessionRecord],
        eventResult: ZCodeEventLogReadResult,
        now: Date
    ) -> [PulseTask] {
        records.compactMap { record in
            guard let event = eventResult.observations[record.sessionID] else { return nil }
            let status = event.status
            if status.isStaleRunning(at: now, cutoff: runningStaleInterval) { return nil }
            if status.state.isTerminal {
                let completedAt = status.completedAt ?? status.updatedAt
                guard now.timeIntervalSince(completedAt) <= terminalRetentionInterval else {
                    return nil
                }
            }

            return PulseTask(
                threadId: record.sessionID,
                turnId: status.turnId,
                identity: .glm,
                sessionID: record.sessionID,
                title: title(for: record),
                projectDirectory: record.projectDirectory,
                state: status.state,
                startedAt: status.startedAt,
                updatedAt: status.updatedAt,
                completedAt: status.completedAt,
                lastStatus: status.lastStatus,
                tokenUsage: record.usage.tokenSnapshot,
                agentActivity: AgentActivityObservation(
                    activeCount: event.activeAgentCount,
                    confidence: event.agentActivityConfidence,
                    observedAt: now
                )
            )
        }.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    private func title(for record: ZCodeSessionRecord) -> String {
        let trimmed = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        let component = URL(fileURLWithPath: record.projectDirectory).lastPathComponent
        return component.isEmpty ? "GLM session" : component
    }

    /// Avoids re-decoding an unchanged daily log on every 750 ms monitor poll.
    /// A growing or replaced file changes the stamp and is parsed immediately.
    private func readEventLogs(
        urls: [URL],
        rootSessionIDs: Set<String>
    ) throws -> ZCodeEventLogReadResult {
        let before = urls.compactMap(EventLogStamp.init)
        if before.count == urls.count,
           before == cachedLogStamps,
           rootSessionIDs == cachedLogRootSessionIDs,
           let cachedEventResult
        {
            return cachedEventResult
        }

        let result = try eventLogReader.read(
            urls: urls,
            rootSessionIDs: rootSessionIDs
        )
        let after = urls.compactMap(EventLogStamp.init)
        if before.count == urls.count, before == after {
            cachedLogStamps = after
            cachedLogRootSessionIDs = rootSessionIDs
            cachedEventResult = result
        } else {
            cachedLogStamps = nil
            cachedLogRootSessionIDs = nil
            cachedEventResult = nil
        }
        return result
    }

    private func reason(for error: Error) -> AdapterHealth.Reason {
        guard let adapterError = error as? DataAdapterError else { return .unreadable }
        switch adapterError {
        case .invalidFormat(_, let detail) where !detail.contains("unsafe"):
            return .formatDrift
        case .missingFile, .sqlite, .invalidFormat:
            return .unreadable
        }
    }

    private func safeMessage(for error: Error, fallback: String) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return fallback
    }

    private static let emptyEventResult = ZCodeEventLogReadResult(
        observations: [:],
        totalLineCount: 0,
        recognizedEventCount: 0,
        matchedRootEventCount: 0,
        invalidLineCount: 0,
        malformedRelevantEventCount: 0
    )

    private struct EventLogStamp: Equatable {
        let deviceID: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init?(_ url: URL) {
            var status = stat()
            guard url.path.withCString({ lstat($0, &status) }) == 0,
                  status.st_mode & S_IFMT == S_IFREG
            else {
                return nil
            }
            deviceID = status.st_dev
            inode = status.st_ino
            size = status.st_size
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        }
    }
}
