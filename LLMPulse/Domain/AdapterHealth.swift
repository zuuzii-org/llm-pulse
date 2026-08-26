import Foundation

struct AdapterHealth: Identifiable, Codable, Equatable, Sendable {
    enum Adapter: String, Codable, CaseIterable, Sendable {
        case appServer
        case sqlite
        case rolloutJSONL
        case pluginJournal
        case receipts
        case runtimeSource
        case claudeSessionRegistry
        case claudeTranscript
        case claudeAgentJournal
        case zcodeSQLite
        case zcodeEventLog
    }

    enum Status: Int, Codable, Comparable, Sendable {
        case healthy = 0
        case degraded = 1
        case unavailable = 2

        static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Why an adapter is not healthy. `message` stays a free-form diagnostic
    /// that is never shown, so anything the interface must say differently
    /// needs to be expressed here instead.
    enum Reason: String, Codable, Sendable {
        /// The source could not be read at all.
        case unreadable
        /// The source was read and parsed, but nothing in it matched what
        /// this version knows how to interpret — the upstream format moved.
        case formatDrift
    }

    let adapter: Adapter
    let status: Status
    let lastSuccessAt: Date?
    let message: String?
    let reason: Reason

    var id: Adapter { adapter }

    /// `appServer` and `pluginJournal` are optional sources, so being unable
    /// to reach them is a normal configuration rather than something to
    /// report. Format drift is never normal: the source answered, and this
    /// version no longer understands it.
    /// Optional sources whose absence is a normal configuration rather than
    /// something to report. A Claude session only grows a subagent journal
    /// once it spawns one, so most sessions never have the directory at all.
    private static let optionalAdapters: Set<Adapter> = [
        .appServer,
        .pluginJournal,
        .claudeAgentJournal,
    ]

    var isActionable: Bool {
        if reason == .formatDrift { return true }
        if status != .unavailable { return true }
        return !Self.optionalAdapters.contains(adapter)
    }

    init(
        adapter: Adapter,
        status: Status,
        lastSuccessAt: Date?,
        message: String?,
        reason: Reason = .unreadable
    ) {
        self.adapter = adapter
        self.status = status
        self.lastSuccessAt = lastSuccessAt
        self.message = message
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            adapter: try container.decode(Adapter.self, forKey: .adapter),
            status: try container.decode(Status.self, forKey: .status),
            lastSuccessAt: try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt),
            message: try container.decodeIfPresent(String.self, forKey: .message),
            reason: try container.decodeIfPresent(Reason.self, forKey: .reason) ?? .unreadable
        )
    }

    static func healthy(_ adapter: Adapter, at date: Date = .now) -> AdapterHealth {
        AdapterHealth(adapter: adapter, status: .healthy, lastSuccessAt: date, message: nil)
    }

    static func degraded(
        _ adapter: Adapter,
        message: String,
        lastSuccessAt: Date? = nil,
        reason: Reason = .unreadable
    ) -> AdapterHealth {
        AdapterHealth(
            adapter: adapter,
            status: .degraded,
            lastSuccessAt: lastSuccessAt,
            message: message,
            reason: reason
        )
    }

    static func unavailable(
        _ adapter: Adapter,
        message: String,
        reason: Reason = .unreadable
    ) -> AdapterHealth {
        AdapterHealth(
            adapter: adapter,
            status: .unavailable,
            lastSuccessAt: nil,
            message: message,
            reason: reason
        )
    }
}
