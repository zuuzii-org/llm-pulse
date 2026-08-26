import Foundation

struct AIRuntimeID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let codexDesktop = AIRuntimeID(rawValue: "codex-desktop")
    static let claudeDesktop = AIRuntimeID(rawValue: "claude-desktop")
    static let zcodeDesktop = AIRuntimeID(rawValue: "zcode-desktop")
}

struct AIProviderID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let openAI = AIProviderID(rawValue: "openai")
    static let anthropic = AIProviderID(rawValue: "anthropic")
    static let bigModel = AIProviderID(rawValue: "bigmodel")
}

struct ModelPlanKind: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

struct ModelProfileID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(
        runtime: AIRuntimeID,
        provider: AIProviderID,
        planKind: ModelPlanKind?,
        modelID: String
    ) {
        let sourceComponent = planKind?.rawValue ?? provider.rawValue
        let normalizedModelID = Self.normalized(modelID)
        rawValue = [runtime.rawValue, sourceComponent, normalizedModelID]
            .joined(separator: ":")
    }

    static let codex = ModelProfileID(
        runtime: .codexDesktop,
        provider: .openAI,
        planKind: nil,
        modelID: "codex"
    )

    static let claudeCode = ModelProfileID(
        runtime: .claudeDesktop,
        provider: .anthropic,
        planKind: nil,
        modelID: "claude-code"
    )

    static let glm = ModelProfileID(
        runtime: .zcodeDesktop,
        provider: .bigModel,
        planKind: nil,
        modelID: "glm"
    )

    func isConsistent(
        runtime: AIRuntimeID,
        provider: AIProviderID,
        modelID: String
    ) -> Bool {
        let normalizedModelID = Self.normalized(modelID)
        guard ModelIdentity.isSafeIdentifier(runtime.rawValue),
              ModelIdentity.isSafeIdentifier(provider.rawValue),
              ModelIdentity.isSafeIdentifier(normalizedModelID) else {
            return false
        }
        if runtime == .codexDesktop {
            return provider == .openAI
                && normalizedModelID == "codex"
                && self == .codex
        }
        if runtime == .claudeDesktop {
            return provider == .anthropic
                && normalizedModelID == "claude-code"
                && self == .claudeCode
        }
        if runtime == .zcodeDesktop {
            return provider == .bigModel
                && normalizedModelID == "glm"
                && self == .glm
        }
        let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        return components[0] == Substring(runtime.rawValue)
            && components[2] == Substring(normalizedModelID)
            && ModelIdentity.isSafeIdentifier(String(components[1]))
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ModelIdentity: Equatable, Codable, Sendable {
    let profileID: ModelProfileID
    let runtime: AIRuntimeID
    let provider: AIProviderID
    let modelID: String
    let displayName: String
    let planKind: ModelPlanKind?

    init?(
        runtime: AIRuntimeID,
        provider: AIProviderID,
        modelID: String,
        displayName: String,
        planKind: ModelPlanKind? = nil
    ) {
        let normalizedModelID = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedDisplayName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeIdentifier(runtime.rawValue),
              Self.isSafeIdentifier(provider.rawValue),
              Self.isSafeIdentifier(normalizedModelID),
              planKind.map({ Self.isSafeIdentifier($0.rawValue) }) ?? true,
              !normalizedDisplayName.isEmpty,
              normalizedDisplayName.utf8.count <= 128 else {
            return nil
        }

        if runtime == .codexDesktop {
            guard provider == .openAI,
                  normalizedModelID == "codex",
                  planKind == nil else {
                return nil
            }
        }
        if runtime == .claudeDesktop {
            // Claude Code exposes one profile. The model actually answering a
            // turn varies within a single session, so it is not an identity.
            guard provider == .anthropic,
                  normalizedModelID == "claude-code",
                  planKind == nil else {
                return nil
            }
        }
        if runtime == .zcodeDesktop {
            // ZCode can switch between concrete GLM versions inside one
            // session. Keep one stable profile so task IDs and receipts do not
            // change when the selected GLM release changes.
            guard provider == .bigModel,
                  normalizedModelID == "glm",
                  planKind == nil else {
                return nil
            }
        }

        self.runtime = runtime
        self.provider = provider
        self.modelID = normalizedModelID
        self.displayName = normalizedDisplayName
        self.planKind = planKind
        profileID = ModelProfileID(
            runtime: runtime,
            provider: provider,
            planKind: planKind,
            modelID: normalizedModelID
        )
    }

    static let codex = ModelIdentity(
        runtime: .codexDesktop,
        provider: .openAI,
        modelID: "codex",
        displayName: "Codex"
    )!

    static let claudeCode = ModelIdentity(
        runtime: .claudeDesktop,
        provider: .anthropic,
        modelID: "claude-code",
        displayName: "Claude Code"
    )!

    static let glm = ModelIdentity(
        runtime: .zcodeDesktop,
        provider: .bigModel,
        modelID: "glm",
        displayName: "GLM"
    )!

    static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 46, 48...57, 95, 97...122:
                    return true
                default:
                    return false
                }
            }
    }

    private enum CodingKeys: String, CodingKey {
        case profileID
        case runtime
        case provider
        case modelID
        case displayName
        case planKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runtime = try container.decode(AIRuntimeID.self, forKey: .runtime)
        let provider = try container.decode(AIProviderID.self, forKey: .provider)
        let modelID = try container.decode(String.self, forKey: .modelID)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let planKind = try container.decodeIfPresent(ModelPlanKind.self, forKey: .planKind)
        guard let decoded = ModelIdentity(
            runtime: runtime,
            provider: provider,
            modelID: modelID,
            displayName: displayName,
            planKind: planKind
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .modelID,
                in: container,
                debugDescription: "Invalid runtime, provider, plan, or model identity"
            )
        }
        self = decoded

        if let encodedProfileID = try container.decodeIfPresent(
            ModelProfileID.self,
            forKey: .profileID
        ), encodedProfileID != profileID {
            throw DecodingError.dataCorruptedError(
                forKey: .profileID,
                in: container,
                debugDescription: "Model profile does not match its identity fields"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(provider, forKey: .provider)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(planKind, forKey: .planKind)
    }
}
