import XCTest
@testable import LLMPulse

@MainActor
final class TaskNavigatorTests: XCTestCase {
    func testBuildsCodexThreadURL() {
        let url = TaskNavigator.taskURL(threadID: "019abc-123")

        XCTAssertEqual(url?.absoluteString, "codex://threads/019abc-123")
    }

    func testEncodesSafeNonASCIIThreadIdentifier() {
        let url = TaskNavigator.taskURL(threadID: "任务 1")

        XCTAssertEqual(url?.scheme, "codex")
        XCTAssertEqual(url?.host, "threads")
        XCTAssertEqual(url?.path, "/任务 1")
    }

    func testRejectsEmptyOrPathLikeIdentifier() {
        XCTAssertNil(TaskNavigator.taskURL(threadID: "  "))
        XCTAssertNil(TaskNavigator.taskURL(threadID: "abc/def"))
        XCTAssertNil(TaskNavigator.taskURL(threadID: "abc\\def"))
    }

    func testOpenUsesGeneratedURL() {
        var openedURL: URL?
        let navigator = TaskNavigator { url in
            openedURL = url
            return true
        }

        XCTAssertTrue(navigator.open(threadID: "thread-42"))
        XCTAssertEqual(openedURL?.absoluteString, "codex://threads/thread-42")
    }

    func testGLMTaskActivatesZCodeWithoutInventingADeepLink() {
        var openedURL: URL?
        var activatedBundleIdentifier: String?
        let navigator = TaskNavigator(
            openHandler: { url in
                openedURL = url
                return true
            },
            activateHandler: { bundleIdentifier in
                activatedBundleIdentifier = bundleIdentifier
                return true
            }
        )
        let task = PulseTask(
            threadId: "session-42",
            identity: .glm,
            sessionID: "session-42",
            title: "GLM task",
            projectDirectory: "/tmp/project",
            state: .running,
            startedAt: .distantPast,
            updatedAt: .distantPast,
            lastStatus: "running"
        )

        XCTAssertTrue(navigator.open(task: task))
        XCTAssertNil(openedURL)
        XCTAssertEqual(activatedBundleIdentifier, "dev.zcode.app")
    }

    func testGLMTaskOpenReturnsFalseWhenZCodeIsNotRunning() {
        let navigator = TaskNavigator(
            openHandler: { _ in XCTFail("GLM must not use a guessed deep link"); return false },
            activateHandler: { _ in false }
        )
        let task = PulseTask(
            threadId: "session-42",
            identity: .glm,
            title: "GLM task",
            projectDirectory: "/tmp/project",
            state: .running,
            startedAt: .distantPast,
            updatedAt: .distantPast,
            lastStatus: "running"
        )

        XCTAssertFalse(navigator.open(task: task))
    }
}
