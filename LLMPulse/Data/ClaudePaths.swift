import Foundation

/// Locations of the Claude Code state this app observes, all read-only.
///
/// `CLAUDE_CONFIG_DIR` is the injection point, mirroring `CODEX_HOME` in
/// `CodexPaths`. It is what lets tests and local development run against a
/// synthetic tree instead of the developer's real sessions.
struct ClaudePaths: Sendable {
    let claudeHome: URL

    /// One JSON file per running process, named `<pid>.json`.
    let sessionsDirectory: URL

    /// One directory per project, each holding `<sessionID>.jsonl` transcripts
    /// plus a `<sessionID>/` sidecar for subagents and workflows.
    let projectsDirectory: URL

    /// Account-level plan usage, written by the desktop app rather than by the
    /// CLI. It lives outside the config directory, so `CLAUDE_CONFIG_DIR`
    /// alone does not redirect it and it carries its own override.
    let planUsageHistoryURL: URL

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudePaths {
        let claudeHome: URL
        if let configuredHome = environment["CLAUDE_CONFIG_DIR"], !configuredHome.isEmpty {
            claudeHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            claudeHome = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }

        let applicationSupport: URL
        if let configured = environment["CLAUDE_APP_SUPPORT_DIR"], !configured.isEmpty {
            applicationSupport = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            applicationSupport = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Claude", isDirectory: true)
        }

        return ClaudePaths(
            claudeHome: claudeHome,
            applicationSupportDirectory: applicationSupport
        )
    }

    init(claudeHome: URL, applicationSupportDirectory: URL? = nil) {
        self.claudeHome = claudeHome
        sessionsDirectory = claudeHome.appendingPathComponent("sessions", isDirectory: true)
        projectsDirectory = claudeHome.appendingPathComponent("projects", isDirectory: true)
        planUsageHistoryURL = (applicationSupportDirectory ?? claudeHome)
            .appendingPathComponent("plan-usage-history.json")
    }

    /// The sidecar directory beside a transcript, holding `subagents/` and
    /// `workflows/`. Derived from the transcript rather than from the project
    /// path, because the directory name is a lossy encoding of the working
    /// directory and must never be reconstructed. See `ClaudeSessionIndex`.
    func sidecarDirectory(forTranscript transcriptURL: URL) -> URL {
        transcriptURL
            .deletingPathExtension()
    }
}
