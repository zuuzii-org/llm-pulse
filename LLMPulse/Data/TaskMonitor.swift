import Combine
import Foundation

@MainActor
final class TaskMonitor: ObservableObject {
    private static let liveInitialSourceRefreshTimeout: Duration = .seconds(30)

    @Published private(set) var snapshot: TaskSnapshot
    @Published private(set) var hubSnapshot: PulseHubSnapshot

    private let repository: any PulseHubRepositoryProtocol
    private let refreshInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    convenience init(
        repository: any TaskRepositoryProtocol,
        refreshInterval: Duration = .milliseconds(750),
        initialSnapshot: TaskSnapshot = .empty
    ) {
        let codexRepository = CodexSourceRepository(repository: repository)
        let hubRepository = PulseHubRepository(
            repositories: [codexRepository],
            receiptRepository: repository
        )
        self.init(
            hubRepository: hubRepository,
            refreshInterval: refreshInterval,
            initialHubSnapshot: PulseHubSnapshot(
                models: [ModelTaskSnapshot(codex: initialSnapshot)],
                refreshedAt: initialSnapshot.refreshedAt
            )
        )
    }

    init(
        hubRepository: any PulseHubRepositoryProtocol,
        refreshInterval: Duration = .milliseconds(750),
        initialHubSnapshot: PulseHubSnapshot = .empty
    ) {
        repository = hubRepository
        self.refreshInterval = refreshInterval
        hubSnapshot = initialHubSnapshot
        snapshot = Self.codexProjection(from: initialHubSnapshot)
    }

    static func makeLive(
        refreshInterval: Duration = .milliseconds(750),
        codexPaths: CodexPaths = .live(),
        claudePaths: ClaudePaths = .live()
    ) -> TaskMonitor {
        let taskRepository = TaskRepository.live(paths: codexPaths)
        let codexRepository = CodexSourceRepository(repository: taskRepository)
        let claudeRepository = ClaudeSourceRepository(paths: claudePaths)
        return TaskMonitor(
            hubRepository: PulseHubRepository(
                // Each source has its own timeout, so one runtime being slow
                // or absent cannot hold up the other.
                sources: [
                    SingleModelSourceAdapter(repository: codexRepository),
                    SingleModelSourceAdapter(repository: claudeRepository),
                ],
                receiptRepository: taskRepository,
                sourceRefreshTimeout: .seconds(2),
                initialSourceRefreshTimeout: Self.liveInitialSourceRefreshTimeout
            ),
            refreshInterval: refreshInterval
        )
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.performRefresh()
                do { try await Task.sleep(for: self.refreshInterval) } catch { return }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() { Task { [weak self] in await self?.performRefresh() } }
    func refreshNow() async { await performRefresh() }
    func markViewed(task: PulseTask) { markViewed(tasks: [task]) }
    func markViewed(tasks: [PulseTask]) {
        guard !tasks.isEmpty else { return }
        Task { [weak self] in _ = await self?.markViewedAndRefresh(tasks: tasks) }
    }

    func markViewedAndRefresh(tasks: [PulseTask]) async -> Bool {
        guard !tasks.isEmpty else { return true }
        do {
            try await repository.markViewed(tasks, at: .now)
            await performRefresh()
            return true
        } catch { return false }
    }

    func unmarkViewed(task: PulseTask) { unmarkViewed(tasks: [task]) }
    func unmarkViewed(tasks: [PulseTask]) {
        guard !tasks.isEmpty else { return }
        Task { [weak self] in _ = await self?.unmarkViewedAndRefresh(tasks: tasks) }
    }

    func unmarkViewedAndRefresh(tasks: [PulseTask]) async -> Bool {
        guard !tasks.isEmpty else { return true }
        do {
            try await repository.unmarkViewed(tasks)
            await performRefresh()
            return true
        } catch { return false }
    }

    private func performRefresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let nextHubSnapshot = await repository.snapshot(now: .now)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        hubSnapshot = nextHubSnapshot
        snapshot = Self.codexProjection(from: nextHubSnapshot)
    }

    private static func codexProjection(from hubSnapshot: PulseHubSnapshot) -> TaskSnapshot {
        hubSnapshot.codexTaskSnapshot ?? TaskSnapshot(
            tasks: [],
            refreshedAt: hubSnapshot.refreshedAt,
            health: []
        )
    }
}
