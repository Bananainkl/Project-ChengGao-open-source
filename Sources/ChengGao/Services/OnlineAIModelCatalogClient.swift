import Foundation

enum OnlineAIModelCatalogError: LocalizedError, Sendable {
    case invalidEndpoint
    case missingAPIKey
    case requestFailed(status: Int, message: String)
    case invalidResponse
    case emptyCatalog

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "无法从 Chat Completions 地址推导模型列表地址。"
        case .missingAPIKey:
            "请先输入或保存 API Key，再读取远程模型。"
        case .requestFailed(let status, let message):
            "读取模型失败（HTTP \(status)）：\(message)"
        case .invalidResponse:
            "远程接口返回的模型列表格式无法识别。"
        case .emptyCatalog:
            "连接成功，但远程接口没有返回可用模型。"
        }
    }
}

struct OnlineAIModelCatalogClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchModels(configuration: OnlineAIConfiguration, apiKey: String) async throws -> [String] {
        try await fetchModels(endpoint: configuration.endpoint, apiKey: apiKey)
    }

    func fetchModels(endpoint sourceEndpoint: String, apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OnlineAIModelCatalogError.missingAPIKey }
        guard let endpoint = Self.modelsEndpoint(from: sourceEndpoint) else {
            throw OnlineAIModelCatalogError.invalidEndpoint
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OnlineAIModelCatalogError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw OnlineAIModelCatalogError.requestFailed(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
        let models = try Self.parseModels(data)
        guard !models.isEmpty else { throw OnlineAIModelCatalogError.emptyCatalog }
        return models
    }

    static func modelsEndpoint(from sourceEndpoint: String) -> URL? {
        let trimmed = sourceEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil else { return nil }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let knownSuffixes = [
            "/chat/completions", "/images/generations", "/responses"
        ]
        let removedKnownSuffix: Bool
        if let suffix = knownSuffixes.first(where: { path.lowercased().hasSuffix($0) }) {
            path.removeLast(suffix.count)
            removedKnownSuffix = true
        } else {
            removedKnownSuffix = false
        }
        if path.isEmpty || path == "/" {
            path = "/v1"
        } else if !removedKnownSuffix, !path.lowercased().hasSuffix("/v1") {
            path += "/v1"
        }
        components.path = path + "/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func parseModels(_ data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data)
        let rawItems: [Any]
        if let dictionary = object as? [String: Any] {
            rawItems = (dictionary["data"] as? [Any])
                ?? (dictionary["models"] as? [Any])
                ?? []
        } else if let array = object as? [Any] {
            rawItems = array
        } else {
            throw OnlineAIModelCatalogError.invalidResponse
        }

        let values = rawItems.compactMap { item -> String? in
            if let value = item as? String { return value.nonEmptyCatalogValue }
            guard let dictionary = item as? [String: Any] else { return nil }
            return (dictionary["id"] as? String)?.nonEmptyCatalogValue
                ?? (dictionary["model"] as? String)?.nonEmptyCatalogValue
                ?? (dictionary["name"] as? String)?.nonEmptyCatalogValue
        }
        return Array(Set(values)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "服务暂时不可用"
        }
        let message = (root["error"] as? [String: Any])?["message"] as? String
            ?? root["message"] as? String
            ?? "服务暂时不可用"
        return String(message.prefix(240))
    }
}

private extension String {
    var nonEmptyCatalogValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
