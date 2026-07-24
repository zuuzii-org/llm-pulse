import Foundation

actor PluginEventJournalReader {
    private struct Accumulator {
        var projectDirectory = ""
        var turnId: String?
        var state: PulseTaskState?
        var startedAt: Date?
        var updatedAt: Date?
        var completedAt: Date?
        var lastStatus = ""
    }

    private let journalURL: URL
    private let maximumBytes: Int
    private let maximumEventAge: TimeInterval
    private var cachedFileSize: Int?
    private var cachedModificationDate: Date?
    private var cachedResult: PluginJournalReadResult?

    init(
        journalURL: URL,
        maximumBytes: Int = 8 * 1_024 * 1_024,
        maximumEventAge: TimeInterval = 24 * 60 * 60
    ) {
        self.journalURL = journalURL
        self.maximumBytes = maximumBytes
        self.maximumEventAge = maximumEventAge
    }

    func load(now: Date = .now) throws -> PluginJournalReadResult {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw DataAdapterError.missingFile(journalURL)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast

        if cachedFileSize == fileSize,
           cachedModificationDate == modificationDate,
           let cachedResult
        {
            return PluginJournalReadResult(
                records: cachedResult.records.filter {
                    now.timeIntervalSince($0.status.updatedAt) <= maximumEventAge
                },
                invalidLineCount: cachedResult.invalidLineCount
            )
        }

        let data = try readTail(fileSize: fileSize)
        var accumulators: [String: Accumulator] = [:]
        var invalidLineCount = 0
        let supportedEvents: Set<String> = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "Stop",
        ]

        data.enumerateJSONLines { object in
            guard
                let sessionId = JSONValueSupport.string(object["session_id"]),
                let eventName = JSONValueSupport.string(object["hook_event_name"]),
                supportedEvents.contains(eventName),
                let timestamp = JSONValueSupport.date(object["timestamp"])
            else {
                invalidLineCount += 1
                return
            }

            // Only the four fields the plugin is allowed to write are read.
            // `Plugin/hooks/record_event.js` builds each record from a closed
            // whitelist — session_id, turn_id, hook_event_name, timestamp —
            // so reading anything else would claim a wider contract than the
            // writer can honour, and would quietly accept a project path from
            // a journal the privacy notice promises never carries one.
            var accumulator = accumulators[sessionId] ?? Accumulator()
            if let turnId = JSONValueSupport.string(object["turn_id"]) {
                accumulator.turnId = turnId
            }

            switch eventName {
            case "SessionStart":
                break

            case "UserPromptSubmit":
                accumulator.state = .running
                accumulator.startedAt = timestamp
                accumulator.updatedAt = timestamp
                accumulator.completedAt = nil
                accumulator.lastStatus = "running"

            case "PreToolUse", "PostToolUse":
                accumulator.state = .running
                accumulator.startedAt = accumulator.startedAt ?? timestamp
                accumulator.updatedAt = timestamp
                accumulator.completedAt = nil
                accumulator.lastStatus = "running"

            case "PermissionRequest":
                accumulator.state = .waitingForApproval
                accumulator.startedAt = accumulator.startedAt ?? timestamp
                accumulator.updatedAt = timestamp
                accumulator.completedAt = nil
                accumulator.lastStatus = "waitingForApproval"

            case "Stop":
                accumulator.state = .running
                accumulator.startedAt = accumulator.startedAt ?? timestamp
                accumulator.updatedAt = timestamp
                accumulator.completedAt = nil
                accumulator.lastStatus = "finalizing"

            default:
                break
            }
            accumulators[sessionId] = accumulator
        }

        let records = accumulators.compactMap { threadId, value -> JournalTaskRecord? in
            guard
                let state = value.state,
                let startedAt = value.startedAt,
                let updatedAt = value.updatedAt,
                now.timeIntervalSince(updatedAt) <= maximumEventAge
            else {
                return nil
            }

            return JournalTaskRecord(
                threadId: threadId,
                projectDirectory: value.projectDirectory,
                status: TaskStatusRecord(
                    threadId: threadId,
                    turnId: value.turnId,
                    state: state,
                    startedAt: startedAt,
                    updatedAt: updatedAt,
                    completedAt: value.completedAt,
                    lastStatus: value.lastStatus
                )
            )
        }

        let result = PluginJournalReadResult(
            records: records,
            invalidLineCount: invalidLineCount
        )
        cachedFileSize = fileSize
        cachedModificationDate = modificationDate
        cachedResult = result
        return result
    }

    private func readTail(fileSize: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: journalURL)
        defer { try? file.close() }

        let offset = max(0, fileSize - maximumBytes)
        try file.seek(toOffset: UInt64(offset))
        let data = try file.readToEnd() ?? Data()
        guard offset > 0, let firstNewline = data.firstIndex(of: 0x0A) else {
            return data
        }
        return Data(data[data.index(after: firstNewline)...])
    }
}
