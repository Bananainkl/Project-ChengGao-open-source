import Foundation

protocol VisualPromptGenerating: Sendable {
    func generate(
        for output: RewriteOutput,
        modelMode: ModelMode,
        language: OutputLanguage,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> VisualPromptGenerationResult
}

actor AdaptiveVisualPromptGenerator: VisualPromptGenerating {
    private let onlineClient: OpenRouterAPIClient
    private let webClient: WebAIChatClient
    private let webConfigurationProvider: @Sendable () -> WebAIConfiguration

    init(
        onlineClient: OpenRouterAPIClient = OpenRouterAPIClient(),
        webClient: WebAIChatClient = WebAIChatClient(),
        webConfigurationProvider: @escaping @Sendable () -> WebAIConfiguration = {
            WebAIConfiguration.load()
        }
    ) {
        self.onlineClient = onlineClient
        self.webClient = webClient
        self.webConfigurationProvider = webConfigurationProvider
    }

    func generate(
        for output: RewriteOutput,
        modelMode: ModelMode,
        language: OutputLanguage,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> VisualPromptGenerationResult {
        let planned = VisualShotPlanner.plannedShots(for: output)
        guard !planned.isEmpty else {
            return VisualPromptGenerationResult(shots: [], source: .templateFallback)
        }

        return try await designOnline(
            planned: planned,
            style: output.style,
            visualStyle: output.effectiveVisualStyle,
            language: language,
            progress: progress
        )
    }

    private func designOnline(
        planned: [VisualShot],
        style: RewriteStyle,
        visualStyle: VisualStyle,
        language: OutputLanguage,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> VisualPromptGenerationResult {
        let batches = planned.chunked(maximumCount: VisualPromptDesigner.batchSize)
        var completedShots: [VisualShot] = []
        var designedCount = 0
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            progress(RewriteProgress(
                completed: index,
                total: batches.count,
                message: "在线 AI 正在设计第 \(index + 1)/\(batches.count) 组镜头场景…"
            ))
            let prompt = VisualPromptDesigner.prompt(
                for: batch,
                style: style,
                language: language,
                visualStyle: visualStyle
            )
            let completion = if webConfigurationProvider().isEnabled {
                try await webCompletionOrFallback(prompt: prompt)
            } else {
                try await onlineClient.complete(prompt: prompt)
            }
            let parsed = VisualPromptDesigner.applying(
                rawResponse: completion.content,
                to: batch,
                language: language,
                visualStyle: visualStyle
            )
            completedShots.append(contentsOf: parsed.shots)
            designedCount += parsed.designedCount
        }
        progress(RewriteProgress(
            completed: batches.count,
            total: batches.count,
            message: "在线 AI 镜头场景设计完成"
        ))
        return VisualPromptGenerationResult(
            shots: completedShots,
            source: designedCount == 0
                ? .templateFallback
                : (designedCount == planned.count ? .onlineAI : .mixedAI)
        )
    }

    private func webCompletionOrFallback(prompt: String) async throws -> OpenRouterCompletion {
        do {
            return try await webClient.complete(prompt: prompt, timeout: .seconds(60))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return OpenRouterCompletion(model: "网页 AI 镜头模板后备", content: "")
        }
    }
}

extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: maximumCount).map { start in
            let end = Swift.min(start + maximumCount, count)
            return Array(self[start..<end])
        }
    }
}
