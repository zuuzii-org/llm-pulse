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
            // Deliberately no deep link. `claude://resume` does not focus a
            // session — it *imports* the CLI transcript as a new desktop
            // session, and its duplicate check only recognizes sessions it
            // imported itself (their id is a prefix plus the CLI id, while a
            // desktop-started session keeps its own). Every click on a live
            // desktop session therefore minted another "General coding
            // session". The desktop's own session id never touches disk, so
            // the exact row cannot be addressed from outside; bringing the
            // app forward — where the session already sits in the sidebar —
            // is everything that can be done correctly.
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
