import Foundation

struct RolloutJSONLTailParser: Sendable {
    private let maximumTailBytes: Int
    private let failureQuietPeriod: TimeInterval
    private let activeFileFreshness: TimeInterval

    /// A failure inferred from a quiet error event is deliberately reversible:
    /// the row reports `.failed` after `failureQuietPeriod`, and returns to
    /// `.running` if the rollout grows again, because an automatic retry
    /// writes after its backoff. `TaskStatusRecord.failedFromError` marks
    /// those inferences so consumers that cannot take an action back — a
    /// notification, most of all — can wait for a terminal event instead.
    init(
        maximumTailBytes: Int = 16 * 1_024 * 1_024,
        failureQuietPeriod: TimeInterval = 3,
        activeFileFreshness: TimeInterval = 10
    ) {
        self.maximumTailBytes = maximumTailBytes
        self.failureQuietPeriod = failureQuietPeriod
        self.activeFileFreshness = activeFileFreshness
    }

    func parse(
        threadId: String,
        defaultStartedAt: Date,
        from url: URL,
        now: Date = .now
    ) throws -> TaskStatusRecord? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = attributes[.modificationDate] as? Date ?? defaultStartedAt
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let tail = try readTail(from: url, fileSize: fileSize)
        return parse(
            threadId: threadId,
            defaultStartedAt: defaultStartedAt,
            tail: tail,
            fileModificationDate: modificationDate,
            now: now,
            initialStatus: nil
        )
    }

    func parse(
        threadId: String,
        defaultStartedAt: Date,
        tail: Data,
        fileModificationDate: Date,
        now: Date,
        initialStatus: TaskStatusRecord? = nil
    ) -> TaskStatusRecord? {
        var state = initialStatus?.state
        var turnId = initialStatus?.turnId
        var startedAt = initialStatus?.startedAt ?? defaultStartedAt
        var updatedAt = initialStatus?.updatedAt ?? defaultStartedAt
        var completedAt = initialStatus?.completedAt
        var lastStatus = initialStatus?.lastStatus ?? ""
        var pendingInputCalls = initialStatus?.pendingInputCallIDs ?? []
        var lastErrorAt = initialStatus?.lastErrorAt
        var latestActivityAt = initialStatus?.latestActivityAt
        var isFreshActivityFallback = initialStatus?.isFreshActivityFallback ?? false
        var failedFromError = initialStatus?.failedFromError ?? false
        var tokenUsage = initialStatus?.tokenUsage
        var rateLimits = initialStatus?.rateLimits

        tail.enumerateJSONLines { object in
            let eventTimestamp = JSONValueSupport.date(object["timestamp"]) ?? fileModificationDate
            guard let topLevelType = object["type"] as? String else { return }
            guard let payload = object["payload"] as? [String: Any] else { return }
            if topLevelType == "event_msg" || topLevelType == "response_item" {
                latestActivityAt = max(latestActivityAt ?? .distantPast, eventTimestamp)
            }

            switch topLevelType {
            case "event_msg":
                guard let eventType = payload["type"] as? String else { return }
                if eventType == "token_count" {
                    if let parsedTokenUsage = parseTokenUsage(from: payload) {
                        tokenUsage = parsedTokenUsage
                    }
                    rateLimits = parseRateLimits(
                        from: payload,
                        eventTimestamp: eventTimestamp,
                        current: rateLimits
                    )
                }
                switch eventType {
                case "user_message":
                    pendingInputCalls.removeAll()
                    state = .running
                    turnId = nil
                    startedAt = eventTimestamp
                    updatedAt = eventTimestamp
                    completedAt = nil
                    lastStatus = "running"
                    lastErrorAt = nil
                    isFreshActivityFallback = false
                    failedFromError = false

                case "task_started":
                    pendingInputCalls.removeAll()
                    state = .running
                    turnId = JSONValueSupport.string(payload["turn_id"])
                    startedAt = JSONValueSupport.date(payload["started_at"]) ?? eventTimestamp
                    updatedAt = eventTimestamp
                    completedAt = nil
                    lastStatus = "running"
                    lastErrorAt = nil
                    isFreshActivityFallback = false
                    failedFromError = false

                case "task_complete":
                    pendingInputCalls.removeAll()
                    state = .completed
                    turnId = JSONValueSupport.string(payload["turn_id"]) ?? turnId
                    completedAt = JSONValueSupport.date(payload["completed_at"]) ?? eventTimestamp
                    if let durationMilliseconds = JSONValueSupport.double(payload["duration_ms"]),
                       let completedAt
                    {
                        startedAt = completedAt.addingTimeInterval(-durationMilliseconds / 1_000)
                    }
                    updatedAt = completedAt ?? eventTimestamp
                    lastStatus = "completed"
                    lastErrorAt = nil
                    isFreshActivityFallback = false
                    failedFromError = false

                case "turn_aborted":
                    pendingInputCalls.removeAll()
                    let reason = (payload["reason"] as? String)?.lowercased()
                    state = reason == "interrupted" ? .interrupted : .failed
                    turnId = JSONValueSupport.string(payload["turn_id"]) ?? turnId
                    completedAt = JSONValueSupport.date(payload["completed_at"]) ?? eventTimestamp
                    if let durationMilliseconds = JSONValueSupport.double(payload["duration_ms"]),
                       let completedAt
                    {
                        startedAt = completedAt.addingTimeInterval(-durationMilliseconds / 1_000)
                    }
                    updatedAt = completedAt ?? eventTimestamp
                    lastStatus = state == .interrupted ? "interrupted" : "failed"
                    lastErrorAt = nil
                    isFreshActivityFallback = false
                    failedFromError = false

                case "task_failed", "turn_failed":
                    pendingInputCalls.removeAll()
                    state = .failed
                    turnId = JSONValueSupport.string(payload["turn_id"]) ?? turnId
                    completedAt = JSONValueSupport.date(payload["completed_at"]) ?? eventTimestamp
                    updatedAt = completedAt ?? eventTimestamp
                    lastStatus = "failed"
                    lastErrorAt = nil
                    isFreshActivityFallback = false
                    failedFromError = false

                case "error":
                    lastErrorAt = eventTimestamp

                default:
                    break
                }

            case "response_item":
                guard let responseType = payload["type"] as? String else { return }
                let callId = JSONValueSupport.string(payload["call_id"])

                if responseType == "function_call" || responseType == "custom_tool_call" {
                    guard
                        let name = JSONValueSupport.string(payload["name"]),
                        isRequestUserInput(name),
                        let callId
                    else {
                        return
                    }

                    pendingInputCalls.insert(callId)
                    state = .waitingForAnswer
                    updatedAt = eventTimestamp
                    completedAt = nil
                    lastStatus = "waitingForAnswer"
                    isFreshActivityFallback = false
                    failedFromError = false
                } else if responseType == "function_call_output"
                    || responseType == "custom_tool_call_output"
                {
                    guard let callId, pendingInputCalls.remove(callId) != nil else { return }
                    updatedAt = eventTimestamp
                    completedAt = nil
                    state = pendingInputCalls.isEmpty ? .running : .waitingForAnswer
                    lastStatus = pendingInputCalls.isEmpty ? "running" : "waitingForAnswer"
                    isFreshActivityFallback = false
                    failedFromError = false
                }

            default:
                break
            }
        }

        if state == nil,
           let latestActivityAt,
           now.timeIntervalSince(fileModificationDate) <= activeFileFreshness
        {
            state = .running
            updatedAt = latestActivityAt
            lastStatus = "running"
            isFreshActivityFallback = true
        }

        guard let state else { return nil }
        let status = TaskStatusRecord(
            threadId: threadId,
            turnId: turnId,
            state: state,
            startedAt: startedAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            lastStatus: lastStatus,
            pendingInputCallIDs: pendingInputCalls,
            lastErrorAt: lastErrorAt,
            latestActivityAt: latestActivityAt,
            isFreshActivityFallback: isFreshActivityFallback,
            failedFromError: failedFromError,
            tokenUsage: tokenUsage,
            rateLimits: rateLimits
        )
        return reevaluate(
            status,
            fileModificationDate: fileModificationDate,
            now: now
        )
    }

    func reevaluate(
        _ status: TaskStatusRecord?,
        fileModificationDate: Date,
        now: Date
    ) -> TaskStatusRecord? {
        guard let status else { return nil }
        if status.isFreshActivityFallback,
           now.timeIntervalSince(fileModificationDate) > activeFileFreshness
        {
            return nil
        }

        var state = status.state
        var updatedAt = status.updatedAt
        var completedAt = status.completedAt
        var lastStatus = status.lastStatus
        var failedFromError = status.failedFromError

        if failedFromError,
           let lastErrorAt = status.lastErrorAt,
           let latestActivityAt = status.latestActivityAt,
           latestActivityAt > lastErrorAt
        {
            state = .running
            updatedAt = latestActivityAt
            completedAt = nil
            lastStatus = "running"
            failedFromError = false
        }

        if let lastErrorAt = status.lastErrorAt,
           lastErrorAt >= (status.latestActivityAt ?? lastErrorAt),
           (!state.isTerminal || failedFromError),
           now.timeIntervalSince(fileModificationDate) >= failureQuietPeriod
        {
            state = .failed
            updatedAt = lastErrorAt
            completedAt = lastErrorAt
            lastStatus = "failed"
            failedFromError = true
        }

        return TaskStatusRecord(
            threadId: status.threadId,
            turnId: status.turnId,
            state: state,
            startedAt: status.startedAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            lastStatus: lastStatus,
            pendingInputCallIDs: status.pendingInputCallIDs,
            lastErrorAt: status.lastErrorAt,
            latestActivityAt: status.latestActivityAt,
            isFreshActivityFallback: status.isFreshActivityFallback,
            failedFromError: failedFromError,
            tokenUsage: status.tokenUsage,
            rateLimits: status.rateLimits
        )
    }

    private func parseTokenUsage(from payload: [String: Any]) -> TokenUsageSnapshot? {
        guard
            let info = payload["info"] as? [String: Any],
            let totalUsage = info["total_token_usage"] as? [String: Any],
            let totalTokens = nonnegativeInt(totalUsage["total_tokens"])
        else {
            return nil
        }

        return TokenUsageSnapshot(
            totalTokens: totalTokens,
            inputTokens: nonnegativeInt(totalUsage["input_tokens"]),
            cachedInputTokens: nonnegativeInt(totalUsage["cached_input_tokens"]),
            outputTokens: nonnegativeInt(totalUsage["output_tokens"]),
            reasoningOutputTokens: nonnegativeInt(totalUsage["reasoning_output_tokens"])
        )
    }

    private func parseRateLimits(
        from payload: [String: Any],
        eventTimestamp: Date,
        current: RateLimitSnapshot?
    ) -> RateLimitSnapshot? {
        guard let object = payload["rate_limits"] as? [String: Any] else {
            return current
        }
        if let current, eventTimestamp < current.updatedAt {
            return current
        }

        let incomingLimitID = JSONValueSupport.string(object["limit_id"])
        let identityChanged = incomingLimitID.map { $0 != current?.limitID } ?? false
        // Keep every rate-limit event atomic. Carrying a missing weekly window
        // from an earlier event can manufacture a reset generation Codex never
        // sent. A legacy 5h window remains optional compatibility data.
        var fiveHour: RateLimitWindowSnapshot?
        var weekly: RateLimitWindowSnapshot?

        for key in ["primary", "secondary"] {
            guard
                let windowObject = object[key] as? [String: Any],
                let window = parseRateLimitWindow(
                    from: windowObject,
                    observedAt: eventTimestamp
                )
            else {
                continue
            }

            switch window.windowMinutes {
            case RateLimitWindowDuration.legacyFiveHourMinutes:
                fiveHour = window
            case RateLimitWindowDuration.weeklyMinutes:
                weekly = window
            default:
                continue
            }
        }

        guard let weekly else { return current }
        let effectiveLimitID = incomingLimitID ?? current?.limitID
        let sameIdentity = current?.limitID?.lowercased() == effectiveLimitID?.lowercased()
        var conflictUntil = sameIdentity ? current?.conflictingResetHistoryUntil : nil
        if conflictUntil.map({ $0 <= eventTimestamp }) == true {
            conflictUntil = nil
        }
        if sameIdentity, let currentWeekly = current?.weekly {
            if currentWeekly.resetsAt > eventTimestamp,
               abs(currentWeekly.resetsAt.timeIntervalSince(weekly.resetsAt)) > 60
            {
                conflictUntil = max(
                    conflictUntil ?? .distantPast,
                    max(currentWeekly.resetsAt, weekly.resetsAt)
                )
            }
        }
        return RateLimitSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            updatedAt: eventTimestamp,
            planType: JSONValueSupport.string(object["plan_type"])
                ?? (identityChanged ? nil : current?.planType),
            limitID: effectiveLimitID,
            conflictingResetHistoryUntil: conflictUntil
        )
    }

    private func parseRateLimitWindow(
        from object: [String: Any],
        observedAt: Date
    ) -> RateLimitWindowSnapshot? {
        guard
            let usedPercent = JSONValueSupport.double(object["used_percent"]),
            usedPercent.isFinite,
            let windowMinutes = nonnegativeInt(object["window_minutes"]),
            let resetsAt = JSONValueSupport.date(object["resets_at"])
        else {
            return nil
        }

        return RateLimitWindowSnapshot(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            observedAt: observedAt
        )
    }

    private func nonnegativeInt(_ value: Any?) -> Int? {
        guard let value = JSONValueSupport.int(value), value >= 0 else { return nil }
        return value
    }

    private func readTail(from url: URL, fileSize: Int) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DataAdapterError.missingFile(url)
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        let offset = max(0, fileSize - maximumTailBytes)
        try file.seek(toOffset: UInt64(offset))
        let data = try file.readToEnd() ?? Data()

        guard offset > 0, let firstNewline = data.firstIndex(of: 0x0A) else {
            return data
        }
        let firstCompleteLine = data.index(after: firstNewline)
        return Data(data[firstCompleteLine...])
    }

    private func isRequestUserInput(_ name: String) -> Bool {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return normalized == "request_user_input"
            || normalized.hasSuffix(".request_user_input")
            || normalized.hasSuffix("__request_user_input")
    }
}
