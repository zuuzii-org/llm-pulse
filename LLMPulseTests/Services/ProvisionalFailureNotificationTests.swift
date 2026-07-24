import Foundation
import XCTest
@testable import LLMPulse

/// Cover for failures the rollout parser is still willing to take back.
///
/// `RolloutJSONLTailParser` reports `.failed` once an error event is followed
/// by a few seconds of silence, and reverts to `.running` if the rollout grows
/// again — an automatic retry does exactly that after its backoff. The panel
/// can show and unshow a row freely; a delivered notification cannot be
/// recalled, so it waits for the inference to settle.
final class ProvisionalFailureNotificationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testAProvisionalFailureIsNotAnnouncedImmediately() {
        var tracker = TaskNotificationTransitionTracker()
        seed(&tracker)

        let notifications = tracker.notifications(in: snapshot(
            task(state: .running),
            at: base.addingTimeInterval(10)
        ))
        XCTAssertTrue(notifications.isEmpty)

        let failure = tracker.notifications(in: snapshot(
            task(state: .failed, isProvisionalFailure: true),
            at: base.addingTimeInterval(20)
        ))
        XCTAssertTrue(failure.isEmpty, "The retry may still be in backoff.")
    }

    func testAProvisionalFailureThatRecoversIsNeverAnnounced() {
        var tracker = TaskNotificationTransitionTracker()
        seed(&tracker)

        _ = tracker.notifications(in: snapshot(
            task(state: .failed, isProvisionalFailure: true),
            at: base.addingTimeInterval(10)
        ))
        let recovered = tracker.notifications(in: snapshot(
            task(state: .running),
            at: base.addingTimeInterval(15)
        ))
        XCTAssertTrue(recovered.isEmpty)

        // Well past the confirmation window, with the task running again.
        let later = tracker.notifications(in: snapshot(
            task(state: .running),
            at: base.addingTimeInterval(600)
        ))
        XCTAssertTrue(later.isEmpty, "A retried task never failed.")
    }

    func testAProvisionalFailureIsAnnouncedOnceItStopsChangingItsMind() {
        var tracker = TaskNotificationTransitionTracker()
        seed(&tracker)

        _ = tracker.notifications(in: snapshot(
            task(state: .failed, isProvisionalFailure: true),
            at: base.addingTimeInterval(10)
        ))

        let confirmed = tracker.notifications(in: snapshot(
            task(state: .failed, isProvisionalFailure: true),
            at: base.addingTimeInterval(
                10 + TaskNotificationTransitionTracker.provisionalFailureConfirmation
            )
        ))
        XCTAssertEqual(confirmed.map(\.kind), [.failed])
    }

    func testAConfirmedProvisionalFailureIsAnnouncedOnlyOnce() {
        var tracker = TaskNotificationTransitionTracker()
        seed(&tracker)

        let window = TaskNotificationTransitionTracker.provisionalFailureConfirmation
        _ = tracker.notifications(in: snapshot(
            task(state: .failed, isProvisionalFailure: true),
            at: base.addingTimeInterval(10)
        ))
        _ = tracker.notifications(in: snapshot(
            task(state: .failed, isProvisionalFailure: true),
            at: base.addingTimeInterval(10 + window)
        ))

        for offset in [window * 2, window * 3, window * 10] {
            let repeated = tracker.notifications(in: snapshot(
                task(state: .failed, isProvisionalFailure: true),
                at: base.addingTimeInterval(10 + offset)
            ))
            XCTAssertTrue(
                repeated.isEmpty,
                "Holding a transition must not turn into re-announcing it."
            )
        }
    }

    func testAnObservedFailureIsAnnouncedImmediately() {
        var tracker = TaskNotificationTransitionTracker()
        seed(&tracker)

        let notifications = tracker.notifications(in: snapshot(
            task(state: .failed),
            at: base.addingTimeInterval(10)
        ))
        XCTAssertEqual(
            notifications.map(\.kind),
            [.failed],
            "A terminal event was observed; there is nothing to take back."
        )
    }

    func testAnObservedFailureSupersedesAHeldInference() {
        var tracker = TaskNotificationTransitionTracker()
        seed(&tracker)

        _ = tracker.notifications(in: snapshot(
            task(state: .failed, isProvisionalFailure: true),
            at: base.addingTimeInterval(10)
        ))
        let observed = tracker.notifications(in: snapshot(
            task(state: .failed),
            at: base.addingTimeInterval(15)
        ))
        XCTAssertEqual(
            observed.map(\.kind),
            [.failed],
            "Confirmation arrived early; there is no reason to keep waiting."
        )
    }

    func testCompletionsAreUnaffected() {
        var tracker = TaskNotificationTransitionTracker()
        seed(&tracker)

        let notifications = tracker.notifications(in: snapshot(
            task(state: .completed),
            at: base.addingTimeInterval(10)
        ))
        XCTAssertEqual(notifications.map(\.kind), [.completed])
    }

    func testProvisionalFailureOnlyAppliesToFailedTasks() {
        // Guards the invariant at the source: a running task can never be
        // marked provisional, so the hold cannot swallow other transitions.
        XCTAssertFalse(task(state: .running, isProvisionalFailure: true).isProvisionalFailure)
        XCTAssertFalse(task(state: .completed, isProvisionalFailure: true).isProvisionalFailure)
        XCTAssertTrue(task(state: .failed, isProvisionalFailure: true).isProvisionalFailure)
    }

    // MARK: - Fixtures

    private func seed(_ tracker: inout TaskNotificationTransitionTracker) {
        _ = tracker.notifications(in: snapshot(task(state: .running), at: base))
    }

    private func task(
        state: PulseTaskState,
        isProvisionalFailure: Bool = false
    ) -> PulseTask {
        PulseTask(
            threadId: "thread-1",
            turnId: "turn-1",
            title: "Retryable request",
            projectDirectory: "/tmp/project",
            state: state,
            startedAt: base.addingTimeInterval(-60),
            updatedAt: base,
            completedAt: state.isTerminal ? base : nil,
            lastStatus: state.rawValue,
            isProvisionalFailure: isProvisionalFailure
        )
    }

    private func snapshot(_ task: PulseTask, at date: Date) -> TaskSnapshot {
        TaskSnapshot(
            tasks: [task],
            refreshedAt: date,
            health: [.healthy(.rolloutJSONL, at: date)]
        )
    }
}
