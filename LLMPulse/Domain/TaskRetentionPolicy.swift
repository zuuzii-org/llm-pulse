import Foundation

/// How long finished work stays on screen, and how much of it.
///
/// Retention is enforced twice: `TaskRepository` bounds a single runtime's
/// tasks, and `PulseHubRepository` bounds each model profile again after
/// receipts are applied, so unread completions win over newer viewed rows.
/// Both passes are idempotent, but only while they agree — the point of this
/// type is that they cannot drift apart.
enum TaskRetentionPolicy {
    /// Terminal tasks kept per model profile. Rows with active agents are
    /// exempt; see `ModelTaskSnapshot.limitingTerminalTasks(to:)`.
    static let maximumTerminalTasks = 20

    /// How long a finished task remains visible.
    static let terminalRetention: TimeInterval = 24 * 60 * 60

    /// How long a task may claim to be running with no activity before it is
    /// treated as abandoned.
    static let runningStale: TimeInterval = 24 * 60 * 60
}
