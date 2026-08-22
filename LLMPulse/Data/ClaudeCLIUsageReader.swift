import Foundation

/// Reads the rate-limit state Claude Code's status line hands out.
///
/// The vendor's own reset times exist — the CLI parses them from
/// `anthropic-ratelimit-unified-{five_hour,seven_day}-reset` response headers
/// and puts them in the JSON it feeds a status line command. The desktop app
/// receives the same values and drops them, persisting only percentages, so
/// this is the one place on disk where a real reset time can be had.
///
/// Nothing here reaches into Claude Code to get it. `usage-bridge.sh`, which
/// ships in this app's bundle and which the user installs themselves, copies
/// four numbers into this app's own directory. A machine without that bridge
/// simply has no file here, and `ClaudePlanUsageReader` keeps inferring.
///
/// The payoff is not only precision. A reset time turns staleness from a
/// guess into arithmetic: a percentage still describes the current window
/// exactly when that window has not reset yet, which a real `resets_at`
/// answers outright.
struct ClaudeCLIUsageReader: Sendable {
    /// Two windows and a timestamp. Anything larger is not this file.
    private static let maximumFileBytes = 64 * 1_024

    private static let fiveHourMinutes = 5 * 60
    private static let sevenDayMinutes = 7 * 24 * 60

    /// How recent the bridge's write must be for a window that arrived
    /// without a reset time to be read as current. Windows that do carry one
    /// need no such guess.
    private static let liveInterval: TimeInterval = 30 * 60

    private static let clockSkewTolerance: TimeInterval = 60

    /// The outer bound, matching `ClaudePlanUsageReader`. A window can stay
    /// open longer than this — a weekly one always does — but a percentage
    /// from half a day ago understates a budget that has been spent since,
    /// and understating what is spent is the dangerous direction.
    private let maximumUsableAge: TimeInterval

    private let usageURL: URL

    static func defaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(PulseBrand.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("claude-cli-usage.json")
    }

    init(
        usageURL: URL = ClaudeCLIUsageReader.defaultURL(),
        maximumUsableAge: TimeInterval = 12 * 60 * 60
    ) {
        self.usageURL = usageURL
        self.maximumUsableAge = maximumUsableAge
    }

    struct Window: Equatable, Sendable {
        let usedPercent: Int
        let resetsAt: Date?
    }

    struct Parsed: Equatable, Sendable {
        let observedAt: Date
        let fiveHour: Window?
        let sevenDay: Window?
    }

    struct Reading: Equatable, Sendable {
        let fiveHourWindow: PlanUsageWindow?
        let sevenDayWindow: PlanUsageWindow?
        let observedAt: Date
    }

    /// Never throws: no bridge installed is the ordinary state, and it is not
    /// a source worth degrading health over.
    func parse() -> Parsed? {
        guard let stamp = ClaudeFileStamp(path: usageURL.path),
              stamp.size > 0,
              stamp.size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: usageURL),
              let document = JSONValueSupport.object(from: data),
              let observedAt = JSONValueSupport.date(document["observedAt"]),
              let limits = document["rateLimits"] as? [String: Any]
        else {
            return nil
        }

        let parsed = Parsed(
            observedAt: observedAt,
            fiveHour: Self.window(limits["five_hour"]),
            sevenDay: Self.window(limits["seven_day"])
        )
        guard parsed.fiveHour != nil || parsed.sevenDay != nil else { return nil }
        return parsed
    }

    private static func window(_ value: Any?) -> Window? {
        guard let object = value as? [String: Any],
              let percent = JSONValueSupport.int(object["used_percentage"]),
              (0...100).contains(percent)
        else {
            return nil
        }
        return Window(
            usedPercent: percent,
            resetsAt: JSONValueSupport.date(object["resets_at"])
        )
    }

    func reading(from parsed: Parsed, now: Date) -> Reading? {
        let age = now.timeIntervalSince(parsed.observedAt)
        guard age >= -Self.clockSkewTolerance, age <= maximumUsableAge else { return nil }

        let fiveHour = Self.plan(
            parsed.fiveHour,
            windowMinutes: Self.fiveHourMinutes,
            age: age,
            now: now
        )
        let sevenDay = Self.plan(
            parsed.sevenDay,
            windowMinutes: Self.sevenDayMinutes,
            age: age,
            now: now
        )
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return Reading(
            fiveHourWindow: fiveHour,
            sevenDayWindow: sevenDay,
            observedAt: parsed.observedAt
        )
    }

    /// With a real reset time, "does this percentage still describe the
    /// window it was measured in?" stops being a judgement call: the window
    /// is the same one exactly while its reset is still ahead.
    private static func plan(
        _ window: Window?,
        windowMinutes: Int,
        age: TimeInterval,
        now: Date
    ) -> PlanUsageWindow? {
        guard let window else { return nil }
        if let resetsAt = window.resetsAt {
            guard resetsAt > now else { return nil }
            return PlanUsageWindow(
                usedPercent: window.usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt,
                resetSource: .reported
            )
        }
        guard age <= liveInterval else { return nil }
        return PlanUsageWindow(usedPercent: window.usedPercent, windowMinutes: windowMinutes)
    }

    func read(now: Date) -> Reading? {
        parse().flatMap { reading(from: $0, now: now) }
    }
}
