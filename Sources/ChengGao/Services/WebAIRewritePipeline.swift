import Foundation

struct WebAIChatClient: Sendable {
    let configurationProvider: @Sendable () -> WebAIConfiguration

    init(
        configurationProvider: @escaping @Sendable () -> WebAIConfiguration = {
            WebAIConfiguration.load()
        }
    ) {
        self.configurationProvider = configurationProvider
    }

    func complete(prompt: String) async throws -> OpenRouterCompletion {
        let configuration = configurationProvider()
        guard configuration.isEnabled else {
            throw WebAIWebError.loginRequired(configuration.provider.title)
        }
        let content = try await completeOnMainActor(
            prompt: prompt,
            provider: configuration.provider
        )
        return OpenRouterCompletion(
            model: "\(configuration.provider.title) 网页会话",
            content: content
        )
    }

    @MainActor
    private func completeOnMainActor(
        prompt: String,
        provider: WebAIProvider
    ) async throws -> String {
        try await WebAIWebSessionPool.shared.session(for: provider).complete(markdownTask: prompt)
    }
}

actor WebAIRewritePipeline: RewriteProcessing {
    private let client: WebAIChatClient

    init(client: WebAIChatClient = WebAIChatClient()) {
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
        let configuration = client.configurationProvider()
        progress(RewriteProgress(
            completed: 0,
            total: 2,
            message: "正在通过 \(configuration.provider.title) 网页会话提交 Markdown 改写任务…"
        ))
        var completion = try await client.complete(prompt: Self.markdownRewriteTask(
            material: material,
            style: style,
            language: language
        ))
        var draft = try OpenRouterRewritePipeline.parseDraft(
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
            progress(RewriteProgress(
                completed: 1,
                total: 2,
                message: "网页 AI 初稿未通过质量检查，正在提交 Markdown 重试…"
            ))
            completion = try await client.complete(prompt: Self.markdownRetryTask(
                material: material,
                style: style,
                language: language,
                firstDraft: draft.revised,
                issues: issues
            ))
            draft = try OpenRouterRewritePipeline.parseDraft(
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
        progress(RewriteProgress(completed: 2, total: 2, message: "网页 AI 全文审稿完成"))
        return RewriteOutput(
            title: language.normalize(
                draft.title ?? EmbeddedModelRuntime.outputTitle(for: material, revisedBody: draft.revised)
            ),
            rawTranscript: material.transcript,
            originalTranscript: draft.corrected,
            corrections: draft.corrections,
            suggestions: draft.suggestions,
            revisedBody: draft.revised,
            notes: language.normalize(
                "原稿来源：\(material.origin.label)。使用 \(completion.model) 完成 Markdown 全文改写与质量复检；完整标题与正文已发送给该在线服务。全文相似度 \(Int((EmbeddedModelRuntime.rewriteSimilarity(original: draft.corrected, revised: draft.revised) * 100).rounded()))%。输出语言：\(language.rawValue)。"
            ),
            transcriptOrigin: material.origin,
            style: style,
            durationSeconds: material.durationSeconds
        )
    }

    nonisolated static func markdownRewriteTask(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage
    ) -> String {
        """
        ## 任务类型

        完整改写为可直接发布的“\(style.rawValue)”。

        ## 最高优先级强制要求

        \(OpenRouterRewritePipeline.rewriteOnlyRule)

        ## 编辑要求

        \(language.promptInstruction)

        1. 通读全文后重做开头、信息顺序、句式和段落层次，不得只做繁简、标点、断句或少量同义词替换。
        2. 保留全部重要事实、人物、出处、日期、数字、因果、争议双方和限定条件；不编造。
        3. 删除关注引导、广告、版权尾注和无关页面噪声，但不得删除正文案例和论证材料。
        4. suggestions 给出 2–6 条针对具体原句和结构的修改建议；不生成配图建议。

        ## 字数与文体硬约束

        \(OpenRouterRewritePipeline.lengthTargetInstruction(material: material, style: style))

        \(OpenRouterRewritePipeline.targetContract(for: style))

        ## 返回的 JSON 数据结构

        必须在 `chenggao-result` 代码块中先输出 revised，字段完整：

        {"revised":"完成实质改写的完整成稿","title":"成稿标题","corrections":[{"original":"原词","corrected":"校正词","reason":"上下文依据"}],"suggestions":[{"original":"具体原句","suggestion":"具体改法","reason":"修改原因"}]}

        ## 素材证据

        \(OpenRouterRewritePipeline.sourceEvidence(for: material))

        ## 原稿标题

        \(material.title)

        ## 完整原稿

        \(material.transcript)
        """
    }

    nonisolated static func markdownRetryTask(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage,
        firstDraft: String,
        issues: [String]
    ) -> String {
        """
        ## 任务类型

        重新完成一次完整改写。上一版未通过澄稿质量门：\(issues.joined(separator: "；"))。

        ## 最高优先级强制要求

        \(OpenRouterRewritePipeline.rewriteOnlyRule)

        \(language.promptInstruction)

        上一版约有 \(OpenRouterRewritePipeline.contentCharacterCount(firstDraft)) 个有效字符。\(OpenRouterRewritePipeline.lengthTargetInstruction(material: material, style: style))
        若上一版过短，必须逐项恢复背景、原因、例子、过程、转折、限定条件和结论；不得用空洞重复或虚构细节凑字数。

        ## 返回结构

        只返回与首次任务完全相同字段的 `chenggao-result` JSON：`revised`、`title`、`corrections`、`suggestions`。

        ## 原稿

        \(material.transcript)

        ## 未通过的上一版

        \(firstDraft)
        """
    }
}
