import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageGenerationError: LocalizedError, Sendable {
    case invalidConfiguration
    case missingAPIKey
    case requestFailed(status: Int, message: String)
    case invalidResponse
    case invalidImageData
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "请先在 AI 设置中填写图片生成模型，并确认图片 API 地址。"
        case .missingAPIKey:
            "当前在线 AI 提供商还没有可复用的 API Key。"
        case .requestFailed(let status, let message):
            "图片生成请求失败（HTTP \(status)）：\(message)"
        case .invalidResponse:
            "图片接口没有返回可识别的 image_url、url 或 b64_json。"
        case .invalidImageData:
            "图片接口返回的内容不是有效图片。"
        case .imageTooLarge:
            "图片接口返回的文件超过 50 MB，已停止保存。"
        }
    }
}

struct GeneratedImagePayload: Sendable, Equatable {
    let data: Data
    let fileExtension: String
    let remoteURL: URL?
    let revisedPrompt: String?
}

protocol ImageGenerating: Sendable {
    func generate(
        prompt: String,
        style: RewriteStyle,
        configuration: OnlineImageGenerationConfiguration,
        fallbackChatEndpoint: String,
        apiKey: String
    ) async throws -> GeneratedImagePayload
}

struct CompatibleImageGenerationClient: ImageGenerating, Sendable {
    private enum ImageReference: Equatable {
        case remoteURL(URL)
        case inlineData(Data)
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generate(
        prompt: String,
        style: RewriteStyle,
        configuration: OnlineImageGenerationConfiguration,
        fallbackChatEndpoint: String,
        apiKey: String
    ) async throws -> GeneratedImagePayload {
        try Task.checkCancellation()
        guard let endpoint = configuration.endpointURL(fallbackChatEndpoint: fallbackChatEndpoint),
              configuration.isValid(fallbackChatEndpoint: fallbackChatEndpoint) else {
            throw ImageGenerationError.invalidConfiguration
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ImageGenerationError.missingAPIKey }

        var body: [String: Any] = [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "prompt": prompt,
            "n": 1,
            "size": configuration.size.apiValue(for: style),
            // Many relay services expose a signed URL as image_url/url. GPT
            // Image implementations that reject this field are retried below.
            "response_format": "url"
        ]
        if let quality = configuration.quality.apiValue {
            body["quality"] = quality
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var (data, response) = try await session.data(for: request)
        guard var http = response as? HTTPURLResponse else {
            throw ImageGenerationError.invalidResponse
        }
        if Self.shouldRetryWithoutResponseFormat(status: http.statusCode, data: data) {
            body.removeValue(forKey: "response_format")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            (data, response) = try await session.data(for: request)
            guard let retriedHTTP = response as? HTTPURLResponse else {
                throw ImageGenerationError.invalidResponse
            }
            http = retriedHTTP
        }
        guard 200..<300 ~= http.statusCode else {
            throw ImageGenerationError.requestFailed(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        let parsed = try Self.parseResponse(data)
        let imageData: Data
        let remoteURL: URL?
        switch parsed.reference {
        case .inlineData(let data):
            imageData = data
            remoteURL = nil
        case .remoteURL(let url):
            // Signed image URLs normally carry their own authorization. Do not
            // forward the user's API key to a possibly different storage host.
            var downloadRequest = URLRequest(url: url)
            downloadRequest.timeoutInterval = 300
            let (downloaded, downloadResponse) = try await session.data(for: downloadRequest)
            if let downloadHTTP = downloadResponse as? HTTPURLResponse,
               !(200..<300).contains(downloadHTTP.statusCode) {
                throw ImageGenerationError.requestFailed(
                    status: downloadHTTP.statusCode,
                    message: "生成成功，但下载 image_url 失败"
                )
            }
            imageData = downloaded
            remoteURL = url
        }

        guard imageData.count <= 50 * 1_024 * 1_024 else {
            throw ImageGenerationError.imageTooLarge
        }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageGenerationError.invalidImageData
        }
        let fileExtension = CGImageSourceGetType(source)
            .flatMap { UTType($0 as String) }
            .flatMap(\.preferredFilenameExtension)
            ?? "png"
        return GeneratedImagePayload(
            data: imageData,
            fileExtension: fileExtension,
            remoteURL: remoteURL,
            revisedPrompt: parsed.revisedPrompt
        )
    }

    static func shouldRetryWithoutResponseFormat(status: Int, data: Data) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let message = errorMessage(from: data).lowercased()
        return message.contains("response_format")
            && (message.contains("unsupported")
                || message.contains("unknown")
                || message.contains("invalid")
                || message.contains("not allowed"))
    }

    static func requestBody(
        prompt: String,
        style: RewriteStyle,
        configuration: OnlineImageGenerationConfiguration
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "prompt": prompt,
            "n": 1,
            "size": configuration.size.apiValue(for: style),
            "response_format": "url"
        ]
        if let quality = configuration.quality.apiValue {
            body["quality"] = quality
        }
        return body
    }

    private static func parseResponse(_ data: Data) throws -> (reference: ImageReference, revisedPrompt: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let reference = imageReference(in: object) else {
            throw ImageGenerationError.invalidResponse
        }
        return (reference, revisedPrompt(in: object))
    }

    private static func imageReference(in object: Any) -> ImageReference? {
        if let dictionary = object as? [String: Any] {
            for key in ["b64_json", "base64", "image_base64"] {
                if let value = dictionary[key] as? String,
                   let data = decodeBase64Image(value) {
                    return .inlineData(data)
                }
            }
            for key in ["image_url", "url"] {
                if let value = dictionary[key] as? String,
                   let reference = reference(from: value) {
                    return reference
                }
                if let nested = dictionary[key] as? [String: Any],
                   let value = nested["url"] as? String,
                   let reference = reference(from: value) {
                    return reference
                }
            }
            for key in ["data", "images", "output", "result"] {
                if let nested = dictionary[key], let reference = imageReference(in: nested) {
                    return reference
                }
            }
        } else if let array = object as? [Any] {
            for element in array {
                if let reference = imageReference(in: element) { return reference }
            }
        }
        return nil
    }

    private static func reference(from value: String) -> ImageReference? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = decodeBase64Image(trimmed) { return .inlineData(data) }
        guard let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return .remoteURL(url)
    }

    private static func decodeBase64Image(_ value: String) -> Data? {
        let payload: String
        if value.lowercased().hasPrefix("data:image/"), let comma = value.firstIndex(of: ",") {
            payload = String(value[value.index(after: comma)...])
        } else if value.count >= 64, !value.contains("://") {
            payload = value
        } else {
            return nil
        }
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }

    private static func revisedPrompt(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary["revised_prompt"] as? String, !value.isEmpty { return value }
            for key in ["data", "images", "output", "result"] {
                if let nested = dictionary[key], let value = revisedPrompt(in: nested) { return value }
            }
        } else if let array = object as? [Any] {
            for element in array {
                if let value = revisedPrompt(in: element) { return value }
            }
        }
        return nil
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = json["message"] as? String { return message }
        }
        let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? String(fallback!.prefix(500)) : "未知错误"
    }
}
