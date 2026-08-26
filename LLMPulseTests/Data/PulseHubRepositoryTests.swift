import XCTest
@testable import LLMPulse

@MainActor
final class PulseHubRepositoryTests: XCTestCase {
    func testHubSummaryAggregatesEveryProfileInConfiguredOrder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secondaryIdentity = secondaryIdentity()
        let snapshot = PulseHubSnapshot(
            models: [
                ModelTaskSnapshot(
                    identity: .codex,
                    tasks: [
                        makeTask(threadID: "codex-running", turnID: "turn", state: .running),
                        makeTask(
                            threadID: "codex-approval",
                            turnID: "turn",
                            state: .waitingForApproval
                        ),
                        makeTask(
                            threadID: "codex-completed",
                            turnID: "turn",
                            state: .completed
                        ),
                        makeTask(threadID: "codex-failed", turnID: "turn", state: .failed),
                    ],
                    health: [],
                    refreshedAt: now
                ),
                ModelTaskSnapshot(
                    identity: secondaryIdentity,
                    tasks: [
                        makeSecondaryTask(
                            identity: secondaryIdentity,
                            sessionID: "secondary-answer",
                            turnID: "turn",
                            state: .waitingForAnswer
                        ),
                        makeSecondaryTask(
                            identity: secondaryIdentity,
                            sessionID: "secondary-completed",
                            turnID: "turn",
                            state: .completed
                        ),
                        makeSecondaryTask(
                            identity: secondaryIdentity,
                            sessionID: "secondary-interrupted",
                            turnID: "turn",
                            state: .interrupted
                        ),
                    ],
                    health: [],
                    refreshedAt: now
                ),
            ],
            refreshedAt: now
        )

        let summary = snapshot.summary

        XCTAssertEqual(summary.activeCount, 3)
        XCTAssertEqual(summary.recentCompletedCount, 4)
        XCTAssertEqual(summary.waitingActionCount, 2)
        XCTAssertTrue(summary.hasWaitingAction)
        XCTAssertTrue(summary.hasFailures)
        XCTAssertEqual(summary.profiles.map(\.identity.profileID), [
            .codex,
            secondaryIdentity.profileID,
        ])
        XCTAssertEqual(summary.profiles[0].activeCount, 2)
        XCTAssertEqual(summary.profiles[0].recentCompletedCount, 2)
        XCTAssertEqual(summary.profiles[0].waitingActionCount, 1)
        XCTAssertTrue(summary.profiles[0].hasFailures)
        XCTAssertEqual(summary.profiles[1].activeCount, 1)
        XCTAssertEqual(summary.profiles[1].recentCompletedCount, 2)
        XCTAssertEqual(summary.profiles[1].waitingActionCount, 1)
        XCTAssertTrue(summary.profiles[1].hasFailures)
    }

    func testEmptyHubSummaryHasNoProfilesOrActivity() {
        let summary = PulseHubSnapshot.empty.summary

        XCTAssertTrue(summary.profiles.isEmpty)
        XCTAssertEqual(summary.activeCount, 0)
        XCTAssertEqual(summary.recentCompletedCount, 0)
        XCTAssertEqual(summary.waitingActionCount, 0)
        XCTAssertFalse(summary.hasWaitingAction)
        XCTAssertFalse(summary.hasFailures)
    }

    func testCodexTaskDefaultsPreserveLegacyIdentityAndID() throws {
        let task = makeTask(threadID: "thread-1", turnID: "turn-1")

        XCTAssertEqual(task.id, "thread-1:turn-1")
        XCTAssertEqual(task.profileID, .codex)
        XCTAssertEqual(task.runtime, .codexDesktop)
        XCTAssertEqual(task.provider, .openAI)
        XCTAssertEqual(task.modelID, "codex")
        XCTAssertEqual(task.sessionID, "thread-1")

        let encoded = try JSONEncoder().encode(task)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in ["profileID", "runtime", "provider", "modelID", "sessionID"] {
            object.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PulseTask.self, from: legacyData)

        XCTAssertEqual(decoded.id, task.id)
        XCTAssertEqual(decoded.profileID, .codex)
        XCTAssertEqual(decoded.runtime, .codexDesktop)
        XCTAssertEqual(decoded.provider, .openAI)
        XCTAssertEqual(decoded.modelID, "codex")
        XCTAssertEqual(decoded.sessionID, task.threadId)
    }

    func testSecondaryRuntimeTaskUsesNamespacedSessionIdentity() {
        let identity = secondaryIdentity()
        let task = PulseTask(
            threadId: "legacy-thread-field",
            turnId: "turn-7",
            identity: identity,
            sessionID: "session-42",
            title: "Secondary task",
            projectDirectory: "/tmp/secondary",
            state: .running,
            startedAt: .distantPast,
            updatedAt: .distantPast,
            lastStatus: "running"
        )

        XCTAssertEqual(
            identity.profileID.rawValue,
            "test-runtime:test-plan-a:test-model"
        )
        XCTAssertEqual(identity.modelID, "test-model")
        XCTAssertTrue(task.id.hasPrefix("test-runtime:"))
        XCTAssertNotEqual(task.id, "test-runtime:session-42:turn-7")
        XCTAssertEqual(task.sessionID, "session-42")
    }

    func testGLMIdentityUsesStableZCodeProfile() throws {
        let identity = ModelIdentity.glm

        XCTAssertEqual(identity.profileID, .glm)
        XCTAssertEqual(identity.profileID.rawValue, "zcode-desktop:bigmodel:glm")
        XCTAssertEqual(identity.runtime, .zcodeDesktop)
        XCTAssertEqual(identity.provider, .bigModel)
        XCTAssertEqual(identity.modelID, "glm")
        XCTAssertEqual(identity.displayName, "GLM")
        XCTAssertTrue(identity.profileID.isConsistent(
            runtime: .zcodeDesktop,
            provider: .bigModel,
            modelID: "glm"
        ))

        let encoded = try JSONEncoder().encode(identity)
        XCTAssertEqual(try JSONDecoder().decode(ModelIdentity.self, from: encoded), identity)
    }

    func testSecondaryRuntimeTaskIDsStayStableAcrossProfilesAndEncodeComponents() throws {
        let tokenPlan = try XCTUnwrap(ModelIdentity(
            runtime: AIRuntimeID(rawValue: "test-runtime"),
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: "test-model",
            displayName: "Secondary3.7 Max",
            planKind: ModelPlanKind(rawValue: "test-plan-a")
        ))
        let codingPlan = try XCTUnwrap(ModelIdentity(
            runtime: AIRuntimeID(rawValue: "test-runtime"),
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: "test-model-plus",
            displayName: "Secondary3.7 Plus",
            planKind: ModelPlanKind(rawValue: "test-plan-b")
        ))
        let tokenTask = makeSecondaryTask(
            identity: tokenPlan,
            sessionID: "shared:session",
            turnID: "shared:turn"
        )
        let codingTask = makeSecondaryTask(
            identity: codingPlan,
            sessionID: "shared:session",
            turnID: "shared:turn"
        )
        let codexTask = makeTask(
            threadID: "shared:session",
            turnID: "shared:turn"
        )

        XCTAssertEqual(tokenTask.id, codingTask.id)
        XCTAssertNotEqual(tokenTask.id, codexTask.id)
        XCTAssertFalse(tokenTask.id.contains("shared:session"))
        XCTAssertFalse(tokenTask.id.contains("shared:turn"))
    }

    func testModelIdentityRejectsUnsupportedRuntimeProviderAndEmptyModel() {
        XCTAssertNil(ModelIdentity(
            runtime: .codexDesktop,
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: "test-model",
            displayName: "Secondary3.7 Max",
            planKind: ModelPlanKind(rawValue: "test-plan-a")
        ))
        XCTAssertNil(ModelIdentity(
            runtime: AIRuntimeID(rawValue: "test-runtime"),
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: "",
            displayName: "Secondary",
            planKind: ModelPlanKind(rawValue: "test-plan-a")
        ))
        XCTAssertNil(ModelIdentity(
            runtime: AIRuntimeID(rawValue: "test-runtime"),
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: "secondary:unsafe",
            displayName: "Secondary",
            planKind: ModelPlanKind(rawValue: "test-plan-a")
        ))
        XCTAssertNil(ModelIdentity(
            runtime: .codexDesktop,
            provider: .openAI,
            modelID: "gpt-5",
            displayName: "Codex",
            planKind: nil
        ))
        XCTAssertNil(ModelIdentity(
            runtime: .zcodeDesktop,
            provider: .anthropic,
            modelID: "glm",
            displayName: "GLM"
        ))
        XCTAssertNil(ModelIdentity(
            runtime: .zcodeDesktop,
            provider: .bigModel,
            modelID: "glm-5.3",
            displayName: "GLM"
        ))
    }

    func testModelIdentityRejectsAnInconsistentEncodedProfile() throws {
        let identity = secondaryIdentity()
        let encoded = try JSONEncoder().encode(identity)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["profileID"] = ["rawValue": ModelProfileID.codex.rawValue]
        let inconsistent = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ModelIdentity.self, from: inconsistent))
    }

    func testModelSnapshotDropsTasksFromAnotherProfile() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codexTask = makeTask(threadID: "codex", turnID: "turn")
        let snapshot = ModelTaskSnapshot(
            identity: secondaryIdentity(),
            tasks: [codexTask],
            health: [],
            refreshedAt: now
        )

        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertEqual(snapshot.health.first?.adapter, .runtimeSource)
        XCTAssertEqual(snapshot.health.first?.status, .degraded)
    }

    func testCodexSourceRepositoryPreservesLegacySnapshot() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = makeTask(threadID: "codex", turnID: "turn")
        let taskSnapshot = TaskSnapshot(
            tasks: [task],
            refreshedAt: now,
            health: [.healthy(.rolloutJSONL, at: now)],
            rateLimits: RateLimitSnapshot(
                fiveHour: nil,
                weekly: nil,
                updatedAt: now,
                planType: "plus"
            )
        )
        let legacyRepository = RecordingTaskRepository(snapshot: taskSnapshot)
        let source = CodexSourceRepository(repository: legacyRepository)

        let modelSnapshot = await source.snapshot(now: now)

        XCTAssertEqual(source.profileID, .codex)
        XCTAssertEqual(modelSnapshot.identity, .codex)
        XCTAssertNil(modelSnapshot.usage)
        XCTAssertEqual(modelSnapshot.taskSnapshot, taskSnapshot)
    }

    func testHubRefreshesSourcesConcurrentlyButPreservesConfiguredOrder() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codexSnapshot = ModelTaskSnapshot(
            identity: .codex,
            tasks: [makeTask(threadID: "codex", turnID: "turn")],
            health: [.healthy(.rolloutJSONL, at: now)],
            refreshedAt: now
        )
        let secondaryIdentity = secondaryIdentity()
        let secondarySnapshot = ModelTaskSnapshot(
            identity: secondaryIdentity,
            tasks: [],
            usage: ModelUsageSnapshot(
                inputTokens: 100,
                outputTokens: 20,
                cacheCreationInputTokens: 8,
                cacheReadInputTokens: 40,
                observedRequestCount: 2,
                observedAt: now
            ),
            health: [.unavailable(.rolloutJSONL, message: "Secondary fixture degraded")],
            refreshedAt: now
        )
        let receipts = RecordingTaskRepository(snapshot: .empty)
        let repository = PulseHubRepository(
            repositories: [
                DelayedModelRepository(snapshot: codexSnapshot, delayNanoseconds: 40_000_000),
                DelayedModelRepository(snapshot: secondarySnapshot, delayNanoseconds: 0),
            ],
            receiptRepository: receipts
        )

        let hubSnapshot = await repository.snapshot(now: now)

        XCTAssertEqual(
            hubSnapshot.models.map(\.identity.profileID),
            [.codex, secondaryIdentity.profileID]
        )
        XCTAssertEqual(hubSnapshot.refreshedAt, now)
        XCTAssertEqual(hubSnapshot.codexTaskSnapshot?.tasks.map(\.id), ["codex:turn"])
        XCTAssertEqual(
            hubSnapshot.model(for: secondaryIdentity.profileID)?.health.first?.status,
            .unavailable
        )
    }

    func testInitialRefreshCanWaitLongerThanSteadyStateTimeout() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = makeTask(threadID: "slow-initial", turnID: "turn")
        let snapshot = ModelTaskSnapshot(
            identity: .codex,
            tasks: [task],
            health: [],
            refreshedAt: now
        )
        let repository = PulseHubRepository(
            repositories: [
                DelayedModelRepository(
                    snapshot: snapshot,
                    delayNanoseconds: 50_000_000
                ),
            ],
            receiptRepository: RecordingTaskRepository(snapshot: .empty),
            sourceRefreshTimeout: .milliseconds(10),
            initialSourceRefreshTimeout: .milliseconds(250)
        )

        let result = await repository.snapshot(now: now)

        XCTAssertEqual(result.codexTaskSnapshot?.tasks.map(\.id), [task.id])
        XCTAssertFalse(
            result.models.flatMap(\.health).contains {
                $0.adapter == .runtimeSource && $0.status == .unavailable
            }
        )
    }

    func testInitialRefreshStillHonorsItsHardTimeout() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let probe = SourceStartProbe()
        let source = BlockingModelSource(
            sourceID: ModelSourceID(singleProfile: .codex),
            fallbackIdentities: [.codex],
            snapshot: ModelSourceSnapshot(
                sourceID: ModelSourceID(singleProfile: .codex),
                models: [ModelTaskSnapshot(
                    identity: .codex,
                    tasks: [],
                    health: [],
                    refreshedAt: now
                )],
                refreshedAt: now
            ),
            probe: probe
        )
        let repository = PulseHubRepository(
            sources: [source],
            receiptRepository: RecordingTaskRepository(snapshot: .empty),
            sourceRefreshTimeout: .milliseconds(10),
            initialSourceRefreshTimeout: .milliseconds(40)
        )

        let result = await repository.snapshot(now: now)
        await probe.release()

        XCTAssertEqual(result.models.map(\.identity.profileID), [.codex])
        XCTAssertEqual(
            result.models.first?.health.first { $0.adapter == .runtimeSource }?.status,
            .unavailable
        )
    }

    func testHubStartsEverySourceBeforeEitherOneCompletes() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let probe = SourceStartProbe()
        let codexSnapshot = ModelTaskSnapshot(
            identity: .codex,
            tasks: [],
            health: [],
            refreshedAt: now
        )
        let secondarySnapshot = ModelTaskSnapshot(
            identity: secondaryIdentity(),
            tasks: [],
            health: [],
            refreshedAt: now
        )
        let receipts = RecordingTaskRepository(snapshot: .empty)
        let repository = PulseHubRepository(
            repositories: [
                BarrierModelRepository(snapshot: codexSnapshot, probe: probe),
                BarrierModelRepository(snapshot: secondarySnapshot, probe: probe),
            ],
            receiptRepository: receipts
        )
        let refresh = Task { await repository.snapshot(now: now) }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let startedCount = await probe.startedCount()
        await probe.release()
        let result = await refresh.value

        XCTAssertEqual(startedCount, 2)
        XCTAssertEqual(result.models.count, 2)
    }

    func testHubExpandsMultipleModelsFromOneDynamicSourceInStableOrder() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secondary = secondaryIdentity()
        let tertiary = tertiaryIdentity()
        let codexSourceID = ModelSourceID(rawValue: "codex-runtime")
        let secondarySourceID = ModelSourceID(rawValue: "test-runtime-source")
        let receipts = RecordingTaskRepository(snapshot: .empty)
        let repository = PulseHubRepository(
            sources: [
                StaticModelSource(
                    sourceID: codexSourceID,
                    snapshot: ModelSourceSnapshot(
                        sourceID: codexSourceID,
                        models: [ModelTaskSnapshot(
                            identity: .codex,
                            tasks: [],
                            health: [],
                            refreshedAt: now
                        )],
                        refreshedAt: now
                    ),
                    delayNanoseconds: 40_000_000
                ),
                StaticModelSource(
                    sourceID: secondarySourceID,
                    snapshot: ModelSourceSnapshot(
                        sourceID: secondarySourceID,
                        models: [
                            ModelTaskSnapshot(
                                identity: secondary,
                                tasks: [],
                                health: [],
                                refreshedAt: now
                            ),
                            ModelTaskSnapshot(
                                identity: tertiary,
                                tasks: [],
                                health: [],
                                refreshedAt: now
                            ),
                        ],
                        refreshedAt: now
                    )
                ),
            ],
            receiptRepository: receipts
        )

        let result = await repository.snapshot(now: now)

        XCTAssertEqual(result.models.map(\.identity.profileID), [
            .codex,
            secondary.profileID,
            tertiary.profileID,
        ])
    }

    func testTimedOutDynamicSourceFallsBackAsOneAtomicModelSet() async {
        let firstRefresh = Date(timeIntervalSince1970: 1_800_000_000)
        let timedOutRefresh = firstRefresh.addingTimeInterval(10)
        let secondary = secondaryIdentity()
        let tertiary = tertiaryIdentity()
        let maxTask = makeSecondaryTask(
            identity: secondary,
            sessionID: "max-session",
            turnID: "turn"
        )
        let plusTask = makeSecondaryTask(
            identity: tertiary,
            sessionID: "plus-session",
            turnID: "turn"
        )
        let sourceID = ModelSourceID(rawValue: "test-runtime-source")
        let initialSnapshot = ModelSourceSnapshot(
            sourceID: sourceID,
            models: [
                ModelTaskSnapshot(
                    identity: secondary,
                    tasks: [maxTask],
                    health: [],
                    refreshedAt: firstRefresh
                ),
                ModelTaskSnapshot(
                    identity: tertiary,
                    tasks: [plusTask],
                    health: [],
                    refreshedAt: firstRefresh
                ),
            ],
            refreshedAt: firstRefresh
        )
        let probe = SourceStartProbe()
        let source = FirstThenBlockingModelSource(
            sourceID: sourceID,
            initialSnapshot: initialSnapshot,
            probe: probe
        )
        let repository = PulseHubRepository(
            sources: [source],
            receiptRepository: RecordingTaskRepository(snapshot: .empty),
            sourceRefreshTimeout: .milliseconds(20)
        )

        let initialResult = await repository.snapshot(now: firstRefresh)
        let timedOutResult = await repository.snapshot(now: timedOutRefresh)
        await probe.release()

        XCTAssertEqual(initialResult.models.count, 2)
        XCTAssertEqual(timedOutResult.models.map(\.identity.profileID), [
            secondary.profileID,
            tertiary.profileID,
        ])
        XCTAssertEqual(
            timedOutResult.models.flatMap(\.tasks).map(\.id),
            [maxTask.id, plusTask.id]
        )
        for model in timedOutResult.models {
            let runtimeHealth = model.health.first { $0.adapter == .runtimeSource }
            XCTAssertEqual(runtimeHealth?.status, .degraded)
            XCTAssertEqual(runtimeHealth?.lastSuccessAt, firstRefresh)
            XCTAssertEqual(model.refreshedAt, firstRefresh)
        }
    }

    func testRepeatedTimeoutsKeepOneBlockedFlightAndExpireEveryCaller() async {
        let now = Date(timeIntervalSince1970: 1_800_000_050)
        let identity = secondaryIdentity()
        let sourceID = ModelSourceID(rawValue: "permanently-blocked-runtime")
        let probe = SourceStartProbe()
        let source = BlockingModelSource(
            sourceID: sourceID,
            fallbackIdentities: [identity],
            snapshot: ModelSourceSnapshot(
                sourceID: sourceID,
                models: [ModelTaskSnapshot(
                    identity: identity,
                    tasks: [],
                    health: [],
                    refreshedAt: now
                )],
                refreshedAt: now
            ),
            probe: probe
        )
        let coordinator = TimedModelSource(
            source: source,
            timeout: .milliseconds(10)
        )

        for offset in 0..<6 {
            let timedOut = await coordinator.snapshot(
                now: now.addingTimeInterval(Double(offset))
            )
            XCTAssertEqual(timedOut.models.map(\.identity), [identity])
            XCTAssertEqual(
                timedOut.models.first?.health.first {
                    $0.adapter == .runtimeSource
                }?.status,
                .unavailable
            )
            let state = await coordinator.debugState()
            XCTAssertEqual(state.inFlightGeneration, 1)
            XCTAssertEqual(state.completionWatcherGeneration, 1)
            XCTAssertEqual(state.waitingCallerCount, 0)
        }

        let sourceStartCount = await probe.startedCount()
        XCTAssertEqual(sourceStartCount, 1)

        await probe.release()
        let recovered = await coordinator.snapshot(now: now.addingTimeInterval(10))
        XCTAssertEqual(recovered.models.map(\.identity), [identity])
        let finalState = await coordinator.debugState()
        XCTAssertNil(finalState.inFlightGeneration)
        XCTAssertNil(finalState.completionWatcherGeneration)
        XCTAssertEqual(finalState.waitingCallerCount, 0)
    }

    func testCrossSourceDuplicateProfileFailsClosedWithoutDroppingOthers() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secondary = secondaryIdentity()
        let tertiary = tertiaryIdentity()
        let firstSecondaryTask = makeSecondaryTask(
            identity: secondary,
            sessionID: "first-source",
            turnID: "turn"
        )
        let secondSecondaryTask = makeSecondaryTask(
            identity: secondary,
            sessionID: "second-source",
            turnID: "turn"
        )
        let plusTask = makeSecondaryTask(
            identity: tertiary,
            sessionID: "plus-source",
            turnID: "turn"
        )
        let firstSourceID = ModelSourceID(rawValue: "first-runtime")
        let secondSourceID = ModelSourceID(rawValue: "second-runtime")
        let repository = PulseHubRepository(
            sources: [
                StaticModelSource(
                    sourceID: firstSourceID,
                    snapshot: ModelSourceSnapshot(
                        sourceID: firstSourceID,
                        models: [
                            ModelTaskSnapshot(
                                identity: .codex,
                                tasks: [],
                                health: [],
                                refreshedAt: now
                            ),
                            ModelTaskSnapshot(
                                identity: secondary,
                                tasks: [firstSecondaryTask],
                                health: [],
                                refreshedAt: now
                            ),
                        ],
                        refreshedAt: now
                    )
                ),
                StaticModelSource(
                    sourceID: secondSourceID,
                    snapshot: ModelSourceSnapshot(
                        sourceID: secondSourceID,
                        models: [
                            ModelTaskSnapshot(
                                identity: secondary,
                                tasks: [secondSecondaryTask],
                                health: [],
                                refreshedAt: now
                            ),
                            ModelTaskSnapshot(
                                identity: tertiary,
                                tasks: [plusTask],
                                health: [],
                                refreshedAt: now
                            ),
                        ],
                        refreshedAt: now
                    )
                ),
            ],
            receiptRepository: RecordingTaskRepository(snapshot: .empty)
        )

        let result = await repository.snapshot(now: now)

        XCTAssertEqual(result.models.map(\.identity.profileID), [
            .codex,
            secondary.profileID,
            tertiary.profileID,
        ])
        let conflictedModel = result.models[1]
        XCTAssertTrue(conflictedModel.tasks.isEmpty)
        XCTAssertNil(conflictedModel.usage)
        XCTAssertNil(conflictedModel.rateLimits)
        XCTAssertEqual(
            conflictedModel.health.first { $0.adapter == .runtimeSource }?.status,
            .unavailable
        )
        XCTAssertEqual(result.models[2].tasks.map(\.id), [plusTask.id])
    }

    func testUnexpectedDynamicSourceIdentityFailsClosed() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = secondaryIdentity()
        let declaredSourceID = ModelSourceID(rawValue: "declared-runtime")
        let returnedSourceID = ModelSourceID(rawValue: "unexpected-runtime")
        let source = StaticModelSource(
            sourceID: declaredSourceID,
            fallbackIdentities: [identity],
            snapshot: ModelSourceSnapshot(
                sourceID: returnedSourceID,
                models: [ModelTaskSnapshot(
                    identity: identity,
                    tasks: [makeSecondaryTask(
                        identity: identity,
                        sessionID: "must-not-leak",
                        turnID: "turn"
                    )],
                    health: [],
                    refreshedAt: now
                )],
                refreshedAt: now
            )
        )
        let repository = PulseHubRepository(
            sources: [source],
            receiptRepository: RecordingTaskRepository(snapshot: .empty)
        )

        let result = await repository.snapshot(now: now)

        XCTAssertEqual(result.models.map(\.identity.profileID), [identity.profileID])
        XCTAssertTrue(result.models[0].tasks.isEmpty)
        XCTAssertEqual(
            result.models[0].health.first { $0.adapter == .runtimeSource }?.status,
            .unavailable
        )
    }

    func testDuplicateProfilesInsideOneDynamicSourceRejectTheWholeSource() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = secondaryIdentity()
        let sourceID = ModelSourceID(rawValue: "test-runtime-source")
        let source = StaticModelSource(
            sourceID: sourceID,
            fallbackIdentities: [identity],
            snapshot: ModelSourceSnapshot(
                sourceID: sourceID,
                models: [
                    ModelTaskSnapshot(
                        identity: identity,
                        tasks: [makeSecondaryTask(
                            identity: identity,
                            sessionID: "first-duplicate",
                            turnID: "turn"
                        )],
                        health: [],
                        refreshedAt: now
                    ),
                    ModelTaskSnapshot(
                        identity: identity,
                        tasks: [makeSecondaryTask(
                            identity: identity,
                            sessionID: "second-duplicate",
                            turnID: "turn"
                        )],
                        health: [],
                        refreshedAt: now
                    ),
                ],
                refreshedAt: now
            )
        )
        let repository = PulseHubRepository(
            sources: [source],
            receiptRepository: RecordingTaskRepository(snapshot: .empty)
        )

        let result = await repository.snapshot(now: now)

        XCTAssertEqual(result.models.map(\.identity.profileID), [identity.profileID])
        XCTAssertTrue(result.models[0].tasks.isEmpty)
        XCTAssertEqual(
            result.models[0].health.first { $0.adapter == .runtimeSource }?.status,
            .unavailable
        )
    }

    func testHubSurfacesMismatchedSourceWithoutDiscardingHealthyProfiles() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secondarySnapshot = ModelTaskSnapshot(
            identity: secondaryIdentity(),
            tasks: [],
            health: [],
            refreshedAt: now
        )
        let receipts = RecordingTaskRepository(snapshot: .empty)
        let repository = PulseHubRepository(
            repositories: [
                DeclaredIdentityModelRepository(
                    declaredIdentity: .codex,
                    snapshot: secondarySnapshot
                ),
                DelayedModelRepository(snapshot: secondarySnapshot),
            ],
            receiptRepository: receipts
        )

        let result = await repository.snapshot(now: now)

        XCTAssertEqual(
            result.models.map(\.identity.profileID),
            [.codex, secondaryIdentity().profileID]
        )
        XCTAssertTrue(result.models[0].tasks.isEmpty)
        XCTAssertEqual(result.models[0].health.first?.adapter, .runtimeSource)
        XCTAssertEqual(result.models[0].health.first?.status, .unavailable)
    }

    func testTimedOutSourceDoesNotBlockHealthyProfile() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secondaryProbe = SourceStartProbe()
        let codexSnapshot = ModelTaskSnapshot(
            identity: .codex,
            tasks: [makeTask(threadID: "codex", turnID: "turn")],
            health: [],
            refreshedAt: now
        )
        let secondarySnapshot = ModelTaskSnapshot(
            identity: secondaryIdentity(),
            tasks: [],
            health: [],
            refreshedAt: now
        )
        let receipts = RecordingTaskRepository(snapshot: .empty)
        let repository = PulseHubRepository(
            repositories: [
                DelayedModelRepository(snapshot: codexSnapshot),
                BarrierModelRepository(snapshot: secondarySnapshot, probe: secondaryProbe),
            ],
            receiptRepository: receipts,
            sourceRefreshTimeout: .milliseconds(20)
        )

        let result = await repository.snapshot(now: now)
        await secondaryProbe.release()

        XCTAssertEqual(result.models.count, 2)
        XCTAssertEqual(result.models[0].tasks.map(\.id), ["codex:turn"])
        XCTAssertEqual(result.models[1].identity, secondaryIdentity())
        XCTAssertEqual(result.models[1].health.first?.adapter, .runtimeSource)
        XCTAssertEqual(result.models[1].health.first?.status, .unavailable)
    }

    func testHubForwardsReceiptMutationsWithoutTouchingSourceData() async throws {
        let task = makeTask(threadID: "codex", turnID: "turn")
        let receipts = RecordingTaskRepository(snapshot: .empty)
        let repository = PulseHubRepository(
            repositories: [],
            receiptRepository: receipts
        )
        let viewedAt = Date(timeIntervalSince1970: 1_800_000_000)

        try await repository.markViewed([task], at: viewedAt)
        try await repository.unmarkViewed([task])

        let mutations = await receipts.mutations()
        XCTAssertEqual(mutations.viewedTaskIDs, [task.id])
        XCTAssertEqual(mutations.viewedAt, viewedAt)
        XCTAssertEqual(mutations.unmarkedTaskIDs, [task.id])
    }

    func testHubAppliesSharedReceiptsToSecondaryTasksEndToEnd() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = secondaryIdentity()
        let completedTask = PulseTask(
            threadId: "secondary-session",
            turnId: "turn",
            identity: identity,
            sessionID: "secondary-session",
            title: "Secondary task",
            projectDirectory: "/tmp/secondary",
            state: .completed,
            startedAt: now.addingTimeInterval(-20),
            updatedAt: now.addingTimeInterval(-1),
            completedAt: now.addingTimeInterval(-1),
            lastStatus: "completed"
        )
        let receipts = RecordingTaskRepository(
            snapshot: .empty,
            receiptBaseline: now.addingTimeInterval(-30)
        )
        let repository = PulseHubRepository(
            repositories: [DelayedModelRepository(snapshot: ModelTaskSnapshot(
                identity: identity,
                tasks: [completedTask],
                health: [],
                refreshedAt: now
            ))],
            receiptRepository: receipts
        )

        var snapshot = await repository.snapshot(now: now)
        XCTAssertEqual(snapshot.models.first?.tasks.first?.isUnread, true)

        try await repository.markViewed([completedTask], at: now)
        snapshot = await repository.snapshot(now: now)
        XCTAssertEqual(snapshot.models.first?.tasks.first?.isUnread, false)

        try await repository.unmarkViewed([completedTask])
        snapshot = await repository.snapshot(now: now)
        XCTAssertEqual(snapshot.models.first?.tasks.first?.isUnread, true)
    }

    func testHubLimitsTerminalRowsAfterReceiptsSoUnreadCompletionWins() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let identity = secondaryIdentity()
        let unreadTask = PulseTask(
            threadId: "unread-oldest",
            turnId: "turn",
            identity: identity,
            sessionID: "unread-oldest",
            title: "Unread completion",
            projectDirectory: "/tmp/unread-oldest",
            state: .completed,
            startedAt: now.addingTimeInterval(-2_000),
            updatedAt: now.addingTimeInterval(-1_000),
            completedAt: now.addingTimeInterval(-1_000),
            lastStatus: PulseTaskState.completed.rawValue
        )
        let viewedTasks = (0..<20).map { index in
            let completedAt = now.addingTimeInterval(-Double(index))
            return PulseTask(
                threadId: "viewed-\(index)",
                turnId: "turn",
                identity: identity,
                sessionID: "viewed-\(index)",
                title: "Viewed completion \(index)",
                projectDirectory: "/tmp/viewed-\(index)",
                state: .completed,
                startedAt: completedAt.addingTimeInterval(-10),
                updatedAt: completedAt,
                completedAt: completedAt,
                lastStatus: PulseTaskState.completed.rawValue
            )
        }
        let receipts = RecordingTaskRepository(
            snapshot: .empty,
            receiptBaseline: now.addingTimeInterval(-3_000)
        )
        try await receipts.markViewed(viewedTasks, at: now)
        let repository = PulseHubRepository(
            repositories: [DelayedModelRepository(snapshot: ModelTaskSnapshot(
                identity: identity,
                tasks: [unreadTask] + viewedTasks,
                health: [],
                refreshedAt: now
            ))],
            receiptRepository: receipts
        )

        let snapshot = await repository.snapshot(now: now)
        let retainedTasks = try XCTUnwrap(snapshot.models.first?.tasks)
        let evictedViewedTask = try XCTUnwrap(viewedTasks.last)

        XCTAssertEqual(retainedTasks.count, 20)
        XCTAssertTrue(retainedTasks.contains { $0.id == unreadTask.id && $0.isUnread })
        XCTAssertFalse(retainedTasks.contains { $0.id == evictedViewedTask.id })
    }

    func testHubStillLimitsTerminalRowsWhenReceiptsAreUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        let identity = secondaryIdentity()
        let tasks = (0..<21).map { index in
            makeSecondaryTask(
                identity: identity,
                sessionID: "receipt-failure-\(index)",
                turnID: "turn",
                state: .completed
            )
        }
        let repository = PulseHubRepository(
            repositories: [DelayedModelRepository(snapshot: ModelTaskSnapshot(
                identity: identity,
                tasks: tasks,
                health: [],
                refreshedAt: now
            ))],
            receiptRepository: UnavailableReceiptRepository()
        )

        let snapshot = await repository.snapshot(now: now)
        let model = try XCTUnwrap(snapshot.models.first)

        XCTAssertEqual(model.tasks.count, 20)
        XCTAssertEqual(
            model.health.first { $0.adapter == .receipts }?.status,
            .unavailable
        )
    }

    func testTaskMonitorPublishesHubButKeepsLegacySnapshotCodexOnly() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codexTask = makeTask(threadID: "codex", turnID: "turn")
        let secondaryIdentity = secondaryIdentity()
        let secondaryTask = PulseTask(
            threadId: "secondary-session",
            turnId: "turn",
            identity: secondaryIdentity,
            sessionID: "secondary-session",
            title: "Secondary task",
            projectDirectory: "/tmp/secondary",
            state: .running,
            startedAt: now,
            updatedAt: now,
            lastStatus: "running"
        )
        let receipts = RecordingTaskRepository(snapshot: .empty)
        let repository = PulseHubRepository(
            repositories: [
                DelayedModelRepository(
                    snapshot: ModelTaskSnapshot(
                        identity: .codex,
                        tasks: [codexTask],
                        health: [.healthy(.rolloutJSONL, at: now)],
                        refreshedAt: now
                    )
                ),
                DelayedModelRepository(
                    snapshot: ModelTaskSnapshot(
                        identity: secondaryIdentity,
                        tasks: [secondaryTask],
                        health: [],
                        refreshedAt: now
                    )
                ),
            ],
            receiptRepository: receipts
        )
        let monitor = TaskMonitor(hubRepository: repository)

        await monitor.refreshNow()

        XCTAssertEqual(monitor.hubSnapshot.models.count, 2)
        XCTAssertEqual(Set(monitor.hubSnapshot.models.flatMap(\.tasks).map(\.id)), [
            codexTask.id,
            secondaryTask.id,
        ])
        XCTAssertEqual(monitor.snapshot.tasks.map(\.id), [codexTask.id])
        XCTAssertFalse(monitor.snapshot.tasks.contains { $0.runtime == AIRuntimeID(rawValue: "test-runtime") })
    }

    func testTaskMonitorProjectsAnEmptyLegacySnapshotWhenCodexIsAbsent() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secondarySnapshot = ModelTaskSnapshot(
            identity: secondaryIdentity(),
            tasks: [],
            health: [],
            refreshedAt: now
        )
        let receipts = RecordingTaskRepository(snapshot: .empty)
        let repository = PulseHubRepository(
            repositories: [DelayedModelRepository(snapshot: secondarySnapshot)],
            receiptRepository: receipts
        )
        let monitor = TaskMonitor(hubRepository: repository)

        await monitor.refreshNow()

        XCTAssertEqual(monitor.hubSnapshot.models.count, 1)
        XCTAssertTrue(monitor.snapshot.tasks.isEmpty)
        XCTAssertEqual(monitor.snapshot.refreshedAt, monitor.hubSnapshot.refreshedAt)
        XCTAssertTrue(monitor.snapshot.health.isEmpty)
    }

    func testTaskMonitorRejectsAnOlderRefreshThatFinishesLast() async {
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let secondDate = firstDate.addingTimeInterval(1)
        let firstTask = makeTask(threadID: "old", turnID: "turn")
        let secondTask = makeTask(threadID: "new", turnID: "turn")
        let repository = OutOfOrderHubRepository(
            first: PulseHubSnapshot(
                models: [ModelTaskSnapshot(
                    identity: .codex,
                    tasks: [firstTask],
                    health: [],
                    refreshedAt: firstDate
                )],
                refreshedAt: firstDate
            ),
            second: PulseHubSnapshot(
                models: [ModelTaskSnapshot(
                    identity: .codex,
                    tasks: [secondTask],
                    health: [],
                    refreshedAt: secondDate
                )],
                refreshedAt: secondDate
            )
        )
        let monitor = TaskMonitor(hubRepository: repository)
        let slowRefresh = Task { await monitor.refreshNow() }
        await repository.waitUntilFirstRefreshStarts()
        let fastRefresh = Task { await monitor.refreshNow() }

        await fastRefresh.value
        await repository.releaseFirstRefresh()
        await slowRefresh.value

        XCTAssertEqual(monitor.snapshot.tasks.map(\.id), [secondTask.id])
        XCTAssertEqual(monitor.hubSnapshot.refreshedAt, secondDate)
    }

    private func secondaryIdentity() -> ModelIdentity {
        ModelIdentity(
            runtime: AIRuntimeID(rawValue: "test-runtime"),
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: " TEST-MODEL ",
            displayName: "Secondary3.7 Max",
            planKind: ModelPlanKind(rawValue: "test-plan-a")
        )!
    }

    private func tertiaryIdentity() -> ModelIdentity {
        ModelIdentity(
            runtime: AIRuntimeID(rawValue: "test-runtime"),
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: "test-model-plus",
            displayName: "Secondary3.7 Plus",
            planKind: ModelPlanKind(rawValue: "test-plan-a")
        )!
    }

    private func makeSecondaryTask(
        identity: ModelIdentity,
        sessionID: String,
        turnID: String,
        state: PulseTaskState = .running
    ) -> PulseTask {
        PulseTask(
            threadId: sessionID,
            turnId: turnID,
            identity: identity,
            sessionID: sessionID,
            title: "Secondary task",
            projectDirectory: "/tmp/secondary",
            state: state,
            startedAt: .distantPast,
            updatedAt: .distantPast,
            completedAt: state.isTerminal ? .distantPast : nil,
            lastStatus: state.rawValue
        )
    }

    private func makeTask(
        threadID: String,
        turnID: String?,
        state: PulseTaskState = .running
    ) -> PulseTask {
        PulseTask(
            threadId: threadID,
            turnId: turnID,
            title: "Task \(threadID)",
            projectDirectory: "/tmp/\(threadID)",
            state: state,
            startedAt: .distantPast,
            updatedAt: .distantPast,
            completedAt: state.isTerminal ? .distantPast : nil,
            lastStatus: state.rawValue
        )
    }
}

private struct StaticModelSource: ModelSnapshotSourceProtocol {
    let sourceID: ModelSourceID
    let fallbackIdentities: [ModelIdentity]
    let snapshotValue: ModelSourceSnapshot
    let delayNanoseconds: UInt64

    init(
        sourceID: ModelSourceID,
        fallbackIdentities: [ModelIdentity] = [],
        snapshot: ModelSourceSnapshot,
        delayNanoseconds: UInt64 = 0
    ) {
        self.sourceID = sourceID
        self.fallbackIdentities = fallbackIdentities
        snapshotValue = snapshot
        self.delayNanoseconds = delayNanoseconds
    }

    func snapshot(now: Date) async -> ModelSourceSnapshot {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return snapshotValue
    }
}

private actor FirstThenBlockingModelSource: ModelSnapshotSourceProtocol {
    nonisolated let sourceID: ModelSourceID

    private let initialSnapshot: ModelSourceSnapshot
    private let probe: SourceStartProbe
    private var requestCount = 0

    init(
        sourceID: ModelSourceID,
        initialSnapshot: ModelSourceSnapshot,
        probe: SourceStartProbe
    ) {
        self.sourceID = sourceID
        self.initialSnapshot = initialSnapshot
        self.probe = probe
    }

    func snapshot(now: Date) async -> ModelSourceSnapshot {
        requestCount += 1
        guard requestCount > 1 else { return initialSnapshot }
        await probe.arriveAndWait()
        return initialSnapshot
    }
}

private actor BlockingModelSource: ModelSnapshotSourceProtocol {
    nonisolated let sourceID: ModelSourceID
    nonisolated let fallbackIdentities: [ModelIdentity]

    private let snapshotValue: ModelSourceSnapshot
    private let probe: SourceStartProbe

    init(
        sourceID: ModelSourceID,
        fallbackIdentities: [ModelIdentity],
        snapshot: ModelSourceSnapshot,
        probe: SourceStartProbe
    ) {
        self.sourceID = sourceID
        self.fallbackIdentities = fallbackIdentities
        snapshotValue = snapshot
        self.probe = probe
    }

    func snapshot(now: Date) async -> ModelSourceSnapshot {
        await probe.arriveAndWait()
        return snapshotValue
    }
}

private struct DelayedModelRepository: ModelTaskRepositoryProtocol {
    let identity: ModelIdentity
    let snapshotValue: ModelTaskSnapshot
    let delayNanoseconds: UInt64

    init(snapshot: ModelTaskSnapshot, delayNanoseconds: UInt64 = 0) {
        identity = snapshot.identity
        snapshotValue = snapshot
        self.delayNanoseconds = delayNanoseconds
    }

    func snapshot(now: Date) async -> ModelTaskSnapshot {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return snapshotValue
    }
}

private struct BarrierModelRepository: ModelTaskRepositoryProtocol {
    let identity: ModelIdentity
    let snapshotValue: ModelTaskSnapshot
    let probe: SourceStartProbe

    init(snapshot: ModelTaskSnapshot, probe: SourceStartProbe) {
        identity = snapshot.identity
        snapshotValue = snapshot
        self.probe = probe
    }

    func snapshot(now: Date) async -> ModelTaskSnapshot {
        await probe.arriveAndWait()
        return snapshotValue
    }
}

private struct DeclaredIdentityModelRepository: ModelTaskRepositoryProtocol {
    let identity: ModelIdentity
    let snapshotValue: ModelTaskSnapshot

    init(declaredIdentity: ModelIdentity, snapshot: ModelTaskSnapshot) {
        identity = declaredIdentity
        snapshotValue = snapshot
    }

    func snapshot(now: Date) async -> ModelTaskSnapshot {
        snapshotValue
    }
}

private actor SourceStartProbe {
    private var starts = 0
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        starts += 1
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func startedCount() -> Int {
        starts
    }

    func release() {
        isReleased = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor OutOfOrderHubRepository: PulseHubRepositoryProtocol {
    private let firstSnapshot: PulseHubSnapshot
    private let secondSnapshot: PulseHubSnapshot
    private var requestCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    init(first: PulseHubSnapshot, second: PulseHubSnapshot) {
        firstSnapshot = first
        secondSnapshot = second
    }

    func snapshot(now: Date) async -> PulseHubSnapshot {
        requestCount += 1
        guard requestCount == 1 else { return secondSnapshot }
        await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
        return firstSnapshot
    }

    func markViewed(_ tasks: [PulseTask], at date: Date) async throws {}
    func unmarkViewed(_ tasks: [PulseTask]) async throws {}

    func waitUntilFirstRefreshStarts() async {
        while requestCount == 0 {
            await Task.yield()
        }
    }

    func releaseFirstRefresh() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor RecordingTaskRepository: TaskRepositoryProtocol {
    struct Mutations: Equatable {
        let viewedTaskIDs: [String]
        let viewedAt: Date?
        let unmarkedTaskIDs: [String]
    }

    private let snapshotValue: TaskSnapshot
    private let receiptBaseline: Date
    private var viewedTaskIDs: [String] = []
    private var receiptViewedTaskIDs: Set<String> = []
    private var viewedAt: Date?
    private var unmarkedTaskIDs: [String] = []

    init(snapshot: TaskSnapshot, receiptBaseline: Date = .distantPast) {
        snapshotValue = snapshot
        self.receiptBaseline = receiptBaseline
    }

    func snapshot(now: Date) async -> TaskSnapshot {
        snapshotValue
    }

    func receiptSnapshot(now: Date) async throws -> ReceiptSnapshot {
        ReceiptSnapshot(
            baselineAt: receiptBaseline,
            viewedTaskIDs: receiptViewedTaskIDs
        )
    }

    func markViewed(_ task: PulseTask, at date: Date) async throws {
        try await markViewed([task], at: date)
    }

    func markViewed(_ tasks: [PulseTask], at date: Date) async throws {
        viewedTaskIDs.append(contentsOf: tasks.map(\.id))
        receiptViewedTaskIDs.formUnion(tasks.map(\.id))
        viewedAt = date
    }

    func unmarkViewed(_ task: PulseTask) async throws {
        try await unmarkViewed([task])
    }

    func unmarkViewed(_ tasks: [PulseTask]) async throws {
        unmarkedTaskIDs.append(contentsOf: tasks.map(\.id))
        receiptViewedTaskIDs.subtract(tasks.map(\.id))
    }

    func mutations() -> Mutations {
        Mutations(
            viewedTaskIDs: viewedTaskIDs,
            viewedAt: viewedAt,
            unmarkedTaskIDs: unmarkedTaskIDs
        )
    }
}

private actor UnavailableReceiptRepository: TaskRepositoryProtocol {
    private enum ReceiptFailure: Error {
        case unavailable
    }

    func snapshot(now: Date) async -> TaskSnapshot {
        .empty
    }

    func receiptSnapshot(now: Date) async throws -> ReceiptSnapshot {
        throw ReceiptFailure.unavailable
    }

    func markViewed(_ task: PulseTask, at date: Date) async throws {}
    func markViewed(_ tasks: [PulseTask], at date: Date) async throws {}
    func unmarkViewed(_ task: PulseTask) async throws {}
    func unmarkViewed(_ tasks: [PulseTask]) async throws {}
}
