import Foundation
import XCTest
@testable import LLMPulse

final class ZCodeEntitlementCacheReaderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_787_740_000)

    func testReadsOnlyAllowlistedEntitlementFieldsFromActiveWAL() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let value = try fixture.entitlementValue(cachedAt: base)
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: 10,
                mutations: [.put(fixture.entitlementKey("account-a"), value)]
            )]
        )

        let result = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        )

        guard case let .observed(observation) = result else {
            return XCTFail("Expected an observed entitlement, got \(result)")
        }
        XCTAssertEqual(observation.provider, .bigModelCodingPlan)
        XCTAssertEqual(observation.cachedAt, base)
        XCTAssertEqual(observation.level, "PRO")
        XCTAssertEqual(observation.fiveHour?.unit, 3)
        XCTAssertEqual(observation.fiveHour?.number, 5)
        XCTAssertEqual(observation.fiveHour?.remaining, 123)
        XCTAssertEqual(observation.fiveHour?.usedPercent, 25)
        XCTAssertEqual(observation.weekly?.unit, 6)
        XCTAssertEqual(observation.weekly?.usedPercent, 40)
        XCTAssertEqual(observation.subscriptionDetails.count, 1)
        XCTAssertEqual(
            observation.subscriptionDetails.first?.productName,
            "GLM Coding Plan Pro"
        )
        XCTAssertNotNil(observation.subscriptionDetails.first?.renewsAt)
        XCTAssertNotNil(observation.subscriptionDetails.first?.expiresAt)
    }

    func testProviderMismatchIsAbsentAndExpiredCacheIsStale() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: 10,
                mutations: [
                    .put(
                        fixture.entitlementKey("account-a"),
                        try fixture.entitlementValue(cachedAt: base)
                    ),
                ]
            )]
        )
        let reader = fixture.reader(maximumCacheAge: 600)

        XCTAssertEqual(
            reader.read(provider: .zaiCodingPlan, now: base.addingTimeInterval(1)),
            .absent
        )
        XCTAssertEqual(
            reader.read(provider: .bigModelCodingPlan, now: base.addingTimeInterval(601)),
            .stale(cachedAt: base)
        )
    }

    func testDefaultCacheAgeKeepsSameDaySnapshotDisplayable() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: 10,
                mutations: [
                    .put(
                        fixture.entitlementKey("account-a"),
                        try fixture.entitlementValue(
                            cachedAt: base.addingTimeInterval(-11 * 60 * 60)
                        )
                    ),
                ]
            )]
        )
        let reader = ZCodeEntitlementCacheReader(
            entitlementLocalStorageDirectory: fixture.directory
        )

        guard case .observed = reader.read(provider: .bigModelCodingPlan, now: base) else {
            return XCTFail("Expected a same-day snapshot to stay displayable")
        }
        XCTAssertEqual(
            reader.read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(24 * 60 * 60 + 61)
            ),
            .stale(cachedAt: base.addingTimeInterval(-11 * 60 * 60))
        )
    }

    func testTwoFreshCacheKeysForSameProviderAreAmbiguous() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let value = try fixture.entitlementValue(cachedAt: base)
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: 10,
                mutations: [
                    .put(fixture.entitlementKey("account-a"), value),
                    .put(fixture.entitlementKey("account-b"), value),
                ]
            )]
        )

        XCTAssertEqual(
            fixture.reader().read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(1)
            ),
            .ambiguous
        )
    }

    func testFreshEmptySnapshotStillParticipatesInAccountAmbiguity() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: 10,
                mutations: [
                    .put(
                        fixture.entitlementKey("old-account"),
                        try fixture.entitlementValue(cachedAt: base)
                    ),
                    .put(
                        fixture.entitlementKey("current-empty-account"),
                        try fixture.emptyEntitlementValue(
                            cachedAt: base.addingTimeInterval(1)
                        )
                    ),
                ]
            )]
        )

        XCTAssertEqual(
            fixture.reader().read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(2)
            ),
            .ambiguous
        )
    }

    func testExcessiveDirectoryEntriesFailClosed() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(sequence: 10, mutations: [])]
        )
        // CURRENT, MANIFEST and WAL already occupy three entries. These
        // recognized temporary files take the direct-child count over 512.
        try fixture.addTemporaryFiles(count: 510, startingAt: 1_000)

        XCTAssertEqual(
            fixture.reader().read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(1)
            ),
            .formatDrift
        )
    }

    func testReadsPhysicallyFragmentedWALRecord() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let value = try fixture.entitlementValue(cachedAt: base, paddingBytes: 70_000)
        let log = fixture.writeBatchLog(
            sequence: 10,
            mutations: [.put(fixture.entitlementKey("fragmented"), value)]
        )
        XCTAssertGreaterThan(log.count, 2 * 32_768)
        try fixture.install(logNumber: 3, logs: [3: log])

        guard case let .observed(observation) = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Fragmented WAL was not decoded")
        }
        XCTAssertEqual(observation.fiveHour?.usedPercent, 25)
    }

    func testHistoricalEmptyFirstAtBlockTailBeforeFullIsIgnored() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let log = fixture.logWithEmptyFirstAtBlockTail(
            sequence: 10,
            mutations: [
                .put(
                    fixture.entitlementKey("after-full"),
                    try fixture.entitlementValue(cachedAt: base)
                ),
            ],
            nextRecordIsFragmented: false
        )
        XCTAssertEqual(log[32_768 + 6], 1)
        try fixture.install(logNumber: 3, logs: [3: log])

        guard case .observed = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Historical empty FIRST rejected the following FULL")
        }
    }

    func testHistoricalEmptyFirstAtBlockTailBeforeFirstIsIgnored() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let log = fixture.logWithEmptyFirstAtBlockTail(
            sequence: 10,
            mutations: [
                .put(
                    fixture.entitlementKey("after-first"),
                    try fixture.entitlementValue(cachedAt: base)
                ),
            ],
            nextRecordIsFragmented: true
        )
        XCTAssertEqual(log[32_768 + 6], 2)
        try fixture.install(logNumber: 3, logs: [3: log])

        guard case .observed = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Historical empty FIRST rejected the following FIRST")
        }
    }

    func testPreviousLogNumberIsActiveAndIntermediateLogIsIgnored() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let value = try fixture.entitlementValue(cachedAt: base)
        try fixture.install(
            logNumber: 5,
            previousLogNumber: 3,
            logs: [
                3: fixture.writeBatchLog(
                    sequence: 10,
                    mutations: [.put(fixture.entitlementKey("previous"), value)]
                ),
                4: fixture.writeBatchLog(
                    sequence: 20,
                    mutations: [.put(fixture.entitlementKey("obsolete"), value)]
                ),
                5: fixture.writeBatchLog(sequence: 30, mutations: []),
            ]
        )

        guard case .observed = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("previousLogNumber was skipped or an intermediate WAL was revived")
        }
    }

    func testZeroLogNumberKeepsExistingWALActive() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 0,
            logs: [
                3: fixture.writeBatchLog(
                    sequence: 10,
                    mutations: [
                        .put(
                            fixture.entitlementKey("zero-log-number"),
                            try fixture.entitlementValue(cachedAt: base)
                        ),
                    ]
                ),
            ]
        )

        guard case .observed = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("logNumber == 0 did not retain the existing WAL")
        }
    }

    func testManifestPartialHeaderAtEOFKeepsCompleteVersionEdit() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: 10,
                mutations: [
                    .put(
                        fixture.entitlementKey("manifest-tail"),
                        try fixture.entitlementValue(cachedAt: base)
                    ),
                ]
            )]
        )
        let manifestURL = fixture.directory.appendingPathComponent("MANIFEST-000001")
        var manifest = try Data(contentsOf: manifestURL)
        manifest.append(contentsOf: [0xAA, 0xBB, 0xCC])
        try manifest.write(to: manifestURL)

        guard case .observed = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Partial MANIFEST header at EOF discarded valid state")
        }
    }

    func testDeclaredWALPayloadTruncatedAtEOFKeepsPriorBatch() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        var log = fixture.writeBatchLog(
            sequence: 10,
            mutations: [
                .put(
                    fixture.entitlementKey("payload-tail"),
                    try fixture.entitlementValue(cachedAt: base)
                ),
            ]
        )
        // Complete physical header declaring 100 bytes, with only two bytes
        // present before EOF. The checksum is intentionally irrelevant.
        log.append(contentsOf: [0, 0, 0, 0, 100, 0, 1, 0xAA, 0xBB])
        try fixture.install(logNumber: 3, logs: [3: log])

        guard case .observed = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Truncated WAL payload invalidated a prior batch")
        }
    }

    func testUnfinishedFragmentChainAtEOFKeepsPriorBatch() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let complete = fixture.writeBatchLog(
            sequence: 10,
            mutations: [
                .put(
                    fixture.entitlementKey("fragment-tail"),
                    try fixture.entitlementValue(cachedAt: base)
                ),
            ]
        )
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.appendingUnfinishedFragment(to: complete)]
        )

        guard case .observed = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Unfinished fragment chain invalidated a prior batch")
        }
    }

    func testCompleteRecordCorruptionBeforeEOFTailStillFailsClosed() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        var log = fixture.writeBatchLog(
            sequence: 10,
            mutations: [
                .put(
                    fixture.entitlementKey("corrupt-before-tail"),
                    try fixture.entitlementValue(cachedAt: base)
                ),
            ]
        )
        log[0] ^= 0xFF
        log.append(contentsOf: [0xAA, 0xBB, 0xCC])
        try fixture.install(logNumber: 3, logs: [3: log])

        XCTAssertEqual(
            fixture.reader().read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(1)
            ),
            .formatDrift
        )
    }

    func testReadsRawSSTSelectedByCurrentManifest() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let table = fixture.table(
            entries: [
                .init(
                    key: fixture.entitlementKey("raw"),
                    sequence: 20,
                    value: try fixture.entitlementValue(cachedAt: base)
                ),
            ],
            compressed: false
        )
        try fixture.install(logNumber: 100, tables: [table])

        guard case let .observed(observation) = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Raw table was not decoded")
        }
        XCTAssertEqual(observation.weekly?.usedPercent, 40)
    }

    func testReadsSnappySSTSelectedByCurrentManifest() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let table = fixture.table(
            number: 7,
            entries: [
                .init(
                    key: fixture.entitlementKey("snappy"),
                    sequence: 30,
                    value: try fixture.entitlementValue(cachedAt: base)
                ),
            ],
            compressed: true
        )
        try fixture.install(logNumber: 100, tables: [table])

        guard case let .observed(observation) = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Snappy table was not decoded")
        }
        XCTAssertEqual(observation.fiveHour?.usedPercent, 25)
    }

    func testReadsSnappyCopyBackReferenceFromActiveSST() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let table = fixture.table(
            number: 8,
            entries: [
                .init(
                    key: fixture.entitlementKey("snappy-copy"),
                    sequence: 30,
                    value: try fixture.entitlementValue(
                        cachedAt: base,
                        paddingBytes: 1_024
                    )
                ),
            ],
            compressed: true,
            dataBlockUsesSnappyCopy: true
        )
        try fixture.install(logNumber: 100, tables: [table])

        guard case let .observed(observation) = fixture.reader().read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Snappy COPY_2 back-reference was not decoded")
        }
        XCTAssertEqual(observation.weekly?.usedPercent, 40)
    }

    func testNewerTombstoneWinsAndObsoleteFilesCannotReviveValue() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let key = fixture.entitlementKey("deleted")
        let activeTable = fixture.table(
            number: 5,
            entries: [
                .init(
                    key: key,
                    sequence: 10,
                    value: try fixture.entitlementValue(cachedAt: base)
                ),
            ],
            compressed: false
        )
        let obsoleteTable = fixture.table(
            number: 4,
            entries: [
                .init(
                    key: key,
                    sequence: 1_000,
                    value: try fixture.entitlementValue(cachedAt: base)
                ),
            ],
            compressed: true
        )
        try fixture.install(
            logNumber: 6,
            tables: [activeTable],
            deletedTablesLeftOnDisk: [obsoleteTable],
            logs: [6: fixture.writeBatchLog(
                sequence: 20,
                mutations: [.delete(key)]
            )]
        )
        try fixture.writeBatchLog(
            sequence: 2_000,
            mutations: [
                .put(key, try fixture.entitlementValue(cachedAt: base)),
            ]
        ).write(to: fixture.directory.appendingPathComponent("000003.log"))

        XCTAssertEqual(
            fixture.reader().read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(1)
            ),
            .absent
        )
    }

    func testSSTTombstoneHidesOlderValueForSameKey() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let key = fixture.entitlementKey("table-deleted")
        let table = fixture.table(
            entries: [
                .init(
                    key: key,
                    sequence: 10,
                    value: try fixture.entitlementValue(cachedAt: base)
                ),
                .init(key: key, sequence: 20, value: nil),
            ],
            compressed: true
        )
        try fixture.install(logNumber: 100, tables: [table])

        XCTAssertEqual(
            fixture.reader().read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(1)
            ),
            .absent
        )
    }

    func testSequenceOverflowFailsClosed() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        let value = try fixture.entitlementValue(cachedAt: base)
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: UInt64.max,
                mutations: [
                    .put(Data("ordinary".utf8), Data("ignored".utf8)),
                    .put(fixture.entitlementKey("overflow"), value),
                ]
            )]
        )

        XCTAssertEqual(
            fixture.reader().read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(1)
            ),
            .formatDrift
        )
    }

    func testCorruptManifestChecksumFailsClosed() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(sequence: 10, mutations: [])]
        )
        let manifestURL = fixture.directory.appendingPathComponent("MANIFEST-000001")
        var manifest = try Data(contentsOf: manifestURL)
        manifest[0] ^= 0xFF
        try manifest.write(to: manifestURL)

        XCTAssertEqual(
            fixture.reader().read(
                provider: .bigModelCodingPlan,
                now: base.addingTimeInterval(1)
            ),
            .formatDrift
        )
    }

    func testGrowthAfterFstatIsUnreadableAndNotCached() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: 10,
                mutations: [
                    .put(
                        fixture.entitlementKey("race"),
                        try fixture.entitlementValue(cachedAt: base)
                    ),
                ]
            )]
        )
        let probe = SourceReadProbe(
            mutateOnceAt: fixture.directory.appendingPathComponent("000003.log")
        )
        let reader = fixture.reader(sourceReadObserver: { url in
            probe.observe(url)
        })

        XCTAssertEqual(
            reader.read(provider: .bigModelCodingPlan, now: base.addingTimeInterval(1)),
            .unreadable
        )
        XCTAssertTrue(probe.didMutate)
    }

    func testUnchangedFileStampsReuseParsedCache() throws {
        let fixture = try EntitlementLevelDBFixture()
        defer { fixture.remove() }
        try fixture.install(
            logNumber: 3,
            logs: [3: fixture.writeBatchLog(
                sequence: 10,
                mutations: [
                    .put(
                        fixture.entitlementKey("cached"),
                        try fixture.entitlementValue(cachedAt: base)
                    ),
                ]
            )]
        )
        let probe = SourceReadProbe()
        let reader = fixture.reader(sourceReadObserver: { url in
            probe.observe(url)
        })
        guard case .observed = reader.read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(1)
        ) else {
            return XCTFail("Initial read failed")
        }
        let readsAfterFirstPoll = probe.readCount
        XCTAssertEqual(readsAfterFirstPoll, 3)

        guard case .observed = reader.read(
            provider: .bigModelCodingPlan,
            now: base.addingTimeInterval(2)
        ) else {
            return XCTFail("Cached read failed")
        }
        XCTAssertEqual(probe.readCount, readsAfterFirstPoll)
    }
}

private final class SourceReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let mutationTarget: URL?
    private var count = 0
    private var mutated = false

    init(mutateOnceAt mutationTarget: URL? = nil) {
        self.mutationTarget = mutationTarget
    }

    func observe(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        guard !mutated,
              url.lastPathComponent == mutationTarget?.lastPathComponent
        else {
            return
        }
        mutated = true
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var didMutate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutated
    }
}

private final class EntitlementLevelDBFixture {
    enum BatchMutation {
        case put(Data, Data)
        case delete(Data)
    }

    struct TableEntry {
        let key: Data
        let sequence: UInt64
        let value: Data?
    }

    struct TableFile {
        let number: UInt64
        let level: Int
        let data: Data
        let smallest: Data
        let largest: Data
        let maximumSequence: UInt64
    }

    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmpulse-zcode-entitlement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func reader(
        maximumCacheAge: TimeInterval = 600,
        sourceReadObserver: (@Sendable (URL) -> Void)? = nil
    ) -> ZCodeEntitlementCacheReader {
        ZCodeEntitlementCacheReader(
            entitlementLocalStorageDirectory: directory,
            maximumCacheAge: maximumCacheAge,
            sourceReadObserver: sourceReadObserver
        )
    }

    func entitlementKey(_ suffix: String) -> Data {
        Data("_file://\0\u{1}zcode:usage-entitlement:\(suffix)".utf8)
    }

    func entitlementValue(
        cachedAt: Date,
        provider: String = "builtin:bigmodel-coding-plan",
        paddingBytes: Int = 0
    ) throws -> Data {
        var object: [String: Any] = [
            "cachedAt": cachedAt.timeIntervalSince1970 * 1_000,
            "snapshot": [
                "provider": [
                    "id": provider,
                    "fingerprint": "forbidden-provider-fingerprint",
                ],
                "quota": [
                    "level": "PRO",
                    "limits": [
                        [
                            "type": "TOKENS_LIMIT",
                            "unit": 3,
                            "number": 5,
                            "remaining": 123,
                            "percentage": 25,
                            "nextResetTime": cachedAt.addingTimeInterval(3_600)
                                .timeIntervalSince1970 * 1_000,
                        ],
                        [
                            "type": "CREDIT_LIMIT",
                            "unit": 6,
                            "number": 7,
                            "remaining": 456,
                            "percentage": 40,
                            "nextResetTime": cachedAt.addingTimeInterval(7 * 86_400)
                                .timeIntervalSince1970 * 1_000,
                        ],
                    ],
                ],
                "subscription": [
                    "details": [
                        [
                            "productName": "GLM Coding Plan Pro",
                            "billingCycle": "MONTH",
                            "renewTime": "2026-09-01T00:00:00Z",
                            "expireTime": "2026-10-01T00:00:00.000Z",
                        ],
                    ],
                ],
                "account": [
                    "email": "must-not-be-decoded@example.invalid",
                    "organization": "must-not-be-decoded",
                ],
            ],
            "credential": "must-not-be-decoded",
        ]
        if paddingBytes > 0 {
            object["ignoredPadding"] = String(repeating: "x", count: paddingBytes)
        }
        var stored = Data([1])
        stored.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        return stored
    }

    func emptyEntitlementValue(
        cachedAt: Date,
        provider: String = "builtin:bigmodel-coding-plan"
    ) throws -> Data {
        let object: [String: Any] = [
            "cachedAt": cachedAt.timeIntervalSince1970 * 1_000,
            "snapshot": [
                "provider": ["id": provider],
            ],
        ]
        var stored = Data([1])
        stored.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        return stored
    }

    func install(
        logNumber: UInt64,
        previousLogNumber: UInt64 = 0,
        tables: [TableFile] = [],
        deletedTablesLeftOnDisk: [TableFile] = [],
        logs: [UInt64: Data] = [:]
    ) throws {
        for table in tables + deletedTablesLeftOnDisk {
            try table.data.write(
                to: directory.appendingPathComponent("\(fileNumber(table.number)).ldb")
            )
        }
        for (number, log) in logs {
            try log.write(
                to: directory.appendingPathComponent("\(fileNumber(number)).log")
            )
        }
        let allTables = tables + deletedTablesLeftOnDisk
        let lastSequence = allTables.map(\.maximumSequence).max() ?? 0
        let next = ([logNumber, previousLogNumber]
            + allTables.map(\.number)
            + Array(logs.keys)).max()! + 1
        let manifest = manifestLog(
            logNumber: logNumber,
            previousLogNumber: previousLogNumber,
            nextFileNumber: next,
            lastSequence: lastSequence,
            tables: allTables,
            deletedTables: deletedTablesLeftOnDisk
        )
        try manifest.write(
            to: directory.appendingPathComponent("MANIFEST-000001")
        )
        try Data("MANIFEST-000001\n".utf8).write(
            to: directory.appendingPathComponent("CURRENT")
        )
    }

    func addTemporaryFiles(count: Int, startingAt: UInt64) throws {
        precondition(count >= 0)
        for offset in 0..<count {
            let number = startingAt + UInt64(offset)
            try Data().write(
                to: directory.appendingPathComponent("\(fileNumber(number)).dbtmp")
            )
        }
    }

    func writeBatchLog(
        sequence: UInt64,
        mutations: [BatchMutation]
    ) -> Data {
        recordLog([writeBatchData(sequence: sequence, mutations: mutations)])
    }

    func logWithEmptyFirstAtBlockTail(
        sequence: UInt64,
        mutations: [BatchMutation],
        nextRecordIsFragmented: Bool
    ) -> Data {
        let paddingBatch = writeBatchData(
            sequence: 1,
            mutations: [
                .put(
                    Data("ordinary".utf8),
                    Data(repeating: 0x78, count: 32_729)
                ),
            ]
        )
        precondition(paddingBatch.count == 32_754)
        var log = recordLog([paddingBatch])
        precondition(log.count == 32_761)
        log.append(physicalRecord(type: 2, payload: Data()))
        precondition(log.count == 32_768)

        let nextBatch = writeBatchData(sequence: sequence, mutations: mutations)
        if nextRecordIsFragmented {
            let split = nextBatch.count / 2
            precondition(split > 0 && split < nextBatch.count)
            log.append(physicalRecord(
                type: 2,
                payload: Data(nextBatch.prefix(split))
            ))
            log.append(physicalRecord(
                type: 4,
                payload: Data(nextBatch.dropFirst(split))
            ))
        } else {
            log.append(physicalRecord(type: 1, payload: nextBatch))
        }
        precondition(log.count <= 2 * 32_768)
        return log
    }

    private func writeBatchData(
        sequence: UInt64,
        mutations: [BatchMutation]
    ) -> Data {
        var batch: [UInt8] = []
        appendFixed64(sequence, to: &batch)
        appendFixed32(UInt32(mutations.count), to: &batch)
        for mutation in mutations {
            switch mutation {
            case let .put(key, value):
                batch.append(1)
                appendLengthPrefixed(key, to: &batch)
                appendLengthPrefixed(value, to: &batch)
            case let .delete(key):
                batch.append(0)
                appendLengthPrefixed(key, to: &batch)
            }
        }
        return Data(batch)
    }

    func appendingUnfinishedFragment(to log: Data) -> Data {
        var result = log
        let payload = Array(Data("unfinished-logical-record".utf8))
        let type: UInt8 = 2 // FIRST, intentionally without a later LAST.
        var header: [UInt8] = []
        appendFixed32(maskedCRC32C([type] + payload), to: &header)
        header.append(UInt8(payload.count & 0xFF))
        header.append(UInt8((payload.count >> 8) & 0xFF))
        header.append(type)
        result.append(contentsOf: header)
        result.append(contentsOf: payload)
        return result
    }

    func table(
        number: UInt64 = 5,
        level: Int = 0,
        entries: [TableEntry],
        compressed: Bool,
        dataBlockUsesSnappyCopy: Bool = false
    ) -> TableFile {
        precondition(!entries.isEmpty)
        precondition(!dataBlockUsesSnappyCopy || compressed)
        let internalEntries = entries.map { entry -> (key: Data, value: Data) in
            (
                internalKey(entry.key, sequence: entry.sequence, value: entry.value != nil),
                entry.value ?? Data()
            )
        }.sorted { lhs, rhs in
            internalKeyPrecedes(lhs.key, rhs.key)
        }
        let dataBlock = block(internalEntries)
        var file = Data()
        let dataHandle = appendStoredBlock(
            dataBlock,
            compressed: compressed,
            useSnappyCopy: dataBlockUsesSnappyCopy,
            to: &file
        )
        let metaindex = block([])
        let metaindexHandle = appendStoredBlock(
            metaindex,
            compressed: compressed,
            to: &file
        )
        let index = block([
            (
                key: internalEntries.last!.key,
                value: blockHandleData(dataHandle)
            ),
        ])
        let indexHandle = appendStoredBlock(index, compressed: compressed, to: &file)
        var footer = blockHandleData(metaindexHandle)
        footer.append(blockHandleData(indexHandle))
        precondition(footer.count <= 40)
        footer.append(Data(repeating: 0, count: 40 - footer.count))
        var magic: [UInt8] = []
        appendFixed64(0xdb47_7524_8b80_fb57, to: &magic)
        footer.append(contentsOf: magic)
        file.append(footer)
        return TableFile(
            number: number,
            level: level,
            data: file,
            smallest: internalEntries.first!.key,
            largest: internalEntries.last!.key,
            maximumSequence: entries.map(\.sequence).max()!
        )
    }

    private func manifestLog(
        logNumber: UInt64,
        previousLogNumber: UInt64,
        nextFileNumber: UInt64,
        lastSequence: UInt64,
        tables: [TableFile],
        deletedTables: [TableFile]
    ) -> Data {
        var edit: [UInt8] = []
        appendVarint(1, to: &edit)
        appendLengthPrefixed(Data("leveldb.BytewiseComparator".utf8), to: &edit)
        appendVarint(2, to: &edit)
        appendVarint(logNumber, to: &edit)
        if previousLogNumber != 0 {
            appendVarint(9, to: &edit)
            appendVarint(previousLogNumber, to: &edit)
        }
        appendVarint(3, to: &edit)
        appendVarint(nextFileNumber, to: &edit)
        appendVarint(4, to: &edit)
        appendVarint(lastSequence, to: &edit)
        for table in tables {
            appendVarint(7, to: &edit)
            appendVarint(UInt64(table.level), to: &edit)
            appendVarint(table.number, to: &edit)
            appendVarint(UInt64(table.data.count), to: &edit)
            appendLengthPrefixed(table.smallest, to: &edit)
            appendLengthPrefixed(table.largest, to: &edit)
        }
        var records = [Data(edit)]
        if !deletedTables.isEmpty {
            var deletionEdit: [UInt8] = []
            for table in deletedTables {
                appendVarint(6, to: &deletionEdit)
                appendVarint(UInt64(table.level), to: &deletionEdit)
                appendVarint(table.number, to: &deletionEdit)
            }
            records.append(Data(deletionEdit))
        }
        return recordLog(records)
    }

    private func recordLog(_ records: [Data]) -> Data {
        var result: [UInt8] = []
        for record in records {
            let bytes = Array(record)
            var position = 0
            var first = true
            repeat {
                let blockOffset = result.count % 32_768
                let remaining = 32_768 - blockOffset
                if remaining <= 7 {
                    result.append(contentsOf: repeatElement(0, count: remaining))
                    continue
                }
                let available = remaining - 7
                let fragmentLength = min(bytes.count - position, available)
                let last = position + fragmentLength == bytes.count
                let type: UInt8
                if first && last {
                    type = 1
                } else if first {
                    type = 2
                } else if last {
                    type = 4
                } else {
                    type = 3
                }
                let fragment = Array(bytes[position..<(position + fragmentLength)])
                let checksum = maskedCRC32C([type] + fragment)
                appendFixed32(checksum, to: &result)
                result.append(UInt8(fragmentLength & 0xFF))
                result.append(UInt8((fragmentLength >> 8) & 0xFF))
                result.append(type)
                result.append(contentsOf: fragment)
                position += fragmentLength
                first = false
            } while position < bytes.count
        }
        return Data(result)
    }

    private func physicalRecord(type: UInt8, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt16.max))
        let payloadBytes = Array(payload)
        var result: [UInt8] = []
        appendFixed32(maskedCRC32C([type] + payloadBytes), to: &result)
        result.append(UInt8(payload.count & 0xFF))
        result.append(UInt8((payload.count >> 8) & 0xFF))
        result.append(type)
        result.append(contentsOf: payloadBytes)
        return Data(result)
    }

    private func block(_ entries: [(key: Data, value: Data)]) -> Data {
        var content: [UInt8] = []
        var restarts: [UInt32] = []
        for entry in entries {
            restarts.append(UInt32(content.count))
            appendVarint(0, to: &content)
            appendVarint(UInt64(entry.key.count), to: &content)
            appendVarint(UInt64(entry.value.count), to: &content)
            content.append(contentsOf: entry.key)
            content.append(contentsOf: entry.value)
        }
        if restarts.isEmpty { restarts = [0] }
        for restart in restarts { appendFixed32(restart, to: &content) }
        appendFixed32(UInt32(restarts.count), to: &content)
        return Data(content)
    }

    private func appendStoredBlock(
        _ raw: Data,
        compressed: Bool,
        useSnappyCopy: Bool = false,
        to file: inout Data
    ) -> (offset: Int, size: Int) {
        let stored: Data
        if useSnappyCopy {
            precondition(compressed)
            stored = snappyWithCopy(raw)
        } else {
            stored = compressed ? snappyLiteral(raw) : raw
        }
        let type: UInt8 = compressed ? 1 : 0
        let handle = (offset: file.count, size: stored.count)
        file.append(stored)
        file.append(type)
        var trailer: [UInt8] = []
        appendFixed32(maskedCRC32C(Array(stored) + [type]), to: &trailer)
        file.append(contentsOf: trailer)
        return handle
    }

    private func snappyLiteral(_ raw: Data) -> Data {
        var result: [UInt8] = []
        appendVarint(UInt64(raw.count), to: &result)
        let bytes = Array(raw)
        appendSnappyLiteral(bytes[...], to: &result)
        return Data(result)
    }

    private func snappyWithCopy(_ raw: Data) -> Data {
        let bytes = Array(raw)
        guard let run = repeatedRun(in: bytes, minimumLength: 8) else {
            preconditionFailure("Snappy COPY fixture requires repeated source bytes")
        }
        var result: [UInt8] = []
        appendVarint(UInt64(bytes.count), to: &result)

        // Emit the first byte of the run literally, then exercise COPY_2 with
        // offset 1. Chunking at 64 bytes covers Snappy's maximum COPY_2 length.
        appendSnappyLiteral(bytes[..<(run.lowerBound + 1)], to: &result)
        var remaining = run.count - 1
        while remaining > 0 {
            let length = min(remaining, 64)
            result.append(UInt8(((length - 1) << 2) | 0x02))
            result.append(1)
            result.append(0)
            remaining -= length
        }
        appendSnappyLiteral(bytes[run.upperBound...], to: &result)
        return Data(result)
    }

    private func appendSnappyLiteral(
        _ bytes: ArraySlice<UInt8>,
        to result: inout [UInt8]
    ) {
        var position = bytes.startIndex
        while position < bytes.endIndex {
            let length = min(bytes.endIndex - position, 65_536)
            let lengthMinusOne = length - 1
            if length <= 60 {
                result.append(UInt8(lengthMinusOne << 2))
            } else {
                var byteCount = 1
                while lengthMinusOne >= 1 << (byteCount * 8) { byteCount += 1 }
                result.append(UInt8((59 + byteCount) << 2))
                for index in 0..<byteCount {
                    result.append(UInt8((lengthMinusOne >> (index * 8)) & 0xFF))
                }
            }
            result.append(contentsOf: bytes[position..<(position + length)])
            position += length
        }
    }

    private func repeatedRun(
        in bytes: [UInt8],
        minimumLength: Int
    ) -> Range<Int>? {
        var start = 0
        while start < bytes.count {
            var end = start + 1
            while end < bytes.count, bytes[end] == bytes[start] {
                end += 1
            }
            if end - start >= minimumLength { return start..<end }
            start = end
        }
        return nil
    }

    private func internalKey(
        _ userKey: Data,
        sequence: UInt64,
        value: Bool
    ) -> Data {
        var result = userKey
        var tag: [UInt8] = []
        appendFixed64((sequence << 8) | (value ? 1 : 0), to: &tag)
        result.append(contentsOf: tag)
        return result
    }

    private func internalSequence(_ internalKey: Data) -> UInt64 {
        let bytes = Array(internalKey.suffix(8))
        var tag: UInt64 = 0
        for index in 0..<8 {
            tag |= UInt64(bytes[index]) << UInt64(index * 8)
        }
        return tag >> 8
    }

    private func blockHandleData(_ handle: (offset: Int, size: Int)) -> Data {
        var result: [UInt8] = []
        appendVarint(UInt64(handle.offset), to: &result)
        appendVarint(UInt64(handle.size), to: &result)
        return Data(result)
    }

    private func appendLengthPrefixed(_ data: Data, to bytes: inout [UInt8]) {
        appendVarint(UInt64(data.count), to: &bytes)
        bytes.append(contentsOf: data)
    }

    private func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var value = value
        while value >= 128 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    private func appendFixed32(_ value: UInt32, to bytes: inout [UInt8]) {
        for index in 0..<4 {
            bytes.append(UInt8((value >> UInt32(index * 8)) & 0xFF))
        }
    }

    private func appendFixed64(_ value: UInt64, to bytes: inout [UInt8]) {
        for index in 0..<8 {
            bytes.append(UInt8((value >> UInt64(index * 8)) & 0xFF))
        }
    }

    private func lexicographicallyPrecedes(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        for index in 0..<min(left.count, right.count) {
            if left[index] != right[index] { return left[index] < right[index] }
        }
        return left.count < right.count
    }

    private func internalKeyPrecedes(_ lhs: Data, _ rhs: Data) -> Bool {
        let leftUser = lhs.dropLast(8)
        let rightUser = rhs.dropLast(8)
        if leftUser != rightUser {
            return lexicographicallyPrecedes(Data(leftUser), Data(rightUser))
        }
        return internalSequence(lhs) > internalSequence(rhs)
    }

    private func fileNumber(_ number: UInt64) -> String {
        String(format: "%06llu", number)
    }

    private func maskedCRC32C(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc = crc32cTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        crc ^= UInt32.max
        return ((crc >> 15) | (crc << 17)) &+ 0xA282_EAD8
    }

    private let crc32cTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82F6_3B78 : 0)
        }
        return crc
    }
}
