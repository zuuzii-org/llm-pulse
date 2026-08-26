import Foundation

/// Composes ZCode's normalized SQLite ledger, narrow lifecycle events, and
/// renderer-owned entitlement cache. All sources are read-only and fail
/// independently.
actor ZCodeTaskRepository {
    private static let entitlementClockSkewTolerance: TimeInterval = 60

    private let paths: ZCodePaths
    private let sqliteReader: ZCodeSQLiteReader
    private let eventLogReader: ZCodeEventLogReader
    private let entitlementReader: any ZCodeEntitlementReading
    private let entitlementFreshnessInterval: TimeInterval
    private let runningStaleInterval: TimeInterval
    private let terminalRetentionInterval: TimeInterval
    private var cachedLogStamps: [EventLogStamp]?
    private var cachedLogRootSessionIDs: Set<String>?
    private var cachedEventResult: ZCodeEventLogReadResult?
    private var lastEntitlementObservation: ZCodeEntitlementCacheReader.Observation?

    init(
        paths: ZCodePaths,
        eventLogReader: ZCodeEventLogReader = ZCodeEventLogReader(),
        entitlementReader: (any ZCodeEntitlementReading)? = nil,
        entitlementFreshnessInterval: TimeInterval = 10 * 60,
        runningStaleInterval: TimeInterval = TaskRetentionPolicy.runningStale,
        terminalRetentionInterval: TimeInterval = TaskRetentionPolicy.terminalRetention
    ) {
        self.paths = paths
        sqliteReader = ZCodeSQLiteReader(databaseURL: paths.databaseURL)
        self.eventLogReader = eventLogReader
        self.entitlementReader = entitlementReader ?? ZCodeEntitlementCacheReader(
            entitlementLocalStorageDirectory: paths.entitlementLocalStorageDirectory,
            maximumCacheAge: entitlementFreshnessInterval
        )
        self.entitlementFreshnessInterval = max(0, entitlementFreshnessInterval)
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

        let entitlement = entitlementTelemetry(
            records: sqliteResult.records,
            visibleSessionIDs: visibleSessionIDs,
            now: now
        )
        health.append(contentsOf: entitlement.health)

        return ModelTaskSnapshot(
            identity: .glm,
            tasks: tasks,
            usage: usage,
            rateLimits: entitlement.rateLimits,
            membership: entitlement.membership,
            health: health,
            refreshedAt: now
        )
    }

    private func entitlementTelemetry(
        records: [ZCodeSessionRecord],
        visibleSessionIDs: Set<String>,
        now: Date
    ) -> EntitlementTelemetry {
        let visibleRecords = records.filter {
            visibleSessionIDs.contains($0.sessionID)
        }
        let visibleCodingPlanProviderIDs = Set(visibleRecords.lazy.filter {
            $0.selection.isCodingPlan
        }.map {
            $0.selection.providerID.lowercased()
        })
        let visibleProviders = Set(visibleCodingPlanProviderIDs.compactMap {
            ZCodeEntitlementCacheReader.ProviderID(rawValue: $0)
        })

        if visibleProviders.count != visibleCodingPlanProviderIDs.count {
            lastEntitlementObservation = nil
            return EntitlementTelemetry(
                rateLimits: nil,
                membership: nil,
                health: [.unavailable(
                    .zcodeEntitlementCache,
                    message: "ZCode selected an unsupported Coding Plan provider",
                    reason: .formatDrift
                )]
            )
        }

        if !visibleRecords.isEmpty, visibleProviders.isEmpty {
            lastEntitlementObservation = nil
            return EntitlementTelemetry(
                rateLimits: nil,
                membership: nil,
                health: []
            )
        }

        if visibleProviders.count > 1 {
            lastEntitlementObservation = nil
            return EntitlementTelemetry(
                rateLimits: nil,
                membership: nil,
                health: [.unavailable(
                    .zcodeEntitlementCache,
                    message: "ZCode entitlement cache does not identify one active provider"
                )]
            )
        }

        if let provider = visibleProviders.first {
            return entitlementTelemetry(
                provider: provider,
                result: entitlementReader.read(provider: provider, now: now),
                now: now
            )
        }

        // No current root can identify the account while ZCode is idle or its
        // lifecycle log is briefly unavailable. A single fresh, provider-typed
        // renderer cache is still authoritative; two fresh providers are not.
        let results = ZCodeEntitlementCacheReader.ProviderID.allCases.map { provider in
            (provider, entitlementReader.read(provider: provider, now: now))
        }
        let observed = results.compactMap { provider, result in
            if case .observed = result { return (provider, result) }
            return nil
        }
        if observed.count == 1, let (provider, result) = observed.first {
            return entitlementTelemetry(provider: provider, result: result, now: now)
        }
        if observed.count > 1 {
            lastEntitlementObservation = nil
            return EntitlementTelemetry(
                rateLimits: nil,
                membership: nil,
                health: [.unavailable(
                    .zcodeEntitlementCache,
                    message: "ZCode entitlement cache contains multiple active providers"
                )]
            )
        }

        let latestProvider = records.max { $0.updatedAt < $1.updatedAt }.flatMap {
            ZCodeEntitlementCacheReader.ProviderID(rawValue: $0.selection.providerID)
        }
        let fallbackProvider = lastEntitlementObservation?.provider ?? latestProvider
        if let fallbackProvider,
           let result = results.first(where: { $0.0 == fallbackProvider })?.1
        {
            return entitlementTelemetry(
                provider: fallbackProvider,
                result: result,
                now: now
            )
        }

        if results.contains(where: { _, result in
            if case .formatDrift = result { return true }
            return false
        }) {
            lastEntitlementObservation = nil
            return EntitlementTelemetry(
                rateLimits: nil,
                membership: nil,
                health: [.unavailable(
                    .zcodeEntitlementCache,
                    message: "ZCode entitlement cache format changed",
                    reason: .formatDrift
                )]
            )
        }

        lastEntitlementObservation = nil
        return EntitlementTelemetry(
            rateLimits: nil,
            membership: nil,
            health: []
        )
    }

    private func entitlementTelemetry(
        provider: ZCodeEntitlementCacheReader.ProviderID,
        result: ZCodeEntitlementCacheReader.ReadResult,
        now: Date
    ) -> EntitlementTelemetry {
        let fallbackMembership = MembershipObservation(tierDisplayName: "Coding Plan")
        switch result {
        case let .observed(observation):
            guard observation.provider == provider else {
                lastEntitlementObservation = nil
                return EntitlementTelemetry(
                    rateLimits: nil,
                    membership: fallbackMembership,
                    health: [.unavailable(
                        .zcodeEntitlementCache,
                        message: "ZCode entitlement cache returned an invalid provider",
                        reason: .formatDrift
                    )]
                )
            }
            let telemetry = telemetry(from: observation, now: now)
            lastEntitlementObservation = observation
            return EntitlementTelemetry(
                rateLimits: telemetry.rateLimits,
                membership: telemetry.membership,
                health: telemetry.health.isEmpty
                    ? [.healthy(.zcodeEntitlementCache, at: observation.cachedAt)]
                    : telemetry.health
            )
        case .unreadable:
            if let retained = lastEntitlementObservation,
               retained.provider == provider,
               (-Self.entitlementClockSkewTolerance...entitlementFreshnessInterval).contains(
                   now.timeIntervalSince(retained.cachedAt)
               )
            {
                let telemetry = telemetry(from: retained, now: now)
                return EntitlementTelemetry(
                    rateLimits: telemetry.rateLimits,
                    membership: telemetry.membership,
                    health: [.degraded(
                        .zcodeEntitlementCache,
                        message: "ZCode entitlement cache changed during a read",
                        lastSuccessAt: retained.cachedAt
                    )]
                )
            }
            lastEntitlementObservation = nil
            return unavailableEntitlement(
                message: "ZCode entitlement cache is unreadable",
                fallbackMembership: fallbackMembership
            )
        case .absent:
            lastEntitlementObservation = nil
            return unavailableEntitlement(
                message: "ZCode entitlement cache is unavailable",
                fallbackMembership: fallbackMembership
            )
        case .stale:
            lastEntitlementObservation = nil
            return unavailableEntitlement(
                message: "ZCode entitlement cache is stale",
                fallbackMembership: fallbackMembership
            )
        case .ambiguous:
            lastEntitlementObservation = nil
            return unavailableEntitlement(
                message: "ZCode entitlement cache contains multiple active accounts",
                fallbackMembership: nil
            )
        case .formatDrift:
            lastEntitlementObservation = nil
            return EntitlementTelemetry(
                rateLimits: nil,
                membership: fallbackMembership,
                health: [.unavailable(
                    .zcodeEntitlementCache,
                    message: "ZCode entitlement cache format changed",
                    reason: .formatDrift
                )]
            )
        }
    }

    private func telemetry(
        from observation: ZCodeEntitlementCacheReader.Observation,
        now: Date
    ) -> EntitlementTelemetry {
        let details = observation.subscriptionDetails.filter {
            $0.productName != nil
                || $0.billingCycle != nil
                || $0.renewsAt != nil
                || $0.expiresAt != nil
        }
        let membership = details.count == 1 ? details.first.map { detail in
            MembershipObservation(
                tierDisplayName: detail.productName ?? observation.level,
                renewsAt: detail.renewsAt,
                expiresAt: detail.expiresAt
            )
        } : nil

        let fiveHour = rateLimitWindow(
            observation.fiveHour,
            windowMinutes: RateLimitWindowDuration.legacyFiveHourMinutes,
            observedAt: observation.cachedAt,
            now: now
        )
        let weekly = rateLimitWindow(
            observation.weekly,
            windowMinutes: RateLimitWindowDuration.weeklyMinutes,
            observedAt: observation.cachedAt,
            now: now
        )
        let rateLimits = fiveHour == nil && weekly == nil
            ? nil
            : RateLimitSnapshot(
                fiveHour: fiveHour,
                weekly: weekly,
                updatedAt: observation.cachedAt,
                planType: observation.level
            )
        return EntitlementTelemetry(
            rateLimits: rateLimits,
            membership: membership,
            health: details.count > 1
                ? [.degraded(
                    .zcodeEntitlementCache,
                    message: "ZCode entitlement cache contains ambiguous membership details",
                    lastSuccessAt: observation.cachedAt
                )]
                : []
        )
    }

    private func rateLimitWindow(
        _ limit: ZCodeEntitlementCacheReader.Limit?,
        windowMinutes: Int,
        observedAt: Date,
        now: Date
    ) -> RateLimitWindowSnapshot? {
        guard let limit,
              let resetsAt = limit.nextResetTime,
              resetsAt > now
        else {
            return nil
        }
        guard let usedPercent = limit.usedPercent,
              usedPercent.isFinite,
              (0...100).contains(usedPercent)
        else {
            return nil
        }
        return RateLimitWindowSnapshot(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            observedAt: observedAt
        )
    }

    private func unavailableEntitlement(
        message: String,
        fallbackMembership: MembershipObservation?
    ) -> EntitlementTelemetry {
        EntitlementTelemetry(
            rateLimits: nil,
            membership: fallbackMembership,
            health: [.unavailable(.zcodeEntitlementCache, message: message)]
        )
    }

    private struct EntitlementTelemetry {
        let rateLimits: RateLimitSnapshot?
        let membership: MembershipObservation?
        let health: [AdapterHealth]
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
