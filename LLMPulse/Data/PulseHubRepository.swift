import Foundation

struct PulseHubRepository: PulseHubRepositoryProtocol {
    private static let maximumTerminalTaskCount = TaskRetentionPolicy.maximumTerminalTasks

    private struct Source: Sendable {
        let coordinator: TimedModelSource
    }

    private let sources: [Source]
    private let receiptRepository: any TaskRepositoryProtocol

    init(
        sources modelSources: [any ModelSnapshotSourceProtocol],
        receiptRepository: any TaskRepositoryProtocol,
        sourceRefreshTimeout: Duration = .seconds(2),
        initialSourceRefreshTimeout: Duration? = nil
    ) {
        precondition(sourceRefreshTimeout > .zero, "Source refresh timeout must be positive")
        let resolvedInitialTimeout = initialSourceRefreshTimeout ?? sourceRefreshTimeout
        precondition(
            resolvedInitialTimeout > .zero,
            "Initial source refresh timeout must be positive"
        )
        sources = modelSources.map { source in
            Source(
                coordinator: TimedModelSource(
                    source: source,
                    timeout: sourceRefreshTimeout,
                    initialTimeout: resolvedInitialTimeout
                )
            )
        }
        self.receiptRepository = receiptRepository
    }

    init(
        repositories: [any ModelTaskRepositoryProtocol],
        receiptRepository: any TaskRepositoryProtocol,
        sourceRefreshTimeout: Duration = .seconds(2),
        initialSourceRefreshTimeout: Duration? = nil
    ) {
        self.init(
            sources: repositories.map { repository in
                SingleModelSourceAdapter(repository: repository)
            },
            receiptRepository: receiptRepository,
            sourceRefreshTimeout: sourceRefreshTimeout,
            initialSourceRefreshTimeout: initialSourceRefreshTimeout
        )
    }

    func snapshot(now: Date) async -> PulseHubSnapshot {
        let sourceSnapshots = await withTaskGroup(
            of: (Int, ModelSourceSnapshot).self,
            returning: [ModelSourceSnapshot].self
        ) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    (index, await source.coordinator.snapshot(now: now))
                }
            }

            var indexedSnapshots: [(Int, ModelSourceSnapshot)] = []
            indexedSnapshots.reserveCapacity(sources.count)
            for await (index, snapshot) in group {
                indexedSnapshots.append((index, snapshot))
            }
            return indexedSnapshots
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
        let sourceModels = resolvingCrossSourceProfileConflicts(
            in: sourceSnapshots,
            now: now
        )

        let models: [ModelTaskSnapshot]
        do {
            let receipts = try await receiptRepository.receiptSnapshot(now: now)
            models = sourceModels.map {
                $0.applying(receipts: receipts)
                    .limitingTerminalTasks(to: Self.maximumTerminalTaskCount)
            }
        } catch {
            models = sourceModels.map {
                $0.replacingReceiptHealth(with: .unavailable(
                    .receipts,
                    message: "Viewed state is unavailable"
                ))
                .limitingTerminalTasks(to: Self.maximumTerminalTaskCount)
            }
        }

        return PulseHubSnapshot(models: models, refreshedAt: now)
    }

    func markViewed(_ tasks: [PulseTask], at date: Date) async throws {
        try await receiptRepository.markViewed(tasks, at: date)
    }

    func unmarkViewed(_ tasks: [PulseTask]) async throws {
        try await receiptRepository.unmarkViewed(tasks)
    }

    private func resolvingCrossSourceProfileConflicts(
        in sourceSnapshots: [ModelSourceSnapshot],
        now: Date
    ) -> [ModelTaskSnapshot] {
        let flattenedModels = sourceSnapshots.flatMap(\.models)
        let profileCounts = flattenedModels.reduce(
            into: [ModelProfileID: Int](),
            { counts, model in
                counts[model.identity.profileID, default: 0] += 1
            }
        )
        var emittedConflictProfiles = Set<ModelProfileID>()
        var resolvedModels: [ModelTaskSnapshot] = []
        resolvedModels.reserveCapacity(flattenedModels.count)

        for model in flattenedModels {
            let profileID = model.identity.profileID
            guard profileCounts[profileID, default: 0] > 1 else {
                resolvedModels.append(model)
                continue
            }
            guard emittedConflictProfiles.insert(profileID).inserted else {
                continue
            }
            resolvedModels.append(ModelTaskSnapshot(
                identity: model.identity,
                tasks: [],
                health: [.unavailable(
                    .runtimeSource,
                    message: "Multiple model sources returned the same profile"
                )],
                refreshedAt: now
            ))
        }
        return resolvedModels
    }
}

#if DEBUG
struct TimedModelSourceDebugState: Equatable, Sendable {
    let inFlightGeneration: UInt64?
    let completionWatcherGeneration: UInt64?
    let waitingCallerCount: Int
}
#endif

actor TimedModelSource {
    private static let maximumWaitingCallerCount = 64

    private struct Flight: Sendable {
        let generation: UInt64
        let task: Task<ModelSourceSnapshot, Never>
    }

    private struct CompletionWatcher: Sendable {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private struct CompletedFlight: Sendable {
        let generation: UInt64
        let snapshot: ModelSourceSnapshot
    }

    private struct WaitingCaller {
        let generation: UInt64
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private enum Outcome: Sendable {
        case snapshot(ModelSourceSnapshot)
        case timedOut
    }

    private let source: any ModelSnapshotSourceProtocol
    private let sourceID: ModelSourceID
    private let timeout: Duration
    private let initialTimeout: Duration
    private var generation: UInt64 = 0
    private var waiterID: UInt64 = 0
    private var inFlight: Flight?
    private var completionWatcher: CompletionWatcher?
    private var completedFlight: CompletedFlight?
    private var waitingCallers: [UInt64: WaitingCaller] = [:]
    private var lastSnapshot: ModelSourceSnapshot?

    init(
        source: any ModelSnapshotSourceProtocol,
        timeout: Duration,
        initialTimeout: Duration? = nil
    ) {
        self.source = source
        sourceID = source.sourceID
        self.timeout = timeout
        self.initialTimeout = initialTimeout ?? timeout
    }

    func snapshot(now: Date) async -> ModelSourceSnapshot {
        let flight: Flight
        if let inFlight {
            flight = inFlight
        } else {
            flight = startFlight(now: now)
        }

        switch await firstOutcome(for: flight) {
        case let .snapshot(snapshot):
            if inFlight?.generation == flight.generation {
                inFlight = nil
                completedFlight = nil
                if completionWatcher?.generation == flight.generation {
                    completionWatcher = nil
                }
            }
            guard snapshot.sourceID == sourceID else {
                return failedSnapshot(
                    now: now,
                    message: "Model source returned an unexpected source identity"
                )
            }
            let profileIDs = snapshot.models.map(\.identity.profileID)
            guard Set(profileIDs).count == profileIDs.count else {
                return failedSnapshot(
                    now: now,
                    message: "Model source returned duplicate profiles"
                )
            }
            lastSnapshot = snapshot
            return snapshot

        case .timedOut:
            return failedSnapshot(
                now: now,
                message: "Model source refresh timed out"
            )
        }
    }

    #if DEBUG
    func debugState() -> TimedModelSourceDebugState {
        TimedModelSourceDebugState(
            inFlightGeneration: inFlight?.generation,
            completionWatcherGeneration: completionWatcher?.generation,
            waitingCallerCount: waitingCallers.count
        )
    }
    #endif

    private func startFlight(now: Date) -> Flight {
        generation &+= 1
        let currentGeneration = generation
        let source = source
        // The flight keeps the `now` of the caller that opened it, so a slow
        // source reports the moment its read began rather than the moment it
        // finished. That is deliberate: `refreshedAt` drives the "updated N
        // ago" label, and anchoring it to completion would claim the data is
        // fresher than the instant it was actually observed.
        let task = Task { await source.snapshot(now: now) }
        let flight = Flight(generation: currentGeneration, task: task)
        inFlight = flight

        let watcher = Task { [weak self] in
            let snapshot = await task.value
            await self?.completeFlight(
                generation: currentGeneration,
                snapshot: snapshot
            )
        }
        completionWatcher = CompletionWatcher(
            generation: currentGeneration,
            task: watcher
        )
        return flight
    }

    private func firstOutcome(for flight: Flight) async -> Outcome {
        if let completedFlight,
           completedFlight.generation == flight.generation
        {
            return .snapshot(completedFlight.snapshot)
        }

        waiterID &+= 1
        let currentWaiterID = waiterID
        let timeout = lastSnapshot == nil ? initialTimeout : self.timeout

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let completedFlight,
                   completedFlight.generation == flight.generation
                {
                    continuation.resume(returning: .snapshot(completedFlight.snapshot))
                    return
                }
                if Task.isCancelled {
                    continuation.resume(returning: .timedOut)
                    return
                }
                guard waitingCallers.count < Self.maximumWaitingCallerCount else {
                    continuation.resume(returning: .timedOut)
                    return
                }

                waitingCallers[currentWaiterID] = WaitingCaller(
                    generation: flight.generation,
                    continuation: continuation
                )
                Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.resolveWaitingCaller(
                        id: currentWaiterID,
                        generation: flight.generation,
                        outcome: .timedOut
                    )
                }
            }
        } onCancel: {
            Task {
                await self.resolveWaitingCaller(
                    id: currentWaiterID,
                    generation: flight.generation,
                    outcome: .timedOut
                )
            }
        }
    }

    private func completeFlight(
        generation: UInt64,
        snapshot: ModelSourceSnapshot
    ) {
        guard inFlight?.generation == generation else { return }
        completedFlight = CompletedFlight(
            generation: generation,
            snapshot: snapshot
        )

        let matchingCallerIDs = waitingCallers.compactMap { id, caller in
            caller.generation == generation ? id : nil
        }
        for id in matchingCallerIDs {
            resolveWaitingCaller(
                id: id,
                generation: generation,
                outcome: .snapshot(snapshot)
            )
        }
    }

    private func resolveWaitingCaller(
        id: UInt64,
        generation: UInt64,
        outcome: Outcome
    ) {
        guard let caller = waitingCallers[id],
              caller.generation == generation
        else {
            return
        }
        waitingCallers[id] = nil
        caller.continuation.resume(returning: outcome)
    }

    private func failedSnapshot(now: Date, message: String) -> ModelSourceSnapshot {
        var seenProfileIDs = Set<ModelProfileID>()
        let fallbackIdentities = source.fallbackIdentities.filter { identity in
            seenProfileIDs.insert(identity.profileID).inserted
        }
        let currentPlanKinds = Set(fallbackIdentities.compactMap(\.planKind))
        let cachedPlanKinds = Set(
            lastSnapshot?.models.compactMap(\.identity.planKind) ?? []
        )
        let canReuseLastSnapshot = fallbackIdentities.isEmpty
            || currentPlanKinds == cachedPlanKinds

        if let lastSnapshot, canReuseLastSnapshot {
            return ModelSourceSnapshot(
                sourceID: sourceID,
                models: lastSnapshot.models.map { model in
                    ModelTaskSnapshot(
                        identity: model.identity,
                        tasks: model.tasks,
                        usage: model.usage,
                        rateLimits: model.rateLimits,
                        health: replacingRuntimeSourceHealth(
                            in: model.health,
                            with: .degraded(
                                .runtimeSource,
                                message: message,
                                lastSuccessAt: lastSnapshot.refreshedAt
                            )
                        ),
                        refreshedAt: model.refreshedAt
                    )
                },
                refreshedAt: lastSnapshot.refreshedAt
            )
        }
        return ModelSourceSnapshot(
            sourceID: sourceID,
            models: fallbackIdentities.map { identity in
                ModelTaskSnapshot(
                    identity: identity,
                    tasks: [],
                    health: [.unavailable(.runtimeSource, message: message)],
                    refreshedAt: now
                )
            },
            refreshedAt: now
        )
    }

    private func replacingRuntimeSourceHealth(
        in health: [AdapterHealth],
        with sourceHealth: AdapterHealth
    ) -> [AdapterHealth] {
        health.filter { $0.adapter != .runtimeSource } + [sourceHealth]
    }
}
