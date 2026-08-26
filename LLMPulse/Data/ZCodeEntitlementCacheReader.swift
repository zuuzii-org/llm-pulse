import CryptoKit
import Darwin
import Foundation

/// Narrow, read-only parser for ZCode's short-lived Chromium Local Storage
/// entitlement cache. No cache-key suffix or non-entitlement value is exposed.
final class ZCodeEntitlementCacheReader: @unchecked Sendable {
    enum ProviderID: String, CaseIterable, Hashable, Sendable {
        case bigModelCodingPlan = "builtin:bigmodel-coding-plan"
        case zaiCodingPlan = "builtin:zai-coding-plan"
    }

    struct Limit: Equatable, Sendable {
        let type: String
        let unit: Int
        /// Window length, not an allowance denominator.
        let number: Double?
        let remaining: Double?
        /// ZCode's percentage field is consumed percentage.
        let usedPercent: Double?
        let nextResetTime: Date?
    }

    struct SubscriptionDetail: Equatable, Sendable {
        let productName: String?
        let billingCycle: String?
        let renewsAt: Date?
        let expiresAt: Date?
    }

    struct Observation: Equatable, Sendable {
        let provider: ProviderID
        let cachedAt: Date
        let level: String?
        let fiveHour: Limit?
        let weekly: Limit?
        let subscriptionDetails: [SubscriptionDetail]

        fileprivate var hasDisplayableData: Bool {
            level != nil || fiveHour != nil || weekly != nil || !subscriptionDetails.isEmpty
        }
    }

    enum ReadResult: Equatable, Sendable {
        case observed(Observation)
        case absent
        case stale(cachedAt: Date)
        case unreadable
        case formatDrift
        case ambiguous
    }

    private enum DatabaseLoad: Sendable {
        case entries([Observation])
        case absent
        case unreadable
        case formatDrift
    }

    private enum DirectoryInspection {
        case snapshot(DirectorySnapshot)
        case absent
        case unreadable
        case formatDrift
    }

    private enum Mutation: Equatable {
        case value(Data)
        case deleted
    }

    private struct VersionedMutation: Equatable {
        let sequence: UInt64
        let mutation: Mutation
    }

    /// SHA-256 preserves exact-key tombstone semantics without retaining an
    /// account/fingerprint suffix from the Local Storage key.
    private struct KeyIdentity: Hashable {
        let byteCount: Int
        let digest: Data
    }

    private struct FileStamp: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let mode: UInt32
    }

    private struct StampedFile: Equatable, Sendable {
        let url: URL
        let stamp: FileStamp
    }

    private struct TableReference: Equatable, Hashable, Sendable {
        let level: Int
        let number: UInt64
        let size: Int
    }

    private struct ManifestState: Equatable, Sendable {
        var comparatorSeen = false
        var logNumber: UInt64?
        var previousLogNumber: UInt64 = 0
        var nextFileNumber: UInt64?
        var lastSequence: UInt64?
        var tables: [TableReference] = []
    }

    private struct ManifestResolution: Equatable, Sendable {
        let current: StampedFile
        let manifest: StampedFile
        let state: ManifestState
    }

    private struct ActiveFile: Equatable, Sendable {
        enum Kind: Int, Equatable, Sendable {
            case table
            case log
        }
        let kind: Kind
        let number: UInt64
        let expectedSize: Int?
        let file: StampedFile
    }

    private struct DirectorySnapshot: Equatable, Sendable {
        let manifest: ManifestResolution
        let files: [ActiveFile]
    }

    private struct CachedLoad {
        let snapshot: DirectorySnapshot
        let load: DatabaseLoad
    }

    private struct CacheEnvelope: Decodable {
        let cachedAt: Double
        let snapshot: SnapshotPayload
    }

    private struct CacheHeader: Decodable {
        let snapshot: HeaderSnapshot
        struct HeaderSnapshot: Decodable {
            let provider: ProviderPayload
        }
    }

    private struct SnapshotPayload: Decodable {
        let provider: ProviderPayload
        let quota: QuotaPayload?
        let subscription: SubscriptionPayload?
    }

    private struct ProviderPayload: Decodable {
        let id: String
    }

    private struct QuotaPayload: Decodable {
        let level: String?
        let limits: [LimitPayload]?
    }

    private struct LimitPayload: Decodable {
        let type: String
        let unit: Int
        let number: Double?
        let remaining: Double?
        let percentage: Double?
        let nextResetTime: Double?
    }

    private struct SubscriptionPayload: Decodable {
        let details: [SubscriptionDetailPayload]?
    }

    private struct SubscriptionDetailPayload: Decodable {
        let productName: String?
        let billingCycle: String?
        let renewTime: String?
        let expireTime: String?
    }

    private struct BlockHandle: Hashable {
        let offset: Int
        let size: Int
    }

    private struct TableKey: Hashable {
        let level: Int
        let number: UInt64
    }

    private static let levelDBBlockBytes = 32 * 1_024
    private static let physicalHeaderBytes = 7
    private static let writeBatchHeaderBytes = 12
    private static let tableFooterBytes = 48
    private static let tableFooterHandleBytes = 40
    private static let tableBlockTrailerBytes = 5
    private static let tableMagicNumber: UInt64 = 0xdb47_7524_8b80_fb57
    private static let maximumSequenceNumber: UInt64 = (1 << 56) - 1
    private static let maximumManifestBytes = 16 * 1_024 * 1_024
    private static let maximumLogBytes = 16 * 1_024 * 1_024
    private static let maximumTableBytes = 64 * 1_024 * 1_024
    private static let maximumTotalBytes = 128 * 1_024 * 1_024
    private static let maximumDirectoryEntries = 512
    private static let maximumActiveFiles = 64
    private static let maximumLogicalRecordBytes = 8 * 1_024 * 1_024
    private static let maximumBatchEntries = 100_000
    private static let maximumManifestRecords = 100_000
    private static let maximumManifestTables = 10_000
    private static let maximumBlockBytes = 8 * 1_024 * 1_024
    private static let maximumBlockEntries = 1_000_000
    private static let maximumBlockKeyBytes = 64 * 1_024
    private static let maximumEntitlementEntries = 64
    private static let maximumEntitlementValueBytes = 256 * 1_024
    private static let clockSkewTolerance: TimeInterval = 60
    private static let localStorageEncodingMarker: UInt8 = 1
    private static let localStorageKeyPrefix = Array(
        Data("_file://\0\u{1}zcode:usage-entitlement:".utf8)
    )
    private static let entitlementNeedle = Array(Data("zcode:usage-entitlement:".utf8))
    private static let tokenLikeTypes: Set<String> = ["TOKENS_LIMIT", "CREDIT_LIMIT"]
    private static let crc32cTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82F6_3B78 : 0)
        }
        return crc
    }

    private let entitlementLocalStorageDirectory: URL
    private let maximumCacheAge: TimeInterval
    private let sourceReadObserver: (@Sendable (URL) -> Void)?
    private let lock = NSLock()
    private var cachedManifest: ManifestResolution?
    private var cachedLoad: CachedLoad?

    init(
        entitlementLocalStorageDirectory: URL,
        maximumCacheAge: TimeInterval = 10 * 60,
        sourceReadObserver: (@Sendable (URL) -> Void)? = nil
    ) {
        self.entitlementLocalStorageDirectory = entitlementLocalStorageDirectory
        self.maximumCacheAge = max(0, maximumCacheAge)
        self.sourceReadObserver = sourceReadObserver
    }

    func read(provider: ProviderID, now: Date = Date()) -> ReadResult {
        lock.lock()
        defer { lock.unlock() }
        switch loadDatabaseWithCache() {
        case .absent:
            return .absent
        case .unreadable:
            return .unreadable
        case .formatDrift:
            return .formatDrift
        case let .entries(entries):
            return evaluate(entries: entries, provider: provider, now: now)
        }
    }

    private func loadDatabaseWithCache() -> DatabaseLoad {
        switch inspectDirectory() {
        case .absent:
            cachedLoad = nil
            return .absent
        case .unreadable:
            return .unreadable
        case .formatDrift:
            cachedLoad = nil
            return .formatDrift
        case let .snapshot(snapshot):
            if let cachedLoad, cachedLoad.snapshot == snapshot {
                return cachedLoad.load
            }
            let load = loadDatabase(from: snapshot)
            guard case let .snapshot(after) = inspectDirectory(), after == snapshot else {
                return .unreadable
            }
            if case .unreadable = load { return load }
            cachedLoad = CachedLoad(snapshot: snapshot, load: load)
            return load
        }
    }

    private func inspectDirectory() -> DirectoryInspection {
        do {
            guard try directoryExistsAndIsSafe() else { return .absent }
            let enumerationState = DirectoryEnumerationState()
            guard let enumerator = FileManager.default.enumerator(
                at: entitlementLocalStorageDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in
                    enumerationState.markFailed()
                    return false
                }
            ) else {
                return .unreadable
            }
            var byName: [String: [URL]] = [:]
            var entryCount = 0
            while let entry = enumerator.nextObject() {
                guard !enumerationState.hasFailed else { return .unreadable }
                guard let url = entry as? URL else { return .formatDrift }
                entryCount += 1
                guard entryCount <= Self.maximumDirectoryEntries else {
                    return .formatDrift
                }
                byName[url.lastPathComponent, default: []].append(url)
            }
            guard !enumerationState.hasFailed else { return .unreadable }
            guard byName.values.allSatisfy({ $0.count == 1 }) else {
                return .formatDrift
            }
            let names = Set(byName.keys)
            guard names.contains("CURRENT") else {
                return names.isEmpty ? .absent : .formatDrift
            }
            for name in names where !Self.isRecognizedLevelDBFilename(name) {
                return .formatDrift
            }

            let resolution = try resolveManifest(byName: byName)
            guard let minimumLog = resolution.state.logNumber else {
                return .formatDrift
            }
            var parsedFiles: [UInt64: [String: URL]] = [:]
            for (name, matchingURLs) in byName {
                guard let parsed = Self.levelDBDataFilename(name) else { continue }
                guard parsedFiles[parsed.number]?[parsed.extension] == nil else {
                    return .formatDrift
                }
                parsedFiles[parsed.number, default: [:]][parsed.extension] = matchingURLs[0]
            }

            var active: [ActiveFile] = []
            var activeTableNumbers = Set<UInt64>()
            for table in resolution.state.tables.sorted(by: Self.tableReferenceSort) {
                guard activeTableNumbers.insert(table.number).inserted,
                      let extensions = parsedFiles[table.number]
                else {
                    return .formatDrift
                }
                let tableURLs = [extensions["ldb"], extensions["sst"]].compactMap { $0 }
                guard tableURLs.count == 1 else { return .formatDrift }
                let stamped = try stampedFile(at: tableURLs[0])
                guard stamped.stamp.size == table.size,
                      stamped.stamp.size >= Self.tableFooterBytes,
                      stamped.stamp.size <= Self.maximumTableBytes
                else {
                    return .formatDrift
                }
                active.append(ActiveFile(
                    kind: .table,
                    number: table.number,
                    expectedSize: table.size,
                    file: stamped
                ))
            }

            // Official LevelDB recovery selects every WAL at/after log_number,
            // plus prev_log_number. Lower obsolete logs and all unreferenced
            // table files are ignored.
            for number in parsedFiles.keys.sorted() {
                guard let logURL = parsedFiles[number]?["log"] else { continue }
                let isActive = number >= minimumLog
                    || (resolution.state.previousLogNumber != 0
                        && number == resolution.state.previousLogNumber)
                guard isActive else { continue }
                let stamped = try stampedFile(at: logURL)
                guard stamped.stamp.size <= Self.maximumLogBytes else {
                    return .formatDrift
                }
                active.append(ActiveFile(
                    kind: .log,
                    number: number,
                    expectedSize: nil,
                    file: stamped
                ))
            }

            active.sort { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                if lhs.number != rhs.number { return lhs.number < rhs.number }
                return lhs.file.url.lastPathComponent < rhs.file.url.lastPathComponent
            }
            guard active.count <= Self.maximumActiveFiles else { return .formatDrift }
            var total = resolution.current.stamp.size + resolution.manifest.stamp.size
            for source in active {
                let sum = total.addingReportingOverflow(source.file.stamp.size)
                guard !sum.overflow, sum.partialValue <= Self.maximumTotalBytes else {
                    return .formatDrift
                }
                total = sum.partialValue
            }
            return .snapshot(DirectorySnapshot(manifest: resolution, files: active))
        } catch ReaderError.concurrentMutation {
            return .unreadable
        } catch ReaderError.unreadable {
            return .unreadable
        } catch {
            cachedManifest = nil
            return .formatDrift
        }
    }

    private func directoryExistsAndIsSafe() throws -> Bool {
        var status = stat()
        let result = entitlementLocalStorageDirectory.path.withCString {
            lstat($0, &status)
        }
        if result != 0 {
            if errno == ENOENT { return false }
            throw ReaderError.unreadable
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            throw ReaderError.unreadable
        }
        return true
    }

    private func resolveManifest(
        byName: [String: [URL]]
    ) throws -> ManifestResolution {
        guard let currentURL = byName["CURRENT"]?.first else {
            throw ReaderError.invalidFormat
        }
        let current = try stampedFile(at: currentURL)
        guard current.stamp.size > 0, current.stamp.size <= 256 else {
            throw ReaderError.invalidFormat
        }
        if let cachedManifest, cachedManifest.current == current {
            let currentManifest = try stampedFile(at: cachedManifest.manifest.url)
            if currentManifest == cachedManifest.manifest { return cachedManifest }
        }

        let currentBytes = try readFile(current, maximumBytes: 256)
        guard let currentText = String(bytes: currentBytes, encoding: .utf8),
              currentText.last == "\n",
              !currentText.dropLast().contains("\n")
        else {
            throw ReaderError.invalidFormat
        }
        let name = String(currentText.dropLast())
        guard Self.manifestFileNumber(name) != nil,
              let manifestURL = byName[name]?.first
        else {
            throw ReaderError.invalidFormat
        }
        let manifest = try stampedFile(at: manifestURL)
        guard manifest.stamp.size > 0,
              manifest.stamp.size <= Self.maximumManifestBytes
        else {
            throw ReaderError.invalidFormat
        }
        let bytes = try readFile(manifest, maximumBytes: Self.maximumManifestBytes)
        let resolution = ManifestResolution(
            current: current,
            manifest: manifest,
            state: try Self.parseManifest(Array(bytes))
        )
        cachedManifest = resolution
        return resolution
    }

    private func stampedFile(at url: URL) throws -> StampedFile {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw ReaderError.unreadable
        }
        guard let stamp = safeStamp(from: status) else { throw ReaderError.unreadable }
        return StampedFile(url: url, stamp: stamp)
    }

    private func safeStamp(from status: stat) -> FileStamp? {
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              status.st_size >= 0,
              status.st_size <= off_t(Int.max)
        else {
            return nil
        }
        return FileStamp(
            device: status.st_dev,
            inode: status.st_ino,
            size: Int(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec),
            mode: UInt32(status.st_mode)
        )
    }

    private func readFile(_ file: StampedFile, maximumBytes: Int) throws -> Data {
        guard file.stamp.size <= maximumBytes else { throw ReaderError.invalidFormat }
        let descriptor = file.url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ReaderError.unreadable }
        defer { Darwin.close(descriptor) }
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              safeStamp(from: descriptorStatus) == file.stamp
        else {
            throw ReaderError.concurrentMutation
        }
        sourceReadObserver?(file.url)

        // Read exactly the snapshotted extent. A writer may append forever
        // after fstat; readToEnd() would otherwise bypass every byte cap before
        // the post-read stamp check gets a chance to fail closed.
        var data = Data(count: file.stamp.size)
        if file.stamp.size > 0 {
            try data.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    throw ReaderError.unreadable
                }
                var offset = 0
                while offset < file.stamp.size {
                    let count = Darwin.pread(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        file.stamp.size - offset,
                        off_t(offset)
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw ReaderError.unreadable
                    }
                    guard count > 0 else { throw ReaderError.concurrentMutation }
                    offset += count
                }
            }
        }

        var extraByte: UInt8 = 0
        while true {
            let count = Darwin.pread(
                descriptor,
                &extraByte,
                1,
                off_t(file.stamp.size)
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw ReaderError.unreadable
            }
            guard count == 0 else { throw ReaderError.concurrentMutation }
            break
        }
        var afterDescriptorStatus = stat()
        guard fstat(descriptor, &afterDescriptorStatus) == 0,
              safeStamp(from: afterDescriptorStatus) == file.stamp
        else {
            throw ReaderError.concurrentMutation
        }
        guard try stampedFile(at: file.url) == file else {
            throw ReaderError.concurrentMutation
        }
        return data
    }

    private func loadDatabase(from snapshot: DirectorySnapshot) -> DatabaseLoad {
        var mutations: [KeyIdentity: VersionedMutation] = [:]
        do {
            for source in snapshot.files {
                let limit = source.kind == .log
                    ? Self.maximumLogBytes
                    : Self.maximumTableBytes
                let bytes = Array(try readFile(source.file, maximumBytes: limit))
                switch source.kind {
                case .log:
                    try Self.parseWriteAheadLog(bytes, mutations: &mutations)
                case .table:
                    try Self.parseTable(bytes, mutations: &mutations)
                }
            }
            var observations: [Observation] = []
            observations.reserveCapacity(mutations.count)
            for versioned in mutations.values {
                guard case let .value(value) = versioned.mutation else { continue }
                if let observation = try Self.decodeObservation(value) {
                    observations.append(observation)
                }
            }
            return observations.isEmpty ? .absent : .entries(observations)
        } catch ReaderError.concurrentMutation {
            return .unreadable
        } catch ReaderError.unreadable {
            return .unreadable
        } catch {
            return .formatDrift
        }
    }

    private func evaluate(
        entries: [Observation],
        provider: ProviderID,
        now: Date
    ) -> ReadResult {
        // Every cache key for the provider participates in account ambiguity.
        // Filtering empty snapshots first could select an older account merely
        // because the current account has no displayable fields.
        let matching = entries.filter { $0.provider == provider }
        guard !matching.isEmpty else { return .absent }
        var fresh: [Observation] = []
        var newestStale: Date?
        for observation in matching {
            let age = now.timeIntervalSince(observation.cachedAt)
            if age < -Self.clockSkewTolerance { return .formatDrift }
            if age <= maximumCacheAge {
                fresh.append(observation)
            } else if newestStale == nil || observation.cachedAt > newestStale! {
                newestStale = observation.cachedAt
            }
        }
        if fresh.count > 1 { return .ambiguous }
        if let observation = fresh.first {
            return observation.hasDisplayableData ? .observed(observation) : .absent
        }
        if let newestStale { return .stale(cachedAt: newestStale) }
        return .absent
    }

    // MARK: Entitlement allowlist

    private static func decodeObservation(_ storedValue: Data) throws -> Observation? {
        guard storedValue.count > 1,
              storedValue.count <= maximumEntitlementValueBytes,
              storedValue.first == localStorageEncodingMarker
        else {
            throw ReaderError.invalidFormat
        }
        let json = Data(storedValue.dropFirst())
        let decoder = JSONDecoder()
        let header = try decoder.decode(CacheHeader.self, from: json)
        guard let provider = ProviderID(rawValue: header.snapshot.provider.id) else {
            return nil
        }
        let envelope = try decoder.decode(CacheEnvelope.self, from: json)
        guard envelope.snapshot.provider.id == provider.rawValue,
              let cachedAt = date(milliseconds: envelope.cachedAt)
        else {
            throw ReaderError.invalidFormat
        }
        let limits = envelope.snapshot.quota?.limits ?? []
        guard limits.count <= 32 else { throw ReaderError.invalidFormat }
        let fiveHour = try uniqueLimit(
            in: limits,
            matching: { tokenLikeTypes.contains($0.type) && $0.unit == 3 && $0.number == 5 }
        )
        let weekly = try uniqueLimit(
            in: limits,
            matching: { tokenLikeTypes.contains($0.type) && $0.unit == 6 }
        )
        let rawDetails = envelope.snapshot.subscription?.details ?? []
        guard rawDetails.count <= 16 else { throw ReaderError.invalidFormat }
        let details = try rawDetails.map { detail in
            SubscriptionDetail(
                productName: try boundedString(detail.productName, maximumBytes: 256),
                billingCycle: try boundedString(detail.billingCycle, maximumBytes: 128),
                renewsAt: try optionalISODate(detail.renewTime),
                expiresAt: try optionalISODate(detail.expireTime)
            )
        }
        return Observation(
            provider: provider,
            cachedAt: cachedAt,
            level: try boundedString(envelope.snapshot.quota?.level, maximumBytes: 128),
            fiveHour: fiveHour,
            weekly: weekly,
            subscriptionDetails: details
        )
    }

    private static func uniqueLimit(
        in limits: [LimitPayload],
        matching predicate: (LimitPayload) -> Bool
    ) throws -> Limit? {
        let matching = limits.filter(predicate)
        guard matching.count <= 1 else { throw ReaderError.invalidFormat }
        guard let raw = matching.first else { return nil }
        guard raw.unit >= 0,
              finiteNonnegative(raw.number),
              finiteNonnegative(raw.remaining),
              finitePercent(raw.percentage)
        else {
            throw ReaderError.invalidFormat
        }
        return Limit(
            type: raw.type,
            unit: raw.unit,
            number: raw.number,
            remaining: raw.remaining,
            usedPercent: raw.percentage,
            nextResetTime: try raw.nextResetTime.map { value in
                guard let date = date(milliseconds: value) else {
                    throw ReaderError.invalidFormat
                }
                return date
            }
        )
    }

    private static func finiteNonnegative(_ value: Double?) -> Bool {
        value.map { $0.isFinite && $0 >= 0 } ?? true
    }

    private static func finitePercent(_ value: Double?) -> Bool {
        value.map { $0.isFinite && (0...100).contains($0) } ?? true
    }

    private static func date(milliseconds: Double) -> Date? {
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds.rounded(.towardZero) == milliseconds
        else {
            return nil
        }
        let seconds = milliseconds / 1_000
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func boundedString(
        _ value: String?,
        maximumBytes: Int
    ) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= maximumBytes else {
            throw ReaderError.invalidFormat
        }
        return trimmed
    }

    private static func optionalISODate(_ value: String?) throws -> Date? {
        guard let value = try boundedString(value, maximumBytes: 64) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw ReaderError.invalidFormat
        }
        return date
    }

    // MARK: MANIFEST

    private static func parseManifest(_ bytes: [UInt8]) throws -> ManifestState {
        var state = ManifestState()
        var tables: [TableKey: TableReference] = [:]
        var recordCount = 0
        try parseRecordLog(bytes, maximumRecordBytes: maximumLogicalRecordBytes) { record in
            recordCount += 1
            guard recordCount <= maximumManifestRecords else {
                throw ReaderError.invalidFormat
            }
            try applyVersionEdit(record, state: &state, tables: &tables)
        }
        guard recordCount > 0,
              state.comparatorSeen,
              state.logNumber != nil,
              state.nextFileNumber != nil,
              state.lastSequence != nil,
              tables.count <= maximumManifestTables
        else {
            throw ReaderError.invalidFormat
        }
        state.tables = Array(tables.values)
        return state
    }

    private static func applyVersionEdit(
        _ bytes: [UInt8],
        state: inout ManifestState,
        tables: inout [TableKey: TableReference]
    ) throws {
        var position = 0
        while position < bytes.count {
            let tag = try readVarint32(bytes, position: &position, limit: bytes.count)
            switch tag {
            case 1:
                let range = try readLengthPrefixed(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
                guard range.count <= 256,
                      String(bytes: bytes[range], encoding: .utf8)
                        == "leveldb.BytewiseComparator"
                else {
                    throw ReaderError.invalidFormat
                }
                state.comparatorSeen = true
            case 2:
                state.logNumber = try readVarint64(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
            case 3:
                state.nextFileNumber = try readVarint64(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
            case 4:
                let sequence = try readVarint64(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
                guard sequence <= maximumSequenceNumber else {
                    throw ReaderError.invalidFormat
                }
                state.lastSequence = sequence
            case 5:
                _ = try readLevel(bytes, position: &position)
                let key = try readLengthPrefixed(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
                try validateInternalKey(bytes, range: key)
            case 6:
                let level = try readLevel(bytes, position: &position)
                let number = try readVarint64(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
                tables.removeValue(forKey: TableKey(level: level, number: number))
            case 7:
                let level = try readLevel(bytes, position: &position)
                let number = try readVarint64(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
                let rawSize = try readVarint64(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
                guard rawSize >= UInt64(tableFooterBytes),
                      rawSize <= UInt64(maximumTableBytes),
                      rawSize <= UInt64(Int.max)
                else {
                    throw ReaderError.invalidFormat
                }
                let smallest = try readLengthPrefixed(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
                let largest = try readLengthPrefixed(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
                try validateInternalKey(bytes, range: smallest)
                try validateInternalKey(bytes, range: largest)
                let key = TableKey(level: level, number: number)
                guard tables[key] == nil else { throw ReaderError.invalidFormat }
                tables[key] = TableReference(
                    level: level,
                    number: number,
                    size: Int(rawSize)
                )
            case 9:
                state.previousLogNumber = try readVarint64(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
            default:
                throw ReaderError.invalidFormat
            }
        }
    }

    private static func readLevel(_ bytes: [UInt8], position: inout Int) throws -> Int {
        let level = try readVarint32(bytes, position: &position, limit: bytes.count)
        guard (0..<7).contains(level) else { throw ReaderError.invalidFormat }
        return level
    }

    // MARK: WAL

    private static func parseWriteAheadLog(
        _ bytes: [UInt8],
        mutations: inout [KeyIdentity: VersionedMutation]
    ) throws {
        try parseRecordLog(bytes, maximumRecordBytes: maximumLogicalRecordBytes) { record in
            try parseWriteBatch(record, mutations: &mutations)
        }
    }

    private static func parseRecordLog(
        _ bytes: [UInt8],
        maximumRecordBytes: Int,
        consume: ([UInt8]) throws -> Void
    ) throws {
        var fragments: [UInt8] = []
        var assembling = false
        var blockStart = 0
        while blockStart < bytes.count {
            let blockEnd = min(blockStart + levelDBBlockBytes, bytes.count)
            let isFinalFileBlock = blockEnd == bytes.count
            let isTruncatedEOFBlock = isFinalFileBlock
                && blockEnd - blockStart < levelDBBlockBytes
            var position = blockStart
            while position < blockEnd {
                if blockEnd - position < physicalHeaderBytes {
                    if isFinalFileBlock {
                        // log::Reader drops an incomplete physical header at
                        // EOF; complete logical records before it remain valid.
                        position = blockEnd
                        continue
                    }
                    guard bytes[position..<blockEnd].allSatisfy({ $0 == 0 }) else {
                        throw ReaderError.invalidFormat
                    }
                    position = blockEnd
                    continue
                }
                let checksum = readUInt32(bytes, at: position)
                let length = Int(readUInt16(bytes, at: position + 4))
                let recordType = bytes[position + 6]
                if length == 0, recordType == 0 {
                    guard bytes[position..<blockEnd].allSatisfy({ $0 == 0 }) else {
                        throw ReaderError.invalidFormat
                    }
                    position = blockEnd
                    continue
                }
                let payloadStart = position + physicalHeaderBytes
                let end = payloadStart.addingReportingOverflow(length)
                guard !end.overflow else { throw ReaderError.invalidFormat }
                if end.partialValue > blockEnd, isTruncatedEOFBlock {
                    // The final physical record was only partly appended.
                    // Match LevelDB recovery by discarding that logical record.
                    return
                }
                guard end.partialValue <= blockEnd else {
                    throw ReaderError.invalidFormat
                }
                let range = payloadStart..<end.partialValue
                guard maskedLogCRC32C(type: recordType, bytes: bytes, range: range)
                    == checksum
                else {
                    throw ReaderError.invalidFormat
                }
                switch recordType {
                case 1:
                    if assembling {
                        // Older LevelDB writers could leave an empty FIRST at
                        // a block boundary. The official reader discards that
                        // empty fragment when the next block starts with FULL.
                        guard fragments.isEmpty else {
                            throw ReaderError.invalidFormat
                        }
                        assembling = false
                    }
                    try consume(Array(bytes[range]))
                case 2:
                    if assembling {
                        // Apply the same historical compatibility when the
                        // next block starts a new fragmented record.
                        guard fragments.isEmpty else {
                            throw ReaderError.invalidFormat
                        }
                    }
                    fragments = Array(bytes[range])
                    assembling = true
                case 3:
                    guard assembling else { throw ReaderError.invalidFormat }
                    fragments.append(contentsOf: bytes[range])
                case 4:
                    guard assembling else { throw ReaderError.invalidFormat }
                    fragments.append(contentsOf: bytes[range])
                    guard fragments.count <= maximumRecordBytes else {
                        throw ReaderError.invalidFormat
                    }
                    try consume(fragments)
                    fragments.removeAll(keepingCapacity: false)
                    assembling = false
                default:
                    throw ReaderError.invalidFormat
                }
                guard fragments.count <= maximumRecordBytes else {
                    throw ReaderError.invalidFormat
                }
                position = end.partialValue
            }
            blockStart = blockEnd
        }
        // A FIRST/MIDDLE chain without LAST at EOF is an ordinary crash or
        // in-flight append tail. LevelDB discards it without invalidating the
        // complete logical records that preceded it.
    }

    private static func parseWriteBatch(
        _ bytes: [UInt8],
        mutations: inout [KeyIdentity: VersionedMutation]
    ) throws {
        guard bytes.count >= writeBatchHeaderBytes else {
            throw ReaderError.invalidFormat
        }
        let startSequence = readUInt64(bytes, at: 0)
        let count = Int(readUInt32(bytes, at: 8))
        guard count <= maximumBatchEntries,
              startSequence <= maximumSequenceNumber
        else {
            throw ReaderError.invalidFormat
        }
        if count > 0 {
            let lastSequence = startSequence.addingReportingOverflow(UInt64(count - 1))
            guard !lastSequence.overflow,
                  lastSequence.partialValue <= maximumSequenceNumber
            else {
                throw ReaderError.invalidFormat
            }
        }
        var position = writeBatchHeaderBytes
        for entryIndex in 0..<count {
            guard position < bytes.count else { throw ReaderError.invalidFormat }
            let tag = bytes[position]
            position += 1
            let key = try readLengthPrefixed(
                bytes,
                position: &position,
                limit: bytes.count
            )
            let value: Range<Int>?
            switch tag {
            case 0:
                value = nil
            case 1:
                value = try readLengthPrefixed(
                    bytes,
                    position: &position,
                    limit: bytes.count
                )
            default:
                throw ReaderError.invalidFormat
            }
            guard try entitlementKeyDisposition(bytes, range: key) else { continue }
            let sequence = startSequence.addingReportingOverflow(UInt64(entryIndex))
            guard !sequence.overflow,
                  sequence.partialValue <= maximumSequenceNumber
            else {
                throw ReaderError.invalidFormat
            }
            let mutation: Mutation
            if let value {
                guard value.count <= maximumEntitlementValueBytes else {
                    throw ReaderError.invalidFormat
                }
                mutation = .value(Data(bytes[value]))
            } else {
                mutation = .deleted
            }
            try merge(
                identity: keyIdentity(bytes, range: key),
                sequence: sequence.partialValue,
                mutation: mutation,
                into: &mutations
            )
        }
        guard position == bytes.count else { throw ReaderError.invalidFormat }
    }

    // MARK: SST

    private static func parseTable(
        _ bytes: [UInt8],
        mutations: inout [KeyIdentity: VersionedMutation]
    ) throws {
        guard bytes.count >= tableFooterBytes else { throw ReaderError.invalidFormat }
        let footerStart = bytes.count - tableFooterBytes
        let magicStart = bytes.count - 8
        guard readUInt64(bytes, at: magicStart) == tableMagicNumber else {
            throw ReaderError.invalidFormat
        }
        var footerPosition = footerStart
        let metaindex = try readBlockHandle(
            bytes,
            position: &footerPosition,
            limit: footerStart + tableFooterHandleBytes
        )
        let index = try readBlockHandle(
            bytes,
            position: &footerPosition,
            limit: footerStart + tableFooterHandleBytes
        )
        guard bytes[footerPosition..<(footerStart + tableFooterHandleBytes)]
            .allSatisfy({ $0 == 0 })
        else {
            throw ReaderError.invalidFormat
        }
        try validateBlockHandle(metaindex, fileBytes: bytes.count, footerStart: footerStart)
        try validateBlockHandle(index, fileBytes: bytes.count, footerStart: footerStart)

        let indexBlock = try readTableBlock(bytes, handle: index, footerStart: footerStart)
        var dataHandles = Set<BlockHandle>()
        try parseBlock(indexBlock) { key, value in
            try validateInternalKey(key, range: 0..<key.count)
            var position = 0
            let handle = try readBlockHandle(value, position: &position, limit: value.count)
            guard position == value.count, dataHandles.insert(handle).inserted else {
                throw ReaderError.invalidFormat
            }
            try validateBlockHandle(handle, fileBytes: bytes.count, footerStart: footerStart)
        }
        for handle in dataHandles.sorted(by: { $0.offset < $1.offset }) {
            let block = try readTableBlock(bytes, handle: handle, footerStart: footerStart)
            try parseBlock(block) { internalKey, value in
                guard internalKey.count >= 8 else { throw ReaderError.invalidFormat }
                let suffix = internalKey.count - 8
                let tag = readUInt64(internalKey, at: suffix)
                let type = UInt8(tag & 0xFF)
                let sequence = tag >> 8
                guard sequence <= maximumSequenceNumber, type <= 1 else {
                    throw ReaderError.invalidFormat
                }
                let userKey = 0..<suffix
                guard try entitlementKeyDisposition(internalKey, range: userKey) else {
                    return
                }
                let mutation: Mutation
                if type == 0 {
                    guard value.isEmpty else { throw ReaderError.invalidFormat }
                    mutation = .deleted
                } else {
                    guard value.count <= maximumEntitlementValueBytes else {
                        throw ReaderError.invalidFormat
                    }
                    mutation = .value(Data(value))
                }
                try merge(
                    identity: keyIdentity(internalKey, range: userKey),
                    sequence: sequence,
                    mutation: mutation,
                    into: &mutations
                )
            }
        }
    }

    private static func validateBlockHandle(
        _ handle: BlockHandle,
        fileBytes: Int,
        footerStart: Int
    ) throws {
        guard handle.size <= maximumBlockBytes else { throw ReaderError.invalidFormat }
        let contentEnd = handle.offset.addingReportingOverflow(handle.size)
        guard !contentEnd.overflow else { throw ReaderError.invalidFormat }
        let trailerEnd = contentEnd.partialValue.addingReportingOverflow(tableBlockTrailerBytes)
        guard !trailerEnd.overflow,
              trailerEnd.partialValue <= footerStart,
              trailerEnd.partialValue <= fileBytes
        else {
            throw ReaderError.invalidFormat
        }
    }

    private static func readTableBlock(
        _ file: [UInt8],
        handle: BlockHandle,
        footerStart: Int
    ) throws -> [UInt8] {
        try validateBlockHandle(handle, fileBytes: file.count, footerStart: footerStart)
        let contentEnd = handle.offset + handle.size
        let compressionType = file[contentEnd]
        let checksum = readUInt32(file, at: contentEnd + 1)
        let range = handle.offset..<contentEnd
        guard maskedTableCRC32C(
            bytes: file,
            range: range,
            compressionType: compressionType
        ) == checksum else {
            throw ReaderError.invalidFormat
        }
        switch compressionType {
        case 0:
            return Array(file[range])
        case 1:
            return try decompressSnappy(Array(file[range]))
        default:
            throw ReaderError.invalidFormat
        }
    }

    private static func parseBlock(
        _ bytes: [UInt8],
        consume: ([UInt8], [UInt8]) throws -> Void
    ) throws {
        guard bytes.count >= 4 else { throw ReaderError.invalidFormat }
        let restartCount = Int(readUInt32(bytes, at: bytes.count - 4))
        let restartBytes = restartCount.multipliedReportingOverflow(by: 4)
        guard !restartBytes.overflow,
              restartBytes.partialValue <= bytes.count - 4
        else {
            throw ReaderError.invalidFormat
        }
        let restartOffset = bytes.count - 4 - restartBytes.partialValue
        var restarts: [Int] = []
        for index in 0..<restartCount {
            let value = Int(readUInt32(bytes, at: restartOffset + index * 4))
            guard value <= restartOffset,
                  restarts.last.map({ value > $0 }) ?? true
            else {
                throw ReaderError.invalidFormat
            }
            restarts.append(value)
        }
        guard restarts.isEmpty || restarts.first == 0 else {
            throw ReaderError.invalidFormat
        }

        var position = 0
        var previousKey: [UInt8] = []
        var entryStarts: [Int: Int] = [:]
        var entryCount = 0
        while position < restartOffset {
            entryCount += 1
            guard entryCount <= maximumBlockEntries else {
                throw ReaderError.invalidFormat
            }
            let entryStart = position
            let shared = try readVarint32(bytes, position: &position, limit: restartOffset)
            let nonShared = try readVarint32(bytes, position: &position, limit: restartOffset)
            let valueLength = try readVarint32(
                bytes,
                position: &position,
                limit: restartOffset
            )
            guard shared <= previousKey.count else { throw ReaderError.invalidFormat }
            let payload = nonShared.addingReportingOverflow(valueLength)
            guard !payload.overflow else { throw ReaderError.invalidFormat }
            let end = position.addingReportingOverflow(payload.partialValue)
            guard !end.overflow, end.partialValue <= restartOffset else {
                throw ReaderError.invalidFormat
            }
            var key = Array(previousKey.prefix(shared))
            key.append(contentsOf: bytes[position..<(position + nonShared)])
            guard key.count <= maximumBlockKeyBytes else {
                throw ReaderError.invalidFormat
            }
            position += nonShared
            let value = Array(bytes[position..<(position + valueLength)])
            position += valueLength
            entryStarts[entryStart] = shared
            try consume(key, value)
            previousKey = key
        }
        guard position == restartOffset else { throw ReaderError.invalidFormat }
        if entryCount == 0 {
            guard restarts == [0] || restarts.isEmpty else {
                throw ReaderError.invalidFormat
            }
        } else {
            guard !restarts.isEmpty else { throw ReaderError.invalidFormat }
            for restart in restarts where entryStarts[restart] != 0 {
                throw ReaderError.invalidFormat
            }
        }
    }

    private static func decompressSnappy(_ input: [UInt8]) throws -> [UInt8] {
        var position = 0
        let expected = try readVarint32(input, position: &position, limit: input.count)
        guard expected <= maximumBlockBytes else { throw ReaderError.invalidFormat }
        var output: [UInt8] = []
        output.reserveCapacity(expected)
        while position < input.count {
            let tag = input[position]
            position += 1
            let kind = tag & 0x03
            var length: Int
            var offset = 0
            switch kind {
            case 0:
                let encoded = Int(tag >> 2)
                if encoded < 60 {
                    length = encoded + 1
                } else {
                    let byteCount = encoded - 59
                    guard byteCount <= 4, byteCount <= input.count - position else {
                        throw ReaderError.invalidFormat
                    }
                    var lengthMinusOne: UInt32 = 0
                    for index in 0..<byteCount {
                        lengthMinusOne |= UInt32(input[position + index])
                            << UInt32(index * 8)
                    }
                    position += byteCount
                    length = Int(lengthMinusOne) + 1
                }
                guard length <= input.count - position else {
                    throw ReaderError.invalidFormat
                }
                let newSize = output.count.addingReportingOverflow(length)
                guard !newSize.overflow, newSize.partialValue <= expected else {
                    throw ReaderError.invalidFormat
                }
                output.append(contentsOf: input[position..<(position + length)])
                position += length
                continue
            case 1:
                guard position < input.count else { throw ReaderError.invalidFormat }
                length = 4 + Int((tag >> 2) & 0x07)
                offset = Int(tag & 0xE0) << 3 | Int(input[position])
                position += 1
            case 2:
                guard input.count - position >= 2 else { throw ReaderError.invalidFormat }
                length = 1 + Int(tag >> 2)
                offset = Int(input[position]) | Int(input[position + 1]) << 8
                position += 2
            case 3:
                guard input.count - position >= 4 else { throw ReaderError.invalidFormat }
                length = 1 + Int(tag >> 2)
                offset = Int(readUInt32(input, at: position))
                position += 4
            default:
                throw ReaderError.invalidFormat
            }
            guard offset > 0, offset <= output.count else {
                throw ReaderError.invalidFormat
            }
            let newSize = output.count.addingReportingOverflow(length)
            guard !newSize.overflow, newSize.partialValue <= expected else {
                throw ReaderError.invalidFormat
            }
            for _ in 0..<length {
                output.append(output[output.count - offset])
            }
        }
        guard output.count == expected else { throw ReaderError.invalidFormat }
        return output
    }

    // MARK: Shared binary helpers

    private static func entitlementKeyDisposition(
        _ bytes: [UInt8],
        range: Range<Int>
    ) throws -> Bool {
        let exact = starts(with: localStorageKeyPrefix, bytes: bytes, range: range)
        if !exact, contains(entitlementNeedle, bytes: bytes, range: range) {
            throw ReaderError.invalidFormat
        }
        guard exact else { return false }
        guard range.count > localStorageKeyPrefix.count, range.count <= 512 else {
            throw ReaderError.invalidFormat
        }
        return true
    }

    private static func keyIdentity(_ bytes: [UInt8], range: Range<Int>) -> KeyIdentity {
        KeyIdentity(
            byteCount: range.count,
            digest: Data(SHA256.hash(data: Data(bytes[range])))
        )
    }

    private static func merge(
        identity: KeyIdentity,
        sequence: UInt64,
        mutation: Mutation,
        into mutations: inout [KeyIdentity: VersionedMutation]
    ) throws {
        let next = VersionedMutation(sequence: sequence, mutation: mutation)
        if let current = mutations[identity] {
            if current.sequence == sequence {
                guard current.mutation == mutation else {
                    throw ReaderError.invalidFormat
                }
                return
            }
            if current.sequence > sequence { return }
        }
        mutations[identity] = next
        guard mutations.count <= maximumEntitlementEntries else {
            throw ReaderError.invalidFormat
        }
    }

    private static func validateInternalKey(
        _ bytes: [UInt8],
        range: Range<Int>
    ) throws {
        guard range.count >= 8 else { throw ReaderError.invalidFormat }
        let tag = readUInt64(bytes, at: range.upperBound - 8)
        guard tag >> 8 <= maximumSequenceNumber, UInt8(tag & 0xFF) <= 1 else {
            throw ReaderError.invalidFormat
        }
    }

    private static func readBlockHandle(
        _ bytes: [UInt8],
        position: inout Int,
        limit: Int
    ) throws -> BlockHandle {
        let offset = try readVarint64(bytes, position: &position, limit: limit)
        let size = try readVarint64(bytes, position: &position, limit: limit)
        guard offset <= UInt64(Int.max), size <= UInt64(Int.max) else {
            throw ReaderError.invalidFormat
        }
        return BlockHandle(offset: Int(offset), size: Int(size))
    }

    private static func readLengthPrefixed(
        _ bytes: [UInt8],
        position: inout Int,
        limit: Int
    ) throws -> Range<Int> {
        let count = try readVarint32(bytes, position: &position, limit: limit)
        let end = position.addingReportingOverflow(count)
        guard !end.overflow, end.partialValue <= limit else {
            throw ReaderError.invalidFormat
        }
        let range = position..<end.partialValue
        position = end.partialValue
        return range
    }

    private static func readVarint32(
        _ bytes: [UInt8],
        position: inout Int,
        limit: Int
    ) throws -> Int {
        let value = try readVarint64(
            bytes,
            position: &position,
            limit: limit,
            maximumBytes: 5
        )
        guard value <= UInt64(UInt32.max) else { throw ReaderError.invalidFormat }
        return Int(value)
    }

    private static func readVarint64(
        _ bytes: [UInt8],
        position: inout Int,
        limit: Int,
        maximumBytes: Int = 10
    ) throws -> UInt64 {
        var result: UInt64 = 0
        for byteIndex in 0..<maximumBytes {
            guard position < limit, position < bytes.count else {
                throw ReaderError.invalidFormat
            }
            let byte = bytes[position]
            position += 1
            if byteIndex == 9, byte > 1 { throw ReaderError.invalidFormat }
            result |= UInt64(byte & 0x7F) << UInt64(byteIndex * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw ReaderError.invalidFormat
    }

    private static func starts(
        with prefix: [UInt8],
        bytes: [UInt8],
        range: Range<Int>
    ) -> Bool {
        guard range.count >= prefix.count else { return false }
        for index in prefix.indices where bytes[range.lowerBound + index] != prefix[index] {
            return false
        }
        return true
    }

    private static func contains(
        _ needle: [UInt8],
        bytes: [UInt8],
        range: Range<Int>
    ) -> Bool {
        guard !needle.isEmpty, range.count >= needle.count else { return false }
        let finalStart = range.upperBound - needle.count
        for start in range.lowerBound...finalStart {
            var matches = true
            for index in needle.indices where bytes[start + index] != needle[index] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }

    private static func maskedLogCRC32C(
        type: UInt8,
        bytes: [UInt8],
        range: Range<Int>
    ) -> UInt32 {
        var crc = UInt32.max
        crc = updateCRC32C(crc, byte: type)
        for index in range { crc = updateCRC32C(crc, byte: bytes[index]) }
        return maskCRC32C(crc ^ UInt32.max)
    }

    private static func maskedTableCRC32C(
        bytes: [UInt8],
        range: Range<Int>,
        compressionType: UInt8
    ) -> UInt32 {
        var crc = UInt32.max
        for index in range { crc = updateCRC32C(crc, byte: bytes[index]) }
        crc = updateCRC32C(crc, byte: compressionType)
        return maskCRC32C(crc ^ UInt32.max)
    }

    private static func updateCRC32C(_ crc: UInt32, byte: UInt8) -> UInt32 {
        crc32cTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }

    private static func maskCRC32C(_ crc: UInt32) -> UInt32 {
        ((crc >> 15) | (crc << 17)) &+ 0xA282_EAD8
    }

    private static func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    private static func readUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[index + offset]) << UInt64(offset * 8)
        }
        return value
    }

    private static func isRecognizedLevelDBFilename(_ name: String) -> Bool {
        if name == "CURRENT" || name == "LOCK" || name == "LOG" || name == "LOG.old" {
            return true
        }
        return manifestFileNumber(name) != nil
            || levelDBDataFilename(name) != nil
            || levelDBTemporaryFilename(name)
    }

    private static func manifestFileNumber(_ name: String) -> UInt64? {
        let prefix = "MANIFEST-"
        guard name.hasPrefix(prefix) else { return nil }
        let digits = String(name.dropFirst(prefix.count))
        guard canonicalNumber(digits) else { return nil }
        return UInt64(digits)
    }

    private static func levelDBDataFilename(
        _ name: String
    ) -> (number: UInt64, extension: String)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              ["log", "ldb", "sst"].contains(String(parts[1])),
              canonicalNumber(String(parts[0])),
              let number = UInt64(parts[0])
        else {
            return nil
        }
        return (number, String(parts[1]))
    }

    private static func levelDBTemporaryFilename(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts[1] == "dbtmp"
            && canonicalNumber(String(parts[0]))
    }

    private static func canonicalNumber(_ digits: String) -> Bool {
        guard digits.utf8.count >= 6,
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(digits)
        else {
            return false
        }
        return digits == String(format: "%06llu", number)
    }

    private static func tableReferenceSort(
        _ lhs: TableReference,
        _ rhs: TableReference
    ) -> Bool {
        if lhs.level != rhs.level { return lhs.level < rhs.level }
        return lhs.number < rhs.number
    }

    private enum ReaderError: Error {
        case unreadable
        case concurrentMutation
        case invalidFormat
    }

    private final class DirectoryEnumerationState: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false

        func markFailed() {
            lock.lock()
            failed = true
            lock.unlock()
        }

        var hasFailed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failed
        }
    }
}

protocol ZCodeEntitlementReading: Sendable {
    func read(
        provider: ZCodeEntitlementCacheReader.ProviderID,
        now: Date
    ) -> ZCodeEntitlementCacheReader.ReadResult
}

extension ZCodeEntitlementCacheReader: ZCodeEntitlementReading {}
