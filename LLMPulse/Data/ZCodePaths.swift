import Foundation

/// Read-only locations used by the ZCode/GLM adapter.
///
/// ZCode keeps credentials and full model I/O beside these files. They are
/// deliberately absent from this type so a caller cannot accidentally turn
/// the narrow monitoring adapter into a generic `~/.zcode` crawler.
struct ZCodePaths: Sendable {
    let zcodeHome: URL
    let databaseURL: URL
    let eventLogDirectory: URL
    let entitlementLocalStorageDirectory: URL

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ZCodePaths {
        let configuredHome = environment["ZCODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let zcodeHome = configuredHome.flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".zcode", isDirectory: true)
        return ZCodePaths(
            zcodeHome: zcodeHome,
            entitlementLocalStorageDirectory: homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("ZCode", isDirectory: true)
                .appendingPathComponent("session", isDirectory: true)
                .appendingPathComponent("Local Storage", isDirectory: true)
                .appendingPathComponent("leveldb", isDirectory: true)
        )
    }

    init(
        zcodeHome: URL,
        entitlementLocalStorageDirectory: URL? = nil
    ) {
        self.zcodeHome = zcodeHome
        databaseURL = zcodeHome
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("db", isDirectory: true)
            .appendingPathComponent("db.sqlite")
        eventLogDirectory = zcodeHome
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("log", isDirectory: true)
        self.entitlementLocalStorageDirectory = entitlementLocalStorageDirectory
            ?? zcodeHome
                .appendingPathComponent("session", isDirectory: true)
                .appendingPathComponent("Local Storage", isDirectory: true)
                .appendingPathComponent("leveldb", isDirectory: true)
    }

    /// The event stream rotates daily. Three lexicographically latest files
    /// cover the 24-hour task retention window even when a turn crosses two
    /// date boundaries because of UTC/local-date differences.
    func recentEventLogURLs(maximumCount: Int = 3) -> [URL] {
        guard maximumCount > 0 else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: eventLogDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return Array(urls.lazy.filter { url in
            Self.isEventLogFilename(url.lastPathComponent)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(maximumCount))
    }

    private static func isEventLogFilename(_ filename: String) -> Bool {
        let prefix = "zcode-"
        let suffix = ".jsonl"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return false }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let date = filename[start..<end]
        guard date.utf8.count == 10 else { return false }

        for (index, byte) in date.utf8.enumerated() {
            if index == 4 || index == 7 {
                guard byte == 45 else { return false }
            } else if !(48...57).contains(byte) {
                return false
            }
        }
        return true
    }
}
