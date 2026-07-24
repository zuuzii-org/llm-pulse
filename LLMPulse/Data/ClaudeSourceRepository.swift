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
        await repository.snapshot(now: now)
    }
}
