import Foundation

/// Reads Claude Code transcripts incrementally.
///
/// Mirrors `CodexRolloutAdapter`: discovery is throttled, each file is keyed
/// on a stamp so an unchanged transcript costs one `lstat`, and only bytes
/// appended since the last poll are read.
actor ClaudeTranscriptAdapter {
    private struct CachedTranscript: Sendable {
        let stamp: ClaudeFileStamp
        let readOffset: Int
        let fold: ClaudeTranscriptFold
        let wasInvalid: Bool
    }

    /// A cold read never takes the whole file. Everything the state machine
    /// needs is carried on the fold, so only enough tail to establish recent
    /// activity is required.
    private static let resyncTailBytes = 256 * 1_024

    /// Past this much growth in one poll, seek to the tail instead. Matches
    /// the fallback `CodexRolloutAdapter` already applies.
    private static let maximumIncrementBytes = 16 * 1_024 * 1_024

    private let paths: ClaudePaths
    private let tailParser: ClaudeTranscriptTailParser
    private let discoveryInterval: TimeInterval
    private let lookback: TimeInterval

    private var transcriptURLsBySession: [String: URL] = [:]
    private var lastDiscoveryAt: Date = .distantPast
    private var cachedTranscripts: [URL: CachedTranscript] = [:]

    init(
        paths: ClaudePaths,
        tailParser: ClaudeTranscriptTailParser = ClaudeTranscriptTailParser(),
        discoveryInterval: TimeInterval = 5,
        lookback: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.paths = paths
        self.tailParser = tailParser
        self.discoveryInterval = discoveryInterval
        self.lookback = lookback
    }

    func loadTasks(
        liveSessionIDs: Set<String>,
        now: Date
    ) throws -> ClaudeTaskReadResult {
        guard FileManager.default.fileExists(atPath: paths.projectsDirectory.path) else {
            throw DataAdapterError.missingFile(paths.projectsDirectory)
        }

        if now.timeIntervalSince(lastDiscoveryAt) >= discoveryInterval
            || liveSessionIDs.contains(where: { transcriptURLsBySession[$0] == nil })
        {
            transcriptURLsBySession = discoverTranscripts(now: now)
            lastDiscoveryAt = now
        }

        var records: [ClaudeTranscriptTaskRecord] = []
        var invalidFileCount = 0
        var missingTranscriptCount = 0

        for (sessionID, url) in transcriptURLsBySession {
            guard let stamp = ClaudeFileStamp(path: url.path) else {
                if liveSessionIDs.contains(sessionID) { missingTranscriptCount += 1 }
                continue
            }

            let cached: CachedTranscript
            if let existing = cachedTranscripts[url], existing.stamp == stamp {
                cached = existing
            } else if let existing = cachedTranscripts[url],
                      !stamp.isRewrite(comparedTo: existing.stamp),
                      stamp.size > existing.stamp.size
            {
                cached = appendingRead(
                    url: url,
                    stamp: stamp,
                    existing: existing,
                    sessionID: sessionID,
                    now: now
                )
            } else {
                // Either the first sighting, or the file was replaced or
                // truncated. Resuming from a stored offset would misread the
                // new contents, so the fold restarts from a bounded tail.
                cached = coldRead(url: url, stamp: stamp, sessionID: sessionID, now: now)
            }
            cachedTranscripts[url] = cached

            if cached.wasInvalid {
                invalidFileCount += 1
                continue
            }
            guard let status = tailParser.reevaluate(
                sessionID: sessionID,
                fold: cached.fold,
                now: now
            ) else {
                continue
            }

            records.append(ClaudeTranscriptTaskRecord(
                sessionID: sessionID,
                transcriptURL: url,
                status: status,
                tokens: cached.fold.tokens
            ))
        }

        pruneCache()

        return ClaudeTaskReadResult(
            records: records,
            invalidFileCount: invalidFileCount,
            missingTranscriptCount: missingTranscriptCount
        )
    }

    // MARK: - Reading

    private func appendingRead(
        url: URL,
        stamp: ClaudeFileStamp,
        existing: CachedTranscript,
        sessionID: String,
        now: Date
    ) -> CachedTranscript {
        let growth = stamp.size - existing.readOffset
        let offset = growth <= Self.maximumIncrementBytes
            ? existing.readOffset
            : max(existing.readOffset, stamp.size - Self.resyncTailBytes)

        do {
            let appended = try read(url: url, from: offset)
            var fold = existing.fold
            if offset != existing.readOffset {
                // A skipped span means the carried partial line no longer
                // adjoins what follows it.
                fold.carryOver = Data()
            }
            let folded = tailParser.parse(
                sessionID: sessionID,
                appended: appended,
                fold: fold,
                now: now
            )
            return CachedTranscript(
                stamp: stamp,
                readOffset: stamp.size,
                fold: folded.fold,
                wasInvalid: false
            )
        } catch {
            // Keep what was already folded; a transient read failure is not
            // evidence about the session.
            return CachedTranscript(
                stamp: existing.stamp,
                readOffset: existing.readOffset,
                fold: existing.fold,
                wasInvalid: false
            )
        }
    }

    private func coldRead(
        url: URL,
        stamp: ClaudeFileStamp,
        sessionID: String,
        now: Date
    ) -> CachedTranscript {
        let offset = max(0, stamp.size - Self.resyncTailBytes)
        do {
            var data = try read(url: url, from: offset)
            if offset > 0, let newline = data.firstIndex(of: 0x0A) {
                // The window almost certainly starts mid-record.
                data = Data(data[data.index(after: newline)...])
            }
            let folded = tailParser.parse(
                sessionID: sessionID,
                appended: data,
                fold: ClaudeTranscriptFold(),
                now: now
            )
            return CachedTranscript(
                stamp: stamp,
                readOffset: stamp.size,
                fold: folded.fold,
                wasInvalid: false
            )
        } catch {
            return CachedTranscript(
                stamp: stamp,
                readOffset: 0,
                fold: ClaudeTranscriptFold(),
                wasInvalid: true
            )
        }
    }

    private func read(url: URL, from offset: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(max(0, offset)))
        return try file.readToEnd() ?? Data()
    }

    // MARK: - Discovery

    /// Maps session identifiers to transcripts without decoding directory names.
    ///
    /// A project directory name is a lossy encoding of a working directory —
    /// separators, underscores, dots, and literal dashes all collapse to the
    /// same character — so it can never be inverted. Enumerating instead makes
    /// the mapping exact, and the same pass also finds sessions whose process
    /// has already exited.
    private func discoverTranscripts(now: Date) -> [String: URL] {
        let fileManager = FileManager.default
        let projectDirectories = (try? fileManager.contentsOfDirectory(
            at: paths.projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var discovered: [String: URL] = [:]
        let cutoff = now.addingTimeInterval(-lookback)

        for projectDirectory in projectDirectories {
            let contents = (try? fileManager.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in contents where url.pathExtension == "jsonl" {
                let sessionID = url.deletingPathExtension().lastPathComponent
                guard ClaudeDeepLink.isValidSessionIdentifier(sessionID) else { continue }

                let modifiedAt = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate ?? .distantPast
                guard modifiedAt >= cutoff else { continue }

                // Two project directories can hold the same session only if a
                // session moved; the most recently written wins.
                if let existing = discovered[sessionID],
                   let existingModified = try? existing.resourceValues(
                       forKeys: [.contentModificationDateKey]
                   ).contentModificationDate,
                   existingModified >= modifiedAt
                {
                    continue
                }
                discovered[sessionID] = url
            }
        }
        return discovered
    }

    private func pruneCache() {
        let live = Set(transcriptURLsBySession.values)
        cachedTranscripts = cachedTranscripts.filter { live.contains($0.key) }
    }
}
