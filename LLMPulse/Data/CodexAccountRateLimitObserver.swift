import Foundation

struct CodexAccountRateLimitObservation: Sendable {
    let snapshot: RateLimitSnapshot?
    let health: AdapterHealth
    let fallbackAllowed: Bool

    init(
        snapshot: RateLimitSnapshot?,
        health: AdapterHealth,
        fallbackAllowed: Bool = true
    ) {
        self.snapshot = snapshot
        self.health = health
        self.fallbackAllowed = fallbackAllowed
    }
}

protocol CodexAccountRateLimitObserving: Sendable {
    func observation(now: Date) async -> CodexAccountRateLimitObservation
}

actor CodexAccountRateLimitObserver: CodexAccountRateLimitObserving {
    private let loader: any CodexAccountRateLimitLoading
    private let refreshInterval: TimeInterval
    private let staleInterval: TimeInterval

    private var cachedSnapshot: RateLimitSnapshot?
    private var lastAttemptAt = Date.distantPast
    private var lastSuccessAt: Date?
    private var lastErrorMessage: String?
    private var lastFailureReason: AdapterHealth.Reason = .unreadable
    private var refreshTask: Task<Void, Never>?

    init(
        loader: any CodexAccountRateLimitLoading,
        refreshInterval: TimeInterval = 30,
        staleInterval: TimeInterval = 5 * 60
    ) {
        let normalizedRefreshInterval = refreshInterval.isFinite
            ? max(0, refreshInterval)
            : 30
        let normalizedStaleInterval = staleInterval.isFinite
            ? max(0, staleInterval)
            : 5 * 60
        self.loader = loader
        self.refreshInterval = normalizedRefreshInterval
        self.staleInterval = max(normalizedRefreshInterval, normalizedStaleInterval)
    }

    func observation(now: Date = .now) -> CodexAccountRateLimitObservation {
        if refreshTask == nil,
           now.timeIntervalSince(lastAttemptAt) >= refreshInterval
        {
            startRefresh(now: now)
        }

        let isFresh = lastSuccessAt.map {
            let age = now.timeIntervalSince($0)
            return age >= -60 && age <= staleInterval
        } ?? false
        let hasUnexpiredOfficialWindow = cachedSnapshot?.weekly.map {
            $0.windowMinutes == RateLimitWindowDuration.weeklyMinutes
                && $0.resetsAt > now
        } ?? false
        let isStaleButAuthoritative = !isFresh
            && hasUnexpiredOfficialWindow
            && (lastErrorMessage != nil || refreshTask != nil)
        let visibleSnapshot = (isFresh || isStaleButAuthoritative) ? cachedSnapshot : nil

        if let lastSuccessAt, visibleSnapshot != nil {
            if let lastErrorMessage {
                return CodexAccountRateLimitObservation(
                    snapshot: visibleSnapshot,
                    health: .degraded(
                        .appServer,
                        message: lastErrorMessage,
                        lastSuccessAt: lastSuccessAt,
                        reason: lastFailureReason
                    ),
                    fallbackAllowed: false
                )
            }
            if isStaleButAuthoritative {
                return CodexAccountRateLimitObservation(
                    snapshot: visibleSnapshot,
                    health: .degraded(
                        .appServer,
                        message: "Refreshing Codex account limits",
                        lastSuccessAt: lastSuccessAt
                    ),
                    fallbackAllowed: false
                )
            }
            return CodexAccountRateLimitObservation(
                snapshot: visibleSnapshot,
                health: .healthy(.appServer, at: lastSuccessAt),
                fallbackAllowed: false
            )
        }

        return CodexAccountRateLimitObservation(
            snapshot: nil,
            health: .unavailable(
                .appServer,
                message: lastErrorMessage ?? "Connecting to Codex account limits",
                reason: lastErrorMessage == nil ? .unreadable : lastFailureReason
            ),
            fallbackAllowed: lastErrorMessage != nil
        )
    }

    func waitForCurrentRefreshForTesting() async {
        let task = refreshTask
        await task?.value
    }

    private func startRefresh(now: Date) {
        lastAttemptAt = now
        let loader = loader
        refreshTask = Task { [weak self] in
            do {
                let snapshot = try await loader.loadRateLimits()
                await self?.finishRefresh(snapshot)
            } catch {
                await self?.failRefresh(error)
            }
        }
    }

    private func finishRefresh(_ snapshot: RateLimitSnapshot) {
        guard let weekly = snapshot.weekly,
              weekly.windowMinutes == RateLimitWindowDuration.weeklyMinutes
        else {
            // The app server answered; its weekly window is simply not the
            // one this build understands. Reporting that as "unavailable"
            // would hide it, because an unreachable app server is a normal
            // configuration and therefore suppressed from the interface.
            failRefresh(
                CodexAppServerRateLimitError.malformedResponse,
                reason: .formatDrift
            )
            return
        }
        cachedSnapshot = snapshot
        lastSuccessAt = snapshot.updatedAt
        lastAttemptAt = snapshot.updatedAt
        lastErrorMessage = nil
        lastFailureReason = .unreadable
        refreshTask = nil
    }

    private func failRefresh(
        _ error: Error,
        reason: AdapterHealth.Reason = .unreadable
    ) {
        lastAttemptAt = .now
        lastErrorMessage = error.localizedDescription
        lastFailureReason = reason
        refreshTask = nil
    }
}
