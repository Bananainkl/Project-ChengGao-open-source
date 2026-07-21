import Foundation

enum OnlineAIReasoningEffort: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case low
    case medium
    case high

    var id: Self { self }

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .low: "快速"
        case .medium: "标准"
        case .high: "深入"
        }
    }

    var apiValue: String? {
        switch self {
        case .automatic: nil
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }

    var promptInstruction: String {
        switch self {
        case .automatic: ""
        case .low: "优先快速完成，但仍要核对关键事实和输出结构。"
        case .medium: "进行标准深度的分析，先梳理事实与结构，再输出完整结果。"
        case .high: "进行深入分析，充分检查事实覆盖、逻辑关系、文体要求和潜在遗漏后再输出。"
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "onlineAI.reasoningEffort") ?? "") ?? .automatic
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "onlineAI.reasoningEffort")
    }
}

enum OnlineImageGenerationSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case square
    case portrait
    case landscape

    var id: Self { self }

    var displayName: String {
        switch self {
        case .automatic: "跟随内容比例"
        case .square: "1:1 方图"
        case .portrait: "竖图"
        case .landscape: "横图"
        }
    }

    func apiValue(for style: RewriteStyle) -> String {
        switch self {
        case .square: "1024x1024"
        case .portrait: "1024x1536"
        case .landscape: "1536x1024"
        case .automatic:
            style == .article ? "1536x1024" : "1024x1536"
        }
    }
}

enum OnlineImageGenerationQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case low
    case medium
    case high

    var id: Self { self }

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .low: "低"
        case .medium: "标准"
        case .high: "高"
        }
    }

    var apiValue: String? { self == .automatic ? nil : rawValue }
}

enum OnlineAIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case deepSeek
    case glm
    case miniMax
    case custom

    var id: Self { self }

    var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .glm: "智谱 GLM"
        case .miniMax: "MiniMax"
        case .custom: "自定义兼容接口"
        }
    }

    var systemImage: String {
        switch self {
        case .deepSeek: "wave.3.right"
        case .glm: "brain"
        case .miniMax: "sparkles.rectangle.stack"
        case .custom: "slider.horizontal.3"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com/chat/completions"
        case .glm: "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .miniMax: "https://api.minimaxi.com/v1/chat/completions"
        case .custom: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepSeek: "deepseek-v4-flash"
        case .glm: "glm-5.2"
        case .miniMax: "MiniMax-M2.7"
        case .custom: ""
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .deepSeek: "DeepSeek API Key"
        case .glm: "智谱 API Key"
        case .miniMax: "MiniMax API Key"
        case .custom: "Bearer API Key"
        }
    }

    func acceptsAPIKey(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return false }
        switch self {
        case .deepSeek:
            return key.hasPrefix("sk-") && key.count >= 20
        case .glm, .miniMax, .custom:
            return key.count >= 16
        }
    }

    var documentationURL: URL? {
        switch self {
        case .deepSeek: URL(string: "https://api-docs.deepseek.com/")
        case .glm: URL(string: "https://docs.bigmodel.cn/cn/guide/develop/http/introduction")
        case .miniMax: URL(string: "https://platform.minimaxi.com/docs/api-reference/api-overview")
        case .custom: nil
        }
    }
}

struct OnlineAIConfiguration: Equatable, Sendable {
    let provider: OnlineAIProvider
    let endpoint: String
    let model: String

    var endpointURL: URL? {
        Self.chatCompletionsURL(from: endpoint)
    }

    var isValid: Bool {
        endpointURL != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func load(defaults: UserDefaults = .standard) -> OnlineAIConfiguration {
        let provider = OnlineAIProvider(
            rawValue: defaults.string(forKey: "onlineAI.provider") ?? ""
        ) ?? .custom
        return load(provider: provider, defaults: defaults)
    }

    static func load(provider: OnlineAIProvider, defaults: UserDefaults = .standard) -> OnlineAIConfiguration {
        let prefix = "onlineAI.\(provider.rawValue)"
        let endpoint = defaults.string(forKey: "\(prefix).endpoint")?.nonEmptyValue
            ?? provider.defaultEndpoint
        let model = defaults.string(forKey: "\(prefix).model")?.nonEmptyValue
            ?? provider.defaultModel
        return OnlineAIConfiguration(provider: provider, endpoint: endpoint, model: model)
    }

    func save(defaults: UserDefaults = .standard) {
        let prefix = "onlineAI.\(provider.rawValue)"
        defaults.set(provider.rawValue, forKey: "onlineAI.provider")
        defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "\(prefix).endpoint")
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "\(prefix).model")
    }

    /// Accept either an OpenAI-compatible server base URL or a complete
    /// Chat Completions URL. Most relay services publish the API under `/v1`,
    /// while their bare host serves only the account dashboard.
    static func chatCompletionsURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil else { return nil }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let lowercasedPath = path.lowercased()
        if lowercasedPath.hasSuffix("/chat/completions") {
            // Already a complete compatible endpoint.
        } else if lowercasedPath.hasSuffix("/v1") {
            path += "/chat/completions"
        } else if path.isEmpty || path == "/" {
            path = "/v1/chat/completions"
        } else {
            path += "/v1/chat/completions"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct OnlineImageGenerationConfiguration: Equatable, Sendable {
    let provider: OnlineAIProvider
    let endpoint: String
    let model: String
    let size: OnlineImageGenerationSize
    let quality: OnlineImageGenerationQuality

    func endpointURL(fallbackChatEndpoint: String) -> URL? {
        Self.imagesGenerationsURL(from: endpoint, fallbackChatEndpoint: fallbackChatEndpoint)
    }

    func isValid(fallbackChatEndpoint: String) -> Bool {
        endpointURL(fallbackChatEndpoint: fallbackChatEndpoint) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func load(
        provider: OnlineAIProvider,
        defaults: UserDefaults = .standard
    ) -> OnlineImageGenerationConfiguration {
        let prefix = "onlineAI.\(provider.rawValue).imageGeneration"
        return OnlineImageGenerationConfiguration(
            provider: provider,
            endpoint: defaults.string(forKey: "\(prefix).endpoint") ?? "",
            model: defaults.string(forKey: "\(prefix).model") ?? "",
            size: OnlineImageGenerationSize(
                rawValue: defaults.string(forKey: "\(prefix).size") ?? ""
            ) ?? .automatic,
            quality: OnlineImageGenerationQuality(
                rawValue: defaults.string(forKey: "\(prefix).quality") ?? ""
            ) ?? .automatic
        )
    }

    func save(defaults: UserDefaults = .standard) {
        let prefix = "onlineAI.\(provider.rawValue).imageGeneration"
        defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "\(prefix).endpoint")
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "\(prefix).model")
        defaults.set(size.rawValue, forKey: "\(prefix).size")
        defaults.set(quality.rawValue, forKey: "\(prefix).quality")
    }

    static func removeSavedEndpoint(
        provider: OnlineAIProvider,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: "onlineAI.\(provider.rawValue).imageGeneration.endpoint")
    }

    /// Detect common credential shapes without treating a malformed host name
    /// as a secret. This is used to keep accidentally pasted keys out of the
    /// plain-text endpoint field and UserDefaults.
    static func looksLikeCredential(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              OnlineAIConfiguration.chatCompletionsURL(from: candidate) == nil else { return false }
        let lowered = candidate.lowercased()
        let knownPrefixes = ["sk-", "sk_", "key-", "api-key-", "bearer-"]
        if knownPrefixes.contains(where: lowered.hasPrefix) { return candidate.count >= 16 }
        guard candidate.count >= 24,
              !candidate.contains(where: \.isWhitespace),
              !candidate.contains("/"),
              !candidate.contains("."),
              !candidate.contains(":") else { return false }
        return candidate.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_=")).contains($0)
        }
    }

    /// Accept a relay base URL, a Chat Completions URL, or a complete Images
    /// API URL. Leaving the dedicated image endpoint blank reuses the current
    /// chat host and replaces `/chat/completions` with `/images/generations`.
    static func imagesGenerationsURL(
        from value: String,
        fallbackChatEndpoint: String
    ) -> URL? {
        let dedicated = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = dedicated.isEmpty
            ? fallbackChatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            : dedicated
        guard var components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil else { return nil }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let lowercasedPath = path.lowercased()
        if lowercasedPath.hasSuffix("/images/generations") {
            // Already a complete compatible endpoint.
        } else if lowercasedPath.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
            path += "/images/generations"
        } else if lowercasedPath.hasSuffix("/responses") {
            path.removeLast("/responses".count)
            path += "/images/generations"
        } else if lowercasedPath.hasSuffix("/v1") {
            path += "/images/generations"
        } else if path.isEmpty || path == "/" {
            path = "/v1/images/generations"
        } else {
            path += "/v1/images/generations"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

private extension String {
    var nonEmptyValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
