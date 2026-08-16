import Foundation

struct ModelTaskSnapshot: Equatable, Sendable {
    let identity: ModelIdentity
    let tasks: [PulseTask]
    let usage: ModelUsageSnapshot?
    let rateLimits: RateLimitSnapshot?
    let membership: MembershipObservation?
    let health: [AdapterHealth]
    let refreshedAt: Date

    init(
        identity: ModelIdentity,
        tasks: [PulseTask],
        usage: ModelUsageSnapshot? = nil,
        rateLimits: RateLimitSnapshot? = nil,
        membership: MembershipObservation? = nil,
        health: [AdapterHealth],
        refreshedAt: Date
    ) {
        self.identity = identity
        let matchingTasks = tasks.filter { $0.profileID == identity.profileID }
        self.tasks = matchingTasks
        self.usage = usage
        self.rateLimits = rateLimits
        self.membership = membership
        if matchingTasks.count == tasks.count {
            self.health = health
        } else {
            self.health = health.filter { $0.adapter != .runtimeSource } + [
                .degraded(
                    .runtimeSource,
                    message: "Model source returned tasks from another profile",
                    lastSuccessAt: refreshedAt
                ),
            ]
        }
        self.refreshedAt = refreshedAt
    }

    init(codex snapshot: TaskSnapshot) {
        let tier = MembershipObservation.tierDisplayName(
            fromCodexPlanType: snapshot.rateLimits?.planType
        )
        self.init(
            identity: .codex,
            tasks: snapshot.tasks,
            rateLimits: snapshot.rateLimits,
            membership: tier.map { MembershipObservation(tierDisplayName: $0) },
            health: snapshot.health,
            refreshedAt: snapshot.refreshedAt
        )
    }

    var taskSnapshot: TaskSnapshot {
        TaskSnapshot(
            tasks: tasks,
            refreshedAt: refreshedAt,
            health: health,
            rateLimits: rateLimits
        )
    }

    func applying(receipts: ReceiptSnapshot) -> ModelTaskSnapshot {
        ModelTaskSnapshot(
            identity: identity,
            tasks: tasks.map { task in
                let completionDate = task.completedAt ?? task.updatedAt
                let isUnread = task.state == .completed
                    && completionDate >= receipts.baselineAt
                    && !receipts.viewedTaskIDs.contains(task.id)
                return task.replacingUnread(with: isUnread)
            },
            usage: usage,
            rateLimits: rateLimits,
            membership: membership,
            health: replacingReceiptHealth(
                in: health,
                with: .healthy(.receipts, at: refreshedAt)
            ),
            refreshedAt: refreshedAt
        )
    }

    func replacingReceiptHealth(with receiptHealth: AdapterHealth) -> ModelTaskSnapshot {
        ModelTaskSnapshot(
            identity: identity,
            tasks: tasks,
            usage: usage,
            rateLimits: rateLimits,
            membership: membership,
            health: replacingReceiptHealth(in: health, with: receiptHealth),
            refreshedAt: refreshedAt
        )
    }

    /// Keeps every nonterminal task and every terminal task that still reports
    /// active agents. Remaining terminal rows are bounded after receipts have
    /// been applied so unread completions win over newer viewed rows.
    func limitingTerminalTasks(to limit: Int) -> ModelTaskSnapshot {
        let protectedTerminalIDs = Set(tasks.lazy.filter {
            $0.state.isTerminal && ($0.agentActivity?.activeCount ?? 0) > 0
        }.map(\.id))
        let retainedTerminalIDs = Set(tasks.lazy.filter {
            $0.state.isTerminal && !protectedTerminalIDs.contains($0.id)
        }.sorted { lhs, rhs in
            if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
            let lhsDate = lhs.completedAt ?? lhs.updatedAt
            let rhsDate = rhs.completedAt ?? rhs.updatedAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }.prefix(max(0, limit)).map(\.id)).union(protectedTerminalIDs)

        return ModelTaskSnapshot(
            identity: identity,
            tasks: tasks.filter {
                !$0.state.isTerminal || retainedTerminalIDs.contains($0.id)
            },
            usage: usage,
            rateLimits: rateLimits,
            membership: membership,
            health: health,
            refreshedAt: refreshedAt
        )
    }

    private func replacingReceiptHealth(
        in health: [AdapterHealth],
        with receiptHealth: AdapterHealth
    ) -> [AdapterHealth] {
        health.filter { $0.adapter != .receipts } + [receiptHealth]
    }
}

struct PulseHubSnapshot: Equatable, Sendable {
    let models: [ModelTaskSnapshot]
    let refreshedAt: Date

    static let empty = PulseHubSnapshot(models: [], refreshedAt: .distantPast)

    func model(for profileID: ModelProfileID) -> ModelTaskSnapshot? {
        models.first { $0.identity.profileID == profileID }
    }

    var codexTaskSnapshot: TaskSnapshot? {
        model(for: .codex)?.taskSnapshot
    }

    var summary: PulseHubSummary {
        PulseHubSummary(snapshot: self)
    }
}

struct ModelProfileSummary: Equatable, Sendable, Identifiable {
    let identity: ModelIdentity
    let activeCount: Int
    let recentCompletedCount: Int
    let waitingActionCount: Int
    let hasFailures: Bool

    var id: ModelProfileID { identity.profileID }
    var hasWaitingAction: Bool { waitingActionCount > 0 }
}

/// A menu-bar-oriented projection of every configured model profile.
///
/// Counts are accumulated in one pass over the Hub's tasks so consumers do
/// not repeatedly flatten and filter the same snapshots every refresh.
struct PulseHubSummary: Equatable, Sendable {
    let profiles: [ModelProfileSummary]
    let activeCount: Int
    let recentCompletedCount: Int
    let waitingActionCount: Int
    let hasFailures: Bool

    var hasWaitingAction: Bool { waitingActionCount > 0 }

    init(snapshot: PulseHubSnapshot) {
        var profiles: [ModelProfileSummary] = []
        profiles.reserveCapacity(snapshot.models.count)

        var totalActiveCount = 0
        var totalRecentCompletedCount = 0
        var totalWaitingActionCount = 0
        var anyFailures = false

        for model in snapshot.models {
            var activeCount = 0
            var recentCompletedCount = 0
            var waitingActionCount = 0
            var hasFailures = false

            for task in model.tasks {
                switch task.state {
                case .running:
                    activeCount += 1
                case .waitingForApproval, .waitingForAnswer:
                    activeCount += 1
                    waitingActionCount += 1
                case .completed:
                    recentCompletedCount += 1
                case .failed, .interrupted:
                    recentCompletedCount += 1
                    hasFailures = true
                }
            }

            profiles.append(ModelProfileSummary(
                identity: model.identity,
                activeCount: activeCount,
                recentCompletedCount: recentCompletedCount,
                waitingActionCount: waitingActionCount,
                hasFailures: hasFailures
            ))
            totalActiveCount += activeCount
            totalRecentCompletedCount += recentCompletedCount
            totalWaitingActionCount += waitingActionCount
            anyFailures = anyFailures || hasFailures
        }

        self.profiles = profiles
        activeCount = totalActiveCount
        recentCompletedCount = totalRecentCompletedCount
        waitingActionCount = totalWaitingActionCount
        hasFailures = anyFailures
    }
}
