import Foundation

/// What is known about the account's paid plan, from read-only observation.
///
/// None of the vendors persist an expiry date outright, so this carries the
/// three facts that exist and lets `MembershipDisplay` decide what they add
/// up to: a tier name, a trial end when the account is on one, and the
/// subscription's start moment — which anchors the monthly renewal day the
/// same way it anchors an App Store subscription.
struct MembershipObservation: Equatable, Codable, Sendable {
    let tierDisplayName: String?
    let subscriptionAnchor: Date?
    let trialEndsAt: Date?

    init(
        tierDisplayName: String? = nil,
        subscriptionAnchor: Date? = nil,
        trialEndsAt: Date? = nil
    ) {
        self.tierDisplayName = tierDisplayName
        self.subscriptionAnchor = subscriptionAnchor
        self.trialEndsAt = trialEndsAt
    }

    var isEmpty: Bool {
        tierDisplayName == nil && subscriptionAnchor == nil && trialEndsAt == nil
    }

    /// "default_claude_max_20x" → "Max 20x". Unknown tiers keep their words
    /// rather than disappearing, so a new plan name still shows something.
    static func tierDisplayName(fromClaudeRateLimitTier tier: String?) -> String? {
        guard var value = tier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        for prefix in ["default_claude_", "claude_", "default_"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        let words = value.split(separator: "_").map { word -> String in
            let text = String(word)
            // "20x" stays "20x"; "max" becomes "Max".
            return text.first?.isNumber == true ? text : text.capitalized
        }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// "plus" → "Plus". Codex telemetry reports the plan as a bare word.
    static func tierDisplayName(fromCodexPlanType planType: String?) -> String? {
        guard let value = planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }
}

/// The one membership line a card shows, resolved from every source that can
/// contribute one.
struct MembershipDisplay: Equatable, Sendable {
    enum DateKind: Equatable, Sendable {
        /// The user typed this date in Settings. Exact, no hedging.
        case manualExpiry
        /// The vendor recorded a trial end. Exact.
        case trialEnd
        /// Projected from the subscription's start by whole months, the way
        /// an App Store subscription renews. An assumption — annual billing
        /// or a cancelled renewal breaks it — so it is always shown as "约".
        case derivedRenewal
    }

    let tierDisplayName: String?
    let date: Date?
    let kind: DateKind?

    /// Exact dates outrank the derived one: a manual entry is the user
    /// correcting the inference, and a recorded trial end is the vendor's
    /// own word.
    static func resolve(
        observation: MembershipObservation?,
        manualExpiry: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> MembershipDisplay? {
        let tier = observation?.tierDisplayName

        if let manualExpiry {
            return MembershipDisplay(
                tierDisplayName: tier,
                date: manualExpiry,
                kind: .manualExpiry
            )
        }
        if let trialEndsAt = observation?.trialEndsAt {
            return MembershipDisplay(
                tierDisplayName: tier,
                date: trialEndsAt,
                kind: .trialEnd
            )
        }
        if let anchor = observation?.subscriptionAnchor,
           let renewal = nextMonthlyRenewal(after: now, anchor: anchor, calendar: calendar) {
            return MembershipDisplay(
                tierDisplayName: tier,
                date: renewal,
                kind: .derivedRenewal
            )
        }
        guard tier != nil else { return nil }
        return MembershipDisplay(tierDisplayName: tier, date: nil, kind: nil)
    }

    /// The first monthly recurrence of `anchor` after `now`.
    ///
    /// Each candidate is computed from the original anchor, never from the
    /// previous candidate: stepping forward one month at a time would let a
    /// short month pull a day-31 anchor down to day 28 permanently, while
    /// real subscriptions return to the anchored day whenever the month has
    /// one.
    static func nextMonthlyRenewal(
        after now: Date,
        anchor: Date,
        calendar: Calendar = .current
    ) -> Date? {
        if anchor > now { return anchor }
        var months = max(0, calendar.dateComponents([.month], from: anchor, to: now).month ?? 0)
        // Bounded: the loop advances at most a few steps past the estimate,
        // and a runaway calendar bug should fail visibly rather than spin.
        for _ in 0..<24 {
            months += 1
            guard let candidate = calendar.date(byAdding: .month, value: months, to: anchor)
            else {
                return nil
            }
            if candidate > now {
                return candidate
            }
        }
        return nil
    }
}
