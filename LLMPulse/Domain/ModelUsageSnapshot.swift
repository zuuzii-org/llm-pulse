import Foundation

/// How much of a usage window has been consumed, with no reset time.
///
/// Deliberately not a `RateLimitWindowSnapshot`: that type requires a reset
/// date, and the vendor app that records these percentages never persists
/// when a window turns over. Inventing a reset time would let this reading be
/// interpreted with Codex's semantics, which is the confusion worth avoiding.
/// Where a window's reset time came from, which decides how it may be phrased.
enum PlanUsageResetSource: String, Equatable, Codable, Sendable {
    /// The vendor's own `resets_at`, relayed by Claude Code's status line.
    /// Exact, and stated without hedging.
    case reported

    /// Bracketed from a percentage collapse in the desktop app's history.
    /// Carries the sampling cadence as its error bar, so it is always shown
    /// as an approximation.
    case inferred
}

struct PlanUsageWindow: Equatable, Codable, Sendable {
    let usedPercent: Int
    let windowMinutes: Int

    /// When the window resets, or `nil` when nothing available knows.
    ///
    /// The desktop app receives `resets_at` from the vendor and drops it,
    /// persisting only the percentage — so this is either relayed from Claude
    /// Code's status line, where the real value survives, or inferred from
    /// the mark a reset leaves behind: the percentage collapsing between two
    /// adjacent samples. `resetSource` says which, because a measured time
    /// and a bracketed one cannot honestly wear the same words.
    let resetsAt: Date?
    let resetSource: PlanUsageResetSource?

    init?(
        usedPercent: Int,
        windowMinutes: Int,
        resetsAt: Date? = nil,
        resetSource: PlanUsageResetSource = .inferred
    ) {
        guard (0...100).contains(usedPercent), windowMinutes > 0 else { return nil }
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetSource = resetsAt == nil ? nil : resetSource
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

    /// Whether any window carries the vendor's own reset time rather than a
    /// bracketed one. Drives the footnote: relayed values need no caveat.
    var hasReportedResets: Bool {
        fiveHourWindow?.resetSource == .reported
            || sevenDayWindow?.resetSource == .reported
    }

    var hasInferredResets: Bool {
        fiveHourWindow?.resetSource == .inferred
            || sevenDayWindow?.resetSource == .inferred
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
