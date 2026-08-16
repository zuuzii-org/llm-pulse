import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }

    var usesChinesePunctuation: Bool {
        effectiveInterfaceLanguage == .simplifiedChinese
    }

    var effectiveInterfaceLanguage: AppLanguage {
        switch self {
        case .simplifiedChinese, .english:
            return self
        case .system:
            return Self.interfaceLanguage(
                forPreferredLocalization: Bundle.main.preferredLocalizations.first
            )
        }
    }

    static func interfaceLanguage(
        forPreferredLocalization identifier: String?
    ) -> AppLanguage {
        guard let identifier else { return .english }
        return identifier.lowercased().hasPrefix("zh") ? .simplifiedChinese : .english
    }

    func displayName(in interfaceLanguage: AppLanguage) -> String {
        switch self {
        case .system:
            return PulseL10n.text("跟随系统", language: interfaceLanguage)
        case .simplifiedChinese:
            return PulseL10n.text("简体中文", language: interfaceLanguage)
        case .english:
            return "English"
        }
    }

    fileprivate var localizationBundle: Bundle {
        let resourceName: String?
        switch self {
        case .system:
            resourceName = nil
        case .simplifiedChinese:
            resourceName = "zh-Hans"
        case .english:
            resourceName = "en"
        }

        guard let resourceName,
              let path = Bundle.main.path(forResource: resourceName, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

/// The wall clock every absolute time in the product is rendered on.
///
/// Quota resets, inferred renewals, and expiry dates all display in Beijing
/// time by explicit product decision — the audience lives there, and a
/// traveling laptop changing what clock the same reset appears on would be
/// worse than a fixed one. Relative descriptions ("3 分钟前") are unaffected.
enum PulseDisplayClock {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .autoupdatingCurrent

    /// A concrete moment: "8月23日 20:03" / "Aug 23, 20:03".
    static func concrete(_ date: Date, language: AppLanguage) -> String {
        formatted(date, language: language, template: "MMMdHm")
    }

    /// A concrete day: "9月6日" / "Sep 6".
    static func day(_ date: Date, language: AppLanguage) -> String {
        formatted(date, language: language, template: "MMMd")
    }

    private static func formatted(
        _ date: Date,
        language: AppLanguage,
        template: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

enum PulseL10n {
    static func text(
        _ key: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        let format = language.localizationBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: arguments)
    }
}

private struct PulseLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.system
}

extension EnvironmentValues {
    var pulseLanguage: AppLanguage {
        get { self[PulseLanguageEnvironmentKey.self] }
        set { self[PulseLanguageEnvironmentKey.self] = newValue }
    }
}
