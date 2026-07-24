import Foundation
import XCTest
@testable import LLMPulse

/// Cover for the account-level usage percentages.
///
/// This file is written by the vendor's desktop app, not by anything here, so
/// a machine that only uses the CLI never sees it move. Showing a percentage
/// from hours ago as if it were current is the failure worth preventing.
final class ClaudePlanUsageReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_918_000)

    func testReadsTheMostRecentSample() throws {
        let url = try write(samples: [
            (now.addingTimeInterval(-600), 10, 3),
            (now.addingTimeInterval(-300), 22, 5),
            (now.addingTimeInterval(-60), 24, 5),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertEqual(reading.fiveHourWindow?.usedPercent, 24)
        XCTAssertEqual(reading.sevenDayWindow?.usedPercent, 5)
        XCTAssertEqual(reading.observedAt, now.addingTimeInterval(-60))
    }

    func testWindowDurationsMatchTheirLabels() throws {
        let url = try write(samples: [(now, 24, 5)])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertEqual(reading.fiveHourWindow?.windowMinutes, 5 * 60)
        XCTAssertEqual(reading.sevenDayWindow?.windowMinutes, 7 * 24 * 60)
    }

    func testAnOutOfOrderFileStillYieldsTheNewestSample() throws {
        // Physical order is not trusted; the timestamps decide.
        let url = try write(samples: [
            (now.addingTimeInterval(-60), 24, 5),
            (now.addingTimeInterval(-600), 10, 3),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertEqual(reading.fiveHourWindow?.usedPercent, 24)
    }

    func testASampleOlderThanTheFreshnessWindowIsWithheld() throws {
        // The desktop app was closed for a day; the last number it wrote says
        // nothing about the account now.
        let url = try write(samples: [(now.addingTimeInterval(-24 * 60 * 60), 90, 40)])
        defer { remove(url) }

        XCTAssertNil(
            ClaudePlanUsageReader(planUsageHistoryURL: url).read(now: now),
            "A stale percentage on screen is indistinguishable from a current one."
        )
    }

    func testASampleWrittenMomentsAheadOfTheClockIsAccepted() throws {
        let url = try write(samples: [(now.addingTimeInterval(5), 24, 5)])
        defer { remove(url) }

        XCTAssertNotNil(ClaudePlanUsageReader(planUsageHistoryURL: url).read(now: now))
    }

    func testAMissingFileIsNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")

        XCTAssertNil(
            ClaudePlanUsageReader(planUsageHistoryURL: missing).read(now: now),
            "Absent is the normal state for a machine that only runs the CLI."
        )
    }

    func testMalformedContentYieldsNothingRatherThanPartialNumbers() throws {
        let url = try writeRaw("{\"samples\": [{\"t\": \"nonsense\"}]}")
        defer { remove(url) }

        XCTAssertNil(ClaudePlanUsageReader(planUsageHistoryURL: url).read(now: now))
    }

    func testPercentagesOutsideTheValidRangeAreRejected() throws {
        let url = try write(samples: [(now, 140, -3)])
        defer { remove(url) }

        XCTAssertNil(
            ClaudePlanUsageReader(planUsageHistoryURL: url).read(now: now),
            "A bar drawn from 140% would render past its track."
        )
    }

    func testOneReadableWindowIsEnough() throws {
        let url = try writeRaw(
            "{\"version\":2,\"samples\":[{\"t\":\(Int(now.timeIntervalSince1970 * 1000)),"
                + "\"u\":{\"fh\":24}}]}"
        )
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertEqual(reading.fiveHourWindow?.usedPercent, 24)
        XCTAssertNil(reading.sevenDayWindow)
    }

    func testAWindowCannotBeBuiltFromAnInvalidPercentage() {
        XCTAssertNil(PlanUsageWindow(usedPercent: -1, windowMinutes: 300))
        XCTAssertNil(PlanUsageWindow(usedPercent: 101, windowMinutes: 300))
        XCTAssertNil(PlanUsageWindow(usedPercent: 50, windowMinutes: 0))
        XCTAssertEqual(PlanUsageWindow(usedPercent: 24, windowMinutes: 300)?.remainingPercent, 76)
    }

    // MARK: - Fixtures

    private func write(samples: [(Date, Int, Int)]) throws -> URL {
        let payload: [String: Any] = [
            "version": 2,
            "samples": samples.map { observedAt, fiveHour, sevenDay in
                [
                    "t": observedAt.timeIntervalSince1970 * 1_000,
                    "org": "org-1",
                    "u": ["fh": fiveHour, "sd": sevenDay],
                ] as [String: Any]
            },
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return url
    }

    private func writeRaw(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
