import AppKit
import SwiftUI
import XCTest
@testable import LLMPulse

/// Runtime cover for the interface-language contract.
///
/// `Tests/Localization/test_localization_keys.py` proves every key reaches the
/// English catalog, but it cannot prove the app *reads* that catalog. Two
/// mechanisms are in play and only one is explicit: `PulseL10n` looks a key up
/// in a chosen `.lproj`, while a bare SwiftUI literal is a
/// `LocalizedStringKey` resolved against the environment locale. A regression
/// in either one shows up as raw Simplified Chinese in an English interface,
/// so each is pinned here.
@MainActor
final class LocalizationRuntimeTests: XCTestCase {
    func testPulseL10nResolvesEachLanguageFromItsOwnCatalog() {
        let key = "暂时没有任务"

        XCTAssertEqual(
            PulseL10n.text(key, language: .simplifiedChinese),
            key,
            "Simplified Chinese is the key itself, so it needs no entry."
        )
        XCTAssertNotEqual(
            PulseL10n.text(key, language: .english),
            key,
            "A key that resolves to itself in English means the entry is missing."
        )
    }

    func testPulseL10nFallsBackToTheKeyForAnUnknownEntry() {
        let absent = "这个键从不存在于任何表中"

        XCTAssertEqual(PulseL10n.text(absent, language: .english), absent)
        XCTAssertEqual(PulseL10n.text(absent, language: .simplifiedChinese), absent)
    }

    func testPulseL10nFormatsArgumentsAgainstTheChosenCatalog() {
        let formatted = PulseL10n.text("项目 %@", language: .english, "alpha")

        XCTAssertTrue(formatted.contains("alpha"))
        XCTAssertFalse(
            formatted.contains("项目"),
            "The English catalog entry must supply the surrounding copy."
        )
    }

    /// The other half of the contract: roughly a third of the panel's copy is
    /// a bare SwiftUI literal, resolved from the environment locale rather
    /// than through `PulseL10n`. Rendering is the only observation point —
    /// SwiftUI builds its accessibility tree lazily and nothing materializes
    /// it while no assistive technology is attached.
    func testSwiftUILiteralsFollowTheSelectedInterfaceLanguage() throws {
        // The literal must stay inline. Passing a `String` variable selects
        // `Text(_:)`'s `StringProtocol` overload, which renders verbatim and
        // would make this test pass against a broken app.
        let chineseRender = try render(
            Text("暂时没有任务"),
            locale: AppLanguage.simplifiedChinese.locale
        )
        let englishRender = try render(
            Text("暂时没有任务"),
            locale: AppLanguage.english.locale
        )
        let verbatimRender = try render(
            Text(verbatim: "No tasks right now"),
            locale: AppLanguage.english.locale
        )

        XCTAssertNotEqual(
            englishRender,
            chineseRender,
            "An unchanged render means SwiftUI ignored the environment locale, "
                + "leaving every bare literal Simplified Chinese in English."
        )
        XCTAssertEqual(
            englishRender,
            verbatimRender,
            "The English render must be exactly the catalog's translation."
        )
    }

    // MARK: - Display clock

    /// CI runs in UTC, which is exactly what makes these worth pinning: a
    /// formatter that silently falls back to the system zone renders 12:03
    /// there and passes on any machine already set to Beijing time.
    func testAbsoluteTimesRenderOnTheBeijingClock() throws {
        let formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: "2026-08-23T12:03:00Z"))

        XCTAssertEqual(
            PulseDisplayClock.concrete(date, language: .simplifiedChinese),
            "8月23日 20:03"
        )
        // The English joiner ("Aug 23 at 20:03" vs "Aug 23, 20:03") belongs
        // to the OS's locale data; only the facts are pinned.
        let english = PulseDisplayClock.concrete(date, language: .english)
        XCTAssertTrue(english.contains("Aug 23"), english)
        XCTAssertTrue(english.contains("20:03"), english)
        XCTAssertEqual(
            PulseDisplayClock.day(date, language: .simplifiedChinese),
            "8月23日"
        )
    }

    func testTheQuotaResetDescriptionDefaultsToBeijingTime() throws {
        let date = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-23T12:03:00Z")
        )

        XCTAssertEqual(
            date.pulseQuotaResetDescription(language: .simplifiedChinese),
            date.pulseQuotaResetDescription(
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")),
                language: .simplifiedChinese
            )
        )
        XCTAssertTrue(
            date.pulseQuotaResetDescription(language: .english).contains("20:03"),
            "The clock reading must be Beijing's regardless of the host zone."
        )
    }

    // MARK: - Rendering

    private func render<Content: View>(
        _ content: Content,
        locale: Locale
    ) throws -> Data {
        let view = content
            .font(.system(size: 13))
            .foregroundStyle(.black)
            .frame(width: 320, height: 40, alignment: .leading)
            .background(Color.white)
            .environment(\.locale, locale)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 320, height: 40)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(
            data.count,
            0,
            "An empty render would make every comparison vacuous."
        )
        return data
    }
}
