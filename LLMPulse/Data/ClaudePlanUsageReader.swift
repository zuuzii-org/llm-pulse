import Foundation

/// Reads the account-level plan usage the Claude desktop app records.
///
/// The file is a rolling history of samples, each holding how much of the
/// five-hour and seven-day windows has been used. It never records when a
/// window resets — the app keeps that in memory only — but the moment a reset
/// happens leaves a mark the history cannot hide: the percentage collapses
/// between two adjacent samples. That is enough to *infer* both reset times:
///
/// - The seven-day reset is a fixed weekly anchor. One observed collapse,
///   bracketed to the sampling cadence, projects forward by whole weeks.
/// - The five-hour window opens with the first request after the previous
///   window expired and resets exactly five hours later. The `0 → positive`
///   transition brackets that opening moment.
///
/// Both are estimates with the cadence (±5 minutes) as their error bar, and
/// they are carried separately from the vendor-reported percentages so the
/// interface can say which is which.
///
/// Only the desktop app writes this file. A machine where it is closed keeps
/// returning the last sample it wrote, which is why the observation time
/// travels with the value instead of being assumed to be now.
struct ClaudePlanUsageReader: Sendable {
    /// The history grows slowly — a sample every few minutes — but it is
    /// unbounded over a machine's lifetime, so the read is capped.
    private static let maximumFileBytes = 8 * 1_024 * 1_024

    private static let fiveHourMinutes = 5 * 60
    private static let sevenDayMinutes = 7 * 24 * 60

    /// The widest gap between two samples that still brackets an event.
    ///
    /// A collapse across a wider gap only proves the reset happened *sometime*
    /// while the app was closed, which is not a time worth displaying. The
    /// nominal cadence is five minutes, but gaps close to seventeen were
    /// observed on a busy machine with the app open the whole time, so the
    /// cap sits above those; midpoint error stays within ±10 minutes, which
    /// the "estimated" label honestly covers.
    private static let maximumBracket: TimeInterval = 20 * 60

    /// A sample written moments ago can carry a timestamp slightly ahead of
    /// this clock; that is not a reason to discard it.
    private static let clockSkewTolerance: TimeInterval = 60

    private let planUsageHistoryURL: URL

    /// How stale a sample may be and still be shown.
    ///
    /// Past this the number says more about when the app was last open than
    /// about the account, and a stale percentage reads as a current one.
    private let freshnessInterval: TimeInterval

    init(
        planUsageHistoryURL: URL,
        freshnessInterval: TimeInterval = 6 * 60 * 60
    ) {
        self.planUsageHistoryURL = planUsageHistoryURL
        self.freshnessInterval = freshnessInterval
    }

    /// Facts extracted from one full pass over the file, all independent of
    /// the current moment so a caller can cache them against a file stamp
    /// instead of re-parsing an ever-growing history every poll.
    struct Parsed: Equatable, Sendable {
        let observedAt: Date
        let fiveHourPercent: Int?
        let sevenDayPercent: Int?

        /// Midpoint of the bracket around the first request of the current
        /// five-hour window, when the samples captured it.
        let fiveHourWindowOpenedAt: Date?

        /// Midpoint of the bracket around the last observed weekly collapse.
        let sevenDayResetAnchor: Date?
    }

    struct Reading: Equatable, Sendable {
        let fiveHourWindow: PlanUsageWindow?
        let sevenDayWindow: PlanUsageWindow?
        let observedAt: Date
    }

    /// The most recent sample plus inferred reset facts, or `nil` when the
    /// file is missing, oversized, or unreadable.
    ///
    /// Never throws: a missing file is the ordinary state on a machine that
    /// only uses the CLI, and this is not a source worth degrading health for.
    func parse() -> Parsed? {
        guard let stamp = ClaudeFileStamp(path: planUsageHistoryURL.path),
              stamp.size > 0,
              stamp.size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: planUsageHistoryURL),
              let document = JSONValueSupport.object(from: data),
              let rawSamples = document["samples"] as? [[String: Any]]
        else {
            return nil
        }

        struct Sample {
            let observedAt: Date
            let organization: String?
            let fiveHour: Int?
            let sevenDay: Int?
        }

        var samples: [Sample] = []
        samples.reserveCapacity(rawSamples.count)
        for raw in rawSamples {
            guard let observedAt = JSONValueSupport.date(raw["t"]),
                  let usage = raw["u"] as? [String: Any]
            else {
                continue
            }
            samples.append(Sample(
                observedAt: observedAt,
                organization: JSONValueSupport.string(raw["org"]),
                fiveHour: JSONValueSupport.int(usage["fh"]),
                sevenDay: JSONValueSupport.int(usage["sd"])
            ))
        }
        // Physical order is not trusted; the timestamps decide.
        samples.sort { $0.observedAt < $1.observedAt }

        guard let latest = samples.last else { return nil }

        // The file interleaves organizations when the account switches.
        // Percentages from another organization are a different budget, and
        // a boundary between organizations would read as a collapse.
        let series = samples.filter { $0.organization == latest.organization }

        var windowOpenedAt: Date?
        var resetAnchor: Date?
        for (previous, current) in zip(series, series.dropFirst()) {
            let bracket = current.observedAt.timeIntervalSince(previous.observedAt)
            guard bracket > 0, bracket <= Self.maximumBracket else { continue }
            let midpoint = previous.observedAt.addingTimeInterval(bracket / 2)

            if let before = previous.fiveHour, let after = current.fiveHour {
                if before == 0, after > 0 {
                    // Idle, then the first request of a fresh window.
                    windowOpenedAt = midpoint
                } else if after > 0, before - after >= 5 {
                    // Expiry and restart inside a single bracket: usage was
                    // continuous, so the collapse moment is also the opening.
                    windowOpenedAt = midpoint
                }
            }

            if let before = previous.sevenDay, let after = current.sevenDay,
               before - after >= 2, after <= 2 {
                // A genuine weekly reset lands at (or next to) zero. A drop
                // that stops well above zero is more likely a limit change
                // rescaling the percentage — the promo kind — than a reset,
                // and a wrong anchor repeats itself every week.
                resetAnchor = midpoint
            }
        }

        return Parsed(
            observedAt: latest.observedAt,
            fiveHourPercent: latest.fiveHour,
            sevenDayPercent: latest.sevenDay,
            fiveHourWindowOpenedAt: windowOpenedAt,
            sevenDayResetAnchor: resetAnchor
        )
    }

    /// Projects parsed facts onto the current moment.
    ///
    /// Separate from `parse()` because the facts age differently: percentages
    /// go stale with the file, while a five-hour estimate can expire between
    /// two polls of an unchanged file.
    func reading(from parsed: Parsed, now: Date) -> Reading? {
        let age = now.timeIntervalSince(parsed.observedAt)
        guard age >= -Self.clockSkewTolerance, age <= freshnessInterval else { return nil }

        var fiveHourResetsAt: Date?
        if let openedAt = parsed.fiveHourWindowOpenedAt,
           (parsed.fiveHourPercent ?? 0) > 0 {
            let resetsAt = openedAt.addingTimeInterval(
                TimeInterval(Self.fiveHourMinutes * 60)
            )
            // An estimate in the past means the opening we observed belongs
            // to an already-expired window; the current one opened while the
            // app was closed, and its reset time is unknowable.
            if resetsAt > now {
                fiveHourResetsAt = resetsAt
            }
        }

        var sevenDayResetsAt: Date?
        if var anchor = parsed.sevenDayResetAnchor {
            let week: TimeInterval = 7 * 24 * 60 * 60
            while anchor <= now {
                anchor += week
            }
            sevenDayResetsAt = anchor
        }

        let fiveHour = parsed.fiveHourPercent.flatMap {
            PlanUsageWindow(
                usedPercent: $0,
                windowMinutes: Self.fiveHourMinutes,
                estimatedResetsAt: fiveHourResetsAt
            )
        }
        let sevenDay = parsed.sevenDayPercent.flatMap {
            PlanUsageWindow(
                usedPercent: $0,
                windowMinutes: Self.sevenDayMinutes,
                estimatedResetsAt: sevenDayResetsAt
            )
        }
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return Reading(
            fiveHourWindow: fiveHour,
            sevenDayWindow: sevenDay,
            observedAt: parsed.observedAt
        )
    }

    /// One-shot convenience for callers without a cache.
    func read(now: Date) -> Reading? {
        parse().flatMap { reading(from: $0, now: now) }
    }
}
