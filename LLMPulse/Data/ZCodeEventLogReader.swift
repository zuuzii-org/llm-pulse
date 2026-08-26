import Foundation

/// Whitelist parser for ZCode's structured event log.
///
/// The log also carries diagnostic messages, errors, and arbitrary context.
/// `Decodable` types below intentionally have no fields for those values, so
/// this adapter cannot surface prompts, tool payloads, or response text.
struct ZCodeEventLogReader: Sendable {
    private static let recognizedEvents: Set<String> = [
        "turn.started",
        "turn.completed",
        "turn.failed",
        "permission.requested",
        "permission.resolved",
        "permission.denied",
        "tool.permission.evaluated",
        "tool.permission.resolved",
        "tool.permission.denied",
        "subagent.spawned",
        "subagent.completed",
    ]

    private let maximumFileBytes: Int
    private let maximumLineBytes: Int

    init(
        maximumFileBytes: Int = 64 * 1_024 * 1_024,
        maximumLineBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumLineBytes = maximumLineBytes
    }

    func read(
        urls: [URL],
        rootSessionIDs: Set<String>
    ) throws -> ZCodeEventLogReadResult {
        var folds = Dictionary(
            uniqueKeysWithValues: rootSessionIDs.map { ($0, Fold()) }
        )
        var totalLineCount = 0
        var recognizedEventCount = 0
        var matchedRootEventCount = 0
        var invalidLineCount = 0
        var malformedRelevantEventCount = 0
        var stateAnomalySessionIDs: Set<String> = []
        var agentAnomalySessionIDs: Set<String> = []

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try readSourceFile(url)
            for line in completeLines(in: data) {
                guard !line.isEmpty else { continue }
                totalLineCount += 1
                guard line.count <= maximumLineBytes,
                      let envelope = try? JSONDecoder().decode(
                          Envelope.self,
                          from: Data(line)
                      )
                else {
                    invalidLineCount += 1
                    continue
                }
                guard let event = envelope.event,
                      Self.recognizedEvents.contains(event)
                else {
                    continue
                }
                recognizedEventCount += 1
                guard let sessionID = envelope.sessionId,
                      rootSessionIDs.contains(sessionID)
                else {
                    if envelope.sessionId == nil {
                        malformedRelevantEventCount += 1
                    }
                    continue
                }
                matchedRootEventCount += 1
                guard let timestamp = envelope.timestamp.flatMap(JSONValueSupport.date) else {
                    malformedRelevantEventCount += 1
                    Self.recordAnomaly(
                        event: event,
                        sessionID: sessionID,
                        stateAnomalies: &stateAnomalySessionIDs,
                        agentAnomalies: &agentAnomalySessionIDs
                    )
                    continue
                }
                guard folds[sessionID]?.apply(
                    event: event,
                    envelope: envelope,
                    timestamp: timestamp
                ) == true else {
                    malformedRelevantEventCount += 1
                    Self.recordAnomaly(
                        event: event,
                        sessionID: sessionID,
                        stateAnomalies: &stateAnomalySessionIDs,
                        agentAnomalies: &agentAnomalySessionIDs
                    )
                    continue
                }
            }
        }

        var observations: [String: ZCodeEventObservation] = [:]
        for (sessionID, fold) in folds {
            guard !stateAnomalySessionIDs.contains(sessionID),
                  let observation = fold.observation(
                      sessionID: sessionID,
                      agentActivityIsReliable: !agentAnomalySessionIDs.contains(sessionID)
                  )
            else {
                continue
            }
            observations[sessionID] = observation
        }
        return ZCodeEventLogReadResult(
            observations: observations,
            totalLineCount: totalLineCount,
            recognizedEventCount: recognizedEventCount,
            matchedRootEventCount: matchedRootEventCount,
            invalidLineCount: invalidLineCount,
            malformedRelevantEventCount: malformedRelevantEventCount
        )
    }

    private func readSourceFile(_ url: URL) throws -> Data {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw DataAdapterError.missingFile(url)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              status.st_size >= 0,
              status.st_size <= maximumFileBytes
        else {
            throw DataAdapterError.invalidFormat(
                url,
                "source type, owner, links, permissions, or size are unsafe"
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    /// The writer appends directly, so the final line may be mid-write. It is
    /// deferred to the next poll instead of being reported as corruption.
    private func completeLines(in data: Data) -> [Data.SubSequence] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if data.last != 0x0A, !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    private static func recordAnomaly(
        event: String,
        sessionID: String,
        stateAnomalies: inout Set<String>,
        agentAnomalies: inout Set<String>
    ) {
        if event.hasPrefix("subagent.") {
            agentAnomalies.insert(sessionID)
        } else {
            stateAnomalies.insert(sessionID)
        }
    }
}

private extension ZCodeEventLogReader {
    struct Envelope: Decodable {
        struct Context: Decodable {
            let agentId: String?
            let approvalId: String?
            let interactionId: String?
            let toolCallId: String?
            let decision: String?
        }

        let timestamp: String?
        let event: String?
        let status: String?
        let sessionId: String?
        let turnId: String?
        let toolCallId: String?
        let approvalId: String?
        let interactionId: String?
        let context: Context?

        var permissionID: String? {
            toolCallId
                ?? approvalId
                ?? interactionId
                ?? context?.toolCallId
                ?? context?.approvalId
                ?? context?.interactionId
        }
    }

    struct Fold {
        var state: PulseTaskState?
        var currentTurnID: String?
        var startedAt: Date?
        var updatedAt: Date?
        var completedAt: Date?
        var pendingPermissionIDs: Set<String> = []
        var activeAgentIDs: Set<String> = []

        mutating func apply(
            event: String,
            envelope: Envelope,
            timestamp: Date
        ) -> Bool {
            switch event {
            case "turn.started":
                guard let turnID = envelope.turnId else { return false }
                currentTurnID = turnID
                state = .running
                startedAt = timestamp
                updatedAt = timestamp
                completedAt = nil
                pendingPermissionIDs.removeAll()
                activeAgentIDs.removeAll()

            case "turn.completed":
                guard let turnID = envelope.turnId else { return false }
                currentTurnID = turnID
                state = .completed
                updatedAt = timestamp
                completedAt = timestamp
                pendingPermissionIDs.removeAll()
                activeAgentIDs.removeAll()

            case "turn.failed":
                guard let turnID = envelope.turnId else { return false }
                currentTurnID = turnID
                state = envelope.status?.lowercased() == "cancelled"
                    ? .interrupted
                    : .failed
                updatedAt = timestamp
                completedAt = timestamp
                pendingPermissionIDs.removeAll()
                activeAgentIDs.removeAll()

            case "permission.requested":
                return applyPermissionRequest(envelope: envelope, timestamp: timestamp)

            case "tool.permission.evaluated":
                guard let decision = envelope.context?.decision?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                    !decision.isEmpty
                else {
                    return false
                }
                guard decision == "ask" else { return true }
                guard envelope.status?.lowercased() == "waiting" else { return false }
                return applyPermissionRequest(envelope: envelope, timestamp: timestamp)

            case "permission.resolved", "permission.denied",
                 "tool.permission.resolved", "tool.permission.denied":
                guard let turnID = envelope.turnId,
                      let currentTurnID else {
                    return false
                }
                guard turnID == currentTurnID else { return true }
                guard state?.isTerminal != true else { return true }
                guard let permissionID = envelope.permissionID,
                      pendingPermissionIDs.remove(permissionID) != nil else {
                    return false
                }
                state = pendingPermissionIDs.isEmpty ? .running : .waitingForApproval
                startedAt = startedAt ?? timestamp
                updatedAt = timestamp
                completedAt = nil

            case "subagent.spawned":
                guard eventBelongsToCurrentTurn(envelope) else { return false }
                guard let agentID = envelope.context?.agentId else { return false }
                activeAgentIDs.insert(agentID)
                updatedAt = max(updatedAt ?? .distantPast, timestamp)

            case "subagent.completed":
                guard eventBelongsToCurrentTurn(envelope) else { return false }
                guard let agentID = envelope.context?.agentId else { return false }
                activeAgentIDs.remove(agentID)
                updatedAt = max(updatedAt ?? .distantPast, timestamp)

            default:
                return false
            }
            return true
        }

        private mutating func applyPermissionRequest(
            envelope: Envelope,
            timestamp: Date
        ) -> Bool {
            guard let turnID = envelope.turnId,
                  let currentTurnID else {
                return false
            }
            guard turnID == currentTurnID else { return true }
            guard state?.isTerminal != true else { return true }
            guard let permissionID = envelope.permissionID else { return false }
            pendingPermissionIDs.insert(permissionID)
            state = .waitingForApproval
            startedAt = startedAt ?? timestamp
            updatedAt = timestamp
            completedAt = nil
            return true
        }

        private func eventBelongsToCurrentTurn(_ envelope: Envelope) -> Bool {
            guard let turnID = envelope.turnId,
                  let currentTurnID else {
                return false
            }
            return turnID == currentTurnID
        }

        func observation(
            sessionID: String,
            agentActivityIsReliable: Bool
        ) -> ZCodeEventObservation? {
            guard let state, let updatedAt else { return nil }
            let effectiveStartedAt = startedAt ?? updatedAt
            let rootAgentCount = state.isTerminal ? 0 : 1
            return ZCodeEventObservation(
                status: TaskStatusRecord(
                    threadId: sessionID,
                    turnId: currentTurnID,
                    state: state,
                    startedAt: effectiveStartedAt,
                    updatedAt: updatedAt,
                    completedAt: state.isTerminal ? (completedAt ?? updatedAt) : nil,
                    lastStatus: state.rawValue,
                    latestActivityAt: updatedAt
                ),
                activeAgentCount: agentActivityIsReliable
                    ? rootAgentCount + activeAgentIDs.count
                    : nil,
                agentActivityConfidence: agentActivityIsReliable ? .exact : .unavailable
            )
        }
    }
}
