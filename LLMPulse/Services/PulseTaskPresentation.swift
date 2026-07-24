import Foundation

extension PulseTask {
    var projectDisplayName: String {
        ProjectDirectoryIdentityResolver.resolve(projectDirectory)
    }

    func projectDisplayName(language: AppLanguage) -> String {
        let displayName = projectDisplayName
        return displayName == "未识别项目"
            ? PulseL10n.text("未识别项目", language: language)
            : displayName
    }

    var projectIdentityDirectory: String {
        ProjectDirectoryIdentityResolver.identityDirectory(projectDirectory)
    }

    var displayStatusText: String {
        displayStatusText(language: .simplifiedChinese)
    }

    func displayStatusText(language: AppLanguage) -> String {
        switch lastStatus {
        case "running":
            return PulseL10n.text("正在执行", language: language)
        case "waitingForApproval":
            return PulseL10n.text("等待你授权", language: language)
        case "waitingForAnswer":
            return PulseL10n.text("等待你回答", language: language)
        case "finalizing":
            return PulseL10n.text("正在整理结果", language: language)
        case "completed":
            return PulseL10n.text("已完成", language: language)
        case "failed":
            return PulseL10n.text("执行失败", language: language)
        case "interrupted":
            return PulseL10n.text("已中断", language: language)
        default:
            return lastStatus
        }
    }
}

extension TokenUsageSnapshot {
    var compactTotalText: String {
        Self.compactTokenCount(totalTokens)
    }

    var hasBreakdown: Bool {
        inputTokens != nil
            || cachedInputTokens != nil
            || outputTokens != nil
            || reasoningOutputTokens != nil
    }

    static func compactTokenCount(_ count: Int?) -> String {
        guard let count else { return "—" }

        let value = max(0, count)
        if value < 1_000 { return "\(value)" }

        let suffixes = ["", "k", "m", "b"]
        var scaled = Double(value)
        var unitIndex = 0
        while scaled >= 1_000, unitIndex < suffixes.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }

        var rounded = (scaled * 10).rounded() / 10
        if rounded >= 1_000, unitIndex < suffixes.count - 1 {
            rounded /= 1_000
            unitIndex += 1
        }
        return compactDecimal(rounded) + suffixes[unitIndex]
    }

    private static func compactDecimal(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

extension RateLimitWindowSnapshot {
    func remainingPercent(asOf date: Date = .now) -> Double? {
        guard resetsAt > date else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }
}

extension Date {
    func pulseQuotaResetDescription(
        asOf _: Date = .now,
        timeZone: TimeZone = .autoupdatingCurrent,
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return PulseL10n.text(
            "重置 %@",
            language: language,
            formatter.string(from: self)
        )
    }
}

enum ProjectDirectoryIdentityResolver {
    private final class CachedResolution: NSObject {
        let identityDirectory: String
        let displayName: String

        init(identityDirectory: String, displayName: String) {
            self.identityDirectory = identityDirectory
            self.displayName = displayName
        }
    }

    // SwiftUI can ask for a task's presentation several times per render pass.
    // Cache the filesystem-backed Git-root lookup by cwd so row rendering stays
    // a cheap in-memory operation after the first resolution.
    // NSCache is documented as safe for concurrent access. Swift does not
    // currently model that guarantee with Sendable, so keep the escape hatch
    // narrowly scoped to this immutable cache reference.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CachedResolution>()

    static func resolve(_ projectDirectory: String) -> String {
        resolution(for: projectDirectory).displayName
    }

    static func identityDirectory(_ projectDirectory: String) -> String {
        resolution(for: projectDirectory).identityDirectory
    }

    private static func resolution(for projectDirectory: String) -> CachedResolution {
        let cacheKey = projectDirectory as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let identity = resolveIdentityDirectory(projectDirectory)
        let lastPathComponent = identity.isEmpty
            ? ""
            : URL(fileURLWithPath: identity).lastPathComponent
        let displayName = lastPathComponent.isEmpty ? "未识别项目" : lastPathComponent
        let result = CachedResolution(
            identityDirectory: identity,
            displayName: displayName
        )
        cache.setObject(result, forKey: cacheKey)
        return result
    }

    private static func resolveIdentityDirectory(_ projectDirectory: String) -> String {
        guard !projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        let standardized = URL(fileURLWithPath: projectDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var candidate = standardized
        guard candidate.path != "/" else { return "" }

        while true {
            let gitMarker = candidate.appendingPathComponent(".git", isDirectory: false)
            if FileManager.default.fileExists(atPath: gitMarker.path),
               !candidate.lastPathComponent.isEmpty {
                return candidate.path
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }

        return standardized.path
    }
}

extension AdapterHealth {
    var displayMessage: String {
        displayMessage(language: .simplifiedChinese)
    }

    func displayMessage(language: AppLanguage) -> String {
        if reason == .formatDrift {
            return PulseL10n.text(
                "Codex 数据格式可能已更新，部分任务无法识别",
                language: language
            )
        }
        switch adapter {
        case .appServer:
            return PulseL10n.text(
                "Codex 本地协议暂不可用，当前使用兼容数据源",
                language: language
            )
        case .sqlite:
            return PulseL10n.text("无法读取 Codex 本地任务索引", language: language)
        case .rolloutJSONL:
            return PulseL10n.text("无法读取 Codex 任务事件记录", language: language)
        case .pluginJournal:
            return PulseL10n.text(
                "插件事件日志尚未生成，当前使用兼容数据源",
                language: language
            )
        case .receipts:
            return PulseL10n.text("未查看状态暂时无法保存", language: language)
        case .runtimeSource:
            return PulseL10n.text("模型数据源暂不可用", language: language)
        case .claudeSessionRegistry:
            return PulseL10n.text("无法读取 Claude Code 会话列表", language: language)
        case .claudeTranscript:
            return PulseL10n.text("无法读取 Claude Code 任务记录", language: language)
        case .claudeAgentJournal:
            return PulseL10n.text("Claude Code 子 Agent 记录尚未生成", language: language)
        }
    }
}

extension Date {
    func pulseRelativeDescription(
        asOf now: Date = .now,
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(self)))

        if seconds < 10 { return PulseL10n.text("刚刚", language: language) }
        if seconds < 60 {
            return PulseL10n.text("%d 秒前", language: language, seconds)
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return PulseL10n.text("%d 分钟前", language: language, minutes)
        }

        let hours = minutes / 60
        if hours < 24 {
            return PulseL10n.text("%d 小时前", language: language, hours)
        }

        let days = hours / 24
        if days < 30 {
            return PulseL10n.text("%d 天前", language: language, days)
        }

        return formatted(
            .dateTime
                .year()
                .month()
                .day()
                .locale(language.locale)
        )
    }
}
