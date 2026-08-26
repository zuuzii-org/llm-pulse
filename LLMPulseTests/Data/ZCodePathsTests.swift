import Foundation
import XCTest
@testable import LLMPulse

final class ZCodePathsTests: XCTestCase {
    func testLiveUsesZCodeHomeOverride() {
        let paths = ZCodePaths.live(
            environment: ["ZCODE_HOME": "/tmp/zcode-fixture"],
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(paths.zcodeHome.path, "/tmp/zcode-fixture")
        XCTAssertEqual(paths.databaseURL.path, "/tmp/zcode-fixture/cli/db/db.sqlite")
        XCTAssertEqual(paths.eventLogDirectory.path, "/tmp/zcode-fixture/cli/log")
        XCTAssertEqual(
            paths.entitlementLocalStorageDirectory.path,
            "/Users/example/Library/Application Support/ZCode/session/Local Storage/leveldb"
        )
    }

    func testEmptyOverrideFallsBackToDotZCodeUnderHome() {
        let paths = ZCodePaths.live(
            environment: ["ZCODE_HOME": "   "],
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(paths.zcodeHome.path, "/Users/example/.zcode")
        XCTAssertEqual(
            paths.entitlementLocalStorageDirectory.path,
            "/Users/example/Library/Application Support/ZCode/session/Local Storage/leveldb"
        )
    }

    func testFixtureInitializerKeepsEntitlementCacheInsideFixtureRoot() {
        let paths = ZCodePaths(
            zcodeHome: URL(fileURLWithPath: "/tmp/zcode-fixture", isDirectory: true)
        )

        XCTAssertEqual(
            paths.entitlementLocalStorageDirectory.path,
            "/tmp/zcode-fixture/session/Local Storage/leveldb"
        )
    }

    func testRecentEventLogsRejectUnrelatedFilesAndRemainBounded() throws {
        let tree = try ZCodeTestTree()
        defer { tree.remove() }
        for day in 23...27 {
            try Data().write(to: tree.paths.eventLogDirectory
                .appendingPathComponent("zcode-2026-08-\(day).jsonl"))
        }
        try Data().write(to: tree.paths.eventLogDirectory.appendingPathComponent("other.jsonl"))

        XCTAssertEqual(
            tree.paths.recentEventLogURLs(maximumCount: 3).map(\.lastPathComponent),
            [
                "zcode-2026-08-25.jsonl",
                "zcode-2026-08-26.jsonl",
                "zcode-2026-08-27.jsonl",
            ]
        )
    }
}
