import Foundation
import XCTest
@testable import LLMPulse

/// Cover for the optional Claude Code bridge.
///
/// Its value over the desktop app's history is not only freshness: a real
/// `resets_at` turns "does this percentage still describe the current
/// window?" from a judgement into arithmetic.
final class ClaudeCLIUsageReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testReadsBothWindowsWithTheVendorsOwnResetTimes() throws {
        let url = try write(
            observedAt: now.addingTimeInterval(-60),
            fiveHour: (75, now.addingTimeInterval(2 * 60 * 60)),
            sevenDay: (29, now.addingTimeInterval(4 * 24 * 60 * 60))
        )
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudeCLIUsageReader(usageURL: url).read(now: now))

        XCTAssertEqual(reading.fiveHourWindow?.usedPercent, 75)
        XCTAssertEqual(reading.fiveHourWindow?.resetSource, .reported)
        XCTAssertEqual(reading.sevenDayWindow?.usedPercent, 29)
        XCTAssertEqual(reading.sevenDayWindow?.resetSource, .reported)
        XCTAssertEqual(reading.observedAt, now.addingTimeInterval(-60))
    }

    /// The whole point of a real reset time: staleness stops being guesswork.
    /// A window whose reset has passed rolled over, so its percentage belongs
    /// to a budget that no longer exists — no matter how recent the sample.
    func testAWindowWhoseResetHasPassedIsWithheldEvenWhenJustWritten() throws {
        let url = try write(
            observedAt: now.addingTimeInterval(-30),
            fiveHour: (75, now.addingTimeInterval(-60)),
            sevenDay: (29, now.addingTimeInterval(4 * 24 * 60 * 60))
        )
        defer { remove(url) }

        let reading = try XCTUnwrap(ClaudeCLIUsageReader(usageURL: url).read(now: now))

        XCTAssertNil(reading.fiveHourWindow, "That five-hour budget already reset.")
        XCTAssertEqual(reading.sevenDayWindow?.usedPercent, 29)
    }

    /// `rate_limits` arrives without a reset only before the first API
    /// response of a session. Then there is nothing to reason with and the
    /// value has to be recent to mean anything.
    func testAPercentageWithoutAResetFallsBackToNeedingToBeFresh() throws {
        let stale = try write(
            observedAt: now.addingTimeInterval(-2 * 60 * 60),
            fiveHour: (75, nil),
            sevenDay: nil
        )
        defer { remove(stale) }
        XCTAssertNil(ClaudeCLIUsageReader(usageURL: stale).read(now: now))

        let fresh = try write(
            observedAt: now.addingTimeInterval(-60),
            fiveHour: (75, nil),
            sevenDay: nil
        )
        defer { remove(fresh) }
        let reading = try XCTUnwrap(ClaudeCLIUsageReader(usageURL: fresh).read(now: now))
        XCTAssertEqual(reading.fiveHourWindow?.usedPercent, 75)
        XCTAssertNil(
            reading.fiveHourWindow?.resetSource,
            "Nothing was reported, so nothing may claim to be."
        )
    }

    func testDataPastTheOuterBoundIsWithheld() throws {
        let url = try write(
            observedAt: now.addingTimeInterval(-13 * 60 * 60),
            fiveHour: nil,
            sevenDay: (29, now.addingTimeInterval(4 * 24 * 60 * 60))
        )
        defer { remove(url) }

        XCTAssertNil(
            ClaudeCLIUsageReader(usageURL: url).read(now: now),
            "A weekly window stays open for days, but a percentage from half a "
                + "day ago understates what has been spent since."
        )
    }

    func testAMissingBridgeIsTheOrdinaryState() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")

        XCTAssertNil(ClaudeCLIUsageReader(usageURL: missing).read(now: now))
    }

    func testMalformedContentYieldsNothing() throws {
        let url = try writeRaw("{\"observedAt\": \"nonsense\"}")
        defer { remove(url) }

        XCTAssertNil(ClaudeCLIUsageReader(usageURL: url).read(now: now))
    }

    func testAnImpossiblePercentageIsRejected() throws {
        let url = try writeRaw(
            "{\"observedAt\":\(Int(now.timeIntervalSince1970)),"
                + "\"rateLimits\":{\"five_hour\":{\"used_percentage\":140}}}"
        )
        defer { remove(url) }

        XCTAssertNil(ClaudeCLIUsageReader(usageURL: url).read(now: now))
    }

    /// The install instructions name a path inside the app bundle. If the
    /// script stops shipping, every one of those instructions goes stale
    /// silently, so the bundle is what gets asserted rather than the repo.
    func testTheBridgeScriptShipsInsideTheApplicationBundle() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "usage-bridge", withExtension: "sh"),
            "usage-bridge.sh must ship in Resources; the setup snippet points at it."
        )
        let script = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))

        // Comments are stripped first: the prose names the fields it promises
        // not to touch, and asserting against that would only ever police the
        // documentation.
        let code = script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")

        XCTAssertTrue(
            code.contains("rate_limits"),
            "The bridge exists to copy exactly that subtree."
        )
        for field in ["session_id", "workspace", "transcript", "model", "cwd"] {
            XCTAssertFalse(
                code.contains(field),
                "The payload also carries \(field); the bridge must not reach for it."
            )
        }
    }

    // MARK: - Fixtures

    private func write(
        observedAt: Date,
        fiveHour: (Int, Date?)?,
        sevenDay: (Int, Date?)?
    ) throws -> URL {
        func window(_ value: (Int, Date?)?) -> String? {
            guard let value else { return nil }
            var fields = ["\"used_percentage\":\(value.0)"]
            if let resetsAt = value.1 {
                fields.append("\"resets_at\":\(Int(resetsAt.timeIntervalSince1970))")
            }
            return "{\(fields.joined(separator: ","))}"
        }
        var limits: [String] = []
        if let five = window(fiveHour) { limits.append("\"five_hour\":\(five)") }
        if let seven = window(sevenDay) { limits.append("\"seven_day\":\(seven)") }
        return try writeRaw(
            "{\"observedAt\":\(Int(observedAt.timeIntervalSince1970)),"
                + "\"rateLimits\":{\(limits.joined(separator: ","))}}"
        )
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
