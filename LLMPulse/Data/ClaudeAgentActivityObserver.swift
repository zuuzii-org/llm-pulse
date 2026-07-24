import Foundation

/// Counts the agents a Claude Code session still has in flight.
///
/// Claude subagents share their parent's process, so the Codex approach —
/// walking a process tree — reports zero for every session and must not be
/// reused. The evidence here is the workflow journal each run appends to.
///
/// Bounded like `CodexAgentActivityObserver`: a session that spawned a great
/// many runs degrades to a provisional count rather than stalling the poll.
actor ClaudeAgentActivityObserver {
    /// Runs examined per session, newest first.
    private static let maximumRunsPerSession = 64

    /// A journal past this size is skipped rather than read.
    private static let maximumJournalBytes = 4 * 1_024 * 1_024

    private struct CachedRun: Sendable {
        let stamp: ClaudeFileStamp
        let startedAgentIDs: Set<String>
        let resolvedAgentIDs: Set<String>
    }

    private var cachedRuns: [URL: CachedRun] = [:]

    /// Active agents for one session, including its own turn.
    ///
    /// Returns `nil` when nothing can be established, which the interface
    /// renders as "unavailable" rather than as zero — an active task always
    /// has at least its own agent, so zero would be visibly wrong.
    func observation(
        sidecarDirectory: URL,
        isRootActive: Bool,
        now: Date
    ) -> AgentActivityObservation {
        let rootCount = isRootActive ? 1 : 0
        let runsDirectory = sidecarDirectory
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)

        guard FileManager.default.fileExists(atPath: runsDirectory.path) else {
            // Most sessions never spawn one. That is a definite answer, not a
            // missing one.
            return AgentActivityObservation(
                activeCount: rootCount,
                confidence: .exact,
                observedAt: now
            )
        }

        let runDirectories = (try? FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let ordered = runDirectories.sorted { lhs, rhs in
            modificationDate(of: lhs) > modificationDate(of: rhs)
        }
        var confidence = AgentActivityObservation.Confidence.exact
        if ordered.count > Self.maximumRunsPerSession {
            confidence = .provisional
        }

        var activeDescendants = 0
        for runDirectory in ordered.prefix(Self.maximumRunsPerSession) {
            let runID = runDirectory.lastPathComponent

            // The cheapest possible verdict: a finished run cannot hold any
            // agent open, so its journal never has to be opened.
            if isRunFinished(runID: runID, sidecarDirectory: sidecarDirectory) {
                continue
            }

            switch pendingAgentCount(inRunAt: runDirectory) {
            case let .some(count):
                activeDescendants += count
            case .none:
                confidence = .provisional
            }
        }

        return AgentActivityObservation(
            activeCount: rootCount + activeDescendants,
            confidence: confidence,
            observedAt: now
        )
    }

    private func isRunFinished(runID: String, sidecarDirectory: URL) -> Bool {
        let snapshotURL = sidecarDirectory
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("\(runID).json")
        guard let data = try? Data(contentsOf: snapshotURL),
              let object = JSONValueSupport.object(from: data),
              let status = JSONValueSupport.string(object["status"])
        else {
            return false
        }
        return ["completed", "failed", "cancelled", "stopped"].contains(status)
    }

    /// Agents started in a run and not yet resolved.
    ///
    /// A set difference rather than a count subtraction: journal appends are
    /// best-effort, so a duplicate line must not push the total negative.
    private func pendingAgentCount(inRunAt runDirectory: URL) -> Int? {
        let journalURL = runDirectory.appendingPathComponent("journal.jsonl")
        guard let stamp = ClaudeFileStamp(path: journalURL.path) else { return nil }
        guard stamp.size <= Self.maximumJournalBytes else { return nil }

        if let cached = cachedRuns[journalURL], cached.stamp == stamp {
            return cached.startedAgentIDs.subtracting(cached.resolvedAgentIDs).count
        }

        guard let data = try? Data(contentsOf: journalURL) else { return nil }

        var startedAgentIDs: Set<String> = []
        var resolvedAgentIDs: Set<String> = []
        data.enumerateJSONLines { object in
            guard let agentID = JSONValueSupport.string(object["agentId"]) else { return }
            switch JSONValueSupport.string(object["type"]) {
            case "started":
                startedAgentIDs.insert(agentID)
            case "result", "error":
                resolvedAgentIDs.insert(agentID)
            default:
                break
            }
        }

        cachedRuns[journalURL] = CachedRun(
            stamp: stamp,
            startedAgentIDs: startedAgentIDs,
            resolvedAgentIDs: resolvedAgentIDs
        )
        return startedAgentIDs.subtracting(resolvedAgentIDs).count
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
