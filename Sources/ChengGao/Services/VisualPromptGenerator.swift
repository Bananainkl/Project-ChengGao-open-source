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

    init(
        onlineClient: OpenRouterAPIClient = OpenRouterAPIClient()
    ) {
        self.onlineClient = onlineClient
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
            language: language,
            progress: progress
        )
    }

    private func designOnline(
        planned: [VisualShot],
        style: RewriteStyle,
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
            let completion = try await onlineClient.complete(
                prompt: VisualPromptDesigner.prompt(for: batch, style: style, language: language)
            )
            let parsed = VisualPromptDesigner.applying(
                rawResponse: completion.content,
                to: batch,
                language: language
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
