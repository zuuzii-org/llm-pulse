import Foundation

/// How much of a usage window has been consumed, with no reset time.
///
/// Deliberately not a `RateLimitWindowSnapshot`: that type requires a reset
/// date, and the vendor app that records these percentages never persists
/// when a window turns over. Inventing a reset time would let this reading be
/// interpreted with Codex's semantics, which is the confusion worth avoiding.
struct PlanUsageWindow: Equatable, Codable, Sendable {
    let usedPercent: Int
    let windowMinutes: Int

    /// When the window is expected to reset, inferred rather than reported.
    ///
    /// The vendor never persists a reset time, but the moment one happens
    /// leaves a mark: the recorded percentage collapses between two adjacent
    /// samples. The weekly reset is a fixed anchor, so one observed collapse
    /// projects forward indefinitely; the five-hour window resets five hours
    /// after the first request that opened it, which the samples bracket to
    /// within their cadence. Estimated, and displayed as such — never nil'd
    /// into looking authoritative.
    let estimatedResetsAt: Date?

    init?(usedPercent: Int, windowMinutes: Int, estimatedResetsAt: Date? = nil) {
        guard (0...100).contains(usedPercent), windowMinutes > 0 else { return nil }
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.estimatedResetsAt = estimatedResetsAt
    }

    var remainingPercent: Int { 100 - usedPercent }
}

struct ModelUsageSnapshot: Equatable, Codable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let observedRequestCount: Int
    let observedAt: Date

    /// Account-level windows reported by the vendor, when readable.
    ///
    /// These span the whole account rather than this runtime alone, and they
    /// only advance while the vendor's own app is running. The interface has
    /// to say both things — read as this app's own accounting they are wrong.
    let fiveHourWindow: PlanUsageWindow?
    let sevenDayWindow: PlanUsageWindow?

    /// When the vendor last wrote those windows, which is not the moment this
    /// snapshot was taken.
    let planUsageObservedAt: Date?

    init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheReadInputTokens: Int,
        observedRequestCount: Int,
        observedAt: Date,
        fiveHourWindow: PlanUsageWindow? = nil,
        sevenDayWindow: PlanUsageWindow? = nil,
        planUsageObservedAt: Date? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.observedRequestCount = observedRequestCount
        self.observedAt = observedAt
        self.fiveHourWindow = fiveHourWindow
        self.sevenDayWindow = sevenDayWindow
        self.planUsageObservedAt = planUsageObservedAt
    }

    var totalTokens: Int { inputTokens + outputTokens }

    var hasPlanUsage: Bool { fiveHourWindow != nil || sevenDayWindow != nil }

    var hasEstimatedResets: Bool {
        fiveHourWindow?.estimatedResetsAt != nil
            || sevenDayWindow?.estimatedResetsAt != nil
    }

    /// Whether the account-level percentages must be shown with the time they
    /// were taken rather than as a current reading.
    ///
    /// Asked rather than stored: the snapshot itself ages between polls, so a
    /// flag captured at read time would go quietly wrong.
    func planUsageIsStale(asOf now: Date) -> Bool {
        guard let planUsageObservedAt else { return false }
        return now.timeIntervalSince(planUsageObservedAt) > ClaudePlanUsageReader.liveInterval
    }
}
