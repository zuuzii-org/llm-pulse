import Foundation

struct ClaudeSourceRepository: ModelTaskRepositoryProtocol {
    let identity = ModelIdentity.claudeCode

    private let repository: ClaudeTaskRepository

    init(repository: ClaudeTaskRepository) {
        self.repository = repository
    }

    init(paths: ClaudePaths = .live()) {
        self.init(repository: ClaudeTaskRepository(paths: paths))
    }

    func snapshot(now: Date) async -> ModelTaskSnapshot {
        let snapshot = await repository.snapshot(now: now)
        return ModelTaskSnapshot(
            identity: identity,
            tasks: snapshot.tasks,
            rateLimits: nil,
            health: snapshot.health,
            refreshedAt: snapshot.refreshedAt
        )
    }
}
