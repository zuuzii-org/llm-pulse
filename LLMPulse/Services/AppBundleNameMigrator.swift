import AppKit
import Darwin
import Foundation

enum AppBundleNameMigrationResult: Equatable {
    case continueLaunch(issues: [AppBundleNameMigrationIssue])
    case terminateAfterRelaunch
}

enum AppBundleNameMigrationIssue: Equatable, Sendable {
    case legacyCopyConflict(legacyPath: String, currentPath: String)
    case applicationSupportConflict(legacyPath: String, currentPath: String)
    case applicationSupportDestinationUnsafe(path: String, detail: String)
    case applicationSupportMigrationBlocked(
        legacyPath: String,
        currentPath: String,
        detail: String
    )
    case applicationSupportMigrationDeferred(
        legacyPath: String,
        currentPath: String,
        detail: String
    )
    case destinationExists(path: String)
    case symbolicLink(path: String)
    case permissionDenied(path: String)
    case loginItemVerificationRequired(detail: String)
    case operationFailed(detail: String)

    var blocksLaunch: Bool {
        switch self {
        case .legacyCopyConflict,
             .destinationExists,
             .applicationSupportConflict,
             .applicationSupportDestinationUnsafe:
            return true
        default:
            return false
        }
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .legacyCopyConflict, .destinationExists:
            return PulseL10n.text("检测到两个 LLM Pulse 安装", language: language)
        case .applicationSupportConflict:
            return PulseL10n.text("检测到两个 LLM Pulse 数据目录", language: language)
        case .applicationSupportDestinationUnsafe:
            return PulseL10n.text("LLM Pulse 数据目录不安全", language: language)
        case .applicationSupportMigrationBlocked:
            return PulseL10n.text("无法安全迁移 LLM Pulse 数据", language: language)
        case .applicationSupportMigrationDeferred:
            return PulseL10n.text("LLM Pulse 数据迁移尚未完成", language: language)
        case .symbolicLink, .permissionDenied, .operationFailed:
            return PulseL10n.text("无法完成应用名称迁移", language: language)
        case .loginItemVerificationRequired:
            return PulseL10n.text("请检查登录时启动设置", language: language)
        }
    }

    func message(language: AppLanguage) -> String {
        switch self {
        case let .legacyCopyConflict(legacyPath, currentPath):
            return PulseL10n.text(
                "同时检测到旧路径 %@ 和当前路径 %@。为避免误删，LLM Pulse 没有自动移除任何文件。请退出应用，并在 Finder 中仅保留一个版本。",
                language: language,
                legacyPath,
                currentPath
            )
        case let .applicationSupportConflict(legacyPath, currentPath):
            return PulseL10n.text(
                "同时检测到旧数据目录 %@ 和当前数据目录 %@。为避免覆盖 receipts、偏好或事件记录，LLM Pulse 没有自动合并或删除任何文件。请先备份并确认要保留的数据目录。",
                language: language,
                legacyPath,
                currentPath
            )
        case let .applicationSupportDestinationUnsafe(path, detail):
            return PulseL10n.text(
                "当前数据目录 %@ 未通过安全检查。为避免写入符号链接、非目录或权限不安全的位置，LLM Pulse 未启动任务监控，也没有移动、合并或删除任何数据。请修复该路径后重新打开。详情：%@",
                language: language,
                path,
                detail
            )
        case let .applicationSupportMigrationBlocked(legacyPath, currentPath, detail):
            return PulseL10n.text(
                "旧数据目录 %@ 未通过安全检查，无法迁移到 %@。LLM Pulse 没有移动、合并或删除旧数据。详情：%@",
                language: language,
                legacyPath,
                currentPath,
                detail
            )
        case let .applicationSupportMigrationDeferred(legacyPath, currentPath, detail):
            return PulseL10n.text(
                "旧数据目录 %@ 暂时无法原子迁移到 %@；本次继续使用旧目录，且没有删除数据。请稍后重新启动再试。详情：%@",
                language: language,
                legacyPath,
                currentPath,
                detail
            )
        case let .destinationExists(path):
            return PulseL10n.text(
                "目标位置 %@ 已存在。为避免两个使用相同身份的应用并存，LLM Pulse 没有覆盖它。请在 Finder 中解决冲突后重新打开应用。",
                language: language,
                path
            )
        case let .symbolicLink(path):
            return PulseL10n.text(
                "安全检查拒绝迁移符号链接：%@。应用将继续从原位置运行。",
                language: language,
                path
            )
        case let .permissionDenied(path):
            return PulseL10n.text(
                "没有权限将应用重命名到 %@。应用将继续从原位置运行；请在 Finder 中完成移动，或重新安装。",
                language: language,
                path
            )
        case let .loginItemVerificationRequired(detail):
            return PulseL10n.text(
                "应用迁移记录无效，已停止使用。无法确认旧登录项是否曾被注销；请在 LLM Pulse 设置中检查“登录时启动”。详情：%@",
                language: language,
                detail
            )
        case let .operationFailed(detail):
            return PulseL10n.text(
                "应用名称迁移失败：%@",
                language: language,
                detail
            )
        }
    }
}

struct AppBundleNameMigrationJournal: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case loginItemUnregistered
        case moved
    }

    let schemaVersion: Int
    let sourcePath: String
    let destinationPath: String
    let previousLoginItemState: LaunchAtLoginRegistrationState
    var phase: Phase

    init(
        sourcePath: String,
        destinationPath: String,
        previousLoginItemState: LaunchAtLoginRegistrationState,
        phase: Phase,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.previousLoginItemState = previousLoginItemState
        self.phase = phase
    }
}

enum AppBundleNameMigrationJournalError: LocalizedError {
    case corruptOrUnsupported
    case exceedsMaximumSize(maximumBytes: Int)
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .corruptOrUnsupported:
            return "The application migration journal is corrupt or unsupported."
        case let .exceedsMaximumSize(maximumBytes):
            return "The application migration journal exceeds the \(maximumBytes)-byte limit."
        case .unsafePath:
            return "The application migration journal path failed safety validation."
        }
    }
}

protocol AppBundleNameMigrationFileManaging: AnyObject {
    func itemExists(at url: URL) -> Bool
    func isSymbolicLink(at url: URL) throws -> Bool
    func isWritableDirectory(at url: URL) -> Bool
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
}

protocol AppBundleNameMigrationJournalStoring: AnyObject {
    func load() throws -> AppBundleNameMigrationJournal?
    func save(_ journal: AppBundleNameMigrationJournal) throws
    func clear() throws
}

@MainActor
protocol AppBundleNameMigrationRelaunching: AnyObject {
    func relaunchApplication(at url: URL) async throws
}

final class LiveAppBundleNameMigrationFileManager: AppBundleNameMigrationFileManaging {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    func isWritableDirectory(at url: URL) -> Bool {
        fileManager.isWritableFile(atPath: url.path)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }
}

final class JSONAppBundleNameMigrationJournalStore: AppBundleNameMigrationJournalStoring {
    // The journal is one small JSON object. Bound it before allocation so a
    // corrupt local file cannot create unbounded launch-time memory pressure.
    static let maximumFileSizeBytes = 64 * 1024

    private let journalURL: URL
    private let fileManager: FileManager
    private let currentUserID: uid_t
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        journalURL: URL,
        fileManager: FileManager = .default,
        currentUserID: uid_t = geteuid()
    ) {
        self.journalURL = journalURL
        self.fileManager = fileManager
        self.currentUserID = currentUserID
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() throws -> AppBundleNameMigrationJournal? {
        switch journalEntry() {
        case .missing:
            return nil
        case .unsafe:
            throw AppBundleNameMigrationJournalError.unsafePath
        case let .safe(fileSize):
            guard fileSize >= 0,
                  fileSize <= off_t(Self.maximumFileSizeBytes) else {
                throw AppBundleNameMigrationJournalError.exceedsMaximumSize(
                    maximumBytes: Self.maximumFileSizeBytes
                )
            }
        }
        do {
            let journal = try decoder.decode(
                AppBundleNameMigrationJournal.self,
                from: Data(contentsOf: journalURL)
            )
            guard journal.schemaVersion == 1 else {
                throw AppBundleNameMigrationJournalError.corruptOrUnsupported
            }
            return journal
        } catch {
            throw AppBundleNameMigrationJournalError.corruptOrUnsupported
        }
    }

    func save(_ journal: AppBundleNameMigrationJournal) throws {
        let data = try encoder.encode(journal)
        guard data.count <= Self.maximumFileSizeBytes else {
            throw AppBundleNameMigrationJournalError.exceedsMaximumSize(
                maximumBytes: Self.maximumFileSizeBytes
            )
        }
        let directoryURL = journalURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateDirectory(directoryURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        if case .unsafe = journalEntry() {
            throw AppBundleNameMigrationJournalError.unsafePath
        }
        try data.write(to: journalURL, options: .atomic)
        guard case .safe(_) = journalEntry() else {
            throw AppBundleNameMigrationJournalError.unsafePath
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: journalURL.path
        )
    }

    func clear() throws {
        switch journalEntry() {
        case .missing:
            return
        case .unsafe:
            throw AppBundleNameMigrationJournalError.unsafePath
        case .safe(_):
            break
        }
        try fileManager.removeItem(at: journalURL)
    }

    private enum JournalEntry {
        case missing
        case safe(fileSize: off_t)
        case unsafe
    }

    private func journalEntry() -> JournalEntry {
        var status = stat()
        let result = journalURL.path.withCString { lstat($0, &status) }
        guard result == 0 else {
            return errno == ENOENT ? .missing : .unsafe
        }
        return status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && status.st_uid == currentUserID
            && status.st_nlink == 1
            && status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
            ? .safe(fileSize: status.st_size)
            : .unsafe
    }

    private func validateDirectory(_ url: URL) throws {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        guard result == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == currentUserID,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            throw AppBundleNameMigrationJournalError.unsafePath
        }
    }
}

@MainActor
final class WorkspaceAppBundleNameMigrationRelauncher: AppBundleNameMigrationRelaunching {
    func relaunchApplication(at url: URL) async throws {
        // No launch argument marks the relaunch. `run()` branches on the
        // bundle filename, which the migration has already changed, so the
        // relaunched instance takes the completion path on its own. An
        // argument would only imply a handshake that nothing reads.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        let _: Void = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application != nil {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: AppBundleNameMigrationError.relaunchReturnedNoApplication
                    )
                }
            }
        }
    }
}

@MainActor
final class AppBundleNameMigrator {
    private let currentBundleURL: URL
    private let allowedApplicationDirectories: Set<String>
    private let fileManager: any AppBundleNameMigrationFileManaging
    private let journalStore: any AppBundleNameMigrationJournalStoring
    private let loginItemManager: any LaunchAtLoginMigrationManaging
    private let relauncher: any AppBundleNameMigrationRelaunching
    private let applicationSupportResolution: LegacyApplicationSupportResolution?
    private let preflightIssue: AppBundleNameMigrationIssue?

    init(
        currentBundleURL: URL,
        allowedApplicationDirectories: [URL],
        fileManager: any AppBundleNameMigrationFileManaging,
        journalStore: any AppBundleNameMigrationJournalStoring,
        loginItemManager: any LaunchAtLoginMigrationManaging,
        relauncher: any AppBundleNameMigrationRelaunching,
        applicationSupportResolution: LegacyApplicationSupportResolution? = nil,
        preflightIssue: AppBundleNameMigrationIssue? = nil
    ) {
        self.currentBundleURL = currentBundleURL.standardizedFileURL
        self.allowedApplicationDirectories = Set(
            allowedApplicationDirectories.map { $0.standardizedFileURL.path }
        )
        self.fileManager = fileManager
        self.journalStore = journalStore
        self.loginItemManager = loginItemManager
        self.relauncher = relauncher
        self.applicationSupportResolution = applicationSupportResolution
        self.preflightIssue = preflightIssue
    }

    static func live(
        loginItemManager: any LaunchAtLoginMigrationManaging,
        fileManager: FileManager = .default
    ) -> AppBundleNameMigrator {
        let allowedDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let migrationFileManager = LiveAppBundleNameMigrationFileManager(
            fileManager: fileManager
        )
        let runningLegacyBundleURLs = NSRunningApplication
            .runningApplications(
                withBundleIdentifier: LegacyCompatibility.V1.bundleIdentifier
            )
            .filter { !$0.isTerminated && $0.processIdentifier != getpid() }
            .compactMap(\.bundleURL)
        let runningLegacyURL = runningLegacyBundleURLs
            .map(\.standardizedFileURL)
            .first { $0.path != currentBundleURL.path }
        let installedLegacyURL = conflictingInstalledBundleURL(
            currentBundleURL: currentBundleURL,
            allowedApplicationDirectories: allowedDirectories,
            fileManager: migrationFileManager
        )
        let conflictingLegacyURL = runningLegacyURL ?? installedLegacyURL
        let preflightIssue = conflictingLegacyURL.map {
            AppBundleNameMigrationIssue.legacyCopyConflict(
                legacyPath: $0.path,
                currentPath: currentBundleURL.path
            )
        }
        let applicationSupportResolution = preflightIssue == nil
            ? LegacyCompatibility.resolveApplicationSupportDirectory(
                homeDirectory: fileManager.homeDirectoryForCurrentUser
            )
            : nil
        let applicationSupportURL = applicationSupportResolution?.directoryURL
            ?? LegacyCompatibility.currentApplicationSupportURL(
                homeDirectory: fileManager.homeDirectoryForCurrentUser
            )
        let journalURL = applicationSupportURL
            .appendingPathComponent("app-bundle-name-migration.json")

        return AppBundleNameMigrator(
            currentBundleURL: currentBundleURL,
            allowedApplicationDirectories: allowedDirectories,
            fileManager: migrationFileManager,
            journalStore: JSONAppBundleNameMigrationJournalStore(
                journalURL: journalURL,
                fileManager: fileManager
            ),
            loginItemManager: loginItemManager,
            relauncher: WorkspaceAppBundleNameMigrationRelauncher(),
            applicationSupportResolution: applicationSupportResolution,
            preflightIssue: preflightIssue
        )
    }

    static func conflictingInstalledBundleURL(
        currentBundleURL: URL,
        allowedApplicationDirectories: [URL],
        fileManager: any AppBundleNameMigrationFileManaging
    ) -> URL? {
        let currentURL = currentBundleURL.standardizedFileURL
        let candidateNames = [
            LegacyCompatibility.V1.applicationBundleFilename,
            PulseBrand.applicationBundleFilename,
        ]
        return allowedApplicationDirectories
            .flatMap { directory in
                candidateNames.map {
                    directory.appendingPathComponent($0, isDirectory: true)
                }
            }
            .map(\.standardizedFileURL)
            .first {
                $0.path != currentURL.path && fileManager.itemExists(at: $0)
            }
    }

    func run() async -> AppBundleNameMigrationResult {
        if let preflightIssue {
            // A second installed or running legacy wrapper can recreate the
            // old data root after migration. Stop before resolving journals,
            // moving support data, or mutating login-item registration.
            return .continueLaunch(issues: [preflightIssue])
        }
        if applicationSupportResolution?.state == .unsafeCurrentDestination
            || applicationSupportResolution?.state == .conflict {
            // The journal store lives below this directory. Stop before any
            // load, write, bundle move, or login-item mutation can follow an
            // unsafe or unresolved destination.
            return applyingApplicationSupportIssue(to: .continueLaunch(issues: []))
        }

        let parentURL = currentBundleURL.deletingLastPathComponent().standardizedFileURL
        guard allowedApplicationDirectories.contains(parentURL.path) else {
            return applyingApplicationSupportIssue(to: .continueLaunch(issues: []))
        }

        let result: AppBundleNameMigrationResult
        switch currentBundleURL.lastPathComponent {
        case LegacyCompatibility.V1.applicationBundleFilename:
            result = await migrateLegacyBundle(in: parentURL)
        case PulseBrand.applicationBundleFilename:
            result = await completePendingMigrationAndInspectLegacyCopy(in: parentURL)
        default:
            result = .continueLaunch(issues: [])
        }
        return applyingApplicationSupportIssue(to: result)
    }

    private func applyingApplicationSupportIssue(
        to result: AppBundleNameMigrationResult
    ) -> AppBundleNameMigrationResult {
        guard let applicationSupportResolution else {
            return result
        }

        let currentURL = applicationSupportResolution.directoryURL
        let supportParentURL = currentURL.deletingLastPathComponent()
        let legacyURL = supportParentURL.appendingPathComponent(
            LegacyCompatibility.V1.applicationSupportDirectoryName,
            isDirectory: true
        )
        let canonicalURL = supportParentURL.appendingPathComponent(
            PulseBrand.applicationSupportDirectoryName,
            isDirectory: true
        )
        let issue: AppBundleNameMigrationIssue
        switch applicationSupportResolution.state {
        case .current, .migrated:
            return result
        case .conflict:
            issue = .applicationSupportConflict(
                legacyPath: legacyURL.path,
                currentPath: canonicalURL.path
            )
        case .unsafeCurrentDestination:
            issue = .applicationSupportDestinationUnsafe(
                path: canonicalURL.path,
                detail: "Current directory type, owner, or permissions are unsafe"
            )
        case .unsafeLegacySource:
            issue = .applicationSupportMigrationBlocked(
                legacyPath: legacyURL.path,
                currentPath: canonicalURL.path,
                detail: "Legacy directory type, owner, or permissions are unsafe"
            )
        case let .legacyFallback(errorCode):
            issue = .applicationSupportMigrationDeferred(
                legacyPath: legacyURL.path,
                currentPath: canonicalURL.path,
                detail: "Atomic move failed with POSIX error \(errorCode)"
            )
        }
        switch result {
        case let .continueLaunch(issues):
            return .continueLaunch(issues: [issue] + issues)
        case .terminateAfterRelaunch:
            // The canonical process will detect and surface the same untouched
            // conflict immediately after relaunch.
            return .terminateAfterRelaunch
        }
    }

    private func completePendingMigrationAndInspectLegacyCopy(
        in parentURL: URL
    ) async -> AppBundleNameMigrationResult {
        var issues: [AppBundleNameMigrationIssue] = []
        let legacyURL = parentURL.appendingPathComponent(
            LegacyCompatibility.V1.applicationBundleFilename,
            isDirectory: true
        )

        let pendingJournal: AppBundleNameMigrationJournal?
        do {
            pendingJournal = try journalStore.load()
        } catch let error as AppBundleNameMigrationJournalError {
            pendingJournal = nil
            issues.append(discardInvalidJournal(
                detail: error.localizedDescription
            ))
        } catch {
            pendingJournal = nil
            issues.append(.operationFailed(detail: error.localizedDescription))
        }

        if let journal = pendingJournal {
            do {
                let sourceURL = URL(fileURLWithPath: journal.sourcePath, isDirectory: true)
                if !journalMatches(
                    journal,
                    sourceURL: legacyURL,
                    destinationURL: currentBundleURL
                ) {
                    issues.append(discardInvalidJournal(
                        detail: AppBundleNameMigrationError.unexpectedJournal
                            .localizedDescription
                    ))
                } else if journal.phase == .moved || !fileManager.itemExists(at: sourceURL) {
                    // A crash can occur after the atomic move but before the phase
                    // update reaches disk. The absent source is sufficient evidence
                    // that this process is running from the canonical destination.
                    try await loginItemManager.restoreAfterBundleNameMigration(
                        from: journal.previousLoginItemState
                    )
                    try journalStore.clear()
                }
            } catch {
                issues.append(.operationFailed(detail: error.localizedDescription))
            }
        }

        if fileManager.itemExists(at: legacyURL) {
            issues.append(
                .legacyCopyConflict(
                    legacyPath: legacyURL.path,
                    currentPath: currentBundleURL.path
                )
            )
        }

        return .continueLaunch(issues: issues)
    }

    private func migrateLegacyBundle(
        in parentURL: URL
    ) async -> AppBundleNameMigrationResult {
        let destinationURL = parentURL.appendingPathComponent(
            PulseBrand.applicationBundleFilename,
            isDirectory: true
        )

        do {
            if try fileManager.isSymbolicLink(at: currentBundleURL) {
                return .continueLaunch(
                    issues: [.symbolicLink(path: currentBundleURL.path)]
                )
            }
        } catch {
            return .continueLaunch(
                issues: [.operationFailed(detail: error.localizedDescription)]
            )
        }

        if fileManager.itemExists(at: destinationURL) {
            do {
                if try fileManager.isSymbolicLink(at: destinationURL) {
                    return .continueLaunch(
                        issues: [.symbolicLink(path: destinationURL.path)]
                    )
                }
            } catch {
                return .continueLaunch(
                    issues: [.operationFailed(detail: error.localizedDescription)]
                )
            }

            return .continueLaunch(
                issues: [.destinationExists(path: destinationURL.path)]
            )
        }

        guard fileManager.isWritableDirectory(at: parentURL) else {
            return .continueLaunch(
                issues: [.permissionDenied(path: destinationURL.path)]
            )
        }

        var journal: AppBundleNameMigrationJournal
        do {
            if let existingJournal = try journalStore.load() {
                guard journalMatches(
                    existingJournal,
                    sourceURL: currentBundleURL,
                    destinationURL: destinationURL
                ) else {
                    return .continueLaunch(issues: [discardInvalidJournal(
                        detail: AppBundleNameMigrationError.unexpectedJournal
                            .localizedDescription
                    )])
                }

                if existingJournal.phase == .moved {
                    try await loginItemManager.restoreAfterBundleNameMigration(
                        from: existingJournal.previousLoginItemState
                    )
                    try journalStore.clear()
                    journal = makeJournal(destinationURL: destinationURL)
                    try journalStore.save(journal)
                } else {
                    journal = existingJournal
                }
            } else {
                journal = makeJournal(destinationURL: destinationURL)
                try journalStore.save(journal)
            }
        } catch let error as AppBundleNameMigrationJournalError {
            return .continueLaunch(issues: [discardInvalidJournal(
                detail: error.localizedDescription
            )])
        } catch {
            return .continueLaunch(
                issues: [.operationFailed(detail: error.localizedDescription)]
            )
        }

        if journal.phase == .prepared {
            do {
                try await loginItemManager.unregisterForBundleNameMigration(
                    preserving: journal.previousLoginItemState
                )
                journal.phase = .loginItemUnregistered
                try journalStore.save(journal)
            } catch {
                let rollbackFailure = await rollback(journal: journal)
                return .continueLaunch(
                    issues: [migrationFailure(error, rollbackFailure: rollbackFailure)]
                )
            }
        }

        do {
            try fileManager.moveItem(at: currentBundleURL, to: destinationURL)
        } catch {
            let rollbackFailure = await rollback(journal: journal)
            return .continueLaunch(
                issues: [migrationFailure(error, rollbackFailure: rollbackFailure)]
            )
        }

        journal.phase = .moved
        do {
            try journalStore.save(journal)
        } catch {
            let rollbackFailure = await rollback(journal: journal)
            return .continueLaunch(
                issues: [migrationFailure(error, rollbackFailure: rollbackFailure)]
            )
        }

        do {
            try await relauncher.relaunchApplication(at: destinationURL)
            return .terminateAfterRelaunch
        } catch {
            let rollbackFailure = await rollback(journal: journal)
            return .continueLaunch(
                issues: [migrationFailure(error, rollbackFailure: rollbackFailure)]
            )
        }
    }

    private func makeJournal(destinationURL: URL) -> AppBundleNameMigrationJournal {
        AppBundleNameMigrationJournal(
            sourcePath: currentBundleURL.path,
            destinationPath: destinationURL.path,
            previousLoginItemState: loginItemManager.migrationRegistrationState,
            phase: .prepared
        )
    }

    private func journalMatches(
        _ journal: AppBundleNameMigrationJournal,
        sourceURL: URL,
        destinationURL: URL
    ) -> Bool {
        URL(fileURLWithPath: journal.sourcePath, isDirectory: true).standardizedFileURL
            == sourceURL.standardizedFileURL
            && URL(
                fileURLWithPath: journal.destinationPath,
                isDirectory: true
            ).standardizedFileURL == destinationURL.standardizedFileURL
    }

    private func rollback(
        journal: AppBundleNameMigrationJournal
    ) async -> String? {
        let sourceURL = URL(fileURLWithPath: journal.sourcePath, isDirectory: true)
        let destinationURL = URL(
            fileURLWithPath: journal.destinationPath,
            isDirectory: true
        )

        do {
            if fileManager.itemExists(at: destinationURL) {
                guard !fileManager.itemExists(at: sourceURL) else {
                    throw AppBundleNameMigrationError.rollbackWouldOverwriteSource
                }
                try fileManager.moveItem(at: destinationURL, to: sourceURL)
            }

            guard fileManager.itemExists(at: sourceURL) else {
                throw AppBundleNameMigrationError.rollbackSourceMissing
            }

            try await loginItemManager.restoreAfterBundleNameMigration(
                from: journal.previousLoginItemState
            )
            try journalStore.clear()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func migrationFailure(
        _ error: Error,
        rollbackFailure: String?
    ) -> AppBundleNameMigrationIssue {
        let detail: String
        if let rollbackFailure {
            detail = "\(error.localizedDescription); rollback: \(rollbackFailure)"
        } else {
            detail = error.localizedDescription
        }
        return .operationFailed(detail: detail)
    }

    private func discardInvalidJournal(detail: String) -> AppBundleNameMigrationIssue {
        do {
            try journalStore.clear()
            return .loginItemVerificationRequired(detail: detail)
        } catch {
            return .loginItemVerificationRequired(
                detail: "\(detail) Cleanup failed: \(error.localizedDescription)"
            )
        }
    }
}

private enum AppBundleNameMigrationError: LocalizedError {
    case unexpectedJournal
    case relaunchReturnedNoApplication
    case rollbackWouldOverwriteSource
    case rollbackSourceMissing

    var errorDescription: String? {
        switch self {
        case .unexpectedJournal:
            return "The migration journal does not match this application path."
        case .relaunchReturnedNoApplication:
            return "macOS did not return a relaunched application instance."
        case .rollbackWouldOverwriteSource:
            return "Rollback refused to overwrite an existing source application."
        case .rollbackSourceMissing:
            return "Rollback could not restore the source application."
        }
    }
}
