import Foundation

struct ZCodeSourceRepository: ModelTaskRepositoryProtocol {
    let identity = ModelIdentity.glm

    private let repository: ZCodeTaskRepository

    init(repository: ZCodeTaskRepository) {
        self.repository = repository
    }

    init(paths: ZCodePaths = .live()) {
        self.init(repository: ZCodeTaskRepository(paths: paths))
    }

    func snapshot(now: Date) async -> ModelTaskSnapshot {
        await repository.snapshot(now: now)
    }
}
