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

    // MARK: - Idle windows

    /// A third of the recorded time on a real machine sits at zero, because a
    /// five-hour window waits for a request to open it. Calling that "unknown"
    /// spends a third of the product's life implying its own data is broken.
    func testAFiveHourWindowAtZeroReadsAsNotStartedRatherThanUnknown() throws {
        let window = try XCTUnwrap(
            PlanUsageWindow(usedPercent: 0, windowMinutes: 5 * 60)
        )

        XCTAssertTrue(window.hasNotStarted)
    }

    func testAWindowWithAnyUsageHasStartedEvenWithoutAResetTime() throws {
        let window = try XCTUnwrap(
            PlanUsageWindow(usedPercent: 1, windowMinutes: 5 * 60)
        )

        XCTAssertFalse(
            window.hasNotStarted,
            "Consumption proves the window opened; only its reset is unknown."
        )
    }

    func testAKnownResetMeansTheWindowIsOpenEvenAtZeroPercent() throws {
        let window = try XCTUnwrap(PlanUsageWindow(
            usedPercent: 0,
            windowMinutes: 5 * 60,
            resetsAt: now.addingTimeInterval(3 * 60 * 60),
            resetSource: .reported
        ))

        XCTAssertFalse(
            window.hasNotStarted,
            "A reported reset is proof of an open window rounding down to zero."
        )
    }

    func testAWeeklyWindowAtZeroIsAFreshWeekNotAnIdleOne() throws {
        let window = try XCTUnwrap(
            PlanUsageWindow(usedPercent: 0, windowMinutes: 7 * 24 * 60)
        )

        XCTAssertFalse(
            window.hasNotStarted,
            "The weekly window is anchored to the calendar, never to a request."
        )
    }

    // MARK: - Staleness

    /// The regression this file's cutoff caused.
    ///
    /// The vendor's desktop app is the only writer and samples only while it
    /// is open, so on a CLI-first machine the newest sample is routinely
    /// hours old. A six-hour cutoff blanked the whole card for hours a day;
    /// an eight-hour-old weekly percentage is still a usable lower bound and
    /// is now kept, with the caller labelling it.
    func testAWeeklyPercentageSurvivesASampleOlderThanSixHours() throws {
        let observedAt = now.addingTimeInterval(-8 * 60 * 60)
        let url = try write(samples: [(observedAt, 30, 12)])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertEqual(reading.sevenDayWindow?.usedPercent, 12)
        XCTAssertEqual(reading.observedAt, observedAt)
    }

    /// The failure the five-hour rule exists to prevent, taken from a real
    /// machine: 21% recorded, a ten-hour blind spot, then 7%. Showing 21%
    /// during that gap is not stale — it is false, because the window it
    /// measured ended hours earlier.
    func testAFiveHourPercentageIsWithheldOnceItsWindowHasExpired() throws {
        let observedAt = now.addingTimeInterval(-8 * 60 * 60)
        let url = try write(samples: [(observedAt, 21, 14)])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertNil(
            reading.fiveHourWindow,
            "A five-hour window certainly rolled over during an eight-hour gap."
        )
        XCTAssertEqual(
            reading.sevenDayWindow?.usedPercent,
            14,
            "The weekly budget did not roll with it."
        )
    }

    /// Being inside a window that is provably still open is the other way to
    /// earn the number, and it beats mere recency.
    func testAFiveHourPercentageSurvivesWhileItsObservedWindowIsStillOpen() throws {
        let opening = now.addingTimeInterval(-2 * 60 * 60)
        let url = try write(samples: [
            (opening, 0, 5),
            (opening.addingTimeInterval(300), 10, 5),
            (now.addingTimeInterval(-90 * 60), 35, 5),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertEqual(
            reading.fiveHourWindow?.usedPercent,
            35,
            "The sample sits inside a window that has not expired yet."
        )
    }

    /// The weekly anchor makes "did a reset happen since this sample?" a fact
    /// rather than a guess, so a sample from the previous week is withheld
    /// even though it is well inside the age limit.
    func testAWeeklyPercentageFromBeforeTheLastResetIsWithheld() throws {
        let reset = now.addingTimeInterval(-4 * 60 * 60)
        let url = try write(samples: [
            (reset.addingTimeInterval(-8 * 60 * 60), 30, 88),
            (reset.addingTimeInterval(-300), 30, 88),
            (reset.addingTimeInterval(300), 30, 1),
            (reset.addingTimeInterval(600), 30, 1),
        ])
        defer { remove(url) }
        let reader = ClaudePlanUsageReader(planUsageHistoryURL: url)
        let parsed = try XCTUnwrap(reader.parse())

        // A week on, the same file's newest sample predates that week's reset.
        let nextWeek = now.addingTimeInterval(7 * 24 * 60 * 60)
        let reading = reader.reading(from: parsed, now: nextWeek)

        XCTAssertNil(
            reading?.sevenDayWindow,
            "That percentage describes the previous week's budget."
        )
    }

    func testSamplesPastTheOuterBoundAreWithheldEntirely() throws {
        let url = try write(samples: [(now.addingTimeInterval(-13 * 60 * 60), 30, 12)])
        defer { remove(url) }

        XCTAssertNil(
            ClaudePlanUsageReader(planUsageHistoryURL: url).read(now: now),
            "Past twelve hours the number describes the app's last session, not the account."
        )
    }

    func testStalenessIsAskedAgainstTheCurrentMomentNotStored() {
        let observedAt = now.addingTimeInterval(-45 * 60)
        let usage = ModelUsageSnapshot(
            inputTokens: 1,
            outputTokens: 1,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0,
            observedRequestCount: 1,
            observedAt: now,
            sevenDayWindow: PlanUsageWindow(usedPercent: 12, windowMinutes: 7 * 24 * 60),
            planUsageObservedAt: observedAt
        )

        XCTAssertTrue(usage.planUsageIsStale(asOf: now))
        XCTAssertFalse(
            usage.planUsageIsStale(asOf: observedAt.addingTimeInterval(60)),
            "A minute after the sample it is the current reading."
        )
    }

    /// The cadence doubled to fifteen minutes, so the bracket has to survive
    /// one dropped sample or it stops bracketing anything.
    func testACollapseAcrossOneDroppedSampleStillBrackets() throws {
        let turnover = now.addingTimeInterval(-2 * 60 * 60)
        let url = try write(samples: [
            (turnover, 98, 5),
            (turnover.addingTimeInterval(30 * 60), 4, 5),
            (now.addingTimeInterval(-60), 35, 5),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertNotNil(
            reading.fiveHourWindow?.resetsAt,
            "A thirty-minute gap is one missed sample at a fifteen-minute cadence."
        )
    }

    func testACollapseAcrossAWiderGapIsNotBracketed() throws {
        let turnover = now.addingTimeInterval(-2 * 60 * 60)
        let url = try write(samples: [
            (turnover, 98, 5),
            (turnover.addingTimeInterval(40 * 60), 4, 5),
            (now.addingTimeInterval(-60), 35, 5),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertNil(
            reading.fiveHourWindow?.resetsAt,
            "Forty minutes only proves the reset happened sometime in there."
        )
    }

    func testASampleOlderThanADayIsWithheld() throws {
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

    // MARK: - Inferred reset times

    func testWeeklyResetIsProjectedFromAnObservedCollapse() throws {
        // The collapse happened six days ago; the anchor projects one week
        // forward from its bracket midpoint.
        let collapseStart = now.addingTimeInterval(-6 * 24 * 60 * 60)
        let url = try write(samples: [
            (collapseStart, 10, 40),
            (collapseStart.addingTimeInterval(300), 10, 0),
            (now.addingTimeInterval(-60), 10, 32),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        let expected = collapseStart.addingTimeInterval(150 + 7 * 24 * 60 * 60)
        let resetsAt = try XCTUnwrap(reading.sevenDayWindow?.resetsAt)
        XCTAssertEqual(
            resetsAt.timeIntervalSince(expected), 0, accuracy: 1,
            "The anchor is the midpoint of the bracket around the collapse."
        )
        XCTAssertNil(
            reading.fiveHourWindow?.resetsAt,
            "No window opening was observed, so the five-hour side stays silent."
        )
    }

    func testFiveHourResetComesFromTheObservedWindowOpening() throws {
        let opening = now.addingTimeInterval(-3 * 60 * 60)
        let url = try write(samples: [
            (opening, 0, 5),
            (opening.addingTimeInterval(300), 10, 5),
            (now.addingTimeInterval(-60), 35, 5),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        let expected = opening.addingTimeInterval(150 + 5 * 60 * 60)
        let resetsAt = try XCTUnwrap(reading.fiveHourWindow?.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince(expected), 0, accuracy: 1)
    }

    func testAnExpiryAndRestartInsideOneBracketStillMarksTheOpening() throws {
        // Continuous use: the old window expired and the new one opened
        // between two samples, so the collapse moment is also the opening.
        let turnover = now.addingTimeInterval(-2 * 60 * 60)
        let url = try write(samples: [
            (turnover, 98, 5),
            (turnover.addingTimeInterval(300), 4, 5),
            (now.addingTimeInterval(-60), 35, 5),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        let expected = turnover.addingTimeInterval(150 + 5 * 60 * 60)
        let resetsAt = try XCTUnwrap(reading.fiveHourWindow?.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince(expected), 0, accuracy: 1)
    }

    func testAnExpiredFiveHourEstimateIsWithheld() throws {
        // The opening we saw belongs to a window that has already ended; the
        // current one opened while the app was closed. Showing the stale
        // arithmetic would put a past time on screen.
        let opening = now.addingTimeInterval(-6 * 60 * 60)
        let url = try write(samples: [
            (opening, 0, 5),
            (opening.addingTimeInterval(300), 10, 5),
            (now.addingTimeInterval(-60), 35, 5),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertNil(reading.fiveHourWindow?.resetsAt)
    }

    func testAnIdleFiveHourWindowCarriesNoEstimate() throws {
        let opening = now.addingTimeInterval(-60 * 60)
        let url = try write(samples: [
            (opening, 0, 5),
            (opening.addingTimeInterval(300), 10, 5),
            (now.addingTimeInterval(-60), 0, 5),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertNil(
            reading.fiveHourWindow?.resetsAt,
            "Nothing is counting down while the window sits at zero."
        )
    }

    func testACollapseAcrossAWideGapIsNotAnAnchor() throws {
        // The app was closed when the reset happened. The collapse proves it
        // occurred sometime in the gap, which is not a time worth showing.
        let collapseStart = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let url = try write(samples: [
            (collapseStart, 10, 40),
            (collapseStart.addingTimeInterval(40 * 60), 10, 0),
            (now.addingTimeInterval(-60), 10, 12),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertNil(reading.sevenDayWindow?.resetsAt)
    }

    func testARescaledPercentageIsNotAWeeklyReset() throws {
        // A limit increase rescales the used share downward without any
        // reset. Anchoring on it would repeat the error every week.
        let drop = now.addingTimeInterval(-24 * 60 * 60)
        let url = try write(samples: [
            (drop, 10, 60),
            (drop.addingTimeInterval(300), 10, 40),
            (now.addingTimeInterval(-60), 10, 45),
        ])
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertNil(reading.sevenDayWindow?.resetsAt)
    }

    func testAnotherOrganizationsCollapseIsNotThisOnes() throws {
        // Percentages from another organization are a different budget, and
        // the boundary between the two would otherwise read as a collapse.
        let collapseStart = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let url = try writeRaw(makeDocument(samples: [
            (collapseStart, "org-other", 10, 40),
            (collapseStart.addingTimeInterval(300), "org-other", 10, 0),
            (now.addingTimeInterval(-60), "org-current", 10, 12),
        ]))
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudePlanUsageReader(planUsageHistoryURL: url)
            .read(now: now))

        XCTAssertEqual(reading.sevenDayWindow?.usedPercent, 12)
        XCTAssertNil(reading.sevenDayWindow?.resetsAt)
    }

    func testAWindowCannotBeBuiltFromAnInvalidPercentage() {
        XCTAssertNil(PlanUsageWindow(usedPercent: -1, windowMinutes: 300))
        XCTAssertNil(PlanUsageWindow(usedPercent: 101, windowMinutes: 300))
        XCTAssertNil(PlanUsageWindow(usedPercent: 50, windowMinutes: 0))
        XCTAssertEqual(PlanUsageWindow(usedPercent: 24, windowMinutes: 300)?.remainingPercent, 76)
    }

    // MARK: - Fixtures

    private func write(samples: [(Date, Int, Int)]) throws -> URL {
        try writeRaw(makeDocument(
            samples: samples.map { ($0.0, "org-1", $0.1, $0.2) }
        ))
    }

    private func makeDocument(samples: [(Date, String, Int, Int)]) -> String {
        let payload: [String: Any] = [
            "version": 2,
            "samples": samples.map { observedAt, organization, fiveHour, sevenDay in
                [
                    "t": observedAt.timeIntervalSince1970 * 1_000,
                    "org": organization,
                    "u": ["fh": fiveHour, "sd": sevenDay],
                ] as [String: Any]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
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
