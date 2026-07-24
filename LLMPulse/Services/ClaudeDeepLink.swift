import Foundation

/// Addresses for bringing a Claude Code session to the front.
///
/// AppKit-free so the whole decision is unit-testable; the caller performs the
/// actual open through `TaskNavigator`'s injected handler.
enum ClaudeDeepLink {
    static let desktopBundleIdentifier = "com.anthropic.claudefordesktop"

    /// The registry `entrypoint` value for sessions the desktop app started.
    static let desktopEntrypoint = "claude-desktop"

    private static let sessionIdentifierPattern = try? NSRegularExpression(
        pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}"
            + "-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
    )

    /// A `claude://resume` URL, or `nil` when the identifier is not a UUID.
    ///
    /// Validation happens here because the receiving handler returns `false`
    /// for a malformed identifier *and skips its own show-and-focus branch* —
    /// the click would do nothing at all, with no error anywhere. Falling back
    /// to plain activation is strictly better than that silence.
    static func resumeURL(sessionID: String) -> URL? {
        guard isValidSessionIdentifier(sessionID) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url
    }

    /// Whether a row may be opened by deep link rather than by activation.
    ///
    /// Only sessions the desktop app itself started. For any other entrypoint
    /// the first resume rewrites the transcript in place to strip thinking
    /// blocks, and a read-only monitor must not cause a destructive write
    /// because someone clicked a row.
    static func isResumable(entrypoint: String?) -> Bool {
        entrypoint == desktopEntrypoint
    }

    static func isValidSessionIdentifier(_ sessionID: String) -> Bool {
        guard let sessionIdentifierPattern else { return false }
        let range = NSRange(sessionID.startIndex..<sessionID.endIndex, in: sessionID)
        return sessionIdentifierPattern.firstMatch(in: sessionID, range: range) != nil
    }
}
