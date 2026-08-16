import Foundation

struct PulseTask: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let threadId: String
    let turnId: String?
    let identity: ModelIdentity
    let sessionID: String
    let title: String
    let projectDirectory: String
    let state: PulseTaskState
    let startedAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let lastStatus: String
    let isUnread: Bool
    let tokenUsage: TokenUsageSnapshot?
    let agentActivity: AgentActivityObservation?

    /// True when `.failed` was inferred from an error event followed by
    /// silence, rather than observed as a terminal event.
    ///
    /// Such a failure is reversible — an automatic retry writes again after
    /// its backoff and the task returns to `.running`. The interface may show
    /// it immediately, but anything that cannot be taken back must not act on
    /// it. See `RolloutJSONLTailParser.reevaluate(_:fileModificationDate:now:)`.
    let isProvisionalFailure: Bool

    /// Whether this row can be reopened by URL rather than by merely bringing
    /// its application forward.
    ///
    /// Not every session is safe to address directly. Resuming a Claude Code
    /// session that was started outside the desktop app rewrites its
    /// transcript in place, and a read-only monitor must not cause a
    /// destructive write because someone clicked a row.

    var profileID: ModelProfileID { identity.profileID }
    var runtime: AIRuntimeID { identity.runtime }
    var provider: AIProviderID { identity.provider }
    var modelID: String { identity.modelID }

    init(
        threadId: String,
        turnId: String? = nil,
        identity: ModelIdentity = .codex,
        sessionID: String? = nil,
        title: String,
        projectDirectory: String,
        state: PulseTaskState,
        startedAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        lastStatus: String,
        isUnread: Bool = false,
        tokenUsage: TokenUsageSnapshot? = nil,
        agentActivity: AgentActivityObservation? = nil,
        isProvisionalFailure: Bool = false,
    ) {
        self.threadId = threadId
        self.turnId = turnId
        self.identity = identity
        self.sessionID = sessionID ?? threadId
        id = identity.profileID == .codex
            ? Self.makeID(threadId: threadId, turnId: turnId)
            : Self.makeID(
                runtime: identity.runtime,
                sessionID: self.sessionID,
                turnId: turnId
            )
        self.title = title
        self.projectDirectory = projectDirectory
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastStatus = lastStatus
        self.isUnread = isUnread
        self.tokenUsage = tokenUsage
        self.agentActivity = agentActivity
        self.isProvisionalFailure = state == .failed && isProvisionalFailure
    }

    var workingDirectory: String { projectDirectory }
    var statusText: String { lastStatus }

    func duration(asOf date: Date = .now) -> TimeInterval {
        max(0, (completedAt ?? date).timeIntervalSince(startedAt))
    }

    func replacingUnread(with isUnread: Bool) -> PulseTask {
        PulseTask(
            threadId: threadId,
            turnId: turnId,
            identity: identity,
            sessionID: sessionID,
            title: title,
            projectDirectory: projectDirectory,
            state: state,
            startedAt: startedAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            lastStatus: lastStatus,
            isUnread: isUnread,
            tokenUsage: tokenUsage,
            agentActivity: agentActivity,
            isProvisionalFailure: isProvisionalFailure,
        )
    }

    static func makeID(threadId: String, turnId: String?) -> String {
        "\(threadId):\(turnId ?? "thread")"
    }

    static func makeID(
        runtime: AIRuntimeID,
        sessionID: String,
        turnId: String?
    ) -> String {
        [
            runtime.rawValue,
            encodedIdentityComponent(sessionID),
            encodedIdentityComponent(turnId ?? "session"),
        ].joined(separator: ":")
    }

    private static func encodedIdentityComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case threadId
        case turnId
        case identity
        case profileID
        case runtime
        case provider
        case modelID
        case sessionID
        case title
        case projectDirectory
        case state
        case startedAt
        case updatedAt
        case completedAt
        case lastStatus
        case isUnread
        case tokenUsage
        case agentActivity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let threadId = try container.decode(String.self, forKey: .threadId)
        let turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
        let identity = try container.decodeIfPresent(ModelIdentity.self, forKey: .identity)
            ?? .codex
        let sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? threadId
        self.init(
            threadId: threadId,
            turnId: turnId,
            identity: identity,
            sessionID: sessionID,
            title: try container.decode(String.self, forKey: .title),
            projectDirectory: try container.decode(String.self, forKey: .projectDirectory),
            state: try container.decode(PulseTaskState.self, forKey: .state),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            completedAt: try container.decodeIfPresent(Date.self, forKey: .completedAt),
            lastStatus: try container.decode(String.self, forKey: .lastStatus),
            isUnread: try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false,
            tokenUsage: try container.decodeIfPresent(TokenUsageSnapshot.self, forKey: .tokenUsage),
            agentActivity: try container.decodeIfPresent(
                AgentActivityObservation.self,
                forKey: .agentActivity
            )
        )

        if let encodedID = try container.decodeIfPresent(String.self, forKey: .id),
           encodedID != id {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Task identity does not match its encoded ID"
            )
        }
        if let encodedProfileID = try container.decodeIfPresent(
            ModelProfileID.self,
            forKey: .profileID
        ), encodedProfileID != profileID {
            throw DecodingError.dataCorruptedError(
                forKey: .profileID,
                in: container,
                debugDescription: "Task profile does not match its identity"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(threadId, forKey: .threadId)
        try container.encodeIfPresent(turnId, forKey: .turnId)
        try container.encode(identity, forKey: .identity)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(provider, forKey: .provider)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(title, forKey: .title)
        try container.encode(projectDirectory, forKey: .projectDirectory)
        try container.encode(state, forKey: .state)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(lastStatus, forKey: .lastStatus)
        try container.encode(isUnread, forKey: .isUnread)
        try container.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(agentActivity, forKey: .agentActivity)
    }
}
