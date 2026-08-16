import Foundation

/// Reads the membership facts Claude Code keeps in its account config.
///
/// The config file holds far more than this — MCP server definitions can
/// carry environment secrets, and per-project state names every directory
/// the CLI has run in. This reader's contract is that it materializes only
/// the `oauthAccount` object and takes exactly three fields from it:
/// `organizationRateLimitTier`, `claudeCodeTrialEndsAt`, and
/// `subscriptionCreatedAt`. Nothing else in the file is examined.
///
/// Never throws and never degrades health: an account that has never signed
/// in simply has no membership to show.
struct ClaudeAccountReader: Sendable {
    /// The config file grows with per-project state over a machine's
    /// lifetime; cap the read rather than trust it.
    private static let maximumFileBytes = 32 * 1_024 * 1_024

    private let accountConfigURL: URL

    init(accountConfigURL: URL) {
        self.accountConfigURL = accountConfigURL
    }

    func read() -> MembershipObservation? {
        guard let stamp = ClaudeFileStamp(path: accountConfigURL.path),
              stamp.size > 0,
              stamp.size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: accountConfigURL),
              let document = JSONValueSupport.object(from: data),
              let account = document["oauthAccount"] as? [String: Any]
        else {
            return nil
        }

        let observation = MembershipObservation(
            tierDisplayName: MembershipObservation.tierDisplayName(
                fromClaudeRateLimitTier: JSONValueSupport.string(
                    account["organizationRateLimitTier"]
                )
            ),
            subscriptionAnchor: JSONValueSupport.date(account["subscriptionCreatedAt"]),
            trialEndsAt: JSONValueSupport.date(account["claudeCodeTrialEndsAt"])
        )
        return observation.isEmpty ? nil : observation
    }
}
