import Foundation
import Testing
@testable import ChengGao

private struct ResearchSearchStub: ResearchSearching {
    let contents: [ResearchContent]

    func search(
        input: ResearchSearchInput,
        progress: @escaping @Sendable (ResearchPlatform, Int, Int) -> Void
    ) async throws -> ResearchSearchOutcome {
        let platform = input.platforms.first ?? .bilibili
        progress(platform, 0, input.platforms.count)
        progress(platform, input.platforms.count, input.platforms.count)
        return ResearchSearchOutcome(contents: contents, warnings: [])
    }
}

private struct FailingResearchSearchStub: ResearchSearching {
    let error: ResearchSearchError

    func search(
        input: ResearchSearchInput,
        progress: @escaping @Sendable (ResearchPlatform, Int, Int) -> Void
    ) async throws -> ResearchSearchOutcome {
        throw error
    }
}

private final class OpenRouterStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ImageGenerationStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) static var receivedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.receivedRequests.append(request)
            if let body = request.httpBody {
                Self.receivedBodies.append(body)
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(buffer, count: count)
                }
                Self.receivedBodies.append(data)
            } else {
                Self.receivedBodies.append(Data())
            }
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor StubExtractor: SourceExtracting {
    func content(kind: SourceKind, urlString: String, pastedText: String) async throws -> SourceMaterial {
        SourceMaterial(title: "粘贴文稿", transcript: pastedText, origin: .pastedText, durationSeconds: nil)
    }
}

private actor StubPipeline: RewriteProcessing {
    func rewrite(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage,
        modelMode: ModelMode,
        onlineCorrection: Bool,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> RewriteOutput {
        progress(RewriteProgress(completed: 1, total: 1, message: "完成"))
        return RewriteOutput(
            title: "可识别的历史标题",
            rawTranscript: material.transcript,
            originalTranscript: material.transcript,
            corrections: [],
            suggestions: [RevisionSuggestion(
                original: material.transcript,
                suggestion: "调整句式",
                reason: "增强可读性",
                imagePlacement: "段落后",
                imageSuggestion: "主题图片"
            )],
            revisedBody: "这是修改后的文稿。",
            notes: "测试",
            transcriptOrigin: material.origin,
            style: style
        )
    }
}

private actor StubVisualPromptGenerator: VisualPromptGenerating {
    func generate(
        for output: RewriteOutput,
        modelMode: ModelMode,
        language: OutputLanguage,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> VisualPromptGenerationResult {
        progress(RewriteProgress(completed: 1, total: 1, message: "AI 镜头设计完成"))
        let planned = VisualShotPlanner.plannedShots(for: output)
        let shots = planned.map { shot in
            VisualShot(
                id: shot.id,
                timecode: shot.timecode,
                spokenContext: shot.spokenContext,
                prompt: "9:16 竖版纪实画面，一名内容创作者坐在深色书桌前，右手滑动笔记本电脑上的 AI 工作流节点，背景有麦克风和分镜便签；中近景、略微俯拍，三分法构图，屏幕冷光与右侧暖色软光形成对比，蓝橙色调，写实电影感，不要水印、不要乱码文字、不要额外手指。"
            )
        }
        return VisualPromptGenerationResult(shots: shots, source: .localAI)
    }
}

private actor SlowStubPipeline: RewriteProcessing {
    func rewrite(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage,
        modelMode: ModelMode,
        onlineCorrection: Bool,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> RewriteOutput {
        progress(RewriteProgress(completed: 0, total: 2, message: "处理中"))
        try await Task.sleep(for: .seconds(5))
        throw CancellationError()
    }
}

@Suite("Offline rewrite pipeline", .serialized)
struct OfflineRewritePipelineTests {
    @Test("Cleans filler words and produces spoken output")
    func spokenRewrite() async throws {
        let pipeline = OfflineRewritePipeline()
        let output = try await pipeline.rewrite(
            material: SourceMaterial(
                title: "测试口播",
                transcript: "嗯，这是第一句话。然后呢，这是第二句话！",
                origin: .pastedText,
                durationSeconds: nil
            ),
            style: .spoken,
            language: .simplifiedChinese,
            modelMode: .fast,
            onlineCorrection: false
        )

        #expect(output.body.hasPrefix("先别急着下结论。"))
        #expect(!output.body.contains("然后呢"))
        #expect(!output.body.contains("\n\n，"))
        #expect(output.originalTranscript.contains("然后呢"))
        #expect(!output.suggestions.isEmpty)
    }

    @Test("Eight GB profile remains within target peak")
    func memoryBudget() {
        let budget = MemoryBudget(
            physicalMemoryGB: 8,
            modelWeightMB: 1_400,
            contextCacheMB: 520,
            workingBufferMB: 780
        )

        #expect(budget.estimatedPeakMB == 2_700)
        #expect(budget.isEightGBSafe)
    }

    @Test("Extracts readable article text without scripts")
    func articleHTML() {
        let html = """
        <html><head><style>hidden</style><script>bad()</script></head>
        <body><article><h1>真正标题</h1><p>第一段内容。</p><p>第二段内容。</p></article></body></html>
        """
        let text = SourceExtractor.readableText(fromHTML: html)
        #expect(text.contains("真正标题"))
        #expect(text.contains("第一段内容"))
        #expect(!text.contains("bad()"))
        #expect(!text.contains("hidden"))
    }

    @Test("Scopes WeChat pages to the article body and removes interaction boilerplate")
    func weChatArticleCleaning() {
        let html = """
        <html><head><title>行业观察</title></head><body>
        <nav>首页 产品中心 完整服务</nav>
        <div id="js_content">
          <h1>行业观察</h1>
          <p>第一段分析市场变化，并给出了关键数据。</p>
          <section><p>第二段解释变化背后的原因和影响。</p></section>
          <p>这篇文章讨论为什么用户会点赞内容，这一句属于正文，不能误删。</p>
          <p>微信扫一扫</p><p>长按识别二维码关注公众号</p>
          <p>点赞 在看 分享 收藏</p><p>完整服务</p>
        </div>
        <footer>相关推荐 无关文章 联系我们</footer>
        </body></html>
        """
        let text = SourceExtractor.articleText(fromHTML: html)
        #expect(text.contains("第一段分析市场变化"))
        #expect(text.contains("第二段解释变化"))
        #expect(text.contains("为什么用户会点赞内容"))
        #expect(!text.contains("微信扫一扫"))
        #expect(!text.contains("完整服务"))
        #expect(!text.contains("相关推荐"))
        #expect(!text.contains("首页 产品中心"))
    }

    @Test("Article prompt retains substance while keeping image work out of the rewrite pass")
    func articlePromptFilteringRule() {
        let prompt = EmbeddedModelRuntime.prompt(
            text: "正文",
            sourceTitle: "测试文章",
            sourceOrigin: .webArticle,
            style: .article,
            language: .simplifiedChinese,
            index: 1,
            total: 2,
            editorialContext: "核心角度：安全缺陷与泄密调查",
            previousDraft: nil,
            nextSourcePreview: "下一段将说明各方回应"
        )
        #expect(prompt.contains("只保留支撑主题的事实、论点、数据、案例和必要背景"))
        #expect(prompt.contains("不要机械复述全部网页文字"))
        #expect(prompt.contains("点赞在看"))
        #expect(prompt.contains("核心角度：安全缺陷与泄密调查"))
        #expect(prompt.contains("下一段将说明各方回应"))
        #expect(prompt.contains("编辑建议与配图将在文字定稿后另行生成"))
        #expect(!prompt.contains("imageSuggestion"))
    }

    @Test("Parses a whole-document editorial blueprint")
    func editorialBlueprintParsing() {
        let raw = #"{"coreAngle":"泄密调查背后的安全争议","openingHook":"一架新专机引发内部调查","storyArc":["缺陷曝光","调查经过","双方回应"],"mustKeepFacts":["CNN援引知情人士","白宫否认安全缺陷"],"tone":"克制、清楚","exclusions":["版权尾注"]}"#
        let blueprint = EmbeddedModelRuntime.parseBlueprint(
            raw,
            sourceTitle: "新专机争议",
            sourceText: "原稿",
            style: .spoken,
            language: .simplifiedChinese
        )
        #expect(blueprint.storyArc.count == 3)
        #expect(blueprint.mustKeepFacts.contains("白宫否认安全缺陷"))
        #expect(blueprint.compactContext.contains("泄密调查背后的安全争议"))
    }

    @Test("Blueprint and review parsers ignore JSON examples echoed from the user prompt")
    func assistantPayloadParsing() {
        let raw = """
        User:
        只输出 {"revised":"示例"}
        Assistant:
        {"revised":"真正完成结构重写的稿件"}
        """
        #expect(EmbeddedModelRuntime.parseRevisedOnly(raw) == "真正完成结构重写的稿件")
        #expect(EmbeddedModelRuntime.assistantPayload(from: raw).hasPrefix("{"))
        let invalidMultilineJSON = """
        {"revised":"第一行
        第二行"}
        """
        #expect(EmbeddedModelRuntime.parseRevisedOnly(invalidMultilineJSON) == "第一行\n第二行")
    }

    @Test("Compatible request uses the configured model")
    func compatibleRequestShape() throws {
        let body = OpenRouterAPIClient.requestBody(
            prompt: "改写全文", model: "gpt-test", maximumTokens: 8_000, structuredOutput: false
        )
        #expect(body["model"] as? String == "gpt-test")
        #expect(body["response_format"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.last?["content"] == "改写全文")
    }

    @Test("Online providers expose complete recommended connection parameters")
    func onlineProviderDefaults() {
        let suite = "OnlineProviderDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for provider in OnlineAIProvider.allCases where provider != .custom {
            let configuration = OnlineAIConfiguration.load(provider: provider, defaults: defaults)
            #expect(configuration.isValid)
            #expect(!configuration.model.isEmpty)
        }
        #expect(OnlineAIProvider.deepSeek.defaultModel == "deepseek-v4-flash")
        #expect(OnlineAIProvider.glm.defaultModel == "glm-5.2")
        #expect(OnlineAIProvider.miniMax.defaultModel == "MiniMax-M2.7")
        #expect(!OnlineAIProvider.allCases.map(\.rawValue).contains("openRouter"))
    }

    @Test("Legacy OpenRouter selection migrates to the custom compatible provider")
    @MainActor
    func legacyOpenRouterProviderMigration() {
        let suite = "LegacyOpenRouterProvider-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openRouter", forKey: "onlineAI.provider")
        let store = RewriteStore(
            pipeline: StubPipeline(),
            defaults: defaults,
            historyURL: FileManager.default.temporaryDirectory
                .appending(path: "legacy-provider-\(UUID().uuidString).json")
        )
        #expect(store.onlineProvider == .custom)
        #expect(defaults.string(forKey: "onlineAI.provider") == "custom")
    }

    @Test("Compatible providers can omit provider-specific structured output fields")
    func compatibleProviderRequestShape() {
        let body = OpenRouterAPIClient.requestBody(
            prompt: "测试",
            model: "glm-5.2",
            maximumTokens: 16,
            structuredOutput: false
        )
        #expect(body["model"] as? String == "glm-5.2")
        #expect(body["max_tokens"] as? Int == 16)
        #expect(body["response_format"] == nil)
    }

    @Test("Reasoning depth is persisted and added only when explicitly selected")
    func reasoningEffortRequestShape() {
        let suite = "ReasoningEffort-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let automatic = OpenRouterAPIClient.requestBody(
            prompt: "测试", model: "gpt-test", maximumTokens: 16,
            structuredOutput: false, reasoningEffort: .automatic
        )
        #expect(automatic["reasoning_effort"] == nil)

        OnlineAIReasoningEffort.high.save(defaults: defaults)
        #expect(OnlineAIReasoningEffort.load(defaults: defaults) == .high)
        let high = OpenRouterAPIClient.requestBody(
            prompt: "测试", model: "gpt-test", maximumTokens: 16,
            structuredOutput: false, reasoningEffort: .high
        )
        #expect(high["reasoning_effort"] as? String == "high")
    }

    @Test("Unsupported reasoning parameters are eligible for a compatibility retry")
    func reasoningCompatibilityRetryDetection() {
        let unsupported = Data(#"{"error":{"message":"Unsupported parameter: reasoning_effort"}}"#.utf8)
        #expect(OpenRouterAPIClient.shouldRetryWithoutReasoning(status: 400, data: unsupported))
        let unrelated = Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
        #expect(!OpenRouterAPIClient.shouldRetryWithoutReasoning(status: 401, data: unrelated))
    }

    @Test("Composer model controller persists the selected remote model")
    @MainActor
    func composerModelSelectionPersistence() {
        let suite = "ComposerModelSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(OnlineAIProvider.custom.rawValue, forKey: "onlineAI.provider")
        defaults.set("https://example.com/v1/chat/completions", forKey: "onlineAI.custom.endpoint")
        defaults.set("old-model", forKey: "onlineAI.custom.model")
        let store = RewriteStore(
            pipeline: StubPipeline(), defaults: defaults,
            historyURL: FileManager.default.temporaryDirectory
                .appending(path: "model-selection-\(UUID().uuidString).json")
        )
        store.selectOnlineModelForProcessing("new-model")
        #expect(store.onlineModelDraft == "new-model")
        #expect(OnlineAIConfiguration.load(defaults: defaults).model == "new-model")
    }

    @Test("Image endpoint can be derived from a compatible relay chat endpoint")
    func compatibleImageEndpointDerivation() throws {
        let derived = try #require(OnlineImageGenerationConfiguration.imagesGenerationsURL(
            from: "",
            fallbackChatEndpoint: "https://api.example.com/v1/chat/completions"
        ))
        #expect(derived.absoluteString == "https://api.example.com/v1/images/generations")

        let explicit = try #require(OnlineImageGenerationConfiguration.imagesGenerationsURL(
            from: "https://images.example.com/openai/v1/images/generations",
            fallbackChatEndpoint: "https://api.example.com/v1/chat/completions"
        ))
        #expect(explicit.absoluteString == "https://images.example.com/openai/v1/images/generations")
    }

    @Test("Image request uses the selected relay model, aspect ratio and quality")
    func compatibleImageRequestShape() {
        let configuration = OnlineImageGenerationConfiguration(
            provider: .custom,
            endpoint: "",
            model: "relay-image-model",
            size: .automatic,
            quality: .high
        )
        let body = CompatibleImageGenerationClient.requestBody(
            prompt: "一张编辑配图",
            style: .article,
            configuration: configuration
        )
        #expect(body["model"] as? String == "relay-image-model")
        #expect(body["size"] as? String == "1536x1024")
        #expect(body["quality"] as? String == "high")
        #expect(body["response_format"] as? String == "url")
    }

    @Test("Compatible image client reads relay image_url and downloads the image")
    func compatibleImageURLResponse() async throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        ImageGenerationStubURLProtocol.receivedRequests = []
        ImageGenerationStubURLProtocol.receivedBodies = []
        ImageGenerationStubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return (200, ["Content-Type": "application/json"], Data(
                    #"{"data":[{"image_url":"https://cdn.example.com/generated.png","revised_prompt":"优化后的提示词"}]}"#.utf8
                ))
            }
            return (200, ["Content-Type": "image/png"], png)
        }
        defer {
            ImageGenerationStubURLProtocol.handler = nil
            ImageGenerationStubURLProtocol.receivedRequests = []
            ImageGenerationStubURLProtocol.receivedBodies = []
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ImageGenerationStubURLProtocol.self]
        let client = CompatibleImageGenerationClient(session: URLSession(configuration: sessionConfiguration))
        let payload = try await client.generate(
            prompt: "测试生成",
            style: .social,
            configuration: OnlineImageGenerationConfiguration(
                provider: .custom, endpoint: "", model: "relay-image-model",
                size: .portrait, quality: .automatic
            ),
            fallbackChatEndpoint: "https://api.example.com/v1/chat/completions",
            apiKey: "test-key-placeholder"
        )
        #expect(payload.data == png)
        #expect(payload.fileExtension == "png")
        #expect(payload.remoteURL?.absoluteString == "https://cdn.example.com/generated.png")
        #expect(payload.revisedPrompt == "优化后的提示词")
        #expect(ImageGenerationStubURLProtocol.receivedRequests.count == 2)
        #expect(ImageGenerationStubURLProtocol.receivedRequests[1].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Compatible image client retries without response_format and accepts b64_json")
    func compatibleImageBase64Retry() async throws {
        let pngString = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let png = try #require(Data(base64Encoded: pngString))
        ImageGenerationStubURLProtocol.receivedRequests = []
        ImageGenerationStubURLProtocol.receivedBodies = []
        ImageGenerationStubURLProtocol.handler = { _ in
            let count = ImageGenerationStubURLProtocol.receivedRequests.count
            if count == 1 {
                return (400, ["Content-Type": "application/json"], Data(
                    #"{"error":{"message":"Unsupported parameter: response_format"}}"#.utf8
                ))
            }
            return (200, ["Content-Type": "application/json"], try JSONSerialization.data(
                withJSONObject: ["data": [["b64_json": pngString]]]
            ))
        }
        defer {
            ImageGenerationStubURLProtocol.handler = nil
            ImageGenerationStubURLProtocol.receivedRequests = []
            ImageGenerationStubURLProtocol.receivedBodies = []
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ImageGenerationStubURLProtocol.self]
        let client = CompatibleImageGenerationClient(session: URLSession(configuration: sessionConfiguration))
        let payload = try await client.generate(
            prompt: "测试生成",
            style: .spoken,
            configuration: OnlineImageGenerationConfiguration(
                provider: .custom, endpoint: "https://api.example.com/v1/images/generations",
                model: "relay-image-model", size: .automatic, quality: .automatic
            ),
            fallbackChatEndpoint: "",
            apiKey: "test-key-placeholder"
        )
        #expect(payload.data == png)
        #expect(ImageGenerationStubURLProtocol.receivedRequests.count == 2)
        let retriedBody = ImageGenerationStubURLProtocol.receivedBodies[1]
        let retriedJSON = try #require(JSONSerialization.jsonObject(with: retriedBody) as? [String: Any])
        #expect(retriedJSON["response_format"] == nil)
    }

    @Test("Provider credentials round-trip through an isolated protected file")
    func providerCredentialRoundTrip() throws {
        let service = "com.itou.chenggao.tests.\(UUID().uuidString)"
        defer { try? OnlineAICredentialStore.delete(for: .custom, serviceName: service) }
        try OnlineAICredentialStore.save("test-key", for: .custom, serviceName: service)
        #expect(OnlineAICredentialStore.load(for: .custom, serviceName: service) == "test-key")
        try OnlineAICredentialStore.delete(for: .custom, serviceName: service)
        #expect(OnlineAICredentialStore.load(for: .custom, serviceName: service) == nil)
    }

    @Test("OpenRouter response records the actual routed model")
    func openRouterResponseParsing() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "qwen/example:free",
            "choices": [["message": ["content": #"{"revised":"完整改写稿"}"#]]]
        ])
        let completion = try OpenRouterAPIClient.parseCompletion(data)
        #expect(completion.model == "qwen/example:free")
        #expect(completion.content.contains("完整改写稿"))
    }

    @Test("OpenRouter draft parser produces complete app output fields")
    func openRouterDraftParsing() throws {
        let raw = #"{"title":"新标题","corrected":"校对后的原稿","corrections":[],"suggestions":[{"original":"旧开头","suggestion":"改用结论开场","reason":"增强注意力"}],"revised":"先说结论，再解释事实依据。这是一份经过结构重写、可以直接使用的完整成稿。"}"#
        let parsed = try OpenRouterRewritePipeline.parseDraft(
            raw,
            material: SourceMaterial(
                title: "旧标题",
                transcript: "旧开头，然后解释事实依据。这是一份需要完成结构改写的原稿。",
                origin: .pastedText,
                durationSeconds: nil
            ),
            style: .spoken,
            language: .simplifiedChinese
        )
        #expect(parsed.title == "新标题")
        #expect(parsed.corrected == "校对后的原稿")
        #expect(parsed.suggestions.first?.suggestion == "改用结论开场")
        #expect(parsed.revised.contains("先说结论"))
    }

    @Test("Online pipeline completes through an OpenRouter-compatible response")
    func openRouterPipelineEndToEnd() async throws {
        let content = #"{"title":"在线成稿","corrected":"人工智能工具需要明确边界。编辑负责最终判断。","corrections":[],"suggestions":[{"original":"人工智能工具需要明确边界","suggestion":"先提出判断再解释分工","reason":"增强开场"}],"revised":"先明确一条边界：最终判断必须由编辑承担。人工智能更适合处理整理和初步改写，让人把精力留给事实与观点。"}"#
        OpenRouterStubURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
            "model": "example/large-free",
            "choices": [["message": ["content": content]]]
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterStubURLProtocol.self]
        let pipeline = OpenRouterRewritePipeline(client: OpenRouterAPIClient(
            session: URLSession(configuration: configuration),
            configurationProvider: {
                OnlineAIConfiguration(
                    provider: .custom,
                    endpoint: "https://example.com/v1/chat/completions",
                    model: "example/large-free"
                )
            },
            apiKeyProvider: { "sk-or-test-placeholder" }
        ))
        let output = try await pipeline.rewrite(
            material: SourceMaterial(
                title: "边界",
                transcript: "人工智能工具需要明确边界。编辑负责最终判断。",
                origin: .pastedText,
                durationSeconds: nil
            ),
            style: .spoken,
            language: .simplifiedChinese,
            modelMode: .onlinePreferred,
            onlineCorrection: false,
            contextLimit: 8_192,
            progress: { _ in }
        )
        #expect(output.title == "在线成稿")
        #expect(output.revisedBody.hasPrefix("先明确一条边界"))
        #expect(output.notes.contains("example/large-free"))
        #expect(output.notes.contains("完整标题与正文已发送"))
    }

    @Test("Online rewrite prompt sends the complete document as one task")
    func onlinePromptKeepsWholeDocumentTogether() {
        let opening = "全文开头的事实锚点"
        let ending = "全文结尾的最终结论"
        let transcript = ([opening] + (1...80).map { "第\($0)段包含需要保留的人物、数据和论证。" } + [ending])
            .joined(separator: "\n\n")
        let prompt = OpenRouterRewritePipeline.prompt(
            material: SourceMaterial(
                title: "完整长文",
                transcript: transcript,
                origin: .pastedText,
                durationSeconds: nil
            ),
            style: .article,
            language: .simplifiedChinese
        )
        #expect(prompt.contains("这是全文任务"))
        #expect(prompt.contains(opening))
        #expect(prompt.contains(ending))
        #expect(prompt.components(separatedBy: transcript).count == 2)
        #expect(prompt.contains("必须先输出 revised"))
        #expect(prompt.contains("不要输出 corrected 字段"))
        #expect(!prompt.contains(#""corrected":"仅纠错后的完整原稿""#))
    }

    @Test("输入素材类型不会覆盖用户选择的成稿类型")
    func targetFormatIsIndependentFromSourceKind() {
        let reference = SourceVisualReference(
            index: 1, imageURL: nil, recognizedText: "原图可见文字",
            sceneDescription: "一名学生查看资料", composition: "书桌俯拍",
            redesignDirection: "更换场景与构图"
        )
        let material = SourceMaterial(
            title: "图文素材", transcript: "这是需要重新组织的完整素材。",
            origin: .socialImageText, durationSeconds: nil,
            visualReferences: [reference], sourceContentKind: .imageText
        )
        let article = OpenRouterRewritePipeline.prompt(
            material: material, style: .article, language: .simplifiedChinese
        )
        let spoken = OpenRouterRewritePipeline.prompt(
            material: material, style: .spoken, language: .simplifiedChinese
        )
        #expect(article.contains("可直接发布的公众号文章"))
        #expect(article.contains("原图可见文字"))
        #expect(article.contains("不得被原素材形式覆盖"))
        #expect(spoken.contains("面向短视频的完整口播稿"))
        #expect(!spoken.contains("生成一篇可直接发布的公众号文章"))
    }

    @Test("四种输出格式具有独立的全文成稿契约")
    func everyTargetFormatHasDistinctEditorialContract() {
        let contracts = Dictionary(uniqueKeysWithValues: RewriteStyle.allCases.map {
            ($0, OpenRouterRewritePipeline.targetContract(for: $0))
        })
        #expect(contracts.count == 4)
        #expect(Set(contracts.values).count == 4)
        #expect(contracts[.spoken]?.contains("不要写小标题") == true)
        #expect(contracts[.article]?.contains("3–6 个有信息量的小节") == true)
        #expect(contracts[.social]?.contains("多张图文卡片") == true)
        #expect(contracts[.channel]?.contains("更稳健") == true)
    }

    @Test("Online draft keeps a complete revised field when trailing metadata is truncated")
    func onlineDraftRecoversCompletedRevisionBeforeTruncatedMetadata() throws {
        let material = SourceMaterial(
            title: "多图笔记",
            transcript: "原稿包含第一项事实和第二项事实，需要重新组织表达。",
            origin: .socialImageText,
            durationSeconds: nil
        )
        let raw = #"{"revised":"先看结论：第一项事实与第二项事实共同说明了问题。\n接下来重新梳理原因。","title":"重新梳理两项事实","suggestions":[{"original":"原稿""#
        let draft = try OpenRouterRewritePipeline.parseDraft(
            raw, material: material, style: .social, language: .simplifiedChinese
        )
        #expect(draft.revised.contains("先看结论"))
        #expect(draft.revised.contains("重新梳理原因"))
    }

    @Test("Online draft accepts complete plain article text from compatible endpoints")
    func onlineDraftAcceptsPlainArticleText() throws {
        let material = SourceMaterial(
            title: "兼容接口",
            transcript: "原稿先陈述背景，再给出结论。",
            origin: .pastedText,
            durationSeconds: nil
        )
        let draft = try OpenRouterRewritePipeline.parseDraft(
            "先说结论：这件事的关键不在表面现象，而在背景与结果之间的联系。",
            material: material,
            style: .article,
            language: .simplifiedChinese
        )
        #expect(draft.revised.hasPrefix("先说结论"))
    }

    @Test("Online-only mode reports a missing key instead of fabricating a local result")
    func onlineOnlyMissingKeyFailure() async {
        let online = OpenRouterRewritePipeline(client: OpenRouterAPIClient(apiKeyProvider: { nil }))
        let pipeline = AdaptiveRewritePipeline(
            onlineModel: online,
            verifier: WikipediaTerminologyVerifier()
        )
        await #expect(throws: OpenRouterError.self) {
            try await pipeline.rewrite(
                material: SourceMaterial(
                    title: "在线测试",
                    transcript: "这是需要交给在线模型完整处理的原稿。",
                    origin: .pastedText,
                    durationSeconds: nil
                ),
                style: .article,
                language: .simplifiedChinese,
                modelMode: .onlinePreferred,
                onlineCorrection: false,
                contextLimit: 16_384,
                progress: { _ in }
            )
        }
    }

    @Test("Whole-document review keeps opposing claims and removes page noise")
    func wholeDocumentReviewInstructions() {
        let blueprint = EditorialBlueprint(
            coreAngle: "安全争议引发泄密调查",
            openingHook: "新专机被曝存在安全缺陷",
            storyArc: ["报道", "调查", "回应"],
            mustKeepFacts: ["白宫否认", "媒体援引消息人士"],
            tone: "克制",
            exclusions: ["关注引导"]
        )
        let prompt = EmbeddedModelRuntime.wholeDocumentReviewPrompt(
            original: "媒体报道存在缺陷，白宫否认。关注我们。",
            draft: "媒体称存在缺陷。",
            blueprint: blueprint,
            sourceOrigin: .webArticle,
            style: .spoken,
            language: .simplifiedChinese
        )
        #expect(prompt.contains("否认或反方说法"))
        #expect(prompt.contains("不能用删掉后半篇的方式伪装成改写"))
        #expect(prompt.contains(#"{"revised":"通过终审的完整成稿"}"#))
        #expect(!prompt.contains("imageSuggestion"))
    }

    @Test("Builds concrete revision advice after the text is drafted")
    func postDraftEditorialSuggestion() {
        let blueprint = EditorialBlueprint(
            coreAngle: "安全争议引发内部调查",
            openingHook: "新专机被曝存在缺陷",
            storyArc: ["缺陷曝光", "调查经过", "双方回应"],
            mustKeepFacts: ["白宫否认"],
            tone: "克制",
            exclusions: []
        )
        let suggestion = EmbeddedModelRuntime.editorialSuggestion(
            original: "媒体先报道安全缺陷，随后介绍调查经过。",
            revised: "一则安全缺陷报道，引发了白宫内部调查。",
            blueprint: blueprint,
            style: .spoken,
            language: .simplifiedChinese,
            index: 1
        )
        #expect(suggestion.suggestion.contains("安全争议引发内部调查"))
        #expect(suggestion.suggestion.contains("媒体先报道安全缺陷"))
        #expect(suggestion.reason.contains("一则安全缺陷报道"))
    }

    @Test("Document quality gate rejects a draft that drops the final third")
    func documentCoverageRejectsTruncation() {
        let original = """
        CNN在15日报道，新专机被曝存在安全缺陷，多名官员被要求交出手机。调查人员在白宫设立作战室，并向参与北约峰会行程的人员索取设备。特朗普8日返美时先乘旧专机前往英国，随后换乘新专机。纽约时报称换机源于特勤局的安全要求，特朗普和白宫均否认新专机存在安全缺陷。该报参与报道的记者随后在11日收到传票。
        """
        let truncated = "CNN在15日报道，新专机被曝存在安全缺陷，多名官员被要求交出手机。调查人员随后在白宫设立作战室，追查消息来源。"
        let issues = EmbeddedModelRuntime.documentQualityIssues(
            original: original,
            revised: truncated,
            sourceOrigin: .webArticle,
            style: .spoken
        )
        #expect(issues.contains("日期、数字、信源或关键名词保留不足") || issues.contains("全文某一部分几乎没有进入成稿，存在截断或整段遗漏"))
    }

    @Test("Document quality gate rejects a ninety-four percent spoken rewrite")
    func documentQualityRejectsNearCopy() {
        let paragraph = "一个被刻意回避的问题，无产阶级夺取政权之后还算不算无产阶级？如果掌权者管理工厂并分配国家财富，这个身份是否已经变化？马克思和恩格斯都讨论过这个问题。"
        let original = paragraph + paragraph
        let revised = (paragraph + paragraph).replacingOccurrences(of: "是否已经变化", with: "是否已经改变")
        #expect(EmbeddedModelRuntime.documentQualityIssues(
            original: original,
            revised: revised,
            sourceOrigin: .localSpeechRecognition,
            style: .spoken
        ).contains("全文仍以逐句复述为主，实质改写幅度不足"))
    }

    @Test("High-similarity retry asks for semantic-group structural reconstruction")
    func structuralRewritePromptIsExplicit() {
        let blueprint = EditorialBlueprint(
            coreAngle: "权力是否改变阶级身份",
            openingHook: "掌权者还能否被罢免",
            storyArc: ["提出问题", "历史论述", "制度判断"],
            mustKeepFacts: ["巴黎公社原则"],
            tone: "克制",
            exclusions: []
        )
        let prompt = EmbeddedModelRuntime.structuralRewritePrompt(
            text: "原始语义组",
            sourceTitle: "阶级身份",
            sourceOrigin: .localSpeechRecognition,
            style: .spoken,
            language: .simplifiedChinese,
            blueprint: blueprint,
            index: 2,
            total: 3,
            previousDraft: "上一组结尾",
            nextSourcePreview: "下一组内容",
            attempt: 2
        )
        #expect(prompt.contains("不得沿用原稿逐句顺序"))
        #expect(prompt.contains("开头不得沿用原稿前十二个字"))
        #expect(prompt.contains("上一组结尾"))
        #expect(prompt.contains(#"{"revised":"完成结构重写的完整语义组"}"#))
    }

    @Test("Turns legacy visual advice into a copy-ready image prompt")
    func imagePromptBuilder() {
        let item = RevisionSuggestion(
            original: "杭州一家自助餐厅要求顾客寄存大包。",
            suggestion: "压缩开头",
            reason: "更直接",
            imagePlacement: "第一段后",
            imageSuggestion: "顾客在自助餐厅入口寄存背包"
        )
        let prompt = ImagePromptBuilder.prompt(for: item, style: .spoken)
        #expect(prompt.hasPrefix("生成一张"))
        #expect(prompt.contains("顾客在自助餐厅入口寄存背包"))
        #expect(prompt.contains("9:16 竖版"))
        #expect(prompt.contains("不要出现任何文字"))
    }

    @Test("Keeps an already complete image prompt unchanged")
    func completeImagePromptPassThrough() {
        let ready = "生成一张餐厅入口的纪实照片，自然光，中景构图；画面比例 16:9；不要出现文字、二维码、水印或品牌标志。"
        let item = RevisionSuggestion(
            original: "正文",
            suggestion: "调整",
            reason: "清楚",
            imagePlacement: "段后",
            imageSuggestion: ready
        )
        #expect(ImagePromptBuilder.prompt(for: item, style: .article) == ready)
    }

    @Test("Parses structured local model suggestion JSON")
    func modelJSON() {
        let raw = """
        User:
        prompt with {"example":"ignored"}
        Assistant:
        <think>hidden reasoning</think>
        {"suggestion":"压缩重复表达","reason":"节奏更清楚","revised":"这是可以直接使用的完整口播稿。"}
        """
        let output = EmbeddedModelRuntime.parseChunk(raw, original: "原始内容")
        #expect(output.suggestion.original == "原始内容")
        #expect(output.suggestion.suggestion == "压缩重复表达")
        #expect(output.revised == "这是可以直接使用的完整口播稿。")
    }

    @Test("Deep rewrite retry gives the model one focused task")
    func deepRewritePromptIsFocused() {
        let prompt = EmbeddedModelRuntime.deepRewritePrompt(
            text: "原始段落",
            sourceTitle: "历史事件",
            style: .spoken,
            language: .simplifiedChinese
        )
        #expect(prompt.contains("你只负责深度改写"))
        #expect(prompt.contains("不得沿用原文的逐句顺序"))
        #expect(prompt.contains(#"{"revised":"深度改写后的完整本段"}"#))
        #expect(!prompt.contains("imageSuggestion"))
        #expect(!prompt.contains("corrections"))
    }

    @Test("Extracts a link without treating its share title as transcript")
    func sharedLinkParsing() {
        let shared = "【视频标题】 https://www.bilibili.com/video/BV13Kj169ETG?from=share"
        #expect(SourceExtractor.firstURL(in: shared)?.host == "www.bilibili.com")
        #expect(SourceExtractor.bilibiliBVID(in: shared) == "BV13Kj169ETG")
        #expect(!SourceExtractor.isPlausibleTranscript("只有标题", duration: 343))
    }

    @Test("Splits a long transcript without losing characters")
    func transcriptChunking() {
        let source = String(repeating: "这是一句完整的口播。", count: 300)
        let chunks = EmbeddedModelRuntime.chunks(source, maximumCharacters: 500)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == source)
    }

    @Test("Builds a task board around numbered sections")
    func structuredTaskBoard() {
        let source = """
        开场说明
        一
        香港身份五大通道
        01
        香港优才计划适合具有专业能力的人士。
        02
        高才通计划分为不同类别。
        1️⃣ A类
        申请人需要满足相应条件。
        2. 审核标准
        审核时需要检查真实贡献。
        """
        let cards = EmbeddedModelRuntime.taskBoard(source, maximumCharacters: 120)
        #expect(cards.map(\.protectedHeading).compactMap { $0 } == ["一", "01", "02", "1️⃣ A类", "2. 审核标准"])
        #expect(cards.allSatisfy { $0.source.count <= 120 })
        #expect(cards.first(where: { $0.protectedHeading == "02" })?.source.contains("高才通计划") == true)
    }

    @Test("Restores locked numbering after a model changes it")
    func restoresLockedNumbering() {
        let card = RewriteTaskCard(source: "02\n高才通计划分为不同类别。", protectedHeading: "02")
        let modelResult = ParsedRewriteChunk(
            corrected: "03\n高才通计划分成三类。",
            corrections: [],
            suggestion: RevisionSuggestion(
                original: card.source,
                suggestion: "压缩表达",
                reason: "更清楚",
                imagePlacement: "段末",
                imageSuggestion: "政策资料画面"
            ),
            revised: "03\n高才通计划可以分为三类。"
        )
        let restored = EmbeddedModelRuntime.restoringStructure(
            in: modelResult,
            from: card,
            language: .simplifiedChinese
        )
        #expect(restored.corrected.hasPrefix("02\n"))
        #expect(restored.revised.hasPrefix("02\n"))
        #expect(!restored.revised.contains("03"))
    }

    @Test("Quality gate rejects changed numbering")
    func numberingQualityGate() {
        let original = "01\n第一项政策内容。"
        let changed = ParsedRewriteChunk(
            corrected: original,
            corrections: [],
            suggestion: RevisionSuggestion(
                original: original,
                suggestion: "调整句式",
                reason: "更适合阅读",
                imagePlacement: "段末",
                imageSuggestion: "政策资料画面"
            ),
            revised: "02\n这是重新表达后的第一项政策内容。"
        )
        #expect(EmbeddedModelRuntime.qualityIssues(in: changed, original: original, style: .spoken)
            .contains("修改稿的标题或序号与原稿不一致"))
    }

    @Test("Local fallback preserves numbering and does not generate a new list")
    func structuredFallbackPreservesNumbering() {
        let result = EmbeddedModelRuntime.qualityFallback(
            original: "1️⃣ A类\n申请人需要达到收入门槛。还要提交证明材料。",
            corrected: "1️⃣ A类\n申请人需要达到收入门槛。还要提交证明材料。",
            corrections: [],
            style: .social,
            language: .simplifiedChinese,
            index: 1
        )
        #expect(result.revised.hasPrefix("1️⃣ A类\n"))
        #expect(!result.revised.contains("1. 申请人"))
        #expect(!result.revised.contains("2. 还要"))
    }

    @Test("Transcribes a local video audio sample when diagnostic assets exist")
    func realSpeechRecognitionSmokeTest() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let model = root.appending(path: "Models/ggml-small-q5_1.bin")
        let audio = URL(fileURLWithPath: "/tmp/chenggao-audio.m4s")
        guard FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: audio.path) else { return }

        let transcriber = LocalSpeechTranscriber(modelURL: model)
        let transcript = try await transcriber.transcribe(audioURL: audio, expectedDuration: 343)
        #expect(transcript.count > 200)
        #expect(!transcript.contains("https://"))
    }

    @Test("Whisper defaults to multilingual automatic language detection")
    func whisperUsesAutomaticLanguageDetection() {
        #expect(LocalSpeechTranscriber.defaultSpokenLanguage == "auto")
    }

    @Test("Live multilingual Whisper samples retain their spoken languages")
    func liveMultilingualSpeechRecognition() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_MULTILINGUAL_AUDIO_TEST"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let model = root.appending(path: "Models/ggml-small-q5_1.bin")
        let transcriber = LocalSpeechTranscriber(modelURL: model)
        let cantonese = try await transcriber.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/chenggao-lang-yue.wav"), expectedDuration: nil
        )
        let english = try await transcriber.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/chenggao-lang-en.wav"), expectedDuration: nil
        )
        let japanese = try await transcriber.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/chenggao-lang-ja.wav"), expectedDuration: nil
        )
        #expect(cantonese.contains("香港") && cantonese.contains("政策"))
        #expect(english.lowercased().contains("immigration policy"))
        #expect(japanese.contains("移民政策"))
    }

    @Test("Cross-language rewrite keeps the source transcript but requires simplified Chinese output")
    func multilingualRewriteContract() throws {
        let material = SourceMaterial(
            title: "Immigration policy update",
            transcript: "Today I want to explain an important change in immigration policy in 2026.",
            origin: .localSpeechRecognition,
            durationSeconds: 12
        )
        let raw = #"""
        {"title":"2026年移民政策变化","corrected":"Today I want to explain an important change in immigration policy in 2026.","corrections":[],"suggestions":[{"original":"important change","suggestion":"先讲政策变化的影响","reason":"增强开场信息密度"}],"revised":"先说结论：2026年的移民政策出现了一项重要变化，这可能直接影响未来的规划。"}
        """#
        let draft = try OpenRouterRewritePipeline.parseDraft(
            raw, material: material, style: .spoken, language: .simplifiedChinese
        )
        #expect(draft.corrected.hasPrefix("Today I want"))
        #expect(draft.revised.contains("移民政策"))
        #expect(OutputLanguage.simplifiedChinese.promptInstruction.contains("英语"))
        #expect(OutputLanguage.simplifiedChinese.promptInstruction.contains("corrected 字段保留原语言"))
    }

    @Test("Cross-language quality gate validates numbers without demanding shared wording")
    func crossLanguageQualityGate() {
        let original = """
        In 2026, the agency interviewed 120 applicants in Tokyo. The approval rate rose from 35% to 48%. Officials said the new policy takes effect on October 1, 2026, while critics warned that processing may still take 90 days.
        """
        let translated = """
        先看最关键的变化：2026年，相关机构在东京访问了120名申请人，批准率也从35%上升到48%。新政策将在2026年10月1日生效，不过批评者提醒，整个处理流程仍可能需要90天。
        """
        #expect(EmbeddedModelRuntime.isCrossLanguageRewrite(original: original, revised: translated))
        #expect(EmbeddedModelRuntime.documentQualityIssues(
            original: original,
            revised: translated,
            sourceOrigin: .localSpeechRecognition,
            style: .spoken
        ).isEmpty)
    }

    @Test("Cross-language quality gate rejects one omitted numeric fact")
    func crossLanguageQualityGateRejectsOmittedNumber() {
        let original = "In 2026, the agency interviewed 120 applicants. Approval rose from 35% to 48%."
        let incomplete = "2026年，批准率从35%上升到48%，但报道没有说明受访人数。"
        #expect(EmbeddedModelRuntime.documentQualityIssues(
            original: original,
            revised: incomplete,
            sourceOrigin: .localSpeechRecognition,
            style: .spoken
        ).contains("日期、数字、信源或关键名词保留不足"))
    }

    @Test("Custom compatible provider rejects incomplete pasted credentials")
    func onlineCredentialFormatValidation() {
        #expect(OnlineAIProvider.custom.acceptsAPIKey("example-compatible-key"))
        #expect(!OnlineAIProvider.custom.acceptsAPIKey("short"))
        #expect(!OnlineAIProvider.custom.acceptsAPIKey("key with spaces 123456"))
    }

    @Test("Model catalog endpoint follows an OpenAI-compatible chat endpoint")
    func onlineModelCatalogEndpoint() {
        #expect(OnlineAIConfiguration(
            provider: .custom,
            endpoint: "https://api.ej2075.com",
            model: "test"
        ).endpointURL?.absoluteString == "https://api.ej2075.com/v1/chat/completions")
        #expect(OnlineAIConfiguration(
            provider: .custom,
            endpoint: "https://api.ej2075.com/v1/",
            model: "test"
        ).endpointURL?.absoluteString == "https://api.ej2075.com/v1/chat/completions")
        #expect(OnlineAIModelCatalogClient.modelsEndpoint(
            from: "https://api.ej2075.com"
        )?.absoluteString == "https://api.ej2075.com/v1/models")
        #expect(OnlineAIModelCatalogClient.modelsEndpoint(
            from: "https://openrouter.ai/api/v1/chat/completions"
        )?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(OnlineAIModelCatalogClient.modelsEndpoint(
            from: "https://example.com/proxy/v1/chat/completions?tenant=1"
        )?.absoluteString == "https://example.com/proxy/v1/models")
    }

    @Test("Model catalog accepts common compatible response shapes")
    func onlineModelCatalogParsing() throws {
        let data = Data(#"{"data":[{"id":"openai/gpt-5.6"},{"id":"google/gemini-3"},{"id":"openai/gpt-5.6"}]}"#.utf8)
        #expect(try OnlineAIModelCatalogClient.parseModels(data) == [
            "google/gemini-3", "openai/gpt-5.6"
        ])
        let alternate = Data(#"{"models":["qwen/qwen3","deepseek/deepseek-v4"]}"#.utf8)
        #expect(try OnlineAIModelCatalogClient.parseModels(alternate) == [
            "deepseek/deepseek-v4", "qwen/qwen3"
        ])
    }

    @Test("Live online pipeline rewrites an English transcript into simplified Chinese")
    func liveOnlineEnglishToSimplifiedChinese() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_ONLINE_MULTILINGUAL_LIVE_TEST"] == "1" else { return }
        let material = SourceMaterial(
                title: "Immigration policy update",
                transcript: """
                In 2026, the agency interviewed 120 applicants in Tokyo. The approval rate rose from 35% to 48%. Officials said the new policy takes effect on October 1, 2026. Critics warned that processing may still take 90 days, so applicants should prepare their documents early and verify every deadline before submitting the application.
                """,
                origin: .localSpeechRecognition,
                durationSeconds: 30
            )
        let client = OpenRouterAPIClient()
        let completion = try await client.complete(prompt: OpenRouterRewritePipeline.prompt(
            material: material, style: .spoken, language: .simplifiedChinese
        ))
        print("LIVE_MULTILINGUAL_MODEL=\(completion.model)")
        print("LIVE_MULTILINGUAL_CONTENT=\(String(completion.content.prefix(2_000)))")
        let draft = try OpenRouterRewritePipeline.parseDraft(
            completion.content, material: material, style: .spoken, language: .simplifiedChinese
        )
        let issues = EmbeddedModelRuntime.documentQualityIssues(
            original: material.transcript,
            revised: draft.revised,
            sourceOrigin: material.origin,
            style: .spoken
        )
        print("LIVE_MULTILINGUAL_ISSUES=\(issues)")
        let hanCount = draft.revised.unicodeScalars.filter {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }.count
        #expect(hanCount >= 30)
        #expect(draft.revised.contains("2026"))
        #expect(draft.revised.contains("120"))
        #expect(draft.revised.contains("批评"))
        #expect(draft.corrected.contains("In 2026"))
        #expect(issues.isEmpty)
    }

    @Test("Fetches the supplied Bilibili video and returns its real spoken transcript")
    func liveBilibiliTranscript() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_LIVE_TEST"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let model = root.appending(path: "Models/ggml-small-q5_1.bin")
        let extractor = SourceExtractor(transcriber: LocalSpeechTranscriber(modelURL: model))
        let material = try await extractor.content(
            kind: .link,
            urlString: "https://www.bilibili.com/video/BV13Kj169ETG",
            pastedText: "【为什么别人都说好的游戏,我就是玩不下去?】 https://www.bilibili.com/video/BV13Kj169ETG"
        )
        #expect(material.title.contains("游戏"))
        #expect(material.origin == .localSpeechRecognition)
        #expect(material.transcript.count > 1_500)
        #expect(material.transcript.contains("玩家") || material.transcript.contains("游戏"))
    }

    @Test("Recognizes Douyin video links instead of treating them as article pages")
    func douyinVideoLinkRecognition() {
        let direct = URL(string: "https://www.douyin.com/video/7588872042955427081")!
        let modal = URL(string: "https://www.douyin.com/search/test?modal_id=7588872042955427081")!
        let short = URL(string: "https://v.douyin.com/abcdef/")!
        #expect(SourceExtractor.isDouyin(direct))
        #expect(SourceExtractor.isDouyin(short))
        #expect(SourceExtractor.douyinVideoID(in: direct) == "7588872042955427081")
        #expect(SourceExtractor.douyinVideoID(in: modal) == "7588872042955427081")
        #expect(SourceExtractor.douyinVideoID(in: short) == nil)
    }

    @Test("Parses a Douyin detail response into a playable video resource")
    func douyinDetailParsing() throws {
        let payload = """
        {
          "aweme_detail": {
            "aweme_id": "7588872042955427081",
            "desc": "真实抖音视频标题",
            "video": {
              "duration": 93250,
              "play_addr": {
                "url_list": [
                  "https://v.example.com/video.mp4",
                  "http://v.example.com/video-backup.mp4"
                ]
              }
            }
          }
        }
        """
        let resource = try #require(DouyinVideoResolver.parse(
            payload: payload,
            videoID: "7588872042955427081",
            userAgent: "test-agent"
        ))
        #expect(resource.title == "真实抖音视频标题")
        #expect(resource.durationSeconds == 94)
        #expect(resource.mediaURLs.map(\.absoluteString) == [
            "https://v.example.com/video.mp4",
            "https://v.example.com/video-backup.mp4"
        ])
        #expect(resource.userAgent == "test-agent")
    }

    @Test("Does not accept a different Douyin video from a captured response")
    func douyinDetailRejectsWrongVideo() {
        let payload = """
        {"aweme_detail":{"aweme_id":"1234567890","desc":"别的视频","video":{"play_addr":{"url_list":["https://example.com/a.mp4"]}}}}
        """
        #expect(DouyinVideoResolver.parse(
            payload: payload,
            videoID: "7588872042955427081",
            userAgent: "test-agent"
        ) == nil)
    }

    @Test("Completes the reported historical Bilibili rewrite without aborting on the quality gate")
    func liveHistoricalRewriteRegression() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_LIVE_REWRITE_TEST"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let speechModel = root.appending(path: "Models/ggml-small-q5_1.bin")
        let executable = root.appending(path: "Runtime/llama-b10015/llama-cli")
        let fastModel = root.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf")
        let enhancedModel = root.appending(path: "Models/qwen3-4b-q4_k_m.gguf")
        let extractor = SourceExtractor(transcriber: LocalSpeechTranscriber(modelURL: speechModel))
        let transcriptCache = URL(fileURLWithPath: "/tmp/chenggao-BV1LMNs6kESs-transcript.txt")
        let material: SourceMaterial
        if let transcript = try? String(contentsOf: transcriptCache, encoding: .utf8), transcript.count > 200 {
            material = SourceMaterial(
                title: "平民眼中的大明：四百年前的市井百态",
                transcript: transcript,
                origin: .localSpeechRecognition,
                durationSeconds: nil
            )
        } else {
            material = try await extractor.content(
                kind: .link,
                urlString: "https://www.bilibili.com/video/BV1LMNs6kESs",
                pastedText: ""
            )
            try? material.transcript.write(to: transcriptCache, atomically: true, encoding: .utf8)
        }
        let runtime = EmbeddedModelRuntime(
            assets: EmbeddedModelAssets(
                executableURL: executable,
                fastModelURL: fastModel,
                enhancedModelURL: enhancedModel
            )
        )
        let output = try await runtime.rewrite(
            material: material,
            style: .spoken,
            language: .simplifiedChinese,
            modelMode: .fast,
            onlineCorrection: false,
            contextLimit: 8_192,
            progress: { _ in }
        )
        #expect(!output.revisedBody.isEmpty)
        #expect(EmbeddedModelRuntime.rewriteSimilarity(
            original: output.originalTranscript,
            revised: output.revisedBody
        ) < 0.96)
        #expect(VisualShotPlanner.shots(for: output).count >= max(1, (material.durationSeconds ?? 4) / 5))
    }

    @Test("Processes long transcripts in multiple complete local-model chunks")
    func longLocalModelRewrite() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_LONG_MODEL_TEST"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = root.appending(path: "Runtime/llama-b10015/llama-cli")
        let model = root.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf")
        let runtime = EmbeddedModelRuntime(
            assets: EmbeddedModelAssets(executableURL: executable, modelURL: model)
        )
        let transcript = Array(repeating: "好的设计应该帮助玩家理解目标，同时保留探索空间。", count: 60)
            .joined(separator: "\n")
        let output = try await runtime.rewrite(
            material: SourceMaterial(title: "长口播测试", transcript: transcript, origin: .localSpeechRecognition, durationSeconds: 300),
            style: .spoken,
            language: .simplifiedChinese,
            modelMode: .fast,
            onlineCorrection: false
        )
        #expect(output.rawTranscript == transcript)
        #expect(output.suggestions.count > 1)
        #expect(!output.revisedBody.isEmpty)
    }

    @Test("Rewrites the reported news article with whole-document context and keeps the final response")
    func editorialNewsModelRegression() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_EDITORIAL_MODEL_TEST"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = EmbeddedModelRuntime(
            assets: EmbeddedModelAssets(
                executableURL: root.appending(path: "Runtime/llama-b10015/llama-cli"),
                fastModelURL: root.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf"),
                enhancedModelURL: root.appending(path: "Models/qwen3-4b-q4_k_m.gguf")
            )
        )
        let article = """
        CNN当地时间15日援引知情人士报道，特朗普的新“空军一号”被曝存在安全缺陷。消息泄露后，白宫幕僚长苏珊·怀尔斯和联邦调查局局长卡什·帕特尔牵头调查，多名官员被要求交出手机。帕特尔原计划前往芝加哥，但在10日被临时召至白宫。两人在白宫西翼设立“作战室”，停留约七个小时。调查人员还向参与北约峰会行程的多个机构官员索取信息和设备，并非所有官员都照做。白宫官员称，危及总统和随行人员安全的泄密属于国家安全威胁。

        特朗普前往土耳其参加北约峰会时乘坐由卡塔尔赠送、刚完成改装的新专机，但8日返美期间先乘旧“空军一号”前往英国米尔登霍尔空军基地，之后才换乘新专机。纽约时报援引匿名人士称，换机是应美国特勤局要求，因为新专机缺少旧专机的部分安全功能。特朗普否认换机与安全问题有关，白宫也否认新专机存在安全缺陷。纽约时报11日报道，参与相关报道的多名记者收到了传票。
        """
        let output = try await runtime.rewrite(
            material: SourceMaterial(
                title: "新专机安全争议引发泄密调查",
                transcript: article,
                origin: .webArticle,
                durationSeconds: nil
            ),
            style: .spoken,
            language: .simplifiedChinese,
            modelMode: .enhanced,
            onlineCorrection: false,
            contextLimit: 8_192,
            progress: { _ in }
        )
        #expect(output.revisedBody.contains("白宫"))
        #expect(output.revisedBody.contains("否认"))
        #expect(output.revisedBody.contains("纽约时报"))
        #expect(output.revisedBody.contains("特勤局"))
        #expect(EmbeddedModelRuntime.documentQualityIssues(
            original: article,
            revised: output.revisedBody,
            sourceOrigin: .webArticle,
            style: .spoken
        ).isEmpty)
    }

    @Test("Rewrites the user's latest real history instead of delivering a near copy")
    func latestHistoryStructuralRewriteRegression() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CHENGGAO_LATEST_HISTORY_MODEL_TEST"] == "1",
              let historyPath = environment["CHENGGAO_LIVE_HISTORY_PATH"],
              !historyPath.isEmpty else { return }
        let historyURL = URL(fileURLWithPath: historyPath)
        let data = try Data(contentsOf: historyURL)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let latest = try #require(records.max {
            ($0["createdAt"] as? Double ?? 0) < ($1["createdAt"] as? Double ?? 0)
        })
        let storedOutput = try #require(latest["output"] as? [String: Any])
        let transcript = try #require(storedOutput["rawTranscript"] as? String)
        let title = try #require(latest["title"] as? String)
        #expect(transcript.count > 1_000)

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = EmbeddedModelRuntime(
            assets: EmbeddedModelAssets(
                executableURL: root.appending(path: "Runtime/llama-b10015/llama-cli"),
                fastModelURL: root.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf"),
                enhancedModelURL: root.appending(path: "Models/qwen3-4b-q4_k_m.gguf")
            )
        )
        let output = try await runtime.rewrite(
            material: SourceMaterial(
                title: title,
                transcript: transcript,
                origin: .localSpeechRecognition,
                durationSeconds: nil
            ),
            style: .spoken,
            language: .simplifiedChinese,
            modelMode: .enhanced,
            onlineCorrection: false,
            contextLimit: 8_192,
            progress: { _ in }
        )
        let similarity = EmbeddedModelRuntime.rewriteSimilarity(
            original: output.originalTranscript,
            revised: output.revisedBody
        )
        print("latest-history structural rewrite similarity: \(similarity)")
        #expect(similarity < 0.90)
        #expect(output.notes.contains("全文结构重写") || output.notes.contains("全文统稿"))
    }

    @Test("Runs only the semantic-group structural pass on the user's latest history")
    func latestHistoryStructuralPassDiagnostic() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CHENGGAO_STRUCTURAL_MODEL_TEST"] == "1",
              let historyPath = environment["CHENGGAO_LIVE_HISTORY_PATH"],
              !historyPath.isEmpty else { return }
        let historyURL = URL(fileURLWithPath: historyPath)
        let data = try Data(contentsOf: historyURL)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let latest = try #require(records.max {
            ($0["createdAt"] as? Double ?? 0) < ($1["createdAt"] as? Double ?? 0)
        })
        let storedOutput = try #require(latest["output"] as? [String: Any])
        let transcript = try #require(storedOutput["rawTranscript"] as? String)
        let title = try #require(latest["title"] as? String)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let modelURL = root.appending(path: "Models/qwen3-4b-q4_k_m.gguf")
        let runtime = EmbeddedModelRuntime(
            assets: EmbeddedModelAssets(
                executableURL: root.appending(path: "Runtime/llama-b10015/llama-cli"),
                fastModelURL: root.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf"),
                enhancedModelURL: modelURL
            )
        )
        let blueprint = EmbeddedModelRuntime.parseBlueprint(
            "",
            sourceTitle: title,
            sourceText: transcript,
            style: .spoken,
            language: .simplifiedChinese
        )
        let rewritten = try await runtime.structuralRewriteDocument(
            original: transcript,
            sourceTitle: title,
            sourceOrigin: .localSpeechRecognition,
            style: .spoken,
            language: .simplifiedChinese,
            blueprint: blueprint,
            modelURL: modelURL,
            contextSize: 8_192,
            maximumOutputTokens: 2_400
        )
        let result = try #require(rewritten)
        #expect(EmbeddedModelRuntime.rewriteSimilarity(original: transcript, revised: result) < 0.90)
    }

    @Test("Defaults generated text to simplified Chinese")
    func simplifiedChineseOutput() {
        let raw = #"{"suggestion":"調整語氣與節奏","reason":"讓觀眾更容易閱讀","revised":"這是修改後的完整稿件。","imagePlacement":"這一段後面","imageSuggestion":"放置一張遊戲場景圖片"}"#
        let output = EmbeddedModelRuntime.parseChunk(
            raw,
            original: "原稿",
            language: .simplifiedChinese,
            index: 1
        )
        #expect(output.revised == "这是修改后的完整稿件。")
        #expect(output.suggestion.imageSuggestion.contains("游戏场景图片"))
    }

    @Test("Parse failure still returns an edited draft, not advice text")
    func fallbackEditedDraft() {
        let original = "嗯\n这是第一句\n然后呢\n这是第二句"
        let output = EmbeddedModelRuntime.parseChunk(
            "只给出修改建议，没有返回 JSON。",
            original: original,
            language: .simplifiedChinese,
            index: 1
        )
        #expect(output.revised != "只给出修改建议，没有返回 JSON。")
        #expect(output.revised.contains("这是第一句"))
        #expect(!output.revised.contains("修改建议"))
    }

    @Test("Records contextual homophone correction")
    func homophoneCorrection() {
        let raw = #"{"corrected":"太平天国领袖洪秀全在这里起事。","corrections":[{"original":"红秀全","corrected":"洪秀全","reason":"上下文明确指向太平天国领袖"}],"suggestion":"调整句式","reason":"口播更顺畅","revised":"说到太平天国，就绕不开领袖洪秀全。","imagePlacement":"洪秀全之后","imageSuggestion":"洪秀全历史画像"}"#
        let output = EmbeddedModelRuntime.parseChunk(raw, original: "太平天国领袖红秀全在这里起事。")
        #expect(output.corrected.contains("洪秀全"))
        #expect(output.corrections.first?.original == "红秀全")
        #expect(output.corrections.first?.corrected == "洪秀全")
    }

    @Test("A single local model behaves consistently across memory sizes")
    func automaticModelSelection() {
        let assets = EmbeddedModelAssets(
            executableURL: URL(fileURLWithPath: "/tmp/llama-cli"),
            fastModelURL: URL(fileURLWithPath: "/tmp/1.7b.gguf"),
            enhancedModelURL: URL(fileURLWithPath: "/tmp/4b.gguf")
        )
        #expect(EmbeddedModelRuntime.selectModel(assets: assets, mode: .automatic, physicalMemoryGB: 8).url.lastPathComponent == "1.7b.gguf")
        #expect(EmbeddedModelRuntime.selectModel(assets: assets, mode: .automatic, physicalMemoryGB: 16).url.lastPathComponent == "1.7b.gguf")
        #expect(EmbeddedModelRuntime.selectModel(assets: assets, mode: .enhanced, physicalMemoryGB: 8).label.contains("保护模式"))
        #expect(EmbeddedModelRuntime.selectModel(
            assets: assets,
            mode: .enhanced,
            physicalMemoryGB: 8,
            requestedContextSize: 8_192
        ).contextSize == 4_096)
        #expect(EmbeddedModelRuntime.selectModel(
            assets: assets,
            mode: .enhanced,
            physicalMemoryGB: 16,
            requestedContextSize: 8_192
        ).contextSize == 8_192)
    }

    @Test("Generation budget scales with context and model while protecting small Macs")
    func adaptiveGenerationBudget() {
        #expect(EmbeddedModelRuntime.generationPlan(
            contextSize: 4_096,
            usesEnhancedModel: false
        ) == RewriteGenerationPlan(maximumCharactersPerCard: 700, maximumOutputTokens: 1_600))
        #expect(EmbeddedModelRuntime.generationPlan(
            contextSize: 8_192,
            usesEnhancedModel: false
        ) == RewriteGenerationPlan(maximumCharactersPerCard: 900, maximumOutputTokens: 2_000))
        #expect(EmbeddedModelRuntime.generationPlan(
            contextSize: 8_192,
            usesEnhancedModel: true
        ) == RewriteGenerationPlan(maximumCharactersPerCard: 1_200, maximumOutputTokens: 2_400))
        #expect(EmbeddedModelRuntime.generationPlan(
            contextSize: 4_096,
            usesEnhancedModel: true
        ).maximumOutputTokens == 1_600)
    }

    @Test("Rejects unchanged article drafts and image advice in the editing field")
    func outputQualityGate() {
        let original = "人工智能正在改变内容生产方式，但工具的价值不在于替代人的判断。过去，编辑需要花大量时间整理录音、修正错别字和重新组织段落。真正有效的工作流，是让机器完成重复工作，让人负责事实与观点。"
        let bad = ParsedRewriteChunk(
            corrected: original,
            corrections: [],
            suggestion: RevisionSuggestion(
                original: original,
                suggestion: "建议第一句后放置一张人工智能图片，第四句前放置工作画面。",
                reason: "图片可以说明场景，画面可以帮助理解。",
                imagePlacement: "第一句后",
                imageSuggestion: "人工智能工作场景"
            ),
            revised: original
        )
        let issues = EmbeddedModelRuntime.qualityIssues(in: bad, original: original, style: .article)
        #expect(issues.contains("只调整了简繁、标点或少量措辞，没有完成实质改写"))
        #expect(issues.contains("修改建议误写成配图建议"))
    }

    @Test("Treats simplified conversion and punctuation changes as an unchanged draft")
    func scriptConversionIsNotARewrite() {
        let traditional = "這是一段沒有真正改寫的原稿內容，只把繁體轉成簡體，再把換行改成標點。這樣的結果不能當作修改稿交付給使用者。"
        let simplified = "这是一段没有真正改写的原稿内容，只把繁体转成简体，再把换行改成标点。这样的结果不能当作修改稿交付给使用者。"
        let result = ParsedRewriteChunk(
            corrected: simplified,
            corrections: [],
            suggestion: RevisionSuggestion(
                original: traditional,
                suggestion: "调整表达",
                reason: "提高可读性",
                imagePlacement: "段后",
                imageSuggestion: "画面"
            ),
            revised: simplified
        )
        #expect(EmbeddedModelRuntime.qualityIssues(in: result, original: traditional, style: .spoken)
            .contains("只调整了简繁、标点或少量措辞，没有完成实质改写"))
    }

    @Test("Uses a strict improvement target but allows a safe final delivery threshold")
    func twoLevelRewriteThreshold() {
        let original = "很多人以为这场变化来自外部压力，但真正影响局势的是内部利益重新分配。不同群体在同一时间作出了不同选择，最后共同推动了结果。"
        let revised = "很多人认为这场变化来自外部压力，但真正左右局势的是内部利益重新分配。不同群体在同一时间作出了不同选择，最终共同推动了结果。"
        let result = ParsedRewriteChunk(
            corrected: original,
            corrections: [],
            suggestion: RevisionSuggestion(
                original: original,
                suggestion: "重组句式",
                reason: "增强节奏",
                imagePlacement: "段后",
                imageSuggestion: "画面"
            ),
            revised: revised
        )
        #expect(!EmbeddedModelRuntime.qualityIssues(in: result, original: original, style: .spoken).isEmpty)
        #expect(EmbeddedModelRuntime.qualityIssues(
            in: result,
            original: original,
            style: .spoken,
            similarityThreshold: 0.96
        ).isEmpty)
    }

    @Test("Plans one short-video visual every three to five seconds")
    func shortVideoShotCadence() {
        let output = RewriteOutput(
            title: "历史口播",
            rawTranscript: "原稿",
            originalTranscript: "原稿",
            corrections: [],
            suggestions: [],
            revisedBody: String(repeating: "清朝末年的社会变化推动局势发展。", count: 20),
            notes: "",
            transcriptOrigin: .platformSubtitle,
            style: .spoken,
            durationSeconds: 40
        )
        let shots = VisualShotPlanner.shots(for: output)
        #expect(shots.count == 10)
        #expect(shots.first?.timecode == "00:00–00:04")
        #expect(shots.last?.timecode == "00:36–00:40")
        #expect(shots.allSatisfy { $0.prompt.contains("9:16 竖版") })
        #expect(shots.allSatisfy { !$0.spokenContext.isEmpty })
    }

    @Test("Exports every visual prompt as an executable ChatGPT Markdown task list")
    func chatGPTImageBatchMarkdown() {
        let shots = [
            VisualShot(
                id: 0,
                timecode: "图文 1 · 封面",
                spokenContext: "第一张对应文案",
                prompt: "第一张完整提示词",
                generatedImagePath: "/private/tmp/already-generated.png"
            ),
            VisualShot(
                id: 1,
                timecode: "图文 2",
                spokenContext: "第二张对应文案",
                prompt: "第二张完整提示词"
            )
        ]
        let output = RewriteOutput(
            title: "测试图文", rawTranscript: "原稿", originalTranscript: "原稿",
            corrections: [], suggestions: [], revisedBody: "成稿", notes: "",
            transcriptOrigin: .socialImageText, style: .social, visualShots: shots
        )

        let markdown = ChatGPTImageBatchDocument.render(output: output)

        #expect(markdown.contains("# 测试图文｜ChatGPT 批量生图任务"))
        #expect(markdown.contains("共 2 张图片、1 批，每批最多 10 张"))
        #expect(markdown.contains("禁止把多个编号合并成拼图"))
        #expect(markdown.contains("首次读取本文档时只执行第 1 批"))
        #expect(markdown.contains("- 统一比例：3:4 竖版"))
        #expect(markdown.contains("- [ ] 图片 01"))
        #expect(markdown.contains("- [ ] 图片 02"))
        #expect(markdown.contains("## 第 1 批｜图片 01–02"))
        #expect(markdown.contains("### 图片 01｜图文 1 · 封面"))
        #expect(markdown.contains("> 第一张对应文案"))
        #expect(markdown.contains("> 第一张完整提示词"))
        #expect(markdown.contains("> 第二张完整提示词"))
        #expect(!markdown.contains("/private/tmp/already-generated.png"))
    }

    @Test("Splits ChatGPT image tasks into explicit groups of ten")
    func chatGPTImageBatchBoundaries() {
        let shots = (0..<12).map { index in
            VisualShot(
                id: index,
                timecode: "镜头 \(index + 1)",
                spokenContext: "文案 \(index + 1)",
                prompt: "提示词 \(index + 1)"
            )
        }
        let output = RewriteOutput(
            title: "十二张配图", rawTranscript: "原稿", originalTranscript: "原稿",
            corrections: [], suggestions: [], revisedBody: "成稿", notes: "",
            transcriptOrigin: .platformSubtitle, style: .spoken, visualShots: shots
        )

        let markdown = ChatGPTImageBatchDocument.render(output: output)

        #expect(markdown.contains("共 12 张图片、2 批，每批最多 10 张"))
        #expect(markdown.contains("- [ ] 第 1 批：图片 01–10（10 张；首次读取自动执行）"))
        #expect(markdown.contains("- [ ] 第 2 批：图片 11–12（2 张；口令：继续第 2 批）"))
        #expect(markdown.contains("## 第 1 批｜图片 01–10"))
        #expect(markdown.contains("## 第 2 批｜图片 11–12"))
        #expect(markdown.contains("第 1 批已完成（图片 01–10）。请回复：继续第 2 批。"))
        #expect(markdown.contains("全部 12 张图片已完成。"))
        #expect(markdown.components(separatedBy: "\n### 图片 ").count - 1 == 12)
    }

    @Test("Sanitizes the default Markdown export filename")
    func chatGPTImageBatchFilename() {
        let output = RewriteOutput(
            title: "测试/标题:版本?", rawTranscript: "原稿", originalTranscript: "原稿",
            corrections: [], suggestions: [], revisedBody: "成稿", notes: "",
            transcriptOrigin: .pastedText, style: .spoken,
            visualShots: [VisualShot(id: 0, timecode: "00:00–00:04", spokenContext: "文案", prompt: "提示词")]
        )

        #expect(
            ChatGPTImageBatchDocument.suggestedDocumentFilename(for: output)
                == "测试-标题-版本-ChatGPT-批量生图.md"
        )
    }

    @Test("Estimates a dense shot list for legacy short-video history")
    func legacyShotCadenceEstimate() {
        let output = RewriteOutput(
            title: "旧记录",
            rawTranscript: "原稿",
            originalTranscript: "原稿",
            corrections: [],
            suggestions: [],
            revisedBody: String(repeating: "这是历史口播内容", count: 100),
            notes: "",
            transcriptOrigin: .localSpeechRecognition,
            style: .spoken
        )
        #expect(VisualShotPlanner.shots(for: output).count > 30)
    }

    @Test("AI visual prompt parser keeps timing but replaces generic templates with concrete scenes")
    func visualPromptDesignParsing() throws {
        let planned = [
            VisualShot(id: 0, timecode: "00:00–00:04", spokenContext: "AI 改变内容工作流", prompt: "基础镜头"),
            VisualShot(id: 1, timecode: "00:04–00:08", spokenContext: "人需要学会提问", prompt: "基础镜头")
        ]
        let raw = #"{"shots":[{"id":0,"prompt":"9:16竖版，年轻编辑在深色工作台前拖动AI流程节点，桌面摆放麦克风与分镜便签，中近景侧后方视角，三分法构图，屏幕冷光与暖色软光对比，蓝橙配色，写实电影感，禁止水印与乱码文字。"},{"id":1,"prompt":"9:16竖版，同一名编辑站在白板前写下三个层层递进的问号，旁边的团队成员凝神思考，全景平视，对角线构图，窗边自然光加顶部软光，米白与青绿色调，纪实摄影风格，禁止水印与多余手指。"}]}"#
        let result = VisualPromptDesigner.applying(
            rawResponse: raw,
            to: planned,
            language: .simplifiedChinese
        )
        #expect(result.designedCount == 2)
        #expect(result.shots[0].timecode == planned[0].timecode)
        #expect(result.shots[1].spokenContext == planned[1].spokenContext)
        #expect(result.shots[0].prompt != result.shots[1].prompt)
        #expect(!result.shots[0].prompt.contains("呈现本段"))
    }

    @Test("Repairs literal newlines in local-model visual JSON")
    func visualPromptDesignRepairsMultilineJSON() {
        let planned = [
            VisualShot(id: 0, timecode: "00:00–00:04", spokenContext: "AI 改变工作流", prompt: "基础镜头")
        ]
        let raw = """
        Assistant:
        {"shots":[{"id":0,"prompt":"9:16 竖版，年轻编辑站在铺满便签的深色工作台前，双手拖动屏幕中的 AI 流程节点，
        背景有麦克风和分镜草图，中近景侧拍，三分法构图，屏幕冷光与桌灯暖光对比，蓝橙色调，写实电影感，不要文字、水印或界面元素。"}]}
        """
        let result = VisualPromptDesigner.applying(
            rawResponse: raw,
            to: planned,
            language: .simplifiedChinese
        )
        #expect(result.designedCount == 1)
        #expect(result.shots[0].prompt.contains("三分法构图"))
    }

    @Test("Old history JSON remains readable before AI visual fields existed")
    func legacyOutputDecoding() throws {
        let json = #"{"title":"旧记录","rawTranscript":"原稿","originalTranscript":"原稿","corrections":[],"suggestions":[],"revisedBody":"修改稿","notes":"","transcriptOrigin":"pastedText","style":"短视频口播"}"#
        let output = try JSONDecoder().decode(RewriteOutput.self, from: Data(json.utf8))
        #expect(output.visualShots == nil)
        #expect(output.visualDesignSource == nil)
    }

    @Test("处理结果工作区位于新建文稿和爆款研究之间")
    func workspaceResultOrder() {
        #expect(WorkspaceSection.allCases == [.compose, .results, .research, .accounts, .history])
    }

    @Test("Generates a useful title for pasted material")
    func generatedPastedTitle() {
        let material = SourceMaterial(
            title: "粘贴文稿",
            transcript: "原稿",
            origin: .pastedText,
            durationSeconds: nil
        )
        let title = EmbeddedModelRuntime.outputTitle(
            for: material,
            revisedBody: "本地人工智能正在重新定义内容工作流。下一段内容。"
        )
        #expect(title == "本地人工智能正在重新定义内容工作流")
    }

    @Test("Store shares persisted settings and keeps history across launches")
    @MainActor
    func storePersistence() async throws {
        let suite = "ChengGaoTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyURL = FileManager.default.temporaryDirectory
            .appending(path: "chenggao-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: historyURL) }

        let first = RewriteStore(
            pipeline: StubPipeline(),
            visualPromptGenerator: StubVisualPromptGenerator(),
            extractor: StubExtractor(),
            defaults: defaults,
            historyURL: historyURL
        )
        first.selectModelMode(.enhanced)
        first.onlineTerminologyCheck = true
        #expect(defaults.string(forKey: "modelMode") == ModelMode.onlinePreferred.rawValue)
        #expect(defaults.bool(forKey: "onlineTerminologyCheck"))

        first.sourceText = "需要保存的原稿"
        first.startRewrite()
        for _ in 0..<50 where first.isProcessing {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(first.history.count == 1)
        #expect(first.hasUnreadResult)
        #expect(first.latestResultOutput?.visualDesignSource == .localAI)
        #expect(first.selectedSection == .compose)
        first.openLatestResult()
        #expect(first.selectedSection == .results)
        #expect(!first.hasUnreadResult)

        let second = RewriteStore(
            pipeline: StubPipeline(),
            extractor: StubExtractor(),
            defaults: defaults,
            historyURL: historyURL
        )
        #expect(second.modelMode == .onlinePreferred)
        #expect(second.contextLimit == 16_384)
        #expect(second.onlineTerminologyCheck)
        #expect(second.history.first?.title == "可识别的历史标题")
    }

    @Test("编辑后的成稿标题和正文会写回历史")
    @MainActor
    func editedDraftPersists() async throws {
        let suite = "ChengGaoTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyURL = FileManager.default.temporaryDirectory
            .appending(path: "chenggao-edited-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: historyURL) }

        let store = RewriteStore(
            pipeline: StubPipeline(), visualPromptGenerator: StubVisualPromptGenerator(),
            extractor: StubExtractor(), defaults: defaults, historyURL: historyURL
        )
        store.sourceText = "需要编辑的原稿"
        store.startRewrite()
        for _ in 0..<50 where store.isProcessing {
            try await Task.sleep(for: .milliseconds(20))
        }
        let historyID = try #require(store.history.first?.id)
        store.saveEditedDraft(title: "人工修改的标题", revisedBody: "这是人工修改并保存后的完整成稿。", historyID: historyID)
        #expect(store.history.first?.title == "人工修改的标题")
        #expect(store.history.first?.output.revisedBody == "这是人工修改并保存后的完整成稿。")

        let reloaded = RewriteStore(
            pipeline: StubPipeline(), extractor: StubExtractor(),
            defaults: defaults, historyURL: historyURL
        )
        #expect(reloaded.history.first?.title == "人工修改的标题")
        #expect(reloaded.history.first?.output.notes.contains("用户手动编辑") == true)
    }

    @Test("Link mode requires a link instead of stale editor text")
    @MainActor
    func linkInputValidation() {
        let store = RewriteStore()
        store.sourceText = "这是一段旧的粘贴内容"
        store.sourceKind = .link
        store.sourceURL = ""
        #expect(!store.canProcess)
        store.sourceURL = "https://example.com/article"
        #expect(store.canProcess)
    }

    @Test("Link mode recovers a URL pasted into the legacy large editor")
    @MainActor
    func legacyLinkInputRecovery() {
        let store = RewriteStore()
        store.sourceKind = .link
        store.sourceURL = ""
        store.sourceText = "分享标题 https://mp.weixin.qq.com/s/example"
        #expect(store.validSourceURL == "https://mp.weixin.qq.com/s/example")
        #expect(store.canProcess)
    }

    @Test("Research results preserve a three-to-one side-by-side ratio")
    @MainActor
    func compactResearchColumns() {
        #expect(ResearchView.resultsListFraction == 0.75)
        #expect(ResearchView.detailsFraction == 0.25)
        #expect(ResearchView.resultsListFraction / ResearchView.detailsFraction == 3)
        #expect(ResearchView.resultsListFraction + ResearchView.detailsFraction == 1)
    }

    @Test("Legacy model choices migrate to online-only mode")
    @MainActor
    func legacyModelModesMigrateOnline() {
        #expect(ModelMode.allCases == [.onlinePreferred])
        #expect(RewriteStore.resolvedModelMode(.onlinePreferred, hasOnlineKey: false) == .onlinePreferred)
        #expect(RewriteStore.resolvedModelMode(.onlinePreferred, hasOnlineKey: true) == .onlinePreferred)
        #expect(RewriteStore.resolvedModelMode(.fast, hasOnlineKey: false) == .onlinePreferred)
        #expect(RewriteStore.resolvedModelMode(.automatic, hasOnlineKey: false) == .onlinePreferred)
    }

    @Test("Processing can be cancelled without producing an error card")
    @MainActor
    func processingCancellation() async throws {
        let store = RewriteStore(pipeline: SlowStubPipeline(), extractor: StubExtractor())
        store.sourceText = "需要停止的长文稿"
        store.startRewrite()
        try await Task.sleep(for: .milliseconds(50))
        store.cancelProcessing()
        for _ in 0..<50 where store.isProcessing {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isProcessing)
        #expect(store.statusMessage == "处理已停止")
        #expect(store.errorMessage == nil)
        #expect(store.output == nil)
    }

    @Test("Enhanced model corrects a contextual historical homophone")
    func enhancedHomophoneSmokeTest() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_ENHANCED_MODEL_TEST"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = root.appending(path: "Runtime/llama-b10015/llama-cli")
        let fast = root.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf")
        let enhanced = root.appending(path: "Models/qwen3-4b-q4_k_m.gguf")
        let runtime = EmbeddedModelRuntime(
            assets: EmbeddedModelAssets(
                executableURL: executable,
                fastModelURL: fast,
                enhancedModelURL: enhanced
            )
        )
        let output = try await runtime.rewrite(
            material: SourceMaterial(
                title: "太平天国历史人物",
                transcript: "太平天国的领袖红秀全在近代史上留下了深刻影响。",
                origin: .localSpeechRecognition,
                durationSeconds: 8
            ),
            style: .spoken,
            language: .simplifiedChinese,
            modelMode: .enhanced,
            onlineCorrection: false
        )
        #expect(output.originalTranscript.contains("洪秀全"))
        #expect(output.corrections.contains { $0.original == "红秀全" && $0.corrected == "洪秀全" })
    }

    @Test("Eight GB fast model produces a real article rewrite that passes the quality gate")
    func fastArticleQualitySmokeTest() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_QUALITY_MODEL_TEST"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = root.appending(path: "Runtime/llama-b10015/llama-cli")
        let fast = root.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf")
        let enhanced = root.appending(path: "Models/qwen3-4b-q4_k_m.gguf")
        let runtime = EmbeddedModelRuntime(
            memoryBudget: MemoryBudget(
                physicalMemoryGB: 8,
                modelWeightMB: 1_400,
                contextCacheMB: 520,
                workingBufferMB: 780
            ),
            assets: EmbeddedModelAssets(
                executableURL: executable,
                fastModelURL: fast,
                enhancedModelURL: enhanced
            )
        )
        let original = "人工智能正在改变内容生产方式，但工具的价值不在于替代人的判断。过去，编辑需要花大量时间整理录音、修正错别字和重新组织段落。现在，本地模型可以承担这些重复工作。不过，模型仍然可能误解专有名词、遗漏限定条件，甚至生成看似合理但并不存在的信息。因此，最终发布前必须由人复核事实。真正有效的工作流，是让机器完成提取、初步校对和结构整理，让人把精力放在观点、事实与表达责任上。"
        let output = try await runtime.rewrite(
            material: SourceMaterial(title: "粘贴文稿", transcript: original, origin: .pastedText, durationSeconds: nil),
            style: .article,
            language: .simplifiedChinese,
            modelMode: .fast,
            onlineCorrection: false
        )
        #expect(EmbeddedModelRuntime.qualityIssues(
            in: ParsedRewriteChunk(
                corrected: output.originalTranscript,
                corrections: output.corrections,
                suggestion: try #require(output.suggestions.first),
                revised: output.revisedBody
            ),
            original: original,
            style: .article
        ).isEmpty)
        #expect(output.revisedBody != original)
        #expect(output.title != "粘贴文稿")
    }

    @Test("Cancels a running llama process instead of waiting for generation to finish")
    func realModelCancellation() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_CANCEL_MODEL_TEST"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = root.appending(path: "Runtime/llama-b10015/llama-cli")
        let fast = root.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf")
        let runtime = EmbeddedModelRuntime(
            assets: EmbeddedModelAssets(executableURL: executable, modelURL: fast)
        )
        let material = SourceMaterial(
            title: "取消测试",
            transcript: Array(repeating: "这是一段需要较长时间处理的内容。", count: 100).joined(),
            origin: .pastedText,
            durationSeconds: nil
        )
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await runtime.rewrite(
                material: material,
                style: .article,
                language: .simplifiedChinese,
                modelMode: .fast,
                onlineCorrection: false
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消后不应返回正常结果")
        } catch is CancellationError {
            // Expected.
        }
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    @Test("Online terminology check verifies only the proposed proper noun")
    func onlineTerminologyVerification() async {
        guard ProcessInfo.processInfo.environment["CHENGGAO_TERMINOLOGY_LIVE_TEST"] == "1" else { return }
        let verifier = WikipediaTerminologyVerifier()
        let input = [TranscriptCorrection(
            original: "红秀全",
            corrected: "洪秀全",
            reason: "太平天国领袖"
        )]
        let result = await verifier.verify(input)
        #expect(result.first?.verification == .onlineVerified)
    }

    @Test("Research hot score rewards engagement and freshness")
    func researchHotScore() {
        let recent = ResearchContent.score(
            views: 100_000, likes: 5_000, comments: 500, collects: 300, shares: 200,
            publishedAt: .now.addingTimeInterval(-86_400)
        )
        let old = ResearchContent.score(
            views: 100_000, likes: 5_000, comments: 500, collects: 300, shares: 200,
            publishedAt: .now.addingTimeInterval(-180 * 86_400)
        )
        let shared = ResearchContent.score(
            views: 100_000, likes: 5_000, comments: 500, collects: 300, shares: 2_000,
            publishedAt: .now.addingTimeInterval(-86_400)
        )
        #expect(recent > old)
        #expect(shared > recent)
    }

    @Test("研究指标不把缺失的日期或零值冒充为高信度")
    func researchMetricConfidence() {
        let knownRecent = ResearchContent.score(
            views: 100_000, likes: 5_000, comments: 500, collects: 300, shares: 200,
            publishedAt: .now.addingTimeInterval(-86_400)
        )
        let unknownDate = ResearchContent.score(
            views: 100_000, likes: 5_000, comments: 500, collects: 300, shares: 200,
            publishedAt: nil
        )
        #expect(knownRecent > unknownDate)
        #expect(ResearchContent.trustedMetric(0) == nil)
        #expect(ResearchContent.trustedMetric(42) == 42)

        let sparse = ResearchContent(
            id: "sparse", platform: .douyin, platformContentID: "1", keyword: "测试",
            title: "指标不完整", description: nil, authorName: nil, authorURL: nil,
            contentURL: URL(string: "https://example.com/1")!, coverURL: nil,
            publishedAt: nil, durationSeconds: nil, viewCount: 0, likeCount: 200,
            commentCount: nil, collectCount: nil, shareCount: nil,
            hotScore: 1, collectedAt: .now
        )
        #expect(sparse.metricConfidence == .low)
    }

    @Test("平台搜索状态会区分公开、需登录和仅链接")
    @MainActor
    func researchPlatformStates() {
        let store = ResearchStore(databaseURL: FileManager.default.temporaryDirectory
            .appending(path: "research-state-\(UUID().uuidString).sqlite3"))
        #expect(store.searchState(for: .bilibili) == .ready("公开搜索"))
        #expect(store.searchState(for: .x) == .loginRequired)
        #expect(store.searchState(for: .wechatChannels) == .manualLinkOnly)
        store.finishLogin(.x, detected: true)
        #expect(store.searchState(for: .x) == .ready("已登录"))
    }

    @Test("Normalizes a Bilibili search result into a ranked content record")
    func bilibiliResearchNormalization() throws {
        let item: [String: Any] = [
            "bvid": "BV1gZSEBcERU",
            "title": "<em class=\"keyword\">香港身份</em>怎么了？",
            "author": "测试作者",
            "mid": 123,
            "pic": "//example.com/cover.jpg",
            "play": "12.5万",
            "video_review": 321,
            "favorites": 456,
            "pubdate": Int(Date().timeIntervalSince1970),
            "duration": "03:21"
        ]
        let value = try #require(ResearchSearchService.bilibiliContent(item, keyword: "香港身份"))
        #expect(value.platform == .bilibili)
        #expect(value.viewCount == 125_000)
        #expect(value.durationSeconds == 201)
        #expect(value.title == "香港身份怎么了？")
        #expect(value.hotScore > 0)
    }

    @Test("Bilibili research adapter searches and ranks a mocked public response")
    func bilibiliResearchAdapter() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OpenRouterStubURLProtocol.responseData = Data("""
        {"code":0,"data":{"result":[
          {"bvid":"BV1gZSEBcERU","title":"香港身份 A","author":"甲","mid":1,"pic":"//example.com/a.jpg","play":200000,"video_review":2000,"favorites":1000,"pubdate":\(Int(Date().timeIntervalSince1970)),"duration":"05:00"},
          {"bvid":"BV13Kj169ETG","title":"香港身份 B","author":"乙","mid":2,"pic":"//example.com/b.jpg","play":1000,"video_review":10,"favorites":5,"pubdate":\(Int(Date().timeIntervalSince1970)),"duration":"01:00"}
        ]}}
        """.utf8)
        let service = ResearchSearchService(
            session: session, youtubeAPIKey: { nil }, preferBilibiliHTML: false
        )
        let outcome = try await service.search(
            input: ResearchSearchInput(keyword: "香港医药", platforms: [.bilibili], maxItems: 20, recentDays: 30),
            progress: { _, _, _ in }
        )
        #expect(outcome.contents.count == 2)
        #expect(outcome.contents.first?.title == "香港身份 A")
        #expect(outcome.warnings.isEmpty)
    }

    @Test("Bilibili search page is a safe fallback when the JSON edge is blocked")
    func bilibiliHTMLFallback() throws {
        let html = """
        <div class="bili-video-card__wrap"><a href="//www.bilibili.com/video/BV1gZSEBcERU/">
        <img src="//example.com/cover.jpg" alt="香港身份"></a>
        <span class="bili-video-card__stats--item"><svg></svg><span>5.6万</span></span>
        <span class="bili-video-card__stats__duration">17:01</span>
        <h3 class="bili-video-card__info--tit" title="香港身份怎么了？"></h3>
        <a class="bili-video-card__info--owner" href="//space.bilibili.com/1">
        <span class="bili-video-card__info--author">测试作者</span>
        <span class="bili-video-card__info--date"> · 2026-07-15</span></a></div>
        """
        let value = try #require(ResearchSearchService.bilibiliContents(fromHTML: html, keyword: "香港身份").first)
        #expect(value.viewCount == 56_000)
        #expect(value.durationSeconds == 1_021)
        #expect(value.authorName == "测试作者")
        #expect(value.publishedAt != nil)
    }

    @Test("External search process drains responses larger than the pipe buffer")
    func externalSearchProcessDrainsLargeOutput() async throws {
        let data = try await ResearchSearchService.processData(
            executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "30000"]
        )
        #expect(data.count > 65_536)
        #expect(String(decoding: data.suffix(6), as: UTF8.self).contains("30000"))
    }

    @MainActor
    @Test("Unavailable selections do not block a ready public platform")
    func unavailablePlatformDoesNotBlockPublicSearch() async {
        let service = ResearchSearchStub(contents: [ResearchContent(
            id: "bilibili:test", platform: .bilibili, platformContentID: "test",
            keyword: "香港医药", title: "公共搜索结果", description: nil,
            authorName: nil, authorURL: nil,
            contentURL: URL(string: "https://www.bilibili.com/video/BV1testtest1")!,
            coverURL: nil, publishedAt: .now, durationSeconds: nil,
            viewCount: 1_000, likeCount: nil, commentCount: nil,
            collectCount: nil, shareCount: nil, hotScore: 1, collectedAt: .now
        )])
        let store = ResearchStore(
            searchService: service,
            databaseURL: FileManager.default.temporaryDirectory
                .appending(path: "research-ready-\(UUID().uuidString).sqlite3")
        )
        try? await Task.sleep(for: .milliseconds(50))
        store.keyword = "香港医药"
        store.selectedPlatforms = [.bilibili, .x]
        store.startSearch()
        while store.isSearching { await Task.yield() }
        #expect(store.results.count == 1)
        #expect(store.warningMessage?.contains("已跳过尚未就绪的平台") == true)
        #expect(store.loginPlatform == nil)
    }

    @Test("Bilibili relative search dates stay inside the requested recent window")
    func bilibiliRelativeSearchDates() throws {
        let now = try #require(ResearchSearchService.isoDate("2026-07-16T12:00:00Z"))
        let yesterday = try #require(ResearchSearchService.parseBilibiliSearchDate("昨天", now: now))
        let hoursAgo = try #require(ResearchSearchService.parseBilibiliSearchDate("7小时前", now: now))
        let monthDay = try #require(ResearchSearchService.parseBilibiliSearchDate("07-06", now: now))
        #expect(now.timeIntervalSince(yesterday) < 2 * 86_400)
        #expect(now.timeIntervalSince(hoursAgo) < 8 * 3_600)
        #expect(Calendar(identifier: .gregorian).component(.year, from: monthDay) == 2026)
    }

    @Test("Logged-in platforms use the rendered browser search path")
    func loggedInBrowserResearchPlatforms() async throws {
        let service = ResearchSearchService(youtubeAPIKey: { nil }) { platform, keyword, _, _ in
            let url = platform == .tiktok
                ? URL(string: "https://www.tiktok.com/@creator/video/123")!
                : URL(string: "https://www.douyin.com/video/456")!
            return [ResearchContent(
                id: "\(platform.rawValue):test", platform: platform, platformContentID: "test",
                keyword: keyword, title: "网页登录结果", description: nil,
                authorName: "测试作者", authorURL: nil, contentURL: url, coverURL: nil,
                publishedAt: nil, durationSeconds: nil, viewCount: 10_000, likeCount: 500,
                commentCount: 20, collectCount: nil, shareCount: nil,
                hotScore: 10, collectedAt: .now
            )]
        }
        let outcome = try await service.search(
            input: ResearchSearchInput(
                keyword: "香港身份", platforms: [.tiktok, .douyin], maxItems: 20, recentDays: 30
            ),
            progress: { _, _, _ in }
        )
        #expect(outcome.contents.count == 2)
        #expect(Set(outcome.contents.map(\.platform)) == Set([.tiktok, .douyin]))
        #expect(outcome.warnings.isEmpty)
    }

    @Test("Rendered browser results are normalized without inventing missing metrics")
    func renderedBrowserResearchNormalization() throws {
        let payload = """
        [{"url":"https://www.youtube.com/watch?v=abc123","title":"香港身份分析","coverURL":"https://i.ytimg.com/vi/abc123/hqdefault.jpg","author":"测试频道","context":"香港身份分析 12万 views 3,200 likes 480 comments"}]
        """
        let value = try #require(WebKitResearchSearchService.renderedContents(
            payload: payload, platform: .youtube, keyword: "香港身份", maxItems: 20, recentDays: 30
        ).first)
        #expect(value.platformContentID == "abc123")
        #expect(value.viewCount == 120_000)
        #expect(value.likeCount == 3_200)
        #expect(value.commentCount == 480)
        #expect(value.collectCount == nil)
    }

    @Test("Douyin modal search links and hydrated metrics become canonical video results")
    func douyinRenderedSearchNormalization() throws {
        let payload = """
        [{"url":"https://www.douyin.com/search/斩杀线?type=video&modal_id=7523456789012345678","title":"斩杀线到底意味着什么","coverURL":"https://p3.douyinpic.com/sample.jpeg","author":"测试作者","context":"斩杀线到底意味着什么","viewCount":126000,"likeCount":8200,"commentCount":430,"collectCount":915,"shareCount":211}]
        """
        let value = try #require(WebKitResearchSearchService.renderedContents(
            payload: payload, platform: .douyin, keyword: "斩杀线", maxItems: 20, recentDays: 30
        ).first)
        #expect(value.platformContentID == "7523456789012345678")
        #expect(value.contentURL.absoluteString == "https://www.douyin.com/video/7523456789012345678")
        #expect(value.viewCount == 126_000)
        #expect(value.likeCount == 8_200)
        #expect(value.collectCount == 915)
        #expect(value.shareCount == 211)
    }

    @Test("Douyin captured network responses become canonical video results")
    func douyinCapturedResponseNormalization() throws {
        let body = #"""
        {"data":{"aweme_list":[{"aweme_id":"7523456789012345678","desc":"斩杀线为什么突然火了","author":{"nickname":"测试作者"},"video":{"cover":{"url_list":["https://p3.douyinpic.com/network.jpeg"]}},"statistics":{"play_count":126000,"digg_count":8200,"comment_count":430,"collect_count":915,"share_count":211},"music":{"id_str":"998877665544332211","title":"测试作者创作的原声"}}]}}
        """#
        let payload = String(decoding: try JSONEncoder().encode([body]), as: UTF8.self)
        let values = WebKitResearchSearchService.capturedResponseContents(
            payload: payload, platform: .douyin, keyword: "斩杀线", maxItems: 20, recentDays: 30
        )
        #expect(values.count == 1)
        let value = try #require(values.first)
        #expect(value.platformContentID == "7523456789012345678")
        #expect(value.title == "斩杀线为什么突然火了")
        #expect(value.authorName == "测试作者")
        #expect(value.coverURL?.absoluteString == "https://p3.douyinpic.com/network.jpeg")
        #expect(value.viewCount == 126_000)
        #expect(value.likeCount == 8_200)
        #expect(value.commentCount == 430)
    }

    @MainActor
    @Test("Hidden research WebViews cannot start audible media automatically")
    func backgroundResearchMediaIsSilent() {
        let session = PlatformWebSession(platform: .douyin)
        #expect(session.webView.configuration.mediaTypesRequiringUserActionForPlayback == .all)
        #expect(PlatformWebSession.mediaSilencingScript.contains("element.muted = true"))
        #expect(PlatformWebSession.mediaSilencingScript.contains("MutationObserver"))
        #expect(PlatformWebSession.searchResponseCaptureScript.contains("priority: priority(url)"))
        #expect(WebKitResearchSearchService.capturedBodiesScript.contains("right.priority"))
    }

    @Test("Douyin capture reads video records nested inside encoded JSON strings")
    func douyinEmbeddedCapturedResponseNormalization() throws {
        let embedded = #"{"aweme_id":"7523456789012345678","desc":"隐藏字符串里的抖音结果","author":{"nickname":"测试作者"},"video":{"cover":{"url_list":["https://p3.douyinpic.com/embedded.jpeg"]}},"statistics":{"digg_count":3200}}"#
        let bodyData = try JSONSerialization.data(withJSONObject: ["payload": embedded])
        let body = String(decoding: bodyData, as: UTF8.self)
        let payload = String(decoding: try JSONEncoder().encode([body]), as: UTF8.self)
        let value = try #require(WebKitResearchSearchService.capturedResponseContents(
            payload: payload, platform: .douyin, keyword: "隐藏结果", maxItems: 20, recentDays: 30
        ).first)
        #expect(value.title == "隐藏字符串里的抖音结果")
        #expect(value.likeCount == 3_200)
        #expect(value.coverURL?.absoluteString == "https://p3.douyinpic.com/embedded.jpeg")
    }

    @Test("Xiaohongshu search URL avoids the redirect loop")
    func xiaohongshuSearchURLUsesCanonicalPath() throws {
        let url = try #require(ResearchPlatform.xiaohongshu.searchURL(keyword: "日本移民"))
        #expect(url.absoluteString.contains("/search_result/?"))
        #expect(url.query?.contains("keyword=") == true)
    }

    @Test("Xiaohongshu logged-out search page is rejected even when a stale cookie exists")
    func xiaohongshuLoggedOutPageDetection() {
        #expect(WebKitResearchSearchService.pageRequiresVerification(
            "发现\nRED\n登录\n关于我们",
            url: URL(string: "https://www.xiaohongshu.com/search_result?keyword=高考"),
            platform: .xiaohongshu
        ))
        #expect(!WebKitResearchSearchService.pageRequiresVerification(
            "发现\nRED\n高考经验分享",
            url: URL(string: "https://www.xiaohongshu.com/search_result?keyword=高考"),
            platform: .xiaohongshu
        ))
    }

    @Test("Xiaohongshu detail pages distinguish expired links from logged-out sessions")
    func xiaohongshuDetailPageFailureDetection() throws {
        let unavailable = try #require(XiaohongshuContentResolver.pageFailure(
            from: #"{"pageStatus":"unavailable"}"#
        ))
        if case .platformLinkUnavailable(let platform) = unavailable {
            #expect(platform == "小红书")
        } else {
            Issue.record("应识别为失效或不可见链接")
        }

        let loggedOut = try #require(XiaohongshuContentResolver.pageFailure(
            from: #"{"pageStatus":"logged_out"}"#
        ))
        if case .platformSessionRequired(let platform) = loggedOut {
            #expect(platform == "小红书")
        } else {
            Issue.record("应识别为登录会话失效")
        }
    }

    @MainActor
    @Test("A stale Xiaohongshu account is invalidated and reopens login after search")
    func staleXiaohongshuAccountReopensLogin() async {
        let store = ResearchStore(
            searchService: FailingResearchSearchStub(error: ResearchSearchError.allPlatformsFailed(
                "小红书：小红书网页要求重新登录或完成人机验证。"
            )),
            databaseURL: FileManager.default.temporaryDirectory
                .appending(path: "research-xhs-stale-\(UUID().uuidString).sqlite3")
        )
        store.finishLogin(.xiaohongshu, detected: true)
        store.keyword = "高考"
        store.selectedPlatforms = [.xiaohongshu]
        store.startSearch()
        while store.isSearching { await Task.yield() }
        #expect(store.searchState(for: .xiaohongshu) == .verificationRequired)
        #expect(store.loginPlatform == .xiaohongshu)
        #expect(store.errorMessage?.contains("重新登录") == true)
    }

    @Test("Xiaohongshu captured network responses become usable note results")
    func xiaohongshuCapturedResponseNormalization() throws {
        let body = #"""
        {"data":{"items":[{"id":"66abc1234567890123456789","xsec_token":"signed-token","note_card":{"display_title":"日本移民真实体验","user":{"nickname":"小红书作者"},"cover":{"url_default":"http://sns-webpic.example.com/cover.jpg"},"interact_info":{"liked_count":"1.2万","collected_count":"345","comment_count":"67","shared_count":"8"}}}]}}
        """#
        let payload = String(decoding: try JSONEncoder().encode([body]), as: UTF8.self)
        let value = try #require(WebKitResearchSearchService.capturedResponseContents(
            payload: payload, platform: .xiaohongshu, keyword: "日本移民", maxItems: 20, recentDays: 30
        ).first)
        #expect(value.platformContentID == "66abc1234567890123456789")
        #expect(value.title == "日本移民真实体验")
        #expect(value.authorName == "小红书作者")
        #expect(value.coverURL?.absoluteString == "https://sns-webpic.example.com/cover.jpg")
        #expect(value.contentURL.absoluteString.contains("xsec_token=signed-token"))
        #expect(value.likeCount == 12_000)
        #expect(value.collectCount == 345)
        #expect(value.commentCount == 67)
        #expect(value.resolvedContentKind == .imageText)
    }

    @Test("Xiaohongshu search distinguishes video notes from image-text notes and keeps all images")
    func xiaohongshuMixedContentKinds() throws {
        let body = #"""
        {"data":{"items":[
          {"id":"66video1234567890123456","note_card":{"type":"video","display_title":"视频笔记","video":{"media":{"stream":"ready"}},"cover":{"url_default":"https://ci.xhscdn.com/video-cover.jpg"}}},
          {"id":"66image1234567890123456","note_card":{"type":"normal","display_title":"图文笔记","image_list":[{"url_default":"https://ci.xhscdn.com/1.jpg"},{"url_default":"https://ci.xhscdn.com/2.jpg"}]}}
        ]}}
        """#
        let payload = String(decoding: try JSONEncoder().encode([body]), as: UTF8.self)
        let values = WebKitResearchSearchService.capturedResponseContents(
            payload: payload, platform: .xiaohongshu, keyword: "测试", maxItems: 20, recentDays: 30
        )
        #expect(values.count == 2)
        #expect(values.first { $0.title == "视频笔记" }?.resolvedContentKind == .video)
        let imageText = try #require(values.first { $0.title == "图文笔记" })
        #expect(imageText.resolvedContentKind == .imageText)
        #expect(imageText.imageURLs?.map(\.absoluteString) == [
            "https://ci.xhscdn.com/1.jpg", "https://ci.xhscdn.com/2.jpg"
        ])
    }

    @Test("Xiaohongshu detail resolver preserves body, image list and video type")
    func xiaohongshuDetailParsing() throws {
        let fallback = ResearchContent(
            id: "xhs:1", platform: .xiaohongshu, platformContentID: "1", keyword: "测试",
            title: "回退标题", description: nil, authorName: nil, authorURL: nil,
            contentURL: URL(string: "https://www.xiaohongshu.com/explore/1")!, coverURL: nil,
            publishedAt: nil, durationSeconds: nil, viewCount: nil, likeCount: nil,
            commentCount: nil, collectCount: nil, shareCount: nil, hotScore: 1, collectedAt: .now,
            contentKind: .imageText
        )
        let image = try #require(XiaohongshuContentResolver.parse(
            payload: #"{"title":"新标题","text":"这是完整正文","type":"image_text","imageURLs":["http://ci.xhscdn.com/a.jpg","https://ci.xhscdn.com/b.jpg"],"videoURL":"","duration":null}"#,
            fallback: fallback,
            userAgent: "test"
        ))
        #expect(image.kind == .imageText)
        #expect(image.text == "这是完整正文")
        #expect(image.imageURLs.count == 2)
        #expect(image.imageURLs.first?.absoluteString == "https://ci.xhscdn.com/a.jpg")
    }

    @Test("A pasted Xiaohongshu explore link enters the authenticated detail route")
    func pastedXiaohongshuLinkRouting() throws {
        let url = try #require(URL(string:
            "https://www.xiaohongshu.com/explore/6a3974ba00000000702d51b?xsec_token=test&xsec_source=pc_search"
        ))
        #expect(SourceExtractor.isXiaohongshu(url))
        let content = try #require(SourceExtractor.xiaohongshuContent(for: url))
        #expect(content.platform == .xiaohongshu)
        #expect(content.platformContentID == "6a3974ba00000000702d51b")
        #expect(content.contentURL == url)
        #expect(content.contentKind == .imageText)
        #expect(SourceExtractor.xiaohongshuContent(
            for: URL(string: "https://example.com/explore/6a3974ba00000000702d51b")!
        ) == nil)
    }

    @Test("Text-only online models fall back to on-device image inspection")
    func textOnlyVisionFallback() async throws {
        #expect(OnlineSourceVisualAnalyzer.isUnsupportedVisionRequest(
            .requestFailed(status: 400, message: "unknown variant image_url, expected text")
        ))
        #expect(!OnlineSourceVisualAnalyzer.isUnsupportedVisionRequest(
            .requestFailed(status: 401, message: "invalid key")
        ))
        let pixel = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let url = try #require(URL(string: "https://ci.xhscdn.com/local-fallback.png"))
        let references = await OnlineSourceVisualAnalyzer.localReferences(from: [(url, pixel)])
        #expect(references.count == 1)
        #expect(references.first?.imageURL == url)
        #expect(references.first?.sceneDescription.contains("本机 Vision") == true)
        #expect(references.first?.redesignDirection.contains("不复制原图") == true)
    }

    @Test("Image fallback discards non-image resources and keeps URL indexes aligned")
    func imageFallbackFiltersNonImages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterStubURLProtocol.self]
        OpenRouterStubURLProtocol.statusCode = 400
        OpenRouterStubURLProtocol.responseData = Data(#"{"error":{"message":"unknown variant image_url, expected text"}}"#.utf8)
        defer {
            OpenRouterStubURLProtocol.statusCode = 200
            OpenRouterStubURLProtocol.responseData = Data()
        }
        let client = OpenRouterAPIClient(
            session: URLSession(configuration: configuration),
            configurationProvider: {
                OnlineAIConfiguration(provider: .deepSeek, endpoint: "https://example.com/v1/chat/completions", model: "test")
            },
            apiKeyProvider: { "sk-test-credential-value" }
        )
        let analyzer = OnlineSourceVisualAnalyzer(client: client)
        let pixel = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let invalidURL = try #require(URL(string: "https://fe-static.xhscdn.com/app.js"))
        let imageURL = try #require(URL(string: "https://ci.xhscdn.com/note.png"))
        let references = try await analyzer.analyze(
            images: [(invalidURL, Data(repeating: 7, count: 8_000)), (imageURL, pixel)],
            postText: "测试正文"
        )
        #expect(references.count == 1)
        #expect(references.first?.index == 1)
        #expect(references.first?.imageURL == imageURL)
    }

    @Test("Image OCR chrome and image indexes are not treated as mandatory facts")
    func imageTextQualityIgnoresOCRChrome() {
        let original = """
        【图片内文字识别，仅作全文改写依据】
        原图 5：edge://extensions 登录2 你的组织浏览器已托管
        Microsoft Edge 扩展程序是简单的工具，可以自定义浏览器体验。
        原图 6：abcdefghijklmnop123456 获取 Microsoft Edge 扩展
        """
        let revised = "想让浏览器更顺手，可以用 Microsoft Edge 扩展程序增加实用功能。选择前先确认权限和来源，再按需安装，避免一次堆叠过多工具。"
        #expect(EmbeddedModelRuntime.documentQualityIssues(
            original: original,
            revised: revised,
            sourceOrigin: .socialImageText,
            style: .social
        ).isEmpty)
    }

    @Test("Image-text source visuals become one redesigned prompt per original image")
    func imageTextVisualPlanning() {
        let references = [1, 2].map { index in
            SourceVisualReference(
                index: index, imageURL: nil, recognizedText: "图中文字 \(index)",
                sceneDescription: "场景 \(index)", composition: "构图 \(index)",
                redesignDirection: "重新设计 \(index)"
            )
        }
        let output = RewriteOutput(
            title: "图文", rawTranscript: "原稿", originalTranscript: "原稿", corrections: [],
            suggestions: [], revisedBody: "改写正文", notes: "", transcriptOrigin: .socialImageText,
            style: .social, sourceVisualReferences: references, sourceContentKind: .imageText
        )
        let shots = VisualShotPlanner.plannedShots(for: output)
        #expect(shots.count == 2)
        #expect(shots[0].spokenContext.contains("图中文字 1"))
        #expect(shots[0].spokenContext.contains("成稿对应内容"))
        #expect(shots[0].prompt.contains("3:4 竖版"))
        #expect(shots[1].spokenContext.contains("重新设计 2"))
    }

    @Test("视频素材转小红书时会生成丰富的多图卡片")
    func videoToSocialCreatesRichImageSet() {
        let body = String(repeating: "这是一段包含背景、案例、数据与结论的小红书改写内容。", count: 30)
        let output = RewriteOutput(
            title: "图文成稿", rawTranscript: "真实视频转写", originalTranscript: "真实视频转写",
            corrections: [], suggestions: [], revisedBody: body, notes: "",
            transcriptOrigin: .localSpeechRecognition, style: .social,
            durationSeconds: 90, sourceContentKind: .video
        )
        let shots = VisualShotPlanner.plannedShots(for: output)
        #expect(shots.count >= 4)
        #expect(shots.count <= 9)
        #expect(shots.first?.timecode.contains("封面") == true)
        #expect(shots.allSatisfy { $0.prompt.contains("3:4 竖版") })
    }

    @Test("图文素材转公众号时使用文章配图而非照搬原图")
    func imageTextToArticleUsesEditorialVisuals() {
        let reference = SourceVisualReference(
            index: 1, imageURL: nil, recognizedText: "图中数据", sceneDescription: "桌面文件",
            composition: "俯拍", redesignDirection: "重新组织"
        )
        let output = RewriteOutput(
            title: "长文", rawTranscript: "原稿", originalTranscript: "原稿", corrections: [],
            suggestions: [], revisedBody: String(repeating: "文章需要完整论证具体的事实与逻辑关系。", count: 40),
            notes: "", transcriptOrigin: .socialImageText, style: .article,
            sourceVisualReferences: [reference], sourceContentKind: .imageText
        )
        let shots = VisualShotPlanner.plannedShots(for: output)
        #expect(shots.count >= 3)
        #expect(shots.count <= 6)
        #expect(shots.first?.spokenContext.contains("图中数据") == true)
        #expect(shots.allSatisfy { $0.prompt.contains("16:9 横版") })
    }

    @Test("视频号镜头节奏比短视频口播更稳健")
    func channelUsesSlowerShotCadenceThanSpoken() {
        func output(style: RewriteStyle) -> RewriteOutput {
            RewriteOutput(
                title: "视频", rawTranscript: "字幕", originalTranscript: "字幕", corrections: [],
                suggestions: [], revisedBody: String(repeating: "这是稳定的视频文案内容。", count: 20), notes: "",
                transcriptOrigin: .platformSubtitle, style: style, durationSeconds: 60,
                sourceContentKind: .video
            )
        }
        let spoken = VisualShotPlanner.plannedShots(for: output(style: .spoken))
        let channel = VisualShotPlanner.plannedShots(for: output(style: .channel))
        #expect(spoken.count == 15)
        #expect(channel.count == 10)
    }

    @MainActor
    @Test("Live Xiaohongshu search must return real note results")
    func liveXiaohongshuSearchReturnsResults() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_XHS_LIVE_TEST"] == "1" else { return }
        let values = try await WebKitResearchSearchService.search(
            platform: .xiaohongshu, keyword: "高考", maxItems: 3, recentDays: 30
        )
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0.platform == .xiaohongshu })
    }

    @Test("Platform cookies must match both the cookie name and domain")
    func platformCookieDomainValidation() throws {
        let wrongDomain = try #require(HTTPCookie(properties: [
            .name: "sessionid", .value: "test", .domain: ".douyin.com", .path: "/"
        ]))
        let correctDomain = try #require(HTTPCookie(properties: [
            .name: "sessionid", .value: "test", .domain: ".tiktok.com", .path: "/"
        ]))
        #expect(!PlatformSessionStore.hasAuthenticatedCookies(in: [wrongDomain], for: .tiktok))
        #expect(PlatformSessionStore.hasAuthenticatedCookies(in: [correctDomain], for: .tiktok))
    }

    @Test("Custom browser schemes are blocked before macOS opens another application")
    func customBrowserSchemeIsBlocked() {
        #expect(!PlatformNavigationDelegate.allowsNavigation(to: URL(string: "bitbrowser://cc/")))
        #expect(PlatformNavigationDelegate.allowsNavigation(to: URL(string: "https://www.douyin.com/search/test")))
    }

    @MainActor
    @Test("WeChat Channels keyword search fails immediately with an honest manual-link route")
    func wechatChannelsSearchIsExplicitlyUnsupported() async {
        #expect(ResearchPlatform.wechatChannels.searchURL(keyword: "日本") == nil)
        do {
            _ = try await WebKitResearchSearchService.search(
                platform: .wechatChannels, keyword: "日本", maxItems: 20, recentDays: 30
            )
            Issue.record("视频号关键词搜索应当立即返回不支持")
        } catch {
            #expect(error.localizedDescription.contains("新建文稿"))
            #expect(error.localizedDescription.contains("分享链接"))
        }
    }

    @Test("Anonymous Douyin CSRF cookies are not treated as a logged-in account")
    func douyinLoginIndicators() {
        #expect(!ResearchPlatform.douyin.cookieIndicators.contains("passport_csrf_token"))
        #expect(ResearchPlatform.douyin.cookieIndicators.contains("sessionid"))
        #expect(ResearchPlatform.douyin.requiresAuthenticatedWebSearch)
        #expect(!ResearchPlatform.tiktok.requiresAuthenticatedWebSearch)
        let urls = ResearchPlatform.douyin.searchURLs(keyword: "香港医药")
        #expect(urls.count == 2)
        #expect(urls[0].query?.contains("type=general") == true)
        #expect(urls[1].query?.contains("type=video") == true)
        #expect(urls.allSatisfy {
            $0.path.contains("香港医药")
                || $0.absoluteString.contains("%E9%A6%99%E6%B8%AF%E5%8C%BB%E8%8D%AF")
        })
    }

    @Test("Douyin verification pages are not mislabeled as changed result markup")
    func douyinVerificationPageDetection() {
        #expect(WebKitResearchSearchService.pageRequiresVerification(
            "访问过于频繁，请完成下方验证后继续",
            url: URL(string: "https://www.douyin.com/search/test"), platform: .douyin
        ))
        #expect(WebKitResearchSearchService.pageRequiresVerification(
            "网络开小差了，请刷新重试",
            url: URL(string: "https://www.douyin.com/search/test"), platform: .douyin
        ))
        #expect(!WebKitResearchSearchService.pageRequiresVerification(
            "香港医药相关视频",
            url: URL(string: "https://www.douyin.com/search/test"), platform: .douyin
        ))
    }

    @MainActor
    @Test("Douyin search without a verified session opens login instead of waiting for an empty page")
    func douyinMissingSessionOpensLogin() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "chenggao-douyin-login-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchStore(
            searchService: ResearchSearchService(),
            databaseURL: root.appending(path: "research.sqlite3")
        )
        await Task.yield()
        store.keyword = "斩杀线"
        store.selectedPlatforms = [.douyin]
        store.startSearch()
        #expect(store.loginPlatform == .douyin)
        #expect(!store.isSearching)
        #expect(store.errorMessage?.contains("没有有效登录会话") == true)
    }

    @Test("Searches live Bilibili results for the user's example keyword")
    func liveBilibiliResearchSearch() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_RESEARCH_LIVE_TEST"] == "1" else { return }
        let service = ResearchSearchService()
        let outcome = try await service.search(
            input: ResearchSearchInput(keyword: "香港身份", platforms: [.bilibili], maxItems: 20, recentDays: 30),
            progress: { _, _, _ in }
        )
        #expect(!outcome.contents.isEmpty)
        #expect(outcome.contents.allSatisfy { $0.platform == .bilibili && $0.contentURL.host?.contains("bilibili.com") == true })
        #expect(outcome.contents.contains { $0.viewCount != nil })
    }

    @Test("Research SQLite persists tasks, accounts and deduplicated contents")
    func researchDatabaseRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chenggao-research-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ResearchDatabase(url: root.appending(path: "research.sqlite3"))
        let now = Date()
        let account = ResearchAccount(
            id: "bilibili:default", platform: .bilibili, displayName: "测试账号",
            status: .loggedIn, lastCheckedAt: now, createdAt: now, updatedAt: now
        )
        let task = ResearchTaskRecord(
            id: "task-1", keyword: "香港身份", platforms: [.bilibili], status: .completed,
            progress: 1, errorMessage: nil, createdAt: now, startedAt: now, completedAt: now
        )
        var content = ResearchContent(
            id: "xiaohongshu:legacy-http", platform: .xiaohongshu,
            platformContentID: "legacy-http", keyword: "香港身份", title: "测试图文",
            description: "正文", authorName: "作者", authorURL: nil,
            contentURL: URL(string: "https://www.xiaohongshu.com/explore/legacy-http")!,
            coverURL: URL(string: "http://sns-webpic-qc.xhscdn.com/cover.jpg")!,
            publishedAt: now, durationSeconds: nil, viewCount: nil, likeCount: 100,
            commentCount: 10, collectCount: 5, shareCount: nil, hotScore: 1,
            collectedAt: now, contentKind: .imageText
        )
        content.imageURLs = [URL(string: "http://ci.xhscdn.com/a.jpg")!]
        try await database.save(account: account)
        try await database.save(task: task)
        try await database.save(contents: [content, content], taskID: task.id)
        #expect(try await database.loadAccounts().count == 1)
        #expect(try await database.loadTasks().count == 1)
        let loaded = try await database.loadRecentContents()
        #expect(loaded.count == 1)
        #expect(loaded.first?.resolvedContentKind == .imageText)
        #expect(loaded.first?.imageURLs?.first?.absoluteString == "https://ci.xhscdn.com/a.jpg")
        #expect(loaded.first?.coverURL?.absoluteString == "https://sns-webpic-qc.xhscdn.com/cover.jpg")
    }

    @Test("Recognizes YouTube links and extracts a player response safely")
    func youtubeResearchParsing() throws {
        #expect(SourceExtractor.youtubeVideoID(in: URL(string: "https://youtu.be/dQw4w9WgXcQ")!) == "dQw4w9WgXcQ")
        #expect(SourceExtractor.youtubeVideoID(in: URL(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ")!) == "dQw4w9WgXcQ")
        let html = """
        <script>var ytInitialPlayerResponse = {"videoDetails":{"title":"示例","lengthSeconds":"90"},"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"languageCode":"zh-CN","baseUrl":"https://example.com/captions?a=1"}]}}};</script>
        """
        let response = try #require(SourceExtractor.youtubePlayerResponse(from: html))
        let details = try #require(response["videoDetails"] as? [String: Any])
        #expect(details["title"] as? String == "示例")
        let configuredHTML = #"<script>ytcfg.set({"INNERTUBE_API_KEY":"public-page-key","VISITOR_DATA":"visitor%3D"});</script>"#
        #expect(SourceExtractor.youtubeConfigurationValue("INNERTUBE_API_KEY", in: configuredHTML) == "public-page-key")
        #expect(SourceExtractor.youtubeConfigurationValue("VISITOR_DATA", in: configuredHTML) == "visitor%3D")

        let captionData = Data(#"{"events":[{"segs":[{"utf8":"第一句"},{"utf8":"字幕"}]},{"segs":[{"utf8":"第二句"}]}]}"#.utf8)
        #expect(SourceExtractor.youtubeTranscript(fromCaptionData: captionData) == "第一句字幕\n第二句")

        let audioPlayer: [String: Any] = [
            "streamingData": [
                "adaptiveFormats": [
                    ["mimeType": "audio/webm; codecs=opus", "bitrate": 200_000, "url": "https://example.com/audio.webm"],
                    ["mimeType": "audio/mp4; codecs=mp4a.40.2", "bitrate": 128_000, "url": "https://example.com/audio.m4a"]
                ]
            ]
        ]
        let audio = try #require(SourceExtractor.youtubeAudioResource(from: audioPlayer))
        #expect(audio.url.absoluteString == "https://example.com/audio.m4a")
        #expect(audio.fileExtension == "m4a")
    }

    @Test("The reported YouTube link returns its real public transcript")
    func liveReportedYouTubeTranscript() async throws {
        guard ProcessInfo.processInfo.environment["CHENGGAO_YOUTUBE_LIVE_TEST"] == "1" else { return }
        let extractor = SourceExtractor()
        let material = try await extractor.content(
            kind: .link,
            urlString: "https://www.youtube.com/watch?v=On1Emt5XQ7o",
            pastedText: ""
        )
        #expect(material.title.contains("如何剪辑"))
        #expect(material.transcript.count > 1_000)
        #expect(material.origin == .platformSubtitle || material.origin == .localSpeechRecognition)
    }

    @Test("A selected research video enters the existing rewrite workflow")
    @MainActor
    func researchSelectionStartsRewrite() async throws {
        let suite = "ResearchSelection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyURL = FileManager.default.temporaryDirectory
            .appending(path: "chenggao-research-selection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let store = RewriteStore(
            pipeline: StubPipeline(),
            visualPromptGenerator: StubVisualPromptGenerator(),
            extractor: StubExtractor(),
            defaults: defaults,
            historyURL: historyURL
        )
        let content = ResearchContent(
            id: "bilibili:BV1gZSEBcERU", platform: .bilibili,
            platformContentID: "BV1gZSEBcERU", keyword: "香港身份", title: "测试热门视频",
            description: nil, authorName: "作者", authorURL: nil,
            contentURL: URL(string: "https://www.bilibili.com/video/BV1gZSEBcERU")!, coverURL: nil,
            publishedAt: .now, durationSeconds: 60, viewCount: 1000, likeCount: nil,
            commentCount: 10, collectCount: 5, shareCount: nil, hotScore: 3, collectedAt: .now
        )
        store.selectedSection = .research
        store.style = .article
        store.processResearchContent(content)
        #expect(store.selectedSection == .compose)
        #expect(store.style == .article)
        #expect(store.sourceURL.contains("BV1gZSEBcERU"))
        #expect(store.isProcessing)
        for _ in 0..<30 where store.isProcessing {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.output?.revisedBody == "这是修改后的文稿。")
        #expect(store.output?.style == .article)
        #expect(store.history.first?.title == "可识别的历史标题")
    }
}
