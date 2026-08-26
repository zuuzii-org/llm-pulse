import XCTest
@testable import LLMPulse

@MainActor
final class PulseSettingsTests: XCTestCase {
    func testMembershipSettingsExposeCodexClaudeCodeAndGLM() {
        XCTAssertEqual(
            SettingsMembershipPresentation.profiles.map(\.profileID),
            [.codex, .claudeCode, .glm]
        )
        XCTAssertEqual(
            SettingsMembershipPresentation.profiles.map(\.displayName),
            ["Codex", "Claude Code", "GLM"]
        )
    }

    func testPersistsGLMMembershipExpiryOverride() {
        let suiteName = "PulseSettingsTests.glm-membership.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        PulseSettings(defaults: defaults).setMembershipExpiryOverride(expiry, for: .glm)

        XCTAssertEqual(
            PulseSettings(defaults: defaults).membershipExpiryOverride(for: .glm),
            expiry
        )
    }

    func testUsesProductDefaultsForNewInstall() {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PulseSettings(defaults: defaults)

        XCTAssertEqual(settings.appLanguage, .system)
        XCTAssertTrue(settings.edgeTriggerEnabled)
        XCTAssertTrue(settings.disableInFullScreen)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertFalse(settings.notificationSoundEnabled)
        XCTAssertEqual(settings.notificationAttentionLevel, .attentionOnly)
        XCTAssertTrue(settings.mutedProjectExpirations.isEmpty)
        XCTAssertTrue(settings.runningSectionExpanded)
        XCTAssertTrue(settings.recentSectionExpanded)
        XCTAssertEqual(settings.edgeDwellDuration, 0.2)
        XCTAssertEqual(settings.panelDismissDelay, 0.3)
        XCTAssertEqual(settings.statusItemPanelDisplayDuration, 5)
        XCTAssertEqual(settings.panelWidth, 400)
    }

    func testPersistsChanges() {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PulseSettings(defaults: defaults)
        settings.appLanguage = .english
        settings.edgeTriggerEnabled = false
        settings.notificationSoundEnabled = true
        settings.notificationAttentionLevel = .important
        settings.runningSectionExpanded = false
        settings.recentSectionExpanded = false
        let expiration = Date(timeIntervalSince1970: 1_900_000_000)
        settings.muteProject("/tmp/project", until: expiration)
        let persistedMuteKeys = defaults.dictionary(
            forKey: PulsePreferenceKey.mutedProjectExpirations
        ).map { Array($0.keys) } ?? []
        XCTAssertFalse(persistedMuteKeys.contains("/tmp/project"))
        XCTAssertEqual(persistedMuteKeys.first?.count, 64)

        let reloaded = PulseSettings(defaults: defaults)
        XCTAssertEqual(reloaded.appLanguage, .english)
        XCTAssertFalse(reloaded.edgeTriggerEnabled)
        XCTAssertTrue(reloaded.notificationSoundEnabled)
        XCTAssertEqual(reloaded.notificationAttentionLevel, .important)
        XCTAssertFalse(reloaded.runningSectionExpanded)
        XCTAssertFalse(reloaded.recentSectionExpanded)
        XCTAssertEqual(reloaded.mutedProjectExpirations.count, 1)
        XCTAssertTrue(
            reloaded.isProjectMuted(
                "/tmp/project",
                asOf: expiration.addingTimeInterval(-1)
            )
        )

        reloaded.unmuteProject("/tmp/project")
        XCTAssertFalse(reloaded.isProjectMuted("/tmp/project", asOf: expiration.addingTimeInterval(-1)))
    }

    func testMigratesWholeLegacyPreferenceDomainWithoutOverwritingCurrentValues() {
        let suiteName = "PulseSettingsTests.legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: PulsePreferenceKey.edgeTriggerEnabled)
        let legacy: [String: Any] = [
            PulsePreferenceKey.edgeTriggerEnabled: true,
            PulsePreferenceKey.notificationSoundEnabled: true,
            PulsePreferenceKey.appLanguage: AppLanguage.english.rawValue,
            "selectedModelProfileID": "test-runtime:test-plan-a:test-model",
        ]

        let settings = PulseSettings(
            defaults: defaults,
            legacyPreferences: legacy
        )

        XCTAssertFalse(settings.edgeTriggerEnabled)
        XCTAssertTrue(settings.notificationSoundEnabled)
        XCTAssertEqual(settings.appLanguage, .english)
        XCTAssertEqual(
            defaults.string(forKey: "selectedModelProfileID"),
            "test-runtime:test-plan-a:test-model"
        )
        XCTAssertTrue(
            defaults.bool(forKey: LegacyCompatibility.preferencesMigrationMarker)
        )
    }

    func testLegacyPreferencesAreReadOnlyOnceAndNeverReappear() {
        let suiteName = "PulseSettingsTests.legacy-once.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstLegacy = [PulsePreferenceKey.notificationSoundEnabled: true]

        var settings = PulseSettings(
            defaults: defaults,
            legacyPreferences: firstLegacy
        )
        XCTAssertTrue(settings.notificationSoundEnabled)

        settings.notificationSoundEnabled = false
        defaults.removeObject(forKey: PulsePreferenceKey.appLanguage)
        settings = PulseSettings(
            defaults: defaults,
            legacyPreferences: [
                PulsePreferenceKey.notificationSoundEnabled: true,
                PulsePreferenceKey.appLanguage: AppLanguage.english.rawValue,
            ]
        )

        XCTAssertFalse(settings.notificationSoundEnabled)
        XCTAssertEqual(settings.appLanguage, .system)
    }

    func testLocalizedCopySupportsExplicitChineseAndEnglish() {
        XCTAssertEqual(
            PulseL10n.text("设置", language: .simplifiedChinese),
            "设置"
        )
        XCTAssertEqual(PulseL10n.text("设置", language: .english), "Settings")
        XCTAssertEqual(
            PulseL10n.text("%d 个任务已完成", language: .english, 3),
            "3 Tasks Completed"
        )
    }

    func testInterfaceLanguageUsesPreferredLocalizationInsteadOfRegionLocale() {
        XCTAssertEqual(
            AppLanguage.interfaceLanguage(forPreferredLocalization: "zh-Hans"),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AppLanguage.interfaceLanguage(forPreferredLocalization: "zh-Hant"),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AppLanguage.interfaceLanguage(forPreferredLocalization: "en-US"),
            .english
        )
        XCTAssertEqual(
            AppLanguage.interfaceLanguage(forPreferredLocalization: "fr"),
            .english
        )
        XCTAssertEqual(
            AppLanguage.interfaceLanguage(forPreferredLocalization: nil),
            .english
        )
    }

    func testFollowSystemCopyUsesEffectiveInterfaceLanguage() {
        let effectiveLanguage = AppLanguage.system.effectiveInterfaceLanguage

        XCTAssertEqual(
            PulseL10n.text("模型", language: .system),
            PulseL10n.text("模型", language: effectiveLanguage)
        )
        XCTAssertEqual(
            AppLanguage.system.usesChinesePunctuation,
            effectiveLanguage == .simplifiedChinese
        )
        XCTAssertTrue(AppLanguage.simplifiedChinese.usesChinesePunctuation)
        XCTAssertFalse(AppLanguage.english.usesChinesePunctuation)
    }

    func testExpiredProjectMutesAreIgnoredAndCleanedUp() {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PulseSettings(defaults: defaults)
        let now = Date.now
        settings.muteProject("/tmp/expired", until: now.addingTimeInterval(60))
        settings.muteProject("/tmp/current", until: now.addingTimeInterval(3_600))

        XCTAssertFalse(
            settings.isProjectMuted(
                "/tmp/expired",
                asOf: now.addingTimeInterval(120)
            )
        )
        settings.cleanupExpiredProjectMutes(asOf: now.addingTimeInterval(120))

        XCTAssertFalse(
            settings.isProjectMuted(
                "/tmp/expired",
                asOf: now.addingTimeInterval(120)
            )
        )
        XCTAssertTrue(
            settings.isProjectMuted(
                "/tmp/current",
                asOf: now.addingTimeInterval(120)
            )
        )
        XCTAssertEqual(settings.mutedProjectExpirations.count, 1)

        settings.clearProjectMutes()
        XCTAssertTrue(settings.mutedProjectExpirations.isEmpty)
    }

    func testPersistsSectionExpansionIndependently() {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = PulseSettings(defaults: defaults)
        settings.runningSectionExpanded = false

        settings = PulseSettings(defaults: defaults)
        XCTAssertFalse(settings.runningSectionExpanded)
        XCTAssertTrue(settings.recentSectionExpanded)

        settings.runningSectionExpanded = true
        settings.recentSectionExpanded = false

        settings = PulseSettings(defaults: defaults)
        XCTAssertTrue(settings.runningSectionExpanded)
        XCTAssertFalse(settings.recentSectionExpanded)
    }

    func testMigratesLegacyPlaintextSubdirectoryMuteKeyToGitRoot() throws {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let repository = temporaryRoot.appendingPathComponent("legacy-project", isDirectory: true)
        let subdirectory = repository.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let expiration = Date.now.addingTimeInterval(3_600)
        defaults.set(
            [subdirectory.path: expiration.timeIntervalSince1970],
            forKey: PulsePreferenceKey.mutedProjectExpirations
        )

        let settings = PulseSettings(defaults: defaults)

        XCTAssertTrue(
            settings.isProjectMuted(
                repository.path,
                asOf: expiration.addingTimeInterval(-1)
            )
        )
        let persistedKeys = defaults.dictionary(
            forKey: PulsePreferenceKey.mutedProjectExpirations
        ).map { Array($0.keys) } ?? []
        XCTAssertEqual(persistedKeys.count, 1)
        XCTAssertEqual(persistedKeys.first?.count, 64)
        XCTAssertFalse(persistedKeys.contains(subdirectory.path))
    }
}
