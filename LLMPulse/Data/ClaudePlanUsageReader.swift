import Foundation

/// Reads the account-level plan usage the Claude desktop app records.
///
/// The file is a rolling history of samples, each holding how much of the
/// five-hour and seven-day windows has been used. It never records when a
/// window resets — the app keeps that in memory only — so the percentages are
/// all that can be shown, and the interface says as much.
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

    struct Reading: Equatable, Sendable {
        let fiveHourWindow: PlanUsageWindow?
        let sevenDayWindow: PlanUsageWindow?
        let observedAt: Date
    }

    /// The most recent sample, or `nil` when there is nothing current to show.
    ///
    /// Never throws: a missing file is the ordinary state on a machine that
    /// only uses the CLI, and this is not a source worth degrading health for.
    func read(now: Date) -> Reading? {
        guard let stamp = ClaudeFileStamp(path: planUsageHistoryURL.path),
              stamp.size > 0,
              stamp.size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: planUsageHistoryURL),
              let document = JSONValueSupport.object(from: data),
              let samples = document["samples"] as? [[String: Any]]
        else {
            return nil
        }

        // Samples are appended in order, but a truncated or reordered file
        // should not be able to present an old reading as the current one.
        var latest: (observedAt: Date, usage: [String: Any])?
        for sample in samples {
            guard let observedAt = JSONValueSupport.date(sample["t"]),
                  let usage = sample["u"] as? [String: Any]
            else {
                continue
            }
            if latest == nil || observedAt > latest!.observedAt {
                latest = (observedAt, usage)
            }
        }

        guard let latest else { return nil }

        let age = now.timeIntervalSince(latest.observedAt)
        guard age >= -Self.clockSkewTolerance, age <= freshnessInterval else { return nil }

        let fiveHour = window(
            from: latest.usage["fh"],
            windowMinutes: Self.fiveHourMinutes
        )
        let sevenDay = window(
            from: latest.usage["sd"],
            windowMinutes: Self.sevenDayMinutes
        )
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return Reading(
            fiveHourWindow: fiveHour,
            sevenDayWindow: sevenDay,
            observedAt: latest.observedAt
        )
    }

    /// A sample written moments ago can carry a timestamp slightly ahead of
    /// this clock; that is not a reason to discard it.
    private static let clockSkewTolerance: TimeInterval = 60

    private func window(from raw: Any?, windowMinutes: Int) -> PlanUsageWindow? {
        guard let percent = JSONValueSupport.int(raw) else { return nil }
        return PlanUsageWindow(usedPercent: percent, windowMinutes: windowMinutes)
    }
}
