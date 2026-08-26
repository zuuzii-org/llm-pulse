import Foundation
import XCTest
@testable import LLMPulse

/// Cover for the membership line: what is read, what is derived, and which
/// source wins.
final class MembershipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: - Renewal derivation

    func testNextRenewalIsProjectedFromTheOriginalAnchor() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let formatter = ISO8601DateFormatter()

        // Anchored on the 31st: February pulls a stepped projection down to
        // the 28th permanently, while projecting from the original anchor
        // returns to the 31st whenever the month has one.
        let anchor = try XCTUnwrap(formatter.date(from: "2026-01-31T06:00:00Z"))
        let inMarch = try XCTUnwrap(formatter.date(from: "2026-03-05T00:00:00Z"))

        let renewal = try XCTUnwrap(MembershipDisplay.nextMonthlyRenewal(
            after: inMarch,
            anchor: anchor,
            calendar: calendar
        ))

        XCTAssertEqual(formatter.string(from: renewal), "2026-03-31T06:00:00Z")
    }

    func testAFutureAnchorIsItsOwnFirstRenewal() {
        let anchor = now.addingTimeInterval(3 * 24 * 60 * 60)

        XCTAssertEqual(
            MembershipDisplay.nextMonthlyRenewal(after: now, anchor: anchor),
            anchor
        )
    }

    // MARK: - Resolution precedence

    func testManualEntryOutranksEverything() {
        let manual = now.addingTimeInterval(10 * 24 * 60 * 60)
        let display = MembershipDisplay.resolve(
            observation: MembershipObservation(
                tierDisplayName: "Max 20x",
                subscriptionAnchor: now.addingTimeInterval(-40 * 24 * 60 * 60),
                trialEndsAt: now.addingTimeInterval(5 * 24 * 60 * 60),
                renewsAt: now.addingTimeInterval(20 * 24 * 60 * 60),
                expiresAt: now.addingTimeInterval(15 * 24 * 60 * 60)
            ),
            manualExpiry: manual,
            now: now
        )

        XCTAssertEqual(display?.date, manual)
        XCTAssertEqual(display?.kind, .manualExpiry)
        XCTAssertEqual(display?.tierDisplayName, "Max 20x")
    }

    func testVendorExpiryOutranksRenewalAndTrial() {
        let expiry = now.addingTimeInterval(8 * 24 * 60 * 60)
        let display = MembershipDisplay.resolve(
            observation: MembershipObservation(
                tierDisplayName: "Coding Plan",
                subscriptionAnchor: now.addingTimeInterval(-40 * 24 * 60 * 60),
                trialEndsAt: now.addingTimeInterval(5 * 24 * 60 * 60),
                renewsAt: now.addingTimeInterval(10 * 24 * 60 * 60),
                expiresAt: expiry
            ),
            manualExpiry: nil,
            now: now
        )

        XCTAssertEqual(display?.date, expiry)
        XCTAssertEqual(display?.kind, .vendorExpiry)
    }

    func testVendorRenewalOutranksTrialEnd() {
        let trialEnd = now.addingTimeInterval(5 * 24 * 60 * 60)
        let renewal = now.addingTimeInterval(10 * 24 * 60 * 60)
        let display = MembershipDisplay.resolve(
            observation: MembershipObservation(
                tierDisplayName: "Coding Plan",
                trialEndsAt: trialEnd,
                renewsAt: renewal
            ),
            manualExpiry: nil,
            now: now
        )

        XCTAssertEqual(display?.date, renewal)
        XCTAssertEqual(display?.kind, .vendorRenewal)
    }

    func testVendorRenewalOutranksDerivedRenewal() {
        let renewal = now.addingTimeInterval(12 * 24 * 60 * 60)
        let display = MembershipDisplay.resolve(
            observation: MembershipObservation(
                tierDisplayName: "Coding Plan",
                subscriptionAnchor: now.addingTimeInterval(-40 * 24 * 60 * 60),
                renewsAt: renewal
            ),
            manualExpiry: nil,
            now: now
        )

        XCTAssertEqual(display?.date, renewal)
        XCTAssertEqual(display?.kind, .vendorRenewal)
    }

    func testATrialEndOutranksTheDerivedRenewal() {
        let trialEnd = now.addingTimeInterval(5 * 24 * 60 * 60)
        let display = MembershipDisplay.resolve(
            observation: MembershipObservation(
                tierDisplayName: "Pro",
                subscriptionAnchor: now.addingTimeInterval(-40 * 24 * 60 * 60),
                trialEndsAt: trialEnd
            ),
            manualExpiry: nil,
            now: now
        )

        XCTAssertEqual(display?.date, trialEnd)
        XCTAssertEqual(display?.kind, .trialEnd)
    }

    func testTheDerivedRenewalIsAlwaysInTheFuture() throws {
        let display = try XCTUnwrap(MembershipDisplay.resolve(
            observation: MembershipObservation(
                tierDisplayName: "Max 20x",
                subscriptionAnchor: now.addingTimeInterval(-100 * 24 * 60 * 60)
            ),
            manualExpiry: nil,
            now: now
        ))

        XCTAssertEqual(display.kind, .derivedRenewal)
        XCTAssertGreaterThan(try XCTUnwrap(display.date), now)
    }

    func testATierAloneStillProducesARow() {
        let display = MembershipDisplay.resolve(
            observation: MembershipObservation(tierDisplayName: "Plus"),
            manualExpiry: nil,
            now: now
        )

        XCTAssertEqual(display?.tierDisplayName, "Plus")
        XCTAssertNil(display?.date)
        XCTAssertNil(display?.kind)
    }

    func testNothingObservedMeansNoRow() {
        XCTAssertNil(MembershipDisplay.resolve(
            observation: nil,
            manualExpiry: nil,
            now: now
        ))
        XCTAssertNil(MembershipDisplay.resolve(
            observation: MembershipObservation(),
            manualExpiry: nil,
            now: now
        ))
    }

    // MARK: - Tier naming

    func testTierNamesReadLikeTheProductNames() {
        XCTAssertEqual(
            MembershipObservation.tierDisplayName(
                fromClaudeRateLimitTier: "default_claude_max_20x"
            ),
            "Max 20x"
        )
        XCTAssertEqual(
            MembershipObservation.tierDisplayName(fromClaudeRateLimitTier: "default_claude_pro"),
            "Pro"
        )
        XCTAssertEqual(
            MembershipObservation.tierDisplayName(fromClaudeRateLimitTier: "some_new_plan"),
            "Some New Plan",
            "An unknown tier keeps its words rather than disappearing."
        )
        XCTAssertNil(MembershipObservation.tierDisplayName(fromClaudeRateLimitTier: nil))
        XCTAssertNil(MembershipObservation.tierDisplayName(fromClaudeRateLimitTier: "  "))

        XCTAssertEqual(
            MembershipObservation.tierDisplayName(fromCodexPlanType: "plus"),
            "Plus"
        )
        XCTAssertNil(MembershipObservation.tierDisplayName(fromCodexPlanType: nil))
    }

    // MARK: - Snapshot threading

    func testSnapshotTransformationsPreserveMembership() {
        let membership = MembershipObservation(tierDisplayName: "Max 20x")
        let snapshot = ModelTaskSnapshot(
            identity: .claudeCode,
            tasks: [],
            membership: membership,
            health: [],
            refreshedAt: now
        )

        let receipts = ReceiptSnapshot(baselineAt: .distantPast, viewedTaskIDs: [])
        XCTAssertEqual(snapshot.applying(receipts: receipts).membership, membership)
        XCTAssertEqual(snapshot.limitingTerminalTasks(to: 5).membership, membership)
        XCTAssertEqual(
            snapshot.replacingReceiptHealth(
                with: .unavailable(.receipts, message: "test")
            ).membership,
            membership
        )
    }

    func testCodexSnapshotDerivesItsTierFromThePlanType() {
        let taskSnapshot = TaskSnapshot(
            tasks: [],
            refreshedAt: now,
            health: [],
            rateLimits: RateLimitSnapshot(
                fiveHour: nil,
                weekly: RateLimitWindowSnapshot(
                    usedPercent: 10,
                    windowMinutes: RateLimitWindowDuration.weeklyMinutes,
                    resetsAt: now.addingTimeInterval(24 * 60 * 60)
                ),
                updatedAt: now,
                planType: "plus"
            )
        )

        XCTAssertEqual(
            ModelTaskSnapshot(codex: taskSnapshot).membership?.tierDisplayName,
            "Plus"
        )
    }

    // MARK: - Account reader

    func testReaderTakesOnlyTheThreeMembershipFields() throws {
        let url = try write(document: """
        {
          "mcpServers": {"secret-server": {"env": {"TOKEN": "must-never-be-read"}}},
          "oauthAccount": {
            "emailAddress": "someone@example.com",
            "organizationRateLimitTier": "default_claude_max_20x",
            "subscriptionCreatedAt": "2026-07-06T06:17:46.879093Z",
            "claudeCodeTrialEndsAt": null
          }
        }
        """)
        defer { remove(url) }

        let observation = try XCTUnwrap(
            ClaudeAccountReader(accountConfigURL: url).read()
        )

        XCTAssertEqual(observation.tierDisplayName, "Max 20x")
        XCTAssertNil(observation.trialEndsAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            observation.subscriptionAnchor,
            formatter.date(from: "2026-07-06T06:17:46.879000Z")
        )
    }

    func testReaderReportsATrialWhenTheAccountIsOnOne() throws {
        let url = try write(document: """
        {"oauthAccount": {"claudeCodeTrialEndsAt": "2026-09-01T00:00:00Z"}}
        """)
        defer { remove(url) }

        let observation = try XCTUnwrap(
            ClaudeAccountReader(accountConfigURL: url).read()
        )

        XCTAssertNotNil(observation.trialEndsAt)
        XCTAssertNil(observation.tierDisplayName)
    }

    func testAMissingOrSignedOutConfigIsNotAnError() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        XCTAssertNil(ClaudeAccountReader(accountConfigURL: missing).read())

        let signedOut = try write(document: "{\"numStartups\": 5}")
        defer { remove(signedOut) }
        XCTAssertNil(ClaudeAccountReader(accountConfigURL: signedOut).read())
    }

    // MARK: - Manual override persistence

    @MainActor
    func testExpiryOverridesSurviveARelaunch() throws {
        let suiteName = "MembershipTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expiry = Date(timeIntervalSince1970: 1_790_000_000)
        let first = PulseSettings(defaults: defaults)
        first.setMembershipExpiryOverride(expiry, for: .codex)

        let second = PulseSettings(defaults: defaults)
        XCTAssertEqual(second.membershipExpiryOverride(for: .codex), expiry)
        XCTAssertNil(
            second.membershipExpiryOverride(for: ModelIdentity.claudeCode.profileID)
        )

        second.setMembershipExpiryOverride(nil, for: .codex)
        let third = PulseSettings(defaults: defaults)
        XCTAssertNil(third.membershipExpiryOverride(for: .codex))
    }

    // MARK: - Fixtures

    private func write(document: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try Data(document.utf8).write(to: url)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
