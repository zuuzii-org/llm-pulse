import Foundation

/// Composes Claude Code's session registry and transcripts into a snapshot.
///
/// Mirrors `TaskRepository`: `snapshot(now:)` never throws, and every failure
/// becomes an `AdapterHealth` entry instead. A monitor that disappears when a
/// source misbehaves is worse than one that says so.
actor ClaudeTaskRepository {
    private let registryReader: ClaudeSessionRegistryReader
    private let transcriptAdapter: ClaudeTranscriptAdapter
    private let agentObserver: ClaudeAgentActivityObserver
    private let planUsageReader: ClaudePlanUsageReader
    private let accountReader: ClaudeAccountReader
    private let paths: ClaudePaths
    private let runningStaleInterval: TimeInterval
    private let terminalRetentionInterval: TimeInterval

    /// Consecutive unreadable polls a registry entry survives.
    ///
    /// The app rewrites these files in place, so a read can legitimately come
    /// back empty. Dropping a row on the first failure would make live
    /// sessions blink out at random.
    private static let registryFailureTolerance = 3

    private var lastEntries: [ClaudeSessionRegistryEntry] = []
    private var consecutiveRegistryFailures = 0

    /// The usage history is parsed in full, and it grows by a sample every
    /// few minutes forever. At a 750 ms poll that parse must be keyed on the
    /// file's stamp, not repeated; projections onto `now` stay per-poll.
    private var planUsageStamp: ClaudeFileStamp?
    private var planUsageParsed: ClaudePlanUsageReader.Parsed?

    /// Same stamp-keyed pattern for the account config, which grows with
    /// per-project state and must not be re-parsed on a 750 ms cadence.
    private var accountStamp: ClaudeFileStamp?
    private var accountObservation: MembershipObservation?

    init(
        paths: ClaudePaths,
        probe: any ClaudeProcessProbing = LibprocProcessProbe(),
        tailParser: ClaudeTranscriptTailParser = ClaudeTranscriptTailParser(),
        discoveryInterval: TimeInterval = 5,
        runningStaleInterval: TimeInterval = TaskRetentionPolicy.runningStale,
        terminalRetentionInterval: TimeInterval = TaskRetentionPolicy.terminalRetention
    ) {
        registryReader = ClaudeSessionRegistryReader(
            sessionsDirectory: paths.sessionsDirectory,
            probe: probe
        )
        transcriptAdapter = ClaudeTranscriptAdapter(
            paths: paths,
            tailParser: tailParser,
            discoveryInterval: discoveryInterval
        )
        agentObserver = ClaudeAgentActivityObserver()
        planUsageReader = ClaudePlanUsageReader(
            planUsageHistoryURL: paths.planUsageHistoryURL
        )
        accountReader = ClaudeAccountReader(accountConfigURL: paths.accountConfigURL)
        self.paths = paths
        self.runningStaleInterval = runningStaleInterval
        self.terminalRetentionInterval = terminalRetentionInterval
    }

    func snapshot(now: Date = .now) async -> ModelTaskSnapshot {
        var health: [AdapterHealth] = []

        let entries: [ClaudeSessionRegistryEntry]
        do {
            let result = try registryReader.read()
            if result.unreadableFileCount > 0 {
                consecutiveRegistryFailures += 1
                health.append(.degraded(
                    .claudeSessionRegistry,
                    message: "\(result.unreadableFileCount) session file(s) were "
                        + "being rewritten while they were read",
                    lastSuccessAt: now
                ))
                entries = consecutiveRegistryFailures < Self.registryFailureTolerance
                    ? mergedEntries(fresh: result.entries)
                    : result.entries
            } else {
                consecutiveRegistryFailures = 0
                entries = result.entries
                health.append(.healthy(.claudeSessionRegistry, at: now))
            }
            lastEntries = entries
        } catch {
            entries = []
            lastEntries = []
            health.append(.unavailable(
                .claudeSessionRegistry,
                message: safeMessage(for: error)
            ))
        }

        let liveSessionIDs = Set(entries.map(\.sessionID))
        let entriesBySession = Dictionary(
            entries.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let readResult: ClaudeTaskReadResult
        do {
            readResult = try await transcriptAdapter.loadTasks(
                liveSessionIDs: liveSessionIDs,
                now: now
            )
            if readResult.missingTranscriptCount > 0 {
                // The registry proves these sessions are running, so having no
                // transcript for them means the layout moved rather than that
                // nothing is happening.
                health.append(.degraded(
                    .claudeTranscript,
                    message: "\(readResult.missingTranscriptCount) live session(s) "
                        + "have no transcript at the expected location",
                    lastSuccessAt: now,
                    reason: .formatDrift
                ))
            } else if readResult.invalidFileCount > 0 {
                health.append(.degraded(
                    .claudeTranscript,
                    message: "\(readResult.invalidFileCount) transcript(s) could not be read",
                    lastSuccessAt: now
                ))
            } else {
                health.append(.healthy(.claudeTranscript, at: now))
            }
        } catch {
            readResult = ClaudeTaskReadResult(
                records: [],
                invalidFileCount: 0,
                missingTranscriptCount: 0
            )
            health.append(.unavailable(
                .claudeTranscript,
                message: safeMessage(for: error)
            ))
        }

        let tasks = await makeTasks(
            from: readResult.records,
            entriesBySession: entriesBySession,
            now: now
        )

        return ModelTaskSnapshot(
            identity: .claudeCode,
            tasks: tasks,
            usage: modelUsage(from: readResult.records, tasks: tasks, now: now),
            // No quota card: the percentage is readable but its reset time is
            // not, and `RateLimitWindowSnapshot` requires one. The percentages
            // travel on `usage` instead, where nothing implies Codex's window
            // semantics.
            rateLimits: nil,
            membership: currentMembership(),
            health: health,
            refreshedAt: now
        )
    }

    private func currentMembership() -> MembershipObservation? {
        let stamp = ClaudeFileStamp(path: paths.accountConfigURL.path)
        if stamp != accountStamp {
            accountStamp = stamp
            accountObservation = accountReader.read()
        }
        return accountObservation
    }

    /// Model-level usage: what this app observed locally, plus the vendor's
    /// account-level windows when they are readable.
    ///
    /// The token total covers the sessions actually on screen, so it moves
    /// with the retention window rather than claiming to be an all-time
    /// figure the app never had access to.
    private func modelUsage(
        from records: [ClaudeTranscriptTaskRecord],
        tasks: [PulseTask],
        now: Date
    ) -> ModelUsageSnapshot? {
        let visibleSessionIDs = Set(tasks.map(\.sessionID))
        var totals = ClaudeTokenFold()
        for record in records where visibleSessionIDs.contains(record.sessionID) {
            totals.promptTokens += record.tokens.promptTokens
            totals.cacheCreationTokens += record.tokens.cacheCreationTokens
            totals.cacheReadTokens += record.tokens.cacheReadTokens
            totals.outputTokens += record.tokens.outputTokens
            totals.requestCount += record.tokens.requestCount
        }

        let stamp = ClaudeFileStamp(path: paths.planUsageHistoryURL.path)
        if stamp != planUsageStamp {
            planUsageStamp = stamp
            planUsageParsed = planUsageReader.parse()
        }
        let planUsage = planUsageParsed.flatMap {
            planUsageReader.reading(from: $0, now: now)
        }
        guard totals.totalTokens > 0 || planUsage != nil else { return nil }

        return ModelUsageSnapshot(
            inputTokens: totals.inputTokens,
            outputTokens: totals.outputTokens,
            cacheCreationInputTokens: totals.cacheCreationTokens,
            cacheReadInputTokens: totals.cacheReadTokens,
            observedRequestCount: totals.requestCount,
            observedAt: now,
            fiveHourWindow: planUsage?.fiveHourWindow,
            sevenDayWindow: planUsage?.sevenDayWindow,
            planUsageObservedAt: planUsage?.observedAt
        )
    }

    // MARK: - Composition

    private func makeTasks(
        from records: [ClaudeTranscriptTaskRecord],
        entriesBySession: [String: ClaudeSessionRegistryEntry],
        now: Date
    ) async -> [PulseTask] {
        var tasks: [PulseTask] = []

        for record in records {
            let entry = entriesBySession[record.sessionID]
            let status = clamped(record.status, isLive: entry != nil)

            if status.isStaleRunning(at: now, cutoff: runningStaleInterval) { continue }
            if status.state.isTerminal {
                let completedAt = status.completedAt ?? status.updatedAt
                guard now.timeIntervalSince(completedAt) <= terminalRetentionInterval else {
                    continue
                }
            }

            let agentActivity = await agentObserver.observation(
                sidecarDirectory: paths.sidecarDirectory(
                    forTranscript: record.transcriptURL
                ),
                isRootActive: !status.state.isTerminal,
                now: now
            )

            tasks.append(PulseTask(
                threadId: record.sessionID,
                turnId: nil,
                identity: .claudeCode,
                sessionID: record.sessionID,
                title: title(for: record, entry: entry),
                projectDirectory: entry?.workingDirectory
                    ?? Self.projectDirectory(forTranscript: record.transcriptURL),
                state: status.state,
                startedAt: status.startedAt,
                updatedAt: status.updatedAt,
                completedAt: status.completedAt,
                lastStatus: status.lastStatus,
                tokenUsage: record.tokenUsage,
                agentActivity: agentActivity
            ))
        }

        return tasks.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    /// Forces a row with no live process into a terminal state.
    ///
    /// A transcript keeps whatever state it last implied, so a session killed
    /// mid-turn would otherwise claim to be running forever. An interruption
    /// or a failure is preserved, because those are evidence rather than an
    /// absence of it.
    private func clamped(_ status: TaskStatusRecord, isLive: Bool) -> TaskStatusRecord {
        guard !isLive, !status.state.isTerminal else { return status }
        return TaskStatusRecord(
            threadId: status.threadId,
            turnId: status.turnId,
            state: .completed,
            startedAt: status.startedAt,
            updatedAt: status.updatedAt,
            completedAt: status.latestActivityAt ?? status.updatedAt,
            lastStatus: PulseTaskState.completed.rawValue,
            latestActivityAt: status.latestActivityAt,
            tokenUsage: status.tokenUsage
        )
    }

    /// The row title, in the order a person would recognise it.
    ///
    /// The registry's `name` is a slug the app generated (`mc-mods-1c`) unless
    /// `nameSource` says otherwise, and showing it means the session cannot be
    /// found by the title Claude itself displays. The transcript carries that
    /// title, so it wins.
    private func title(
        for record: ClaudeTranscriptTaskRecord,
        entry: ClaudeSessionRegistryEntry?
    ) -> String {
        // What the user named it, then what the app named it.
        if let title = record.customTitle { return title }
        if let title = record.generatedTitle { return title }

        // A registry name only helps when the app says it is not a slug.
        if let entry, !entry.hasDerivedName, let name = entry.name, !name.isEmpty {
            return name
        }

        let directory = entry?.workingDirectory
            ?? Self.projectDirectory(forTranscript: record.transcriptURL)
        let lastComponent = URL(fileURLWithPath: directory).lastPathComponent
        if !lastComponent.isEmpty, lastComponent != "/" { return lastComponent }

        // Better a slug than nothing.
        if let name = entry?.name, !name.isEmpty { return name }
        return "Claude Code session"
    }

    /// Only a live registry entry carries a real working directory.
    ///
    /// The project directory name cannot be decoded back into a path, so a
    /// history row is left without one rather than showing a guess.
    private static func projectDirectory(forTranscript url: URL) -> String {
        ""
    }

    private func mergedEntries(
        fresh: [ClaudeSessionRegistryEntry]
    ) -> [ClaudeSessionRegistryEntry] {
        var merged = fresh
        let freshIDs = Set(fresh.map(\.sessionID))
        for entry in lastEntries where !freshIDs.contains(entry.sessionID) {
            merged.append(entry)
        }
        return merged
    }

    private func safeMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return "Claude Code data is unavailable"
    }
}
