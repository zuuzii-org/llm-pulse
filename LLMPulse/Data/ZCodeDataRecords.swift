import Foundation

struct ZCodeModelSelection: Equatable, Sendable {
    let providerID: String
    let modelID: String
    let thoughtLevel: String?

    var isGLM: Bool {
        Self.isSupportedGLM(providerID: providerID, modelID: modelID)
    }

    var isCodingPlan: Bool {
        isGLM && providerID.lowercased().hasSuffix("-coding-plan")
    }

    static func isSupportedGLM(providerID: String, modelID: String) -> Bool {
        let provider = providerID.lowercased()
        let supportedProvider = provider == "builtin:bigmodel"
            || provider.hasPrefix("builtin:bigmodel-")
            || provider == "builtin:zai"
            || provider.hasPrefix("builtin:zai-")
        return supportedProvider && modelID.uppercased().hasPrefix("GLM")
    }
}

struct ZCodeUsageTotals: Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let requestCount: Int
    let latestUsageAt: Date?

    var totalTokens: Int? {
        Self.checkedSum([inputTokens, outputTokens, reasoningTokens])
    }

    var tokenSnapshot: TokenUsageSnapshot? {
        guard requestCount > 0 || totalTokens != 0, let totalTokens else { return nil }
        return TokenUsageSnapshot(
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            cachedInputTokens: cacheReadInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningTokens
        )
    }

    static let zero = ZCodeUsageTotals(
        inputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        cacheCreationInputTokens: 0,
        cacheReadInputTokens: 0,
        requestCount: 0,
        latestUsageAt: nil
    )

    static func combined(_ values: some Sequence<ZCodeUsageTotals>) -> ZCodeUsageTotals? {
        var input = 0
        var output = 0
        var reasoning = 0
        var cacheCreation = 0
        var cacheRead = 0
        var requests = 0
        var latest: Date?

        for value in values {
            guard let nextInput = checkedSum([input, value.inputTokens]),
                  let nextOutput = checkedSum([output, value.outputTokens]),
                  let nextReasoning = checkedSum([reasoning, value.reasoningTokens]),
                  let nextCacheCreation = checkedSum([
                      cacheCreation,
                      value.cacheCreationInputTokens,
                  ]),
                  let nextCacheRead = checkedSum([cacheRead, value.cacheReadInputTokens]),
                  let nextRequests = checkedSum([requests, value.requestCount])
            else {
                return nil
            }
            input = nextInput
            output = nextOutput
            reasoning = nextReasoning
            cacheCreation = nextCacheCreation
            cacheRead = nextCacheRead
            requests = nextRequests
            if let observed = value.latestUsageAt {
                latest = latest.map { max($0, observed) } ?? observed
            }
        }

        return ZCodeUsageTotals(
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: cacheRead,
            requestCount: requests,
            latestUsageAt: latest
        )
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }
}

struct ZCodeSessionRecord: Equatable, Sendable {
    let sessionID: String
    let title: String
    let projectDirectory: String
    let createdAt: Date
    let updatedAt: Date
    let selection: ZCodeModelSelection
    let usage: ZCodeUsageTotals
}

struct ZCodeSQLiteReadResult: Sendable {
    let records: [ZCodeSessionRecord]
    let driftedRootCount: Int
}

struct ZCodeEventObservation: Equatable, Sendable {
    let status: TaskStatusRecord
    let activeAgentCount: Int?
    let agentActivityConfidence: AgentActivityObservation.Confidence
}

struct ZCodeEventLogReadResult: Sendable {
    let observations: [String: ZCodeEventObservation]
    let totalLineCount: Int
    let recognizedEventCount: Int
    let matchedRootEventCount: Int
    let invalidLineCount: Int
    let malformedRelevantEventCount: Int
}
