import Foundation
import XCTest
@testable import LLMPulse

/// Cover for the transcript state machine and its privacy contract.
final class ClaudeTranscriptTailParserTests: XCTestCase {
    private let parser = ClaudeTranscriptTailParser(idleGrace: 90)
    private let base = Date(timeIntervalSince1970: 1_784_918_000)
    private let sessionID = "86343497-3a6c-4bc3-84ba-3383c8b5696a"

    // MARK: - State

    func testRecentActivityWithNothingPendingStillReportsRunning() throws {
        let result = try fold([
            record("user", at: base),
            assistant(at: base.addingTimeInterval(5), stopReason: "end_turn"),
        ], now: base.addingTimeInterval(30))

        XCTAssertEqual(
            result.status?.state,
            .running,
            "A whole message is flushed only once it completes, so silence "
                + "shorter than the grace period is not evidence of an end."
        )
    }

    func testSilenceBeyondTheGracePeriodSettlesToCompleted() throws {
        let result = try fold([
            record("user", at: base),
            assistant(at: base.addingTimeInterval(5), stopReason: "end_turn"),
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(result.status?.state, .completed)
        XCTAssertEqual(result.status?.completedAt, base.addingTimeInterval(5))
    }

    func testATrailingToolUseStopReasonStillCompletes() throws {
        // Claude's own resume classifier treats any trailing assistant record
        // as a finished turn, regardless of why it stopped.
        let result = try fold([
            record("user", at: base),
            assistant(at: base.addingTimeInterval(1), stopReason: "tool_use"),
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(result.status?.state, .completed)
    }

    func testAnUnresolvedToolUseKeepsTheTaskRunning() throws {
        let result = try fold([
            record("user", at: base),
            assistant(
                at: base.addingTimeInterval(1),
                stopReason: "tool_use",
                content: [toolUse(id: "tool-1", name: "Bash")]
            ),
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(
            result.status?.state,
            .running,
            "A pending permission dialog and a long Bash are identical here."
        )
    }

    func testAResolvedToolUseReleasesTheTask() throws {
        let result = try fold([
            record("user", at: base),
            assistant(
                at: base.addingTimeInterval(1),
                stopReason: "tool_use",
                content: [toolUse(id: "tool-1", name: "Bash")]
            ),
            userMessage(
                at: base.addingTimeInterval(2),
                content: [toolResult(id: "tool-1")]
            ),
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(result.status?.state, .completed)
    }

    func testAPendingQuestionReportsWaitingForAnAnswer() throws {
        let result = try fold([
            assistant(
                at: base,
                stopReason: "tool_use",
                content: [toolUse(id: "ask-1", name: "AskUserQuestion")]
            ),
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(result.status?.state, .waitingForAnswer)
    }

    func testAPendingPlanApprovalReportsWaitingForApproval() throws {
        let result = try fold([
            assistant(
                at: base,
                stopReason: "tool_use",
                content: [toolUse(id: "plan-1", name: "ExitPlanMode")]
            ),
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(result.status?.state, .waitingForApproval)
    }

    func testAQueuedPromptKeepsTheTaskRunning() throws {
        let result = try fold([
            record("user", at: base),
            assistant(at: base.addingTimeInterval(1), stopReason: "end_turn"),
            ["type": "queue-operation", "operation": "enqueue", "content": "next"],
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(result.status?.state, .running)
    }

    func testAnApiErrorReportsFailure() throws {
        let result = try fold([
            record("user", at: base),
            [
                "type": "assistant",
                "timestamp": iso(base.addingTimeInterval(1)),
                "isApiErrorMessage": true,
                "message": ["role": "assistant", "content": []] as [String: Any],
            ],
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(result.status?.state, .failed)
    }

    func testSidechainRecordsDoNotHoldTheRootTaskOpen() throws {
        let result = try fold([
            record("user", at: base),
            assistant(at: base.addingTimeInterval(1), stopReason: "end_turn"),
            // A subagent's own turn, which finishes independently.
            [
                "type": "assistant",
                "timestamp": iso(base.addingTimeInterval(2)),
                "isSidechain": true,
                "message": [
                    "role": "assistant",
                    "content": [toolUse(id: "sub-1", name: "Read")],
                ] as [String: Any],
            ],
        ], now: base.addingTimeInterval(600))

        XCTAssertEqual(
            result.status?.state,
            .completed,
            "Otherwise every session that ever spawned an agent stays running."
        )
    }

    func testActivityUsesTheLatestTimestampNotTheLastLine() throws {
        // Timestamps step backwards in real transcripts.
        let result = try fold([
            record("user", at: base),
            assistant(at: base.addingTimeInterval(120), stopReason: "end_turn"),
            assistant(at: base.addingTimeInterval(5), stopReason: "end_turn"),
        ], now: base.addingTimeInterval(150))

        XCTAssertEqual(result.status?.state, .running)
        XCTAssertEqual(result.status?.updatedAt, base.addingTimeInterval(120))
    }

    // MARK: - Tokens

    func testRepeatedMessageIdentifiersAreNotDoubleCounted() throws {
        // One assistant message is written once per content block, each repeat
        // carrying a larger cumulative output count.
        let result = try fold([
            assistant(at: base, stopReason: nil, usage: usage(input: 100, output: 10)),
            assistant(
                at: base.addingTimeInterval(1),
                stopReason: nil,
                usage: usage(input: 100, output: 40)
            ),
            assistant(
                at: base.addingTimeInterval(2),
                stopReason: "end_turn",
                usage: usage(input: 100, output: 90)
            ),
        ], now: base.addingTimeInterval(600))

        let tokens = try XCTUnwrap(result.fold.tokens.snapshot)
        XCTAssertEqual(tokens.inputTokens, 100)
        XCTAssertEqual(tokens.outputTokens, 90)
        XCTAssertEqual(tokens.totalTokens, 190, "Summing every record inflates this.")
    }

    func testDistinctMessagesAccumulate() throws {
        let result = try fold([
            assistant(
                at: base,
                stopReason: "end_turn",
                usage: usage(input: 100, output: 10),
                messageID: "msg-a"
            ),
            assistant(
                at: base.addingTimeInterval(1),
                stopReason: "end_turn",
                usage: usage(input: 50, output: 5),
                messageID: "msg-b"
            ),
        ], now: base.addingTimeInterval(600))

        let tokens = try XCTUnwrap(result.fold.tokens.snapshot)
        XCTAssertEqual(tokens.inputTokens, 150)
        XCTAssertEqual(tokens.outputTokens, 15)
    }

    func testCachedInputIsReportedAsASubsetOfInput() throws {
        let result = try fold([
            assistant(
                at: base,
                stopReason: "end_turn",
                usage: [
                    "input_tokens": 2,
                    "cache_creation_input_tokens": 300,
                    "cache_read_input_tokens": 700,
                    "output_tokens": 40,
                ]
            ),
        ], now: base.addingTimeInterval(600))

        let tokens = try XCTUnwrap(result.fold.tokens.snapshot)
        XCTAssertEqual(tokens.inputTokens, 1_002, "Matches Codex: cache is inside input.")
        XCTAssertEqual(tokens.cachedInputTokens, 700)
        XCTAssertEqual(tokens.totalTokens, 1_042)
    }

    // MARK: - Incremental reading

    func testFoldingInChunksMatchesFoldingAtOnce() throws {
        let records = [
            record("user", at: base),
            assistant(
                at: base.addingTimeInterval(1),
                stopReason: "tool_use",
                content: [toolUse(id: "tool-1", name: "Bash")],
                usage: usage(input: 100, output: 10)
            ),
            userMessage(
                at: base.addingTimeInterval(2),
                content: [toolResult(id: "tool-1")]
            ),
            assistant(
                at: base.addingTimeInterval(3),
                stopReason: "end_turn",
                usage: usage(input: 120, output: 30),
                messageID: "msg-b"
            ),
        ]
        let whole = try jsonLines(records)
        let now = base.addingTimeInterval(600)

        let atOnce = parser.parse(
            sessionID: sessionID,
            appended: whole,
            fold: ClaudeTranscriptFold(),
            now: now
        )

        // Split at every byte, including mid-record, to prove the carry-over
        // reassembles lines that arrive in pieces.
        for splitPoint in stride(from: 1, to: whole.count, by: 37) {
            var incremental = parser.parse(
                sessionID: sessionID,
                appended: Data(whole.prefix(splitPoint)),
                fold: ClaudeTranscriptFold(),
                now: now
            )
            incremental = parser.parse(
                sessionID: sessionID,
                appended: Data(whole.dropFirst(splitPoint)),
                fold: incremental.fold,
                now: now
            )

            XCTAssertEqual(
                incremental.status?.state,
                atOnce.status?.state,
                "Split at \(splitPoint)"
            )
            XCTAssertEqual(
                incremental.fold.tokens.snapshot?.totalTokens,
                atOnce.fold.tokens.snapshot?.totalTokens,
                "Split at \(splitPoint)"
            )
        }
    }

    func testReevaluateCrossesTheGracePeriodWithoutReadingBytes() throws {
        let result = try fold([
            record("user", at: base),
            assistant(at: base.addingTimeInterval(1), stopReason: "end_turn"),
        ], now: base.addingTimeInterval(10))
        XCTAssertEqual(result.status?.state, .running)

        let later = parser.reevaluate(
            sessionID: sessionID,
            fold: result.fold,
            now: base.addingTimeInterval(600)
        )
        XCTAssertEqual(later?.state, .completed)
    }

    func testATranscriptWithNoTimestampedRecordsYieldsNoStatus() throws {
        let result = try fold([
            ["type": "custom-title", "customTitle": "New session"],
        ], now: base)

        XCTAssertNil(result.status, "Nothing here says a task ever ran.")
    }

    // MARK: - Privacy

    func testNoTranscriptProseIsCarriedOnTheFold() throws {
        let secret = "CANARY-c3f0a1-user-prose"
        let result = try fold([
            [
                "type": "user",
                "timestamp": iso(base),
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": secret]],
                ] as [String: Any],
            ],
            [
                "type": "assistant",
                "timestamp": iso(base.addingTimeInterval(1)),
                "message": [
                    "role": "assistant",
                    "id": "msg-a",
                    "stop_reason": "tool_use",
                    "content": [
                        ["type": "thinking", "thinking": secret],
                        ["type": "text", "text": secret],
                        [
                            "type": "tool_use",
                            "id": "tool-1",
                            "name": "Bash",
                            "input": ["command": secret],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ],
            [
                "type": "user",
                "timestamp": iso(base.addingTimeInterval(2)),
                "message": [
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": "tool-1",
                        "content": secret,
                    ]],
                ] as [String: Any],
            ],
        ], now: base.addingTimeInterval(600))

        let described = String(describing: result.fold)
            + String(describing: result.status)
        XCTAssertFalse(
            described.contains(secret),
            "Prompts, thinking, tool input, and tool output must not survive "
                + "the fold in any form."
        )
        XCTAssertEqual(result.status?.state, .completed)
    }

    func testTheParsedFieldListStaysAClosedSet() {
        // The privacy statement is only meaningful if the field list is the
        // real one, so it is enumerated rather than described in prose.
        let fields = Set(ClaudeTranscriptTailParser.ParsedField.allCases.map(\.rawValue))

        for forbidden in ["text", "thinking", "input", "command", "customTitle", "lastPrompt"] {
            XCTAssertFalse(
                fields.contains(forbidden),
                "\(forbidden) carries user or model prose."
            )
        }
        XCTAssertTrue(fields.contains("usage"))
        XCTAssertTrue(fields.contains("tool_use_id"))
    }

    // MARK: - Fixtures

    private func fold(
        _ records: [[String: Any]],
        now: Date
    ) throws -> (fold: ClaudeTranscriptFold, status: TaskStatusRecord?) {
        parser.parse(
            sessionID: sessionID,
            appended: try jsonLines(records),
            fold: ClaudeTranscriptFold(),
            now: now
        )
    }

    private func jsonLines(_ records: [[String: Any]]) throws -> Data {
        try records.reduce(into: Data()) { result, record in
            result.append(try JSONSerialization.data(withJSONObject: record))
            result.append(0x0A)
        }
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func record(_ type: String, at date: Date) -> [String: Any] {
        ["type": type, "timestamp": iso(date)]
    }

    private func assistant(
        at date: Date,
        stopReason: String?,
        content: [[String: Any]] = [],
        usage: [String: Any]? = nil,
        messageID: String = "msg-a"
    ) -> [String: Any] {
        var message: [String: Any] = [
            "role": "assistant",
            "id": messageID,
            "content": content,
        ]
        if let stopReason { message["stop_reason"] = stopReason }
        if let usage { message["usage"] = usage }
        return ["type": "assistant", "timestamp": iso(date), "message": message]
    }

    private func userMessage(at date: Date, content: [[String: Any]]) -> [String: Any] {
        [
            "type": "user",
            "timestamp": iso(date),
            "message": ["role": "user", "content": content] as [String: Any],
        ]
    }

    private func toolUse(id: String, name: String) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": [:] as [String: Any]]
    }

    private func toolResult(id: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": "ok"]
    }

    private func usage(input: Int, output: Int) -> [String: Any] {
        [
            "input_tokens": input,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
            "output_tokens": output,
        ]
    }
}
