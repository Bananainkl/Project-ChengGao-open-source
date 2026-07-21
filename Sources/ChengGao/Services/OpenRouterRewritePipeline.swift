import Foundation

enum OpenRouterError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidConfiguration
    case invalidResponse
    case requestFailed(status: Int, message: String)
    case emptyCompletion
    case invalidDraft
    case draftQualityRejected([String])

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "尚未在设置中保存当前在线 AI 提供商的 API Key。"
        case .invalidConfiguration: "在线 AI 的接口地址或模型名称不完整。"
        case .invalidResponse: "在线 AI 返回了无法识别的响应。"
        case .requestFailed(let status, let message): "在线 AI 请求失败（HTTP \(status)）：\(message)"
        case .emptyCompletion: "在线模型没有返回正文。"
        case .invalidDraft: "在线模型没有返回完整、可用的改写稿。"
        case .draftQualityRejected(let issues):
            "在线改写稿未通过质量检查：\(issues.joined(separator: "；"))"
        }
    }
}

struct OpenRouterCompletion: Sendable, Equatable {
    let model: String
    let content: String
}

struct OpenRouterParsedDraft: Sendable {
    let title: String?
    let corrected: String
    let corrections: [TranscriptCorrection]
    let suggestions: [RevisionSuggestion]
    let revised: String
}

struct OpenRouterAPIClient: Sendable {
    let session: URLSession
    let configurationProvider: @Sendable () -> OnlineAIConfiguration
    let apiKeyProvider: @Sendable () -> String?
    let reasoningEffortProvider: @Sendable () -> OnlineAIReasoningEffort

    init(
        session: URLSession = .shared,
        configurationProvider: @escaping @Sendable () -> OnlineAIConfiguration = {
            OnlineAIConfiguration.load()
        },
        apiKeyProvider: @escaping @Sendable () -> String? = {
            let configuration = OnlineAIConfiguration.load()
            return OnlineAICredentialStore.load(for: configuration.provider)
        },
        reasoningEffortProvider: @escaping @Sendable () -> OnlineAIReasoningEffort = {
            OnlineAIReasoningEffort.load()
        }
    ) {
        self.session = session
        self.configurationProvider = configurationProvider
        self.apiKeyProvider = apiKeyProvider
        self.reasoningEffortProvider = reasoningEffortProvider
    }

    func complete(
        prompt: String,
        systemInstruction: String? = nil
    ) async throws -> OpenRouterCompletion {
        try await complete(
            prompt: prompt,
            maximumTokens: 8_000,
            structuredOutput: true,
            systemInstruction: systemInstruction
        )
    }

    func testConnection() async throws -> OpenRouterCompletion {
        try await complete(
            prompt: "连接测试：请只回复 OK。",
            maximumTokens: 16,
            structuredOutput: false,
            systemInstruction: nil
        )
    }

    func completeWithImages(prompt: String, jpegImages: [Data]) async throws -> OpenRouterCompletion {
        try Task.checkCancellation()
        let configuration = configurationProvider()
        guard let endpoint = configuration.endpointURL, configuration.isValid else {
            throw OpenRouterError.invalidConfiguration
        }
        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { throw OpenRouterError.missingAPIKey }
        var userContent: [[String: Any]] = [["type": "text", "text": prompt]]
        for image in jpegImages.prefix(9) {
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())", "detail": "low"]
            ])
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": "你是资深中文图文编辑和视觉导演。只依据输入图片与文字分析，不得臆测不可见信息；只返回有效 JSON。"],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.35,
            "max_tokens": 4_000
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw OpenRouterError.requestFailed(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return try Self.parseCompletion(data)
    }

    func resolvedConfiguration() -> OnlineAIConfiguration {
        configurationProvider()
    }

    func resolvedReasoningEffort() -> OnlineAIReasoningEffort {
        reasoningEffortProvider()
    }

    private func complete(
        prompt: String,
        maximumTokens: Int,
        structuredOutput: Bool,
        systemInstruction: String?
    ) async throws -> OpenRouterCompletion {
        try Task.checkCancellation()
        let configuration = configurationProvider()
        guard let endpoint = configuration.endpointURL, configuration.isValid else {
            throw OpenRouterError.invalidConfiguration
        }
        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { throw OpenRouterError.missingAPIKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Full-document cross-format rewrites can legitimately take longer
        // than a short chat completion, especially through compatible relay
        // endpoints. Cancellation remains immediate through URLSession's async
        // task, while this limit prevents valid long-form work being cut off.
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let reasoningEffort = reasoningEffortProvider()
        var body = Self.requestBody(
            prompt: prompt,
            model: configuration.model,
            maximumTokens: maximumTokens,
            structuredOutput: false,
            reasoningEffort: reasoningEffort,
            systemInstruction: systemInstruction
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard var http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        if reasoningEffort.apiValue != nil,
           Self.shouldRetryWithoutReasoning(status: http.statusCode, data: data) {
            body.removeValue(forKey: "reasoning_effort")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let retryHTTP = response as? HTTPURLResponse else {
                throw OpenRouterError.invalidResponse
            }
            http = retryHTTP
        }
        guard 200..<300 ~= http.statusCode else {
            throw OpenRouterError.requestFailed(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
        return try Self.parseCompletion(data)
    }

    static func requestBody(
        prompt: String,
        model: String,
        maximumTokens: Int,
        structuredOutput: Bool,
        reasoningEffort: OnlineAIReasoningEffort = .automatic,
        systemInstruction: String? = nil
    ) -> [String: Any] {
        let reasoningInstruction = reasoningEffort.promptInstruction
        var body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "\(systemInstruction ?? "你是资深中文总编辑。严格保留事实，完成实质改写，只返回有效 JSON。")\(reasoningInstruction.isEmpty ? "" : " \(reasoningInstruction)")"
                ],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.55,
            "max_tokens": maximumTokens
        ]
        if structuredOutput { body["response_format"] = ["type": "json_object"] }
        if let apiValue = reasoningEffort.apiValue {
            body["reasoning_effort"] = apiValue
        }
        return body
    }

    static func shouldRetryWithoutReasoning(status: Int, data: Data) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let message = errorMessage(from: data).lowercased()
        return message.contains("reasoning_effort")
            || (message.contains("reasoning") && (
                message.contains("unsupported")
                    || message.contains("unknown")
                    || message.contains("invalid parameter")
                    || message.contains("不支持")
                    || message.contains("未知")
            ))
    }

    static func parseCompletion(_ data: Data) throws -> OpenRouterCompletion {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterError.emptyCompletion
        }
        return OpenRouterCompletion(
            model: (root["model"] as? String) ?? "未返回模型名称",
            content: content
        )
    }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "服务暂时不可用"
        }
        let message = (root["error"] as? [String: Any])?["message"] as? String
            ?? (root["base_resp"] as? [String: Any])?["status_msg"] as? String
            ?? root["message"] as? String
            ?? "服务暂时不可用"
        return String(message.prefix(240))
    }
}

actor OpenRouterRewritePipeline: RewriteProcessing {
    private let client: OpenRouterAPIClient

    nonisolated static let rewriteOnlyRule = "最高优先级强制要求：本任务只做改写，不做缩写或摘要。改写时必须保证原稿的结构层次、内容、观点、论证关系和重要细节全部完整；可以重组结构与表达，但不得删减信息层次。成稿字数必须与原稿接近，并同时满足下方最低字数要求。若其他文体、节奏或精简要求与本条冲突，以本条为准。"

    nonisolated static var rewriteSystemInstruction: String {
        "你是资深中文总编辑。\(rewriteOnlyRule)严格保留事实，完成实质改写，只返回有效 JSON。"
    }

    init(client: OpenRouterAPIClient = OpenRouterAPIClient()) {
        self.client = client
    }

    func rewrite(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage,
        modelMode: ModelMode,
        onlineCorrection: Bool,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> RewriteOutput {
        let configuration = client.resolvedConfiguration()
        let reasoningEffort = client.resolvedReasoningEffort()
        progress(RewriteProgress(completed: 0, total: 2, message: "正在通过 \(configuration.provider.displayName) · \(reasoningEffort.displayName)推理通读全文并改写…"))
        var completion = try await client.complete(
            prompt: Self.prompt(material: material, style: style, language: language),
            systemInstruction: Self.rewriteSystemInstruction
        )
        var draft = try Self.parseDraft(
            completion.content,
            material: material,
            style: style,
            language: language
        )
        var issues = EmbeddedModelRuntime.documentQualityIssues(
            original: material.transcript,
            revised: draft.revised,
            sourceOrigin: material.origin,
            style: style
        )
        if !issues.isEmpty {
            progress(RewriteProgress(completed: 1, total: 2, message: "在线初稿未通过质量检查，正在重新统稿…"))
            completion = try await client.complete(
                prompt: Self.retryPrompt(
                    material: material,
                    style: style,
                    language: language,
                    firstDraft: draft.revised,
                    issues: issues
                ),
                systemInstruction: Self.rewriteSystemInstruction
            )
            draft = try Self.parseDraft(
                completion.content,
                material: material,
                style: style,
                language: language
            )
            issues = EmbeddedModelRuntime.documentQualityIssues(
                original: material.transcript,
                revised: draft.revised,
                sourceOrigin: material.origin,
                style: style
            )
        }
        guard issues.isEmpty else { throw OpenRouterError.draftQualityRejected(issues) }
        progress(RewriteProgress(completed: 2, total: 2, message: "在线全文审稿完成"))
        return RewriteOutput(
            title: language.normalize(draft.title ?? EmbeddedModelRuntime.outputTitle(for: material, revisedBody: draft.revised)),
            rawTranscript: material.transcript,
            originalTranscript: draft.corrected,
            corrections: draft.corrections,
            suggestions: draft.suggestions,
            revisedBody: draft.revised,
            notes: language.normalize("原稿来源：\(material.origin.label)。使用 \(configuration.provider.displayName) 完成在线全文改写与质量复检；实际模型：\(completion.model)；推理深度：\(reasoningEffort.displayName)。完整标题与正文已发送给该在线服务。全文相似度 \(Int((EmbeddedModelRuntime.rewriteSimilarity(original: draft.corrected, revised: draft.revised) * 100).rounded()))%。输出语言：\(language.rawValue)。"),
            transcriptOrigin: material.origin,
            style: style,
            durationSeconds: material.durationSeconds
        )
    }

    nonisolated static func prompt(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage
    ) -> String {
        let sourceEvidence = sourceEvidence(for: material)
        return """
        请把下面的完整原稿改写为可直接发布的“\(style.rawValue)”。这是全文任务，不要逐段机械复述。

        \(rewriteOnlyRule)

        要求：
        1. \(language.promptInstruction)
        2. 先通读全文，确定核心判断、受众、开头钩子和叙事顺序，再在内部完成编辑；不要输出分析过程。
        3. revised 必须重做开头、信息顺序、句式、段落层次和口播节奏，不能只做繁简转换、标点、断句或少量同义词替换；与原稿的表达应有肉眼可见的区别。
        4. 保留全部重要事实、人物、出处、日期、数字、因果关系、争议双方和限定条件；不编造，不把不同立场合并成单一结论。
        5. 不要在响应里重复输出完整原稿。只在 corrections 中列出高置信度的语音识别错误或错别字；无法确定的词不要修改。revised 负责翻译并改写为目标语言。
        6. 跨语言改写必须忠实区分官员、专家、批评者、支持者、媒体和消息人士等不同身份；不得为了中文顺口而替换信源身份或强化原稿语气。
        7. 删除关注引导、广告、版权尾注和与主题无关的页面噪声。正文中的品牌案例和论证材料不能误删。
        8. suggestions 给出 2–6 条针对具体原句和成稿结构的修改建议。不要生成配图建议。
        9. 只返回一个 JSON 对象，不要 Markdown。必须先输出 revised，确保完整成稿优先返回；不要输出 corrected 字段。字段顺序与结构为：
        {"revised":"完成实质改写的完整成稿","title":"成稿标题","corrections":[{"original":"原词","corrected":"校正词","reason":"上下文依据"}],"suggestions":[{"original":"具体原句","suggestion":"具体改法","reason":"修改原因"}]}

        成稿信息量硬性要求：
        \(lengthTargetInstruction(material: material, style: style))

        目标成稿规格（以此决定文体，不得被原素材形式覆盖）：
        \(targetContract(for: style))

        原稿标题：
        \(material.title)

        原稿来源：\(material.origin.label)

        输入素材证据（只用于忠实理解内容，不用来决定输出文体）：
        \(sourceEvidence)

        完整原稿：
        \(material.transcript)
        """
    }

    nonisolated static func retryPrompt(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage,
        firstDraft: String,
        issues: [String]
    ) -> String {
        let missingAnchors = EmbeddedModelRuntime.missingFactualAnchors(
            original: material.transcript,
            revised: firstDraft,
            sourceOrigin: material.origin
        )
        let anchorInstruction = missingAnchors.isEmpty ? "" : """

        上一版中尚未得到可核对保留的事实锚点：\(missingAnchors.prefix(24).joined(separator: "、"))。
        请逐项核对原稿语境，把这些日期、数字、专有名词或被引用名称准确写回 revised；可以重写句子，但不得删掉事实或改变含义。
        """
        return """
        上一版“\(style.rawValue)”未通过编辑质量检查：\(issues.joined(separator: "；"))。
        \(rewriteOnlyRule)
        请重新通读原稿和上一版，完成一次真正的全文结构重写。必须保留事实，但要更换开头、信息顺序、段落结构和句式，消除逐句复述与拼接感。
        上一版 revised 约有 \(contentCharacterCount(firstDraft)) 个有效字符。\(lengthTargetInstruction(material: material, style: style))
        若上一版过短，必须逐项恢复原稿中被压缩的背景、原因、例子、过程、转折、限定条件和结论；不得用空洞重复、口号或虚构细节凑字数。
        \(anchorInstruction)
        \(language.promptInstruction)
        仍必须严格按照以下目标成稿规格，不得回到原素材的表达形式：
        \(targetContract(for: style))
        只返回与上一请求完全相同字段的 JSON 对象，不要解释。必须先输出 revised，且不要重复输出完整原稿或 corrected 字段。

        原稿标题：\(material.title)
        输入素材证据：
        \(sourceEvidence(for: material))
        完整原稿：
        \(material.transcript)

        未通过的上一版：
        \(firstDraft)
        """
    }

    nonisolated static func targetContract(for style: RewriteStyle) -> String {
        switch style {
        case .spoken:
            return "生成一篇面向短视频的完整口播稿。前 1–2 句直接给出冲突、利益或问题钩子；使用自然、简短、可一口说出的句子，节奏明快，段落紧凑。revised 中不要写小标题、分镜、时间码、配图说明或标签。"
        case .article:
            return "生成一篇可直接发布的公众号文章。用编辑化的导语建立问题，再按逻辑展开 3–6 个有信息量的小节，每节有必要的上下文和过渡，结尾收束核心判断。避免口播填充词、短视频口令、密集标签和无意义的碎句。"
        case .social:
            return "生成一篇可直接发布的小红书图文文案。标题要具体且有利益点；正文用短段落和清晰层次组织，保留充足信息量，便于拆成封面与多张图文卡片。输入有原图时，必须将可验证的图片文字和可见内容融入新文案，但不照搬原图表达。不要把正文写成口播稿、公众号长文或图片提示词。"
        case .channel:
            return "生成一篇可直接用于视频号的完整文案。保留口播的自然感，但比短视频口播更稳健、信息更完整，先交代背景和事实链，再给出判断与启发；避免过度猎奇、高密度口号和无依据的情绪放大。revised 中不要输出分镜或配图提示词。"
        }
    }

    nonisolated static func lengthTargetInstruction(material: SourceMaterial, style: RewriteStyle) -> String {
        let sourceCount = contentCharacterCount(material.transcript)
        let hanCount = material.transcript.unicodeScalars.filter {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }.count
        guard sourceCount >= 180, hanCount * 2 >= sourceCount else {
            return "必须保留原稿的完整信息量，不得把改写做成摘要或只保留主旨。"
        }
        let minimum = Int((Double(sourceCount) * 0.75).rounded(.up))
        return "原稿约 \(sourceCount) 个有效字符；revised 不得少于 \(minimum) 个有效字符，并应接近原稿信息量。“句子简短”只指句式和节奏，不得减少全文篇幅，不得把改写做成摘要。"
    }

    nonisolated static func contentCharacterCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
    }

    nonisolated static func sourceEvidence(for material: SourceMaterial) -> String {
        let kind = material.sourceContentKind?.label ?? {
            switch material.origin {
            case .platformSubtitle, .localSpeechRecognition: return "视频字幕或音轨"
            case .socialImageText: return "图文"
            case .webArticle: return "网页文章"
            case .pastedText: return "粘贴文本"
            }
        }()
        guard let references = material.visualReferences, !references.isEmpty else {
            return "素材类型：\(kind)。没有可验证的原图证据；不得臆造画面中的人物、场景或数据。"
        }
        let details = references.prefix(9).map { reference in
            let compact = reference.promptContext
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return "原图 \(reference.index)：\(String(compact.prefix(700)))"
        }.joined(separator: "\n")
        return "素材类型：\(kind)。以下是通过图像识别取得的可见证据；只保留可验证信息：\n\(details)"
    }

    nonisolated static func parseDraft(
        _ raw: String,
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage
    ) throws -> OpenRouterParsedDraft {
        let cleaned = EmbeddedModelRuntime.assistantPayload(from: raw)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = EmbeddedModelRuntime.parseJSONObject(from: cleaned)
        let revised = Self.revisedText(from: root, raw: cleaned)
        guard let revised, !revised.isEmpty else { throw OpenRouterError.invalidDraft }
        let modelCorrected = (root?["corrected"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyValue ?? material.transcript
        let correctedWasTranslated = EmbeddedModelRuntime.isCrossLanguageRewrite(
            original: material.transcript, revised: modelCorrected
        )
        let corrected = correctedWasTranslated ? material.transcript : modelCorrected
        let corrections = correctedWasTranslated ? [] : (root?["corrections"] as? [[String: Any]] ?? []).compactMap { item -> TranscriptCorrection? in
            guard let original = (item["original"] as? String)?.nonEmptyValue,
                  let corrected = (item["corrected"] as? String)?.nonEmptyValue,
                  original != corrected else { return nil }
            return TranscriptCorrection(
                original: original,
                corrected: corrected,
                reason: language.normalize((item["reason"] as? String)?.nonEmptyValue ?? "根据上下文判断")
            )
        }
        var suggestions = (root?["suggestions"] as? [[String: Any]] ?? []).compactMap { item -> RevisionSuggestion? in
            guard let suggestion = (item["suggestion"] as? String)?.nonEmptyValue else { return nil }
            let original = (item["original"] as? String)?.nonEmptyValue ?? String(material.transcript.prefix(120))
            return RevisionSuggestion(
                original: original,
                suggestion: language.normalize(suggestion),
                reason: language.normalize((item["reason"] as? String)?.nonEmptyValue ?? "增强结构、节奏与可读性"),
                imagePlacement: "核心事实之后",
                imageSuggestion: "呈现“\(String(language.normalize(revised).prefix(80)))”对应的核心场景"
            )
        }
        if suggestions.isEmpty {
            let blueprint = EmbeddedModelRuntime.parseBlueprint(
                "",
                sourceTitle: material.title,
                sourceText: material.transcript,
                style: style,
                language: language
            )
            suggestions = [EmbeddedModelRuntime.editorialSuggestion(
                original: material.transcript,
                revised: revised,
                blueprint: blueprint,
                style: style,
                language: language,
                index: 1
            )]
        }
        return OpenRouterParsedDraft(
            title: (root?["title"] as? String)?.nonEmptyValue.map(language.normalize),
            corrected: corrected,
            corrections: corrections,
            suggestions: suggestions,
            revised: language.normalize(revised)
        )
    }

    /// Online-compatible endpoints do not all honor JSON mode consistently.
    /// Prefer a valid JSON object, but keep a complete revised field when the
    /// service truncates only the metadata that follows it. Plain article text
    /// is also accepted and still passes the normal document quality gate.
    nonisolated private static func revisedText(
        from root: [String: Any]?,
        raw: String
    ) -> String? {
        let keys = ["revised", "revisedBody", "rewrite", "article", "body", "content"]
        for key in keys {
            if let value = (root?[key] as? String)?.nonEmptyValue { return value }
        }
        if let nested = root?["result"] as? [String: Any] {
            for key in keys {
                if let value = (nested[key] as? String)?.nonEmptyValue { return value }
            }
        }
        for key in keys {
            if let value = completedJSONStringValue(for: key, in: raw)?.nonEmptyValue { return value }
        }
        let plain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty,
              !plain.hasPrefix("{"),
              !plain.hasPrefix("[") else { return nil }
        return plain
    }

    /// Extracts one *complete* JSON string value from an otherwise truncated
    /// object. It never accepts an unterminated value, so a half-written draft
    /// cannot bypass the document quality gate.
    nonisolated private static func completedJSONStringValue(
        for key: String,
        in raw: String
    ) -> String? {
        guard let keyRange = raw.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
        guard index < raw.endIndex, raw[index] == ":" else { return nil }
        index = raw.index(after: index)
        while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
        guard index < raw.endIndex, raw[index] == "\"" else { return nil }

        let valueStart = index
        index = raw.index(after: index)
        var escaped = false
        while index < raw.endIndex {
            let character = raw[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let literal = String(raw[valueStart...index])
                guard let data = "[\(literal)]".data(using: .utf8),
                      let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                    return nil
                }
                return values.first
            }
            index = raw.index(after: index)
        }
        return nil
    }
}

private extension String {
    var nonEmptyValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
