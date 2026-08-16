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

    // No resume URL is offered on purpose. `claude://resume?session=` exists,
    // but its verified semantics are *import*: the desktop copies the CLI
    // transcript into a fresh session of its own, and its duplicate check
    // only matches sessions it imported (prefix + CLI id), never the ones it
    // started natively. Aimed at a live desktop session it mints a duplicate
    // per click. The desktop's own session id is not persisted anywhere
    // readable, so there is nothing correct to link to — activation is the
    // whole contract.

    static func isValidSessionIdentifier(_ sessionID: String) -> Bool {
        guard let sessionIdentifierPattern else { return false }
        let range = NSRange(sessionID.startIndex..<sessionID.endIndex, in: sessionID)
        return sessionIdentifierPattern.firstMatch(in: sessionID, range: range) != nil
    }
}
