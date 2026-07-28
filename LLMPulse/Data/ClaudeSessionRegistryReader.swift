import Foundation

/// Reads `~/.claude/sessions/<pid>.json` and keeps only sessions still running.
///
/// The registry is the strongest evidence this adapter has: a session exists
/// exactly while its process does. Everything else — transcripts, sidecars —
/// outlives the process and can only ever describe the past.
struct ClaudeSessionRegistryReader: Sendable {
    /// A registry entry is a handful of short fields. Anything larger is not
    /// one, and is skipped before it is read into memory.
    private static let maximumFileBytes = 64 * 1_024

    private let sessionsDirectory: URL
    private let probe: any ClaudeProcessProbing

    init(
        sessionsDirectory: URL,
        probe: any ClaudeProcessProbing = LibprocProcessProbe()
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.probe = probe
    }

    func read() throws -> ClaudeSessionRegistryReadResult {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
            throw DataAdapterError.missingFile(sessionsDirectory)
        }

        let filenames = try FileManager.default.contentsOfDirectory(
            atPath: sessionsDirectory.path
        )

        var entries: [ClaudeSessionRegistryEntry] = []
        var unreadableFileCount = 0

        for filename in filenames {
            guard let processID = Self.processID(fromFilename: filename) else { continue }
            let url = sessionsDirectory.appendingPathComponent(filename)

            guard let stamp = ClaudeFileStamp(path: url.path),
                  stamp.size > 0,
                  stamp.size <= Self.maximumFileBytes,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let payload = object as? [String: Any]
            else {
                // The app rewrites these files in place, so a read can land
                // mid-write and come back empty. Reported, never treated as
                // the session having ended.
                unreadableFileCount += 1
                continue
            }

            guard let entry = Self.entry(
                from: payload,
                declaredProcessID: processID,
                probe: probe
            ) else {
                continue
            }
            entries.append(entry)
        }

        return ClaudeSessionRegistryReadResult(
            entries: entries.sorted { $0.startedAt > $1.startedAt },
            unreadableFileCount: unreadableFileCount
        )
    }

    private static func processID(fromFilename filename: String) -> Int32? {
        guard filename.hasSuffix(".json") else { return nil }
        let digits = filename.dropLast(".json".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int32(digits)
    }

    /// Slack for clock granularity between the two sources, not for the
    /// session-creation delay — that only moves the value the other way.
    private static let startTimeSkewTolerance: TimeInterval = 2

    private static func entry(
        from payload: [String: Any],
        declaredProcessID: Int32,
        probe: any ClaudeProcessProbing
    ) -> ClaudeSessionRegistryEntry? {
        guard let recordedProcessID = JSONValueSupport.int(payload["pid"]),
              Int32(exactly: recordedProcessID) == declaredProcessID,
              let sessionID = JSONValueSupport.string(payload["sessionId"]),
              !sessionID.isEmpty,
              let workingDirectory = JSONValueSupport.string(payload["cwd"]),
              !workingDirectory.isEmpty
        else {
            return nil
        }

        // Background and daemon sessions are out of scope; only what a person
        // is sitting in front of belongs in an attention monitor.
        let kind = JSONValueSupport.string(payload["kind"]) ?? "interactive"
        guard kind == "interactive" else { return nil }

        guard let facts = probe.facts(forProcessID: declaredProcessID),
              Self.isClaudeExecutable(facts.executablePath)
        else {
            return nil
        }

        // Process ids wrap under load, so a registry file left behind by a
        // crash can name a pid that now belongs to something else. Start
        // times rule that out — but only in one direction.
        //
        // A session is created after its process starts, never before, and
        // how long that takes varies with load: usually a fraction of a
        // second, but a cold start here took 2.1s, which a symmetric window
        // read as pid reuse and dropped a live session for. Resuming into an
        // existing process makes the gap larger still.
        //
        // Reuse has the opposite sign. A file written by a dead process
        // records when *that* process started, which necessarily predates the
        // younger process now holding the pid. So a recorded start earlier
        // than the running process is the thing to reject.
        if let recordedStart = JSONValueSupport.date(payload["startedAt"]),
           recordedStart.timeIntervalSince1970
            < Double(facts.startedAt) - Self.startTimeSkewTolerance
        {
            return nil
        }

        let startedAt = JSONValueSupport.date(payload["startedAt"])
            ?? Date(timeIntervalSince1970: Double(facts.startedAt))

        return ClaudeSessionRegistryEntry(
            processID: declaredProcessID,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            entrypoint: JSONValueSupport.string(payload["entrypoint"]),
            startedAt: startedAt,
            name: JSONValueSupport.string(payload["name"]),
            hasDerivedName: JSONValueSupport.string(payload["nameSource"]) == "derived"
        )
    }

    /// Matches the executable itself rather than the command line.
    ///
    /// A launcher that passes the Claude binary path as an *argument* looks
    /// identical under `ps`, so argument matching reports wrappers as
    /// sessions. `proc_pidpath` cannot be shaped that way.
    private static func isClaudeExecutable(_ path: String) -> Bool {
        path.hasSuffix("/claude.app/Contents/MacOS/claude")
            || path.hasSuffix("/bin/claude")
            || path.hasSuffix("/claude")
    }
}
