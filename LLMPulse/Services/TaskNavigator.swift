import AppKit
import Foundation

@MainActor
final class TaskNavigator {
    typealias OpenHandler = @MainActor (URL) -> Bool
    typealias ActivateHandler = @MainActor (String) -> Bool

    private let openHandler: OpenHandler
    private let activateHandler: ActivateHandler

    init(
        openHandler: @escaping OpenHandler = { NSWorkspace.shared.open($0) },
        activateHandler: @escaping ActivateHandler = { bundleIdentifier in
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            )
            guard let application = running.first else { return false }
            return application.activate(options: [])
        }
    ) {
        self.openHandler = openHandler
        self.activateHandler = activateHandler
    }

    @discardableResult
    func open(threadID: String) -> Bool {
        guard let url = Self.taskURL(threadID: threadID) else { return false }
        return openHandler(url)
    }

    @discardableResult
    func open(task: PulseTask) -> Bool {
        guard task.profileID.isConsistent(
            runtime: task.runtime,
            provider: task.provider,
            modelID: task.modelID
        ) else {
            return false
        }

        switch task.runtime {
        case .codexDesktop:
            return open(threadID: task.threadId)

        case .claudeDesktop:
            // A malformed identifier makes the receiving handler bail out
            // before it shows anything, so the click would silently do
            // nothing. Bringing the app forward is a worse outcome than a
            // direct jump, but it is never a no-op.
            if task.supportsDeepLink,
               let url = ClaudeDeepLink.resumeURL(sessionID: task.sessionID),
               openHandler(url)
            {
                return true
            }
            return activateHandler(ClaudeDeepLink.desktopBundleIdentifier)

        default:
            return false
        }
    }

    static func taskURL(threadID: String) -> URL? {
        let trimmedID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              !trimmedID.contains("/"),
              !trimmedID.contains("\\") else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(trimmedID)"
        return components.url
    }
}
