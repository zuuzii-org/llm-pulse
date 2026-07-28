import Foundation

/// Folds appended transcript bytes into a task state.
///
/// Pure and incremental, mirroring `RolloutJSONLTailParser`: every call takes
/// the fold carried from the previous poll plus only the bytes that arrived
/// since, and returns the new fold. Nothing is ever recomputed from a bounded
/// window, because a window can drop an opening record while keeping its
/// closing one — pending tool uses and queued prompts would both under-count.
///
/// **Privacy.** Only the fields listed in `ParsedField` are read out of a
/// record. Message text, thinking blocks, tool inputs, and tool outputs are
/// never copied out of the decoded line, never stored on the fold, and never
/// reach `PulseTask`. This matches how `RolloutJSONLTailParser` already treats
/// Codex rollouts, which carry the same kind of content.
struct ClaudeTranscriptTailParser: Sendable {
    /// The complete set of fields this parser reads. Named so the privacy
    /// contract is testable rather than merely asserted.
    enum ParsedField: String, CaseIterable, Sendable {
        case type
        case timestamp
        case sessionId
        case isSidechain
        case isMeta
        case operation
        case subtype
        case preventedContinuation
        case isApiErrorMessage
        case message
        case id
        case role
        case usage
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case content
        case contentType = "content.type"
        case name
        case toolUseID = "tool_use_id"
        case isError = "is_error"
        case customTitle
        case aiTitle
    }

    /// Tool names that change what the row says rather than just keeping it
    /// running.
    private static let questionToolNames: Set<String> = ["AskUserQuestion"]
    private static let approvalToolNames: Set<String> = ["ExitPlanMode"]

    /// A turn stays "running" through silence this long.
    ///
    /// An assistant message is flushed only once it is complete, so a single
    /// long tool call leaves the file untouched for a stretch. Anything
    /// shorter makes a working session flicker between completed and running
    /// mid-message.
    private let idleGrace: TimeInterval

    /// Bound on the unresolved-tool set. Past this the set stops being
    /// trusted rather than growing without limit.
    private let maximumPendingToolUses: Int

    init(
        idleGrace: TimeInterval = 90,
        maximumPendingToolUses: Int = 512
    ) {
        self.idleGrace = idleGrace
        self.maximumPendingToolUses = maximumPendingToolUses
    }

    /// Folds `appended` into `fold` and derives the resulting state.
    func parse(
        sessionID: String,
        appended: Data,
        fold: ClaudeTranscriptFold,
        now: Date
    ) -> (fold: ClaudeTranscriptFold, status: TaskStatusRecord?) {
        var fold = fold
        var pending = fold.carryOver
        pending.append(appended)

        // A chunk almost never ends on a line boundary. The remainder is held
        // for the next poll instead of being parsed as a truncated record.
        let lastNewline = pending.lastIndex(of: 0x0A)
        let completeLines: Data
        if let lastNewline {
            completeLines = Data(pending[pending.startIndex...lastNewline])
            fold.carryOver = Data(pending[pending.index(after: lastNewline)...])
        } else {
            completeLines = Data()
            fold.carryOver = pending
        }

        completeLines.enumerateJSONLines { object in
            apply(object, to: &fold)
        }

        return (fold, status(for: sessionID, fold: fold, now: now))
    }

    /// Re-derives state without reading bytes.
    ///
    /// This is what lets an untouched transcript cross `idleGrace` and settle
    /// into `.completed` at zero I/O cost.
    func reevaluate(
        sessionID: String,
        fold: ClaudeTranscriptFold,
        now: Date
    ) -> TaskStatusRecord? {
        status(for: sessionID, fold: fold, now: now)
    }

    // MARK: - Folding

    private func apply(_ object: [String: Any], to fold: inout ClaudeTranscriptFold) {
        guard let rawType = JSONValueSupport.string(object["type"]) else { return }

        // Sidechain records belong to a subagent's turn, not the root task.
        // Counting their tool uses would leave the root permanently mid-turn.
        if object["isSidechain"] as? Bool == true { return }

        let timestamp = JSONValueSupport.date(object["timestamp"])
        if let timestamp {
            fold.startedAt = fold.startedAt.map { min($0, timestamp) } ?? timestamp
            // Timestamps are not monotonic in practice, so activity is the
            // maximum seen rather than the most recent line's value.
            fold.latestActivityAt = fold.latestActivityAt.map { max($0, timestamp) }
                ?? timestamp
        }

        guard let kind = ClaudeRecordKind(rawValue: rawType) else { return }
        if timestamp != nil || kind == .queueOperation {
            fold.lastRecordKind = kind
        }

        switch kind {
        case .queueOperation:
            switch JSONValueSupport.string(object["operation"]) {
            case "enqueue":
                fold.queuedPromptCount += 1
            case "dequeue", "remove":
                fold.queuedPromptCount = max(0, fold.queuedPromptCount - 1)
            default:
                break
            }

        case .assistant:
            fold.isInterrupted = false
            if object["isApiErrorMessage"] as? Bool == true {
                fold.isFailed = true
            } else {
                fold.isFailed = false
            }
            applyMessage(object["message"], to: &fold)

        case .user:
            // Injected reminders carry no `origin` and must not look like a
            // person having typed something.
            if object["isMeta"] as? Bool == true { return }
            applyMessage(object["message"], to: &fold)

        case .system:
            if object["preventedContinuation"] as? Bool == true {
                fold.isFailed = true
            }

        case .customTitle:
            if let title = JSONValueSupport.string(object["customTitle"]) {
                fold.customTitle = Self.sanitizedTitle(title)
            }

        case .generatedTitle:
            if let title = JSONValueSupport.string(object["aiTitle"]) {
                fold.generatedTitle = Self.sanitizedTitle(title)
            }

        case .attachment:
            break
        }
    }

    /// Bounds a title and rejects one that is only whitespace.
    ///
    /// These are short labels by construction, but nothing enforces that on
    /// disk and the value goes straight into a row.
    private static func sanitizedTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(120))
    }

    private func applyMessage(_ raw: Any?, to fold: inout ClaudeTranscriptFold) {
        guard let message = raw as? [String: Any] else { return }

        if let usage = message["usage"] as? [String: Any] {
            fold.tokens.apply(
                messageID: JSONValueSupport.string(message["id"]),
                promptTokens: JSONValueSupport.int(usage["input_tokens"]) ?? 0,
                cacheCreationTokens: JSONValueSupport
                    .int(usage["cache_creation_input_tokens"]) ?? 0,
                cacheReadTokens: JSONValueSupport
                    .int(usage["cache_read_input_tokens"]) ?? 0,
                outputTokens: JSONValueSupport.int(usage["output_tokens"]) ?? 0
            )
        }

        guard let content = message["content"] as? [[String: Any]] else { return }
        for block in content {
            switch JSONValueSupport.string(block["type"]) {
            case "tool_use":
                guard let identifier = JSONValueSupport.string(block["id"]) else { continue }
                guard fold.pendingToolUseIDs.count < maximumPendingToolUses else {
                    fold.pendingToolUsesOverflowed = true
                    continue
                }
                fold.pendingToolUseIDs.insert(identifier)
                let name = JSONValueSupport.string(block["name"]) ?? ""
                if Self.questionToolNames.contains(name) {
                    fold.pendingQuestionToolUseIDs.insert(identifier)
                } else if Self.approvalToolNames.contains(name) {
                    fold.pendingApprovalToolUseIDs.insert(identifier)
                }

            case "tool_result":
                guard let identifier = JSONValueSupport.string(block["tool_use_id"]) else {
                    continue
                }
                fold.pendingToolUseIDs.remove(identifier)
                fold.pendingQuestionToolUseIDs.remove(identifier)
                fold.pendingApprovalToolUseIDs.remove(identifier)

            default:
                continue
            }
        }
    }

    // MARK: - State

    private func status(
        for sessionID: String,
        fold: ClaudeTranscriptFold,
        now: Date
    ) -> TaskStatusRecord? {
        guard let latestActivityAt = fold.latestActivityAt else { return nil }
        let startedAt = fold.startedAt ?? latestActivityAt

        let state: PulseTaskState
        if fold.isInterrupted {
            state = .interrupted
        } else if fold.isFailed {
            state = .failed
        } else if !fold.pendingQuestionToolUseIDs.isEmpty {
            state = .waitingForAnswer
        } else if !fold.pendingApprovalToolUseIDs.isEmpty {
            state = .waitingForApproval
        } else if !fold.pendingToolUseIDs.isEmpty && !fold.pendingToolUsesOverflowed {
            // A pending permission dialog and a long-running tool are
            // byte-identical here: nothing is written while a dialog is open.
            // Reporting the work as running is the safe direction.
            state = .running
        } else if fold.queuedPromptCount > 0 {
            state = .running
        } else if now.timeIntervalSince(latestActivityAt) < idleGrace {
            state = .running
        } else {
            state = .completed
        }

        return TaskStatusRecord(
            threadId: sessionID,
            turnId: nil,
            state: state,
            startedAt: startedAt,
            updatedAt: latestActivityAt,
            completedAt: state.isTerminal ? latestActivityAt : nil,
            lastStatus: state.rawValue,
            latestActivityAt: latestActivityAt
        )
    }
}
