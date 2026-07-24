import Foundation

/// One live Claude Code session, as declared by `~/.claude/sessions/<pid>.json`.
struct ClaudeSessionRegistryEntry: Equatable, Sendable {
    let processID: Int32
    let sessionID: String
    let workingDirectory: String

    /// Present only for sessions the desktop app launched. Rows for other
    /// entrypoints are still shown, but must never be activated by deep link.
    let entrypoint: String?
    let startedAt: Date

    /// The session name the app derived or the user set. Shown as the row
    /// title, and the only free text this adapter reads — it is a label the
    /// app already displays, never conversation content.
    let name: String?

    var isDesktopEntrypoint: Bool {
        entrypoint == ClaudeDeepLink.desktopEntrypoint
    }
}

struct ClaudeSessionRegistryReadResult: Sendable {
    let entries: [ClaudeSessionRegistryEntry]

    /// Registry files that existed but could not be parsed this poll.
    ///
    /// The app rewrites these in place with no temp-and-rename, so a read
    /// landing mid-write comes back empty. That is not evidence a session
    /// ended, which is why the reader reports it separately instead of
    /// dropping the row.
    let unreadableFileCount: Int
}

/// Identity of a file's contents, used to skip work when nothing changed.
///
/// Device and inode are part of the key because a transcript can be replaced
/// rather than appended to, and a fresh file may reuse both a size and a
/// modification time.
struct ClaudeFileStamp: Equatable, Sendable {
    let deviceID: Int32
    let inode: UInt64
    let size: Int
    let modifiedAt: Date

    init?(path: String) {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        deviceID = status.st_dev
        inode = status.st_ino
        size = Int(status.st_size)
        modifiedAt = Date(
            timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
                + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    /// True when the file was replaced or truncated rather than appended to.
    func isRewrite(comparedTo previous: ClaudeFileStamp) -> Bool {
        deviceID != previous.deviceID
            || inode != previous.inode
            || size < previous.size
    }
}

/// Everything carried between polls so a transcript is never re-scanned.
///
/// The counters and identifier sets are folded forward from each appended
/// chunk. Recomputing them from a bounded tail would bias the result: a
/// window can lose an opening record while keeping its closing one.
struct ClaudeTranscriptFold: Equatable, Sendable {
    var startedAt: Date?
    var latestActivityAt: Date?
    var lastRecordKind: ClaudeRecordKind?

    /// Tool uses seen minus tool results seen. A non-empty set means the
    /// session is mid-turn.
    var pendingToolUseIDs: Set<String> = []

    /// Set when `pendingToolUseIDs` was capped, so callers stop trusting it.
    var pendingToolUsesOverflowed = false

    /// Names of unresolved tool uses, for the two that change the state.
    var pendingQuestionToolUseIDs: Set<String> = []
    var pendingApprovalToolUseIDs: Set<String> = []

    /// Prompts enqueued but not yet dequeued or removed.
    var queuedPromptCount = 0

    var tokens = ClaudeTokenFold()

    /// Bytes of a trailing partial line, prepended to the next chunk.
    var carryOver = Data()

    var isInterrupted = false
    var isFailed = false
}

/// Token totals folded incrementally, deduplicating by message id.
///
/// A single assistant message is written once per content block, and each
/// repeat carries a larger cumulative `output_tokens`. Summing every record
/// inflates the total severalfold, which looks entirely plausible on screen.
struct ClaudeTokenFold: Equatable, Sendable {
    /// Fresh input, excluding anything served from or written to the cache.
    var promptTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var outputTokens = 0

    /// Distinct assistant messages counted, not records seen.
    var requestCount = 0

    private var lastMessageID: String?
    private var lastPrompt = 0
    private var lastCacheCreation = 0
    private var lastCacheRead = 0
    private var lastOutput = 0

    /// Everything that counted as input, matching Codex's convention that
    /// cached tokens are a subset of input rather than a separate bucket.
    var inputTokens: Int { promptTokens + cacheCreationTokens + cacheReadTokens }
    var totalTokens: Int { inputTokens + outputTokens }

    /// Applies one assistant record's usage, replacing the previous
    /// contribution when the record repeats a message already counted.
    mutating func apply(
        messageID: String?,
        promptTokens newPrompt: Int,
        cacheCreationTokens newCacheCreation: Int,
        cacheReadTokens newCacheRead: Int,
        outputTokens newOutput: Int
    ) {
        if let messageID, messageID == lastMessageID {
            promptTokens += newPrompt - lastPrompt
            cacheCreationTokens += newCacheCreation - lastCacheCreation
            cacheReadTokens += newCacheRead - lastCacheRead
            outputTokens += newOutput - lastOutput
        } else {
            promptTokens += newPrompt
            cacheCreationTokens += newCacheCreation
            cacheReadTokens += newCacheRead
            outputTokens += newOutput
            requestCount += 1
        }
        lastMessageID = messageID
        lastPrompt = newPrompt
        lastCacheCreation = newCacheCreation
        lastCacheRead = newCacheRead
        lastOutput = newOutput
    }

    var snapshot: TokenUsageSnapshot? {
        guard totalTokens > 0 else { return nil }
        return TokenUsageSnapshot(
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            cachedInputTokens: cacheReadTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: nil
        )
    }
}

/// The record kinds that affect state. Everything else is skipped.
enum ClaudeRecordKind: String, Equatable, Sendable {
    case user
    case assistant
    case system
    case attachment
    case queueOperation = "queue-operation"
}

struct ClaudeTranscriptTaskRecord: Sendable {
    let sessionID: String
    let transcriptURL: URL
    let status: TaskStatusRecord

    /// The full fold rather than its compressed form, so a model-level total
    /// can keep the cache breakdown a `TokenUsageSnapshot` folds away.
    let tokens: ClaudeTokenFold

    var tokenUsage: TokenUsageSnapshot? { tokens.snapshot }
}

struct ClaudeTaskReadResult: Sendable {
    let records: [ClaudeTranscriptTaskRecord]
    let invalidFileCount: Int

    /// Live sessions whose transcript could not be located on disk.
    ///
    /// The registry proves the session exists, so finding no transcript for it
    /// means the layout moved rather than that nothing is running.
    let missingTranscriptCount: Int
}
