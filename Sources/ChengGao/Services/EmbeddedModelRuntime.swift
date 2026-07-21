import Foundation

enum EmbeddedModelError: LocalizedError {
    case assetsMissing
    case launchFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .assetsMissing:
            "应用包里缺少本地模型或推理运行时。"
        case .launchFailed(let detail):
            "无法启动本地模型：\(detail)"
        case .generationFailed(let detail):
            "本地模型生成失败：\(detail)"
        }
    }
}

struct EmbeddedModelAssets: Equatable, Sendable {
    let executableURL: URL
    let fastModelURL: URL
    let enhancedModelURL: URL?

    init(executableURL: URL, fastModelURL: URL, enhancedModelURL: URL? = nil) {
        self.executableURL = executableURL
        self.fastModelURL = fastModelURL
        self.enhancedModelURL = enhancedModelURL
    }

    // Keeps older tests and call sites source-compatible.
    init(executableURL: URL, modelURL: URL) {
        self.init(executableURL: executableURL, fastModelURL: modelURL)
    }
}

private final class ModelProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

struct ParsedRewriteChunk: Sendable {
    var corrected: String
    var corrections: [TranscriptCorrection]
    var suggestion: RevisionSuggestion
    var revised: String
}

/// One card on the internal rewrite task board. Numbered headings are kept as
/// immutable metadata so the language model only has to rewrite the card body.
struct RewriteTaskCard: Equatable, Sendable {
    let source: String
    let protectedHeading: String?
}

struct RewriteGenerationPlan: Equatable, Sendable {
    let maximumCharactersPerCard: Int
    let maximumOutputTokens: Int
}

struct EditorialBlueprint: Equatable, Sendable {
    var coreAngle: String
    var openingHook: String
    var storyArc: [String]
    var mustKeepFacts: [String]
    var tone: String
    var exclusions: [String]

    var compactContext: String {
        "核心角度：\(coreAngle)\n开头钩子：\(openingHook)\n叙事顺序：\(storyArc.joined(separator: " → "))\n必须保留：\(mustKeepFacts.joined(separator: "；"))\n语气：\(tone)\n删除项：\(exclusions.joined(separator: "；"))"
    }
}

/// Calls the llama.cpp executable shipped inside the app bundle. This is a
/// direct child process, not a server: no port, daemon, account or API key.
actor EmbeddedModelRuntime: RewriteProcessing {
    let profile: ModelProfile
    let memoryBudget: MemoryBudget
    let assets: EmbeddedModelAssets?

    init(
        profile: ModelProfile = .qwenDefault,
        memoryBudget: MemoryBudget = .currentMachine,
        assets: EmbeddedModelAssets? = EmbeddedModelRuntime.discoverAssets()
    ) {
        self.profile = profile
        self.memoryBudget = memoryBudget
        self.assets = assets
    }

    nonisolated static func discoverAssets(bundle: Bundle = .main) -> EmbeddedModelAssets? {
        guard let resources = bundle.resourceURL else { return nil }
        let executable = resources.appending(path: "Runtime/llama-cli")
        let fastModel = resources.appending(path: "Models/qwen3-1.7b-q4_k_m.gguf")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: fastModel.path) else {
            return nil
        }
        return EmbeddedModelAssets(
            executableURL: executable,
            fastModelURL: fastModel
        )
    }

    nonisolated static var installationLabel: String {
        discoverAssets() == nil ? "离线规则预览可用" : "Qwen3 本地模型就绪"
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
        guard let assets else { throw EmbeddedModelError.assetsMissing }
        guard memoryBudget.isEightGBSafe else {
            throw EmbeddedModelError.launchFailed("内存预算超过安全上限。")
        }

        let selection = Self.selectModel(
            assets: assets,
            mode: modelMode,
            physicalMemoryGB: memoryBudget.physicalMemoryGB,
            requestedContextSize: contextLimit
        )
        let generationPlan = Self.generationPlan(
            contextSize: selection.contextSize,
            usesEnhancedModel: assets.enhancedModelURL == selection.url
        )
        let maximumCharactersPerCard = switch style {
        case .spoken, .channel: min(300, generationPlan.maximumCharactersPerCard)
        case .article, .social: min(900, generationPlan.maximumCharactersPerCard)
        }
        let taskBoard = Self.taskBoard(
            material.transcript,
            maximumCharacters: maximumCharactersPerCard
        )
        progress(RewriteProgress(completed: 0, total: taskBoard.count + 2, message: "正在通读全文并建立编辑蓝图…"))
        let blueprintRaw = try await run(
            prompt: Self.blueprintPrompt(
                text: Self.documentOverview(
                    material.transcript,
                    maximumCharacters: selection.contextSize <= 4_096 ? 1_500 : 2_800
                ),
                sourceTitle: material.title,
                sourceOrigin: material.origin,
                style: style,
                language: language
            ),
            modelURL: selection.url,
            contextSize: selection.contextSize,
            maximumOutputTokens: min(800, generationPlan.maximumOutputTokens)
        )
        let blueprint = Self.parseBlueprint(
            blueprintRaw,
            sourceTitle: material.title,
            sourceText: material.transcript,
            style: style,
            language: language
        )
        var suggestions: [RevisionSuggestion] = []
        var correctedChunks: [String] = []
        var corrections: [TranscriptCorrection] = []
        var revisedChunks: [String] = []
        var modelLabel = selection.label
        var usedQualityRetry = false
        for (index, card) in taskBoard.enumerated() {
            let chunk = card.source
            try Task.checkCancellation()
            progress(RewriteProgress(
                completed: index + 1,
                total: taskBoard.count + 2,
                message: "正在处理任务板第 \(index + 1)/\(taskBoard.count) 块…"
            ))
            let raw = try await run(
                prompt: Self.prompt(
                    text: chunk,
                    sourceTitle: material.title,
                    sourceOrigin: material.origin,
                    style: style,
                    language: language,
                    index: index + 1,
                    total: taskBoard.count,
                    protectedHeading: card.protectedHeading,
                    editorialContext: blueprint.compactContext,
                    previousDraft: revisedChunks.last.map { String($0.suffix(260)) },
                    nextSourcePreview: index + 1 < taskBoard.count
                        ? String(taskBoard[index + 1].source.prefix(260))
                        : nil
                ),
                modelURL: selection.url,
                contextSize: selection.contextSize,
                maximumOutputTokens: generationPlan.maximumOutputTokens
            )
            var result = Self.parseChunk(raw, original: chunk, language: language, index: index + 1)
            result = Self.restoringStructure(in: result, from: card, language: language)
            var qualityCandidates = [result]
            let issues = Self.qualityIssues(in: result, original: chunk, style: style)
            if !issues.isEmpty {
                usedQualityRetry = true
                let retrySelection = Self.qualityRetryModel(
                    assets: assets,
                    current: selection,
                    physicalMemoryGB: memoryBudget.physicalMemoryGB
                )
                let retryGenerationPlan = Self.generationPlan(
                    contextSize: retrySelection.contextSize,
                    usesEnhancedModel: assets.enhancedModelURL == retrySelection.url
                )
                progress(RewriteProgress(
                    completed: index,
                    total: taskBoard.count,
                    message: "第 \(index + 1) 段未通过质量检查，正在重新生成…"
                ))
                let retryRaw = try await run(
                    prompt: Self.prompt(
                        text: chunk,
                        sourceTitle: material.title,
                        sourceOrigin: material.origin,
                        style: style,
                        language: language,
                        index: index + 1,
                        total: taskBoard.count,
                        protectedHeading: card.protectedHeading,
                        retryReason: issues.joined(separator: "；"),
                        editorialContext: blueprint.compactContext,
                        previousDraft: revisedChunks.last.map { String($0.suffix(260)) },
                        nextSourcePreview: index + 1 < taskBoard.count
                            ? String(taskBoard[index + 1].source.prefix(260))
                            : nil
                    ),
                    modelURL: retrySelection.url,
                    contextSize: retrySelection.contextSize,
                    maximumOutputTokens: retryGenerationPlan.maximumOutputTokens
                )
                result = Self.parseChunk(retryRaw, original: chunk, language: language, index: index + 1)
                result = Self.restoringStructure(in: result, from: card, language: language)
                qualityCandidates.append(result)
                let retryIssues = Self.qualityIssues(in: result, original: chunk, style: style)
                if !retryIssues.isEmpty {
                    let microCards = Self.taskBoard(chunk, maximumCharacters: 320)
                    progress(RewriteProgress(
                        completed: index,
                        total: taskBoard.count,
                        message: "第 \(index + 1) 段仍不合格，已拆成 \(microCards.count) 个小任务深度改写…"
                    ))
                    var microResults: [ParsedRewriteChunk] = []
                    var microFailure: String?
                    for (microIndex, microCard) in microCards.enumerated() {
                        let microRaw = try await run(
                            prompt: Self.deepRewritePrompt(
                                text: microCard.source,
                                sourceTitle: material.title,
                                style: style,
                                language: language,
                                protectedHeading: microCard.protectedHeading,
                                editorialContext: blueprint.compactContext
                            ),
                            modelURL: retrySelection.url,
                            contextSize: retrySelection.contextSize,
                            maximumOutputTokens: retryGenerationPlan.maximumOutputTokens
                        )
                        var microResult = Self.parseChunk(
                            microRaw,
                            original: microCard.source,
                            language: language,
                            index: microIndex + 1
                        )
                        microResult = Self.restoringStructure(in: microResult, from: microCard, language: language)
                        let microIssues = Self.qualityIssues(
                            in: microResult,
                            original: microCard.source,
                            style: style,
                            similarityThreshold: 1.01
                        )
                        if !microIssues.isEmpty {
                            microFailure = microIssues.joined(separator: "；")
                            break
                        }
                        microResults.append(microResult)
                    }
                    if microFailure == nil, microResults.count == microCards.count {
                        qualityCandidates.append(Self.combine(
                            microResults,
                            original: chunk,
                            language: language,
                            index: index + 1
                        ))
                    }
                    let deliverableCandidates = qualityCandidates.filter {
                        Self.qualityIssues(
                            in: $0,
                            original: chunk,
                            style: style,
                            similarityThreshold: 1.01
                        ).isEmpty
                    }
                    guard let best = deliverableCandidates.min(by: {
                        Self.rewriteSimilarity(original: chunk, revised: $0.revised)
                            < Self.rewriteSimilarity(original: chunk, revised: $1.revised)
                    }) else {
                        throw EmbeddedModelError.generationFailed(
                            "第 \(index + 1) 段经过三轮处理后仍存在结构或完整性问题（\(microFailure ?? retryIssues.joined(separator: "；"))）。请切换增强模型或缩短素材后重试。"
                        )
                    }
                    result = best
                    modelLabel = retrySelection.label + "（多候选择优）"
                } else {
                    modelLabel = retrySelection.label == selection.label
                        ? selection.label + "（质量重试）"
                        : retrySelection.label + "（质量检查后自动升级）"
                }
            }
            suggestions.append(result.suggestion)
            correctedChunks.append(result.corrected)
            corrections.append(contentsOf: result.corrections)
            revisedChunks.append(result.revised)
        }

        progress(RewriteProgress(
            completed: taskBoard.count + 1,
            total: taskBoard.count + 2,
            message: "正在统一全文节奏并执行编辑审稿…"
        ))
        let correctedBody = correctedChunks.joined(separator: "\n\n")
        var revisedBody = revisedChunks.joined(separator: "\n\n")
        var finalReviewLabel = "分段上下文审稿"
        let reviewSelection = Self.qualityRetryModel(
            assets: assets,
            current: selection,
            physicalMemoryGB: memoryBudget.physicalMemoryGB
        )
        let reviewPlan = Self.generationPlan(
            contextSize: reviewSelection.contextSize,
            usesEnhancedModel: assets.enhancedModelURL == reviewSelection.url
        )
        if (style == .spoken || style == .channel),
           Self.rewriteSimilarity(original: correctedBody, revised: revisedBody) >= 0.90 {
            progress(RewriteProgress(
                completed: taskBoard.count + 1,
                total: taskBoard.count + 2,
                message: "全文仍与原稿过于接近，正在按语义组重新设计结构…"
            ))
            if let structurallyRewritten = try await structuralRewriteDocument(
                original: correctedBody,
                sourceTitle: material.title,
                sourceOrigin: material.origin,
                style: style,
                language: language,
                blueprint: blueprint,
                modelURL: reviewSelection.url,
                contextSize: reviewSelection.contextSize,
                maximumOutputTokens: reviewPlan.maximumOutputTokens
            ) {
                revisedBody = structurallyRewritten
                finalReviewLabel = "高相似度全文结构重写"
                modelLabel = reviewSelection.label + "（全文结构重写）"
            }
        }
        if Self.canRunWholeDocumentReview(
            original: material.transcript,
            draft: revisedBody,
            contextSize: selection.contextSize
        ) {
            let reviewedRaw = try await run(
                prompt: Self.wholeDocumentReviewPrompt(
                    original: material.transcript,
                    draft: revisedBody,
                    blueprint: blueprint,
                    sourceOrigin: material.origin,
                    style: style,
                    language: language
                ),
                modelURL: reviewSelection.url,
                contextSize: reviewSelection.contextSize,
                maximumOutputTokens: reviewPlan.maximumOutputTokens
            )
            let reviewed = Self.parseRevisedOnly(reviewedRaw, language: language)
            if let reviewed,
               Self.rewriteSimilarity(original: correctedBody, revised: reviewed)
                   < Self.rewriteSimilarity(original: correctedBody, revised: revisedBody),
               Self.documentQualityIssues(
                   original: material.transcript,
                   revised: reviewed,
                   sourceOrigin: material.origin,
                   style: style
               ).isEmpty {
                revisedBody = reviewed
                finalReviewLabel = "全文统稿与独立审稿"
                modelLabel = reviewSelection.label
            }
        }
        let documentIssues = Self.documentQualityIssues(
            original: material.transcript,
            revised: revisedBody,
            sourceOrigin: material.origin,
            style: style
        )
        if !documentIssues.isEmpty {
            throw EmbeddedModelError.generationFailed(
                "全文编辑审稿未通过（\(documentIssues.joined(separator: "；"))）。为避免交付遗漏重点或拼接感明显的稿件，已停止本次处理。"
            )
        }
        suggestions = zip(taskBoard, revisedChunks).enumerated().map { index, pair in
            Self.editorialSuggestion(
                original: pair.0.source,
                revised: pair.1,
                blueprint: blueprint,
                style: style,
                language: language,
                index: index + 1
            )
        }
        progress(RewriteProgress(completed: taskBoard.count + 2, total: taskBoard.count + 2, message: "全文审稿完成"))
        let overallSimilarity = Self.rewriteSimilarity(
            original: correctedBody,
            revised: revisedBody
        )
        if (style == .spoken || style == .channel),
           revisedBody.count >= 120,
           overallSimilarity >= 0.90 {
            throw EmbeddedModelError.generationFailed(
                "全文经过多轮处理后仍与原稿过于接近（相似度 \(Int((overallSimilarity * 100).rounded()))%）。为避免交付近似原稿，已停止本次处理。"
            )
        }
        return RewriteOutput(
            title: language.normalize(Self.outputTitle(for: material, revisedBody: revisedBody)),
            rawTranscript: material.transcript,
            originalTranscript: correctedBody,
            corrections: corrections,
            suggestions: suggestions,
            revisedBody: revisedBody,
            notes: language.normalize("原稿来源：\(material.origin.label)。使用 \(modelLabel) 完成“全文编辑蓝图 → 带上下文分段改写 → \(finalReviewLabel)”本机流水线，共 \(taskBoard.count) 块；标题与序号由程序锁定，单块上限约 \(maximumCharactersPerCard) 字，生成上限 \(generationPlan.maximumOutputTokens) tokens，上下文 \(selection.contextSize) tokens。全文相似度 \(Int((overallSimilarity * 100).rounded()))%。输出语言：\(language.rawValue)。\(usedQualityRetry ? "分段结果已通过自动质量复检。" : "")"),
            transcriptOrigin: material.origin,
            style: style,
            durationSeconds: material.durationSeconds
        )
    }

    func designVisualPrompts(
        for output: RewriteOutput,
        modelMode: ModelMode,
        language: OutputLanguage,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> VisualPromptGenerationResult {
        guard let assets else { throw EmbeddedModelError.assetsMissing }
        guard memoryBudget.isEightGBSafe else {
            throw EmbeddedModelError.launchFailed("内存预算超过安全上限。")
        }
        let planned = VisualShotPlanner.plannedShots(for: output)
        guard !planned.isEmpty else {
            return VisualPromptGenerationResult(shots: [], source: .templateFallback)
        }
        let selection = Self.selectModel(
            assets: assets,
            mode: modelMode,
            physicalMemoryGB: memoryBudget.physicalMemoryGB,
            requestedContextSize: contextLimit
        )
        let plan = Self.generationPlan(
            contextSize: selection.contextSize,
            usesEnhancedModel: assets.enhancedModelURL == selection.url
        )
        let batches = planned.chunked(maximumCount: VisualPromptDesigner.batchSize)
        var completedShots: [VisualShot] = []
        var designedCount = 0
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            progress(RewriteProgress(
                completed: index,
                total: batches.count,
                message: "AI 正在设计第 \(index + 1)/\(batches.count) 组镜头场景…"
            ))
            let raw = try await run(
                prompt: VisualPromptDesigner.prompt(
                    for: batch,
                    style: output.style,
                    language: language,
                    visualStyle: output.effectiveVisualStyle
                ),
                modelURL: selection.url,
                contextSize: selection.contextSize,
                maximumOutputTokens: min(
                    plan.maximumOutputTokens,
                    max(900, batch.count * 180)
                ),
                temperature: 0.55
            )
            let parsed = VisualPromptDesigner.applying(
                rawResponse: raw,
                to: batch,
                language: language,
                visualStyle: output.effectiveVisualStyle
            )
            completedShots.append(contentsOf: parsed.shots)
            designedCount += parsed.designedCount
        }
        progress(RewriteProgress(
            completed: batches.count,
            total: batches.count,
            message: "AI 镜头场景设计完成"
        ))
        return VisualPromptGenerationResult(
            shots: completedShots,
            source: designedCount == 0
                ? .templateFallback
                : (designedCount == planned.count ? .localAI : .mixedAI)
        )
    }

    func structuralRewriteDocument(
        original: String,
        sourceTitle: String,
        sourceOrigin: TranscriptOrigin,
        style: RewriteStyle,
        language: OutputLanguage,
        blueprint: EditorialBlueprint,
        modelURL: URL,
        contextSize: Int,
        maximumOutputTokens: Int
    ) async throws -> String? {
        let maximumCharacters = contextSize <= 4_096 ? 420 : 620
        let cards = Self.taskBoard(original, maximumCharacters: maximumCharacters)
        var drafts: [String] = []
        let debug = ProcessInfo.processInfo.environment["CHENGGAO_REWRITE_DEBUG"] == "1"

        for (index, card) in cards.enumerated() {
            try Task.checkCancellation()
            var candidates: [String] = []
            for attempt in 1...2 {
                let raw = try await run(
                    prompt: Self.structuralRewritePrompt(
                        text: card.source,
                        sourceTitle: sourceTitle,
                        sourceOrigin: sourceOrigin,
                        style: style,
                        language: language,
                        blueprint: blueprint,
                        index: index + 1,
                        total: cards.count,
                        protectedHeading: card.protectedHeading,
                        previousDraft: drafts.last.map { String($0.suffix(240)) },
                        nextSourcePreview: index + 1 < cards.count
                            ? String(cards[index + 1].source.prefix(240))
                            : nil,
                        attempt: attempt
                    ),
                    modelURL: modelURL,
                    contextSize: contextSize,
                    maximumOutputTokens: maximumOutputTokens,
                    temperature: attempt == 1 ? 0.55 : 0.65
                )
                guard let parsed = Self.parseRevisedOnly(raw, language: language) else {
                    if debug {
                        print("structural group \(index + 1)/\(cards.count) attempt \(attempt): parse failed, prefix=\(String(raw.prefix(300))), suffix=\(String(raw.suffix(900)))")
                    }
                    continue
                }
                let restored = Self.restoringStructure(
                    in: ParsedRewriteChunk(
                        corrected: card.source,
                        corrections: [],
                        suggestion: RevisionSuggestion(
                            original: card.source,
                            suggestion: "全文结构重写",
                            reason: "降低逐句复述",
                            imagePlacement: "本段后",
                            imageSuggestion: "本段核心场景"
                        ),
                        revised: parsed
                    ),
                    from: card,
                    language: language
                ).revised
                let lengthRatio = Double(restored.count) / Double(max(1, card.source.count))
                let candidateSimilarity = Self.rewriteSimilarity(original: card.source, revised: restored)
                if debug {
                    print("structural group \(index + 1)/\(cards.count) attempt \(attempt): similarity=\(candidateSimilarity), lengthRatio=\(lengthRatio)")
                }
                if lengthRatio >= 0.68,
                   lengthRatio <= 1.20,
                   candidateSimilarity < 0.92,
                   Self.structuralMarkers(in: restored) == Self.structuralMarkers(in: card.source) {
                    candidates.append(restored)
                }
            }
            guard let best = candidates.min(by: {
                Self.rewriteSimilarity(original: card.source, revised: $0)
                    < Self.rewriteSimilarity(original: card.source, revised: $1)
            }) else { return nil }
            drafts.append(best)
        }

        let combined = drafts.joined(separator: "\n\n")
        let combinedSimilarity = Self.rewriteSimilarity(original: original, revised: combined)
        let combinedIssues = Self.documentQualityIssues(
            original: original,
            revised: combined,
            sourceOrigin: sourceOrigin,
            style: style
        )
        if debug {
            print("structural combined: similarity=\(combinedSimilarity), issues=\(combinedIssues)")
        }
        guard combinedSimilarity < 0.90, combinedIssues.isEmpty else { return nil }
        return combined
    }

    private func run(
        prompt: String,
        modelURL: URL,
        contextSize: Int,
        maximumOutputTokens: Int,
        temperature: Double = 0.35
    ) async throws -> String {
        guard let assets else { throw EmbeddedModelError.assetsMissing }
        let process = Process()
        let standardError = Pipe()
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "chenggao-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        process.executableURL = assets.executableURL
        process.currentDirectoryURL = assets.executableURL.deletingLastPathComponent()
        process.arguments = [
            "-m", modelURL.path,
            "-c", String(contextSize),
            "-n", String(maximumOutputTokens),
            "-ngl", "99",
            "--temp", String(format: "%.2f", temperature),
            "--top-k", "20",
            "--top-p", "0.90",
            "--repeat-penalty", "1.08",
            "--no-display-prompt",
            "--single-turn",
            "--simple-io",
            "--no-warmup",
            "--log-disable",
            "--no-show-timings",
            "--jinja",
            "--chat-template-kwargs", #"{"enable_thinking":false}"#,
            "--reasoning", "off",
            "-o", outputURL.path,
            "-p", prompt
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        process.standardInput = FileHandle.nullDevice

        let box = ModelProcessBox(process)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { _ in
                        continuation.resume(returning: ())
                    }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                if box.process.isRunning { box.process.terminate() }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EmbeddedModelError.launchFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EmbeddedModelError.generationFailed(detail.isEmpty ? "退出码 \(process.terminationStatus)" : detail)
        }

        guard let outputData = try? Data(contentsOf: outputURL) else {
            throw EmbeddedModelError.generationFailed("没有生成输出文件。")
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    nonisolated static func blueprintPrompt(
        text: String,
        sourceTitle: String,
        sourceOrigin: TranscriptOrigin,
        style: RewriteStyle,
        language: OutputLanguage
    ) -> String {
        """
        /no_think
        你是总编辑。先通读下面的全文概览，为后续分段改写建立一份紧凑、可执行的编辑蓝图。此阶段不写成稿、不做配图。

        要求：
        1. \(language.promptInstruction)
        2. 输出目标是“\(style.rawValue)”，原稿来源是“\(sourceOrigin.label)”。
        3. coreAngle 写清真正值得讲的核心判断；openingHook 必须来自原稿事实，不能制造悬念或结论。
        4. storyArc 给出 3–6 个叙事步骤，明确哪些信息先讲、哪些后讲。
        5. mustKeepFacts 列出 4–10 条不可遗漏的事实、争议双方、因果关系或限定条件；保留关键人名、日期和数字。
        6. exclusions 只列页面噪声、重复信息和与主题无关的内容，不得把不同信源、否认、反方说法或关键背景列为可删除项。
        7. 只输出一个 JSON 对象，不要 Markdown、解释或思考过程。

        JSON 字段：
        {"coreAngle":"核心角度","openingHook":"事实型开头","storyArc":["步骤1","步骤2","步骤3"],"mustKeepFacts":["事实1","事实2"],"tone":"语气和节奏","exclusions":["可删除噪声"]}

        标题：
        \(sourceTitle)

        全文概览：
        \(text)
        """
    }

    nonisolated static func parseBlueprint(
        _ raw: String,
        sourceTitle: String,
        sourceText: String,
        style: RewriteStyle,
        language: OutputLanguage
    ) -> EditorialBlueprint {
        let cleaned = assistantPayload(from: raw)
        if let response = parseJSONObject(from: cleaned) {
            let arc = (response["storyArc"] as? [String] ?? []).filter { !$0.isEmpty }
            let facts = (response["mustKeepFacts"] as? [String] ?? []).filter { !$0.isEmpty }
            let exclusions = (response["exclusions"] as? [String] ?? []).filter { !$0.isEmpty }
            if let angle = (response["coreAngle"] as? String)?.nonEmpty,
               let hook = (response["openingHook"] as? String)?.nonEmpty,
               !arc.isEmpty,
               !facts.isEmpty {
                return EditorialBlueprint(
                    coreAngle: language.normalize(angle),
                    openingHook: language.normalize(hook),
                    storyArc: arc.map(language.normalize),
                    mustKeepFacts: facts.map(language.normalize),
                    tone: language.normalize((response["tone"] as? String)?.nonEmpty ?? style.rawValue),
                    exclusions: exclusions.map(language.normalize)
                )
            }
        }

        let sentences = OfflineRewritePipeline.sentences(in: sourceText)
        let facts = Array(sentences.filter { $0.count >= 12 }.prefix(6))
        return EditorialBlueprint(
            coreAngle: language.normalize(sourceTitle),
            openingHook: language.normalize(sentences.first ?? sourceTitle),
            storyArc: ["核心事实", "关键经过或依据", "影响、争议与必要限定"],
            mustKeepFacts: facts.isEmpty ? [language.normalize(sourceTitle)] : facts.map(language.normalize),
            tone: language.normalize(style == .spoken || style == .channel ? "清楚、有节奏、克制，不夸张" : "清楚、准确、层次分明"),
            exclusions: ["关注引导、版权尾注、相关推荐和重复页面文字"]
        )
    }

    nonisolated static func documentOverview(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        let sections = chunks(text, maximumCharacters: max(180, maximumCharacters / 5))
        let indices = Set([0, 1, sections.count / 2, max(0, sections.count - 2), max(0, sections.count - 1)])
        return indices.sorted().compactMap { index in
            guard sections.indices.contains(index) else { return nil }
            return "[全文位置 \(index + 1)/\(sections.count)]\n\(sections[index])"
        }.joined(separator: "\n\n")
    }

    nonisolated static func canRunWholeDocumentReview(
        original: String,
        draft: String,
        contextSize: Int
    ) -> Bool {
        original.count + draft.count <= Int(Double(contextSize) * 0.46)
    }

    nonisolated static func wholeDocumentReviewPrompt(
        original: String,
        draft: String,
        blueprint: EditorialBlueprint,
        sourceOrigin: TranscriptOrigin,
        style: RewriteStyle,
        language: OutputLanguage
    ) -> String {
        """
        /no_think
        你是独立终审编辑。下面有原稿、编辑蓝图和分段改写初稿。请先在内部逐项核对，再直接给出统一后的最终成稿。

        终审标准：
        1. \(language.promptInstruction)
        2. 成稿必须符合“\(style.rawValue)”，开头直接建立关注点，正文按蓝图推进，结尾完成必要收束。
        3. 保留原稿的重要事实、人名、地名、日期、数字、信源、因果关系、否认或反方说法；不得把不同立场压成单一结论。
        4. 删除“\(sourceOrigin == .webArticle ? "版权尾注、关注引导、往期推荐等页面噪声" : "无意义口头填充和重复表达")”，但不能用删掉后半篇的方式伪装成改写。
        5. 消除分段拼接感、重复开场、重复结论和机械连接词；重新组织句式和信息顺序，不逐句压缩复述。
        6. 不新增原稿没有的事实、评价或煽动性表达，不输出镜头指令、配图建议和编辑说明。
        7. 只输出一个 JSON 对象：{"revised":"通过终审的完整成稿"}。不要输出其他字段、Markdown或解释。

        编辑蓝图：
        \(blueprint.compactContext)

        原稿：
        \(original)

        分段改写初稿：
        \(draft)
        """
    }

    nonisolated static func parseRevisedOnly(
        _ raw: String,
        language: OutputLanguage = .simplifiedChinese
    ) -> String? {
        let cleaned = assistantPayload(from: raw)
        if let response = parseJSONObject(from: cleaned),
           let revised = (response["revised"] as? String)?.nonEmpty {
            return language.normalize(revised)
        }
        return nil
    }

    nonisolated static func parseJSONObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        let json = String(text[start...end])
        if let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        var repaired = ""
        var isInsideString = false
        var isEscaped = false
        for character in json {
            if isInsideString {
                if isEscaped {
                    repaired.append(character)
                    isEscaped = false
                } else if character == "\\" {
                    repaired.append(character)
                    isEscaped = true
                } else if character == "\"" {
                    repaired.append(character)
                    isInsideString = false
                } else if character == "\n" {
                    repaired += "\\n"
                } else if character == "\r" {
                    repaired += "\\r"
                } else if character == "\t" {
                    repaired += "\\t"
                } else {
                    repaired.append(character)
                }
            } else {
                repaired.append(character)
                if character == "\"" { isInsideString = true }
            }
        }
        guard let data = repaired.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func assistantPayload(from raw: String) -> String {
        var cleaned = raw.replacingOccurrences(
            of: #"(?s)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if let assistantMarker = cleaned.range(of: "Assistant:", options: .backwards) {
            cleaned = String(cleaned[assistantMarker.upperBound...])
        } else if let assistantMarker = cleaned.range(of: "<|im_start|>assistant", options: .backwards) {
            cleaned = String(cleaned[assistantMarker.upperBound...])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func documentQualityIssues(
        original: String,
        revised: String,
        sourceOrigin: TranscriptOrigin,
        style: RewriteStyle
    ) -> [String] {
        let source = comparisonText(original)
        let draft = comparisonText(revised)
        guard !source.isEmpty else { return draft.isEmpty ? ["修改稿为空"] : [] }
        var issues: [String] = []
        let crossLanguage = isCrossLanguageRewrite(original: original, revised: revised)

        if (style == .spoken || style == .channel),
           source.count >= 120,
           similarity(source, draft) >= 0.90 {
            issues.append("全文仍以逐句复述为主，实质改写幅度不足")
        }

        let minimumRatio: Double = if crossLanguage {
            style == .spoken || style == .channel ? 0.28 : 0.24
        } else {
            switch (sourceOrigin, style) {
            case (.webArticle, .spoken), (.webArticle, .channel): 0.55
            case (.webArticle, .article), (.webArticle, .social): 0.42
            case (.socialImageText, _): 0.35
            case (_, .spoken), (_, .channel): 0.62
            case (_, .article), (_, .social): 0.50
            }
        }
        if source.count >= 180, Double(draft.count) / Double(source.count) < minimumRatio {
            issues.append("成稿过度缩短，可能遗漏后半篇重要信息")
        }

        let anchorSource: String
        if sourceOrigin == .socialImageText {
            anchorSource = original
                .replacingOccurrences(of: #"原图\s*\d+："#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"https?://\S+|[A-Za-z0-9_-]{16,}"#, with: "", options: .regularExpression)
        } else {
            anchorSource = original
        }
        var anchors = factualAnchors(in: anchorSource)
        if sourceOrigin == .socialImageText {
            anchors.removeAll { anchor in
                anchor.count == 1 && anchor.first?.isNumber == true
            }
        }
        let comparableAnchors = crossLanguage
            ? anchors.filter { $0.first?.isNumber == true }
            : anchors
        let minimumAnchorCount = crossLanguage ? 2 : 4
        if comparableAnchors.count >= minimumAnchorCount {
            let retained = comparableAnchors.filter { revised.localizedCaseInsensitiveContains($0) }
            let requiredRatio = crossLanguage ? 1.0 : (sourceOrigin == .socialImageText ? 0.30 : 0.60)
            if Double(retained.count) / Double(comparableAnchors.count) < requiredRatio {
                issues.append("日期、数字、信源或关键名词保留不足")
            }
        }

        let substantiveSections = original
            .replacingOccurrences(of: #"\n\s*\n"#, with: "\u{1E}", options: .regularExpression)
            .components(separatedBy: "\u{1E}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 60 }
        if substantiveSections.count >= 2, !crossLanguage, sourceOrigin != .socialImageText {
            let omittedSection = substantiveSections.contains { section in
                let sectionAnchors = factualAnchors(in: section)
                if sectionAnchors.count >= 2 {
                    let retained = sectionAnchors.filter { revised.localizedCaseInsensitiveContains($0) }
                    return Double(retained.count) / Double(sectionAnchors.count) < 0.50
                }
                return bigramCoverage(source: comparisonText(section), target: draft) < 0.12
            }
            if omittedSection {
                issues.append("至少一个实质段落的独有事实没有进入成稿")
            }
        }

        if source.count >= 360, !crossLanguage, sourceOrigin != .socialImageText {
            let characters = Array(source)
            let cut1 = characters.count / 3
            let cut2 = characters.count * 2 / 3
            let thirds = [
                String(characters[0..<cut1]),
                String(characters[cut1..<cut2]),
                String(characters[cut2..<characters.count])
            ]
            if thirds.contains(where: { bigramCoverage(source: $0, target: draft) < 0.10 }) {
                issues.append("全文某一部分几乎没有进入成稿，存在截断或整段遗漏")
            }
        }

        let repetitiveOpenings = ["先说结论", "先看重点", "接着看", "进一步来看"]
        if repetitiveOpenings.contains(where: { revised.components(separatedBy: $0).count - 1 >= 3 }) {
            issues.append("成稿存在明显的分段拼接和重复连接词")
        }
        return issues
    }

    nonisolated static func isCrossLanguageRewrite(original: String, revised: String) -> Bool {
        struct ScriptCounts {
            var latin = 0
            var han = 0
            var kana = 0
            var total: Int { latin + han + kana }
        }
        func counts(_ text: String) -> ScriptCounts {
            var result = ScriptCounts()
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x0041...0x005A, 0x0061...0x007A:
                    result.latin += 1
                case 0x3400...0x4DBF, 0x4E00...0x9FFF:
                    result.han += 1
                case 0x3040...0x30FF:
                    result.kana += 1
                default:
                    continue
                }
            }
            return result
        }
        let source = counts(original)
        let target = counts(revised)
        guard source.total >= 12, target.total >= 12 else { return false }
        let targetIsChinese = Double(target.han) / Double(target.total) >= 0.55
            && target.kana <= max(2, target.han / 20)
        guard targetIsChinese else { return false }
        let sourceIsLatin = Double(source.latin) / Double(source.total) >= 0.55
        let sourceIsJapanese = source.kana >= 4
            && Double(source.kana) / Double(source.total) >= 0.12
        return sourceIsLatin || sourceIsJapanese
    }

    nonisolated static func editorialSuggestion(
        original: String,
        revised: String,
        blueprint: EditorialBlueprint,
        style: RewriteStyle,
        language: OutputLanguage,
        index: Int
    ) -> RevisionSuggestion {
        let sourcePreview = String(original.replacingOccurrences(of: "\n", with: " ").prefix(54))
        let revisedPreview = String(revised.replacingOccurrences(of: "\n", with: " ").prefix(54))
        let arc = blueprint.storyArc.prefix(3).joined(separator: "、")
        return RevisionSuggestion(
            original: original,
            suggestion: language.normalize("将原段“\(sourcePreview)”从逐句推进改为服从全文核心角度“\(blueprint.coreAngle)”；本段按“\(arc)”中的对应位置重排信息，并与相邻段避免重复开场或结论。"),
            reason: language.normalize("修改稿改以“\(revisedPreview)”展开，目的是强化\(style.rawValue)的关注点和节奏，同时保留本段事实、数字与限定条件。"),
            imagePlacement: language.normalize("第 \(index) 段核心事实之后"),
            imageSuggestion: language.normalize("呈现本段“\(revisedPreview)”对应的核心人物、地点或事件场景")
        )
    }

    nonisolated static func factualAnchors(in text: String) -> [String] {
        let patterns = [
            #"[A-Za-z]{2,}(?:[- ][A-Za-z0-9]+)*"#,
            #"\d+(?:\.\d+)?(?:年|月|日|号|时|小时|分钟|人|名|个|架|次|%|％)?"#,
            #"[“「『《][^”」』》\n]{2,24}[”」』》]"#
        ]
        var values: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let value = String(text[swiftRange])
                if !values.contains(value) { values.append(value) }
            }
        }
        return values
    }

    nonisolated private static func bigramCoverage(source: String, target: String) -> Double {
        func bigrams(_ text: String) -> Set<String> {
            let characters = Array(text)
            guard characters.count >= 2 else { return [] }
            return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
        }
        let sourceBigrams = bigrams(source)
        guard !sourceBigrams.isEmpty else { return 1 }
        return Double(sourceBigrams.intersection(bigrams(target)).count) / Double(sourceBigrams.count)
    }

    nonisolated static func prompt(
        text: String,
        sourceTitle: String,
        sourceOrigin: TranscriptOrigin = .pastedText,
        style: RewriteStyle,
        language: OutputLanguage,
        index: Int,
        total: Int,
        protectedHeading: String? = nil,
        retryReason: String? = nil,
        editorialContext: String? = nil,
        previousDraft: String? = nil,
        nextSourcePreview: String? = nil
    ) -> String {
        let articleRule = sourceOrigin == .webArticle
            ? """
            11. 这是网页文章。只保留支撑主题的事实、论点、数据、案例和必要背景；删除关注引导、二维码提示、点赞在看、阅读原文、商务合作、服务宣传、作者自我推广及与主题无关的推荐内容。
            12. 不要机械复述全部网页文字。revised 应重新组织核心信息，但不得把删减变成过度摘要，不得遗漏影响结论的重要限定条件。
            """
            : ""
        let sourceLabel = switch style {
        case .article: "文章正文"
        case .social: "原始图文文案"
        case .spoken, .channel: "完整口播稿"
        }
        let correctionLabel = switch sourceOrigin {
        case .webArticle, .socialImageText: "网页正文"
        case .platformSubtitle, .localSpeechRecognition: "语音识别稿"
        case .pastedText: "原始内容"
        }
        let retryRule = retryReason.map {
            """
            上次输出未通过质量检查（\($0)）。这次必须真正改写句式和结构；suggestion/reason 只能讨论文字修改，禁止写图片、画面或配图；revised 不得与原文相同。
            """
        } ?? ""
        let substantiveRewriteRule = switch style {
        case .spoken, .channel:
            "11. revised 必须进行实质改写：重新设计开头钩子，调整信息顺序，合并或拆分句子，替换重复表达并建立口播节奏；至少约四分之一的句式与措辞应发生变化。只做简繁转换、断句、标点或少量同义词替换视为失败。"
        case .article, .social:
            "11. revised 必须重组信息层次和句式，不能只做简繁转换、断句、标点或少量同义词替换；事实、数字和限定条件必须保留。"
        }
        let structureRule = protectedHeading.map {
            """
            11. 本任务板块的锁定标题/序号是“\($0)”。corrected 和 revised 必须以这一行原样开头，不得删除、改写、重排或另行生成序号；只处理它后面的正文。
            """
        } ?? ""
        let contextRule = editorialContext.map {
            """
            全文编辑蓝图：
            \($0)
            本段必须服从这份蓝图，不得把它当成需要输出的正文。
            """
        } ?? ""
        let continuityRule = """
        上一段成稿结尾（仅用于衔接，禁止重复）：
        \(previousDraft ?? "这是全文第一段，请承担开场任务。")

        下一段原稿预览（仅用于避免抢写后文）：
        \(nextSourcePreview ?? "这是全文最后一段，应完成必要收束，但不要添加原文没有的结论。")
        """
        return """
        /no_think
        你是一名严谨的中文内容编辑。下面是\(sourceLabel)的第 \(index)/\(total) 段。你只负责校对和生成成稿，编辑建议与配图将在文字定稿后另行生成。

        规则：
        1. \(language.promptInstruction)
        2. 先校对\(correctionLabel)。corrected 必须保持原稿语言，只纠正高置信度的同音错词、专有名词和明显错别字，不得翻译或润色；revised 才负责翻译成目标语言并改写。
        3. corrections 逐项记录原词、校正词和上下文理由。没有高置信度纠错时返回空数组。
        4. 保持原意与事实，不编造人名、数字、日期或结论。
        5. revised 必须以 corrected 为依据，不遗漏本段实质信息；跨语言时必须忠实区分官员、专家、批评者、支持者、媒体和消息人士等身份，不得替换信源或强化语气。
        6. revised 必须是修改后的完整本段，不能写摘要、建议、分析报告、镜头指令或配图文字。
        7. 第 1 段承担开场，第 \(total) 段承担收束；中间段不得重复开场或提前总结全文。
        8. 无法确定的专有名词保持原样，不得猜测替换。
        9. 只输出一个 JSON 对象，不要 Markdown，不要代码围栏，不要思考过程。
        \(substantiveRewriteRule)
        \(structureRule)
        \(articleRule)
        \(retryRule)

        \(contextRule)
        \(continuityRule)

        JSON 字段：
        {"corrected":"仅纠错后的完整本段","corrections":[{"original":"误识别词","corrected":"正确词","reason":"上下文依据"}],"revised":"修改后的完整本段"}

        视频或文章标题：
        \(sourceTitle)

        原始\(sourceLabel)第 \(index) 段：
        \(text)
        """
    }

    nonisolated static func parseChunk(
        _ raw: String,
        original: String,
        language: OutputLanguage = .simplifiedChinese,
        index: Int = 1
    ) -> ParsedRewriteChunk {
        var cleaned = raw.replacingOccurrences(
            of: #"(?s)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if let assistantMarker = cleaned.range(of: "Assistant:", options: .backwards) {
            cleaned = String(cleaned[assistantMarker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start <= end {
            let json = String(cleaned[start...end])
            if let data = json.data(using: .utf8),
               let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let revised = (response["revised"] as? String)?.nonEmpty {
                let modelCorrected = (response["corrected"] as? String)?.nonEmpty ?? original
                let correctedWasTranslated = isCrossLanguageRewrite(original: original, revised: modelCorrected)
                let corrected = correctedWasTranslated ? original : modelCorrected
                let correctionItems = correctedWasTranslated ? [] : (response["corrections"] as? [[String: Any]] ?? []).compactMap { item -> TranscriptCorrection? in
                    guard let from = (item["original"] as? String)?.nonEmpty,
                          let to = (item["corrected"] as? String)?.nonEmpty,
                          from != to else { return nil }
                    return TranscriptCorrection(
                        original: from,
                        corrected: to,
                        reason: language.normalize((item["reason"] as? String)?.nonEmpty ?? "根据上下文判断")
                    )
                }
                return ParsedRewriteChunk(
                    corrected: corrected,
                    corrections: correctionItems,
                    suggestion: RevisionSuggestion(
                        original: original,
                        suggestion: language.normalize((response["suggestion"] as? String)?.nonEmpty ?? "优化本段结构和表达。"),
                        reason: language.normalize((response["reason"] as? String)?.nonEmpty ?? "提高口播清晰度，同时保留原意。"),
                        imagePlacement: language.normalize((response["imagePlacement"] as? String)?.nonEmpty ?? "第 \(index) 段结尾后"),
                        imageSuggestion: language.normalize((response["imageSuggestion"] as? String)?.nonEmpty ?? "生成一张能够概括本段核心信息的真实场景图，主体明确，中景构图，自然光，纪实编辑摄影风格；画面比例 9:16；不要出现文字、二维码、水印和品牌标志。")
                    ),
                    revised: language.normalize(revised)
                )
            }
        }

        let fallback = Self.fallbackRevision(original, language: language)
        return ParsedRewriteChunk(
            corrected: original,
            corrections: [],
            suggestion: RevisionSuggestion(
                original: original,
                suggestion: language.normalize("模型没有返回完整结构，已对本段执行基础断句、去填充词和标点整理。"),
                reason: language.normalize("确保第三页始终包含修改后的稿件，而不是把修改意见误当成成稿。"),
                imagePlacement: language.normalize("第 \(index) 段结尾后"),
                imageSuggestion: language.normalize("生成一张呈现本段核心人物、产品或场景的真实图片，主体明确，中景构图，自然光，纪实编辑摄影风格；画面比例 9:16；不要出现文字、二维码、水印和品牌标志；专有名词不确定时避免虚构具体外貌。")
            ),
            revised: fallback
        )
    }

    nonisolated static func deepRewritePrompt(
        text: String,
        sourceTitle: String,
        style: RewriteStyle,
        language: OutputLanguage,
        protectedHeading: String? = nil,
        editorialContext: String? = nil
    ) -> String {
        let headingRule = protectedHeading.map {
            "首行必须原样保留锁定标题或序号“\($0)”，从第二行开始改写正文。"
        } ?? ""
        let styleRule = switch style {
        case .spoken, .channel:
            "像成熟短视频主笔一样重写：先提炼本段最有冲击力的判断，再按因果关系重新排列信息；合并零碎短句，拆开过长句，使用自然口语和有变化的节奏。"
        case .article:
            "像资深编辑一样重写：先明确核心判断，再按事实、原因和影响重新组织段落与句式。"
        case .social:
            "像成熟社交媒体编辑一样重写：强化开头、信息层次和阅读节奏，避免逐句复述。"
        }
        return """
        /no_think
        你只负责深度改写，不做校对报告、修改建议、配图建议或分析。

        要求：
        1. \(language.promptInstruction)
        2. \(styleRule)
        3. 保留原文全部重要事实、人名、地名、日期、数字、因果关系和限定条件，不新增事实。
        4. 不得沿用原文的逐句顺序；不得只做简繁转换、标点、断句或少量同义词替换。
        5. 改写稿长度保持在原文的 75%–115%，必须是可以直接使用的完整本段。
        6. \(headingRule)
        7. 只输出一个 JSON 对象：{"revised":"深度改写后的完整本段"}。不要输出其他字段、Markdown或解释。

        全文标题：
        \(sourceTitle)

        全文编辑蓝图：
        \(editorialContext ?? "围绕标题保留事实并重组表达。")

        待深度改写的本段：
        \(text)
        """
    }

    nonisolated static func structuralRewritePrompt(
        text: String,
        sourceTitle: String,
        sourceOrigin: TranscriptOrigin,
        style: RewriteStyle,
        language: OutputLanguage,
        blueprint: EditorialBlueprint,
        index: Int,
        total: Int,
        protectedHeading: String? = nil,
        previousDraft: String? = nil,
        nextSourcePreview: String? = nil,
        attempt: Int = 1
    ) -> String {
        let headingRule = protectedHeading.map {
            "首行必须原样保留“\($0)”，只重写它后面的正文。"
        } ?? ""
        let retryRule = attempt > 1
            ? "上一次仍然太像原稿。这次必须更换切入点，把结论、原因、例证和限定条件重新排列；开头不得沿用原稿前十二个字。"
            : ""
        return """
        /no_think
        你是短视频总编，正在修复一版与原稿过于相似的成稿。当前是全文第 \(index)/\(total) 个语义组。只做结构重写，不输出校对、建议、镜头或分析。

        硬性要求：
        1. \(language.promptInstruction)
        2. 围绕编辑蓝图重新选择本组切入点。先讲本组最关键的判断、矛盾或结果，再组织原因和证据；不得沿用原稿逐句顺序。
        3. 至少合并或拆分两组句子，改变段落层次和连接方式。不能只做繁简转换、标点、断句和少量同义词替换。
        4. 保留所有重要人物、出处、数字、时间、因果关系和限定条件；语音识别不确定的词保持原样，不得自行编造。
        5. 长度保持在原文的 72%–110%，写成可以直接使用的“\(style.rawValue)”。
        6. 第 1 组负责建立开场，最后一组负责收束；其他组禁止重复全文标题、开场和结论。
        7. \(headingRule)
        8. \(retryRule)
        9. 只输出一个 JSON 对象：{"revised":"完成结构重写的完整语义组"}。不要输出其他内容。

        全文标题：
        \(sourceTitle)

        原稿来源：\(sourceOrigin.label)

        编辑蓝图：
        \(blueprint.compactContext)

        上一组成稿结尾（仅用于衔接，不得重复）：
        \(previousDraft ?? "这是第一组。")

        下一组原稿预览（仅用于避免抢写后文）：
        \(nextSourcePreview ?? "这是最后一组。")

        待结构重写的语义组：
        \(text)
        """
    }

    nonisolated static func selectModel(
        assets: EmbeddedModelAssets,
        mode: ModelMode,
        physicalMemoryGB: Int,
        requestedContextSize: Int = 4_096
    ) -> (url: URL, label: String, contextSize: Int) {
        let supportedContext = [2_048, 4_096, 8_192]
        let requested = supportedContext.min { abs($0 - requestedContextSize) < abs($1 - requestedContextSize) } ?? 4_096
        let contextSize = physicalMemoryGB >= 16 ? requested : min(requested, 4_096)
        _ = mode
        let label = physicalMemoryGB >= 16 ? "Qwen3 1.7B Q4_K_M" : "Qwen3 1.7B Q4_K_M（8GB 保护模式）"
        return (assets.fastModelURL, label, contextSize)
    }

    nonisolated static func generationPlan(
        contextSize: Int,
        usesEnhancedModel: Bool
    ) -> RewriteGenerationPlan {
        if contextSize <= 4_096 {
            return RewriteGenerationPlan(
                maximumCharactersPerCard: 700,
                maximumOutputTokens: 1_600
            )
        }
        if usesEnhancedModel {
            return RewriteGenerationPlan(
                maximumCharactersPerCard: 1_200,
                maximumOutputTokens: 2_400
            )
        }
        return RewriteGenerationPlan(
            maximumCharactersPerCard: 900,
            maximumOutputTokens: 2_000
        )
    }

    nonisolated static func qualityRetryModel(
        assets: EmbeddedModelAssets,
        current: (url: URL, label: String, contextSize: Int),
        physicalMemoryGB: Int
    ) -> (url: URL, label: String, contextSize: Int) {
        _ = assets
        _ = physicalMemoryGB
        return current
    }

    nonisolated static func qualityIssues(
        in result: ParsedRewriteChunk,
        original: String,
        style: RewriteStyle,
        similarityThreshold: Double? = nil
    ) -> [String] {
        var issues: [String] = []
        let source = comparisonText(original)
        let revised = comparisonText(result.revised)
        let crossLanguage = isCrossLanguageRewrite(original: original, revised: result.revised)
        let defaultMaximumSimilarity = switch style {
        case .spoken, .channel: 0.88
        case .social: 0.90
        case .article: 0.94
        }
        let maximumSimilarity = similarityThreshold ?? defaultMaximumSimilarity
        if source.count >= 40, similarity(source, revised) >= maximumSimilarity {
            issues.append("只调整了简繁、标点或少量措辞，没有完成实质改写")
        }

        let advice = result.suggestion.suggestion + result.suggestion.reason
        let imageTerms = ["图片", "画面", "配图", "放置", "插图"].filter { advice.contains($0) }.count
        let editingTerms = ["删", "改", "压缩", "调整", "重组", "句式", "结构", "表达", "重复", "开头", "段落"]
        if imageTerms >= 2, !editingTerms.contains(where: advice.contains) {
            issues.append("修改建议误写成配图建议")
        }

        if result.revised.contains("修改建议") || result.revised.contains("作为AI") || result.revised.contains("无法完成") {
            issues.append("修改稿包含说明性文字")
        }
        let minimumArticleLength = crossLanguage ? max(40, original.count / 5) : max(40, original.count / 3)
        if style == .article, result.revised.count < minimumArticleLength {
            issues.append("文章改写过度缩短")
        }
        let expectedMarkers = structuralMarkers(in: original)
        if !expectedMarkers.isEmpty, structuralMarkers(in: result.revised) != expectedMarkers {
            issues.append("修改稿的标题或序号与原稿不一致")
        }
        return issues
    }

    nonisolated static func rewriteSimilarity(original: String, revised: String) -> Double {
        similarity(comparisonText(original), comparisonText(revised))
    }

    nonisolated static func qualityFallback(
        original: String,
        corrected: String,
        corrections: [TranscriptCorrection],
        style: RewriteStyle,
        language: OutputLanguage,
        index: Int
    ) -> ParsedRewriteChunk {
        let source = corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original : corrected
        let heading = protectedHeading(in: source)
        let bodySource = removingProtectedHeading(from: source, heading: heading)
        let sentences = OfflineRewritePipeline.sentences(in: bodySource)
        let revised: String
        switch style {
        case .article:
            let sectionNames = ["核心判断", "变化正在发生", "能力边界", "需要注意的风险", "为什么仍需人工复核", "更合理的协作方式"]
            revised = sentences.enumerated().map { offset, sentence in
                let heading = offset < sectionNames.count ? sectionNames[offset] : "补充信息 \(offset + 1)"
                var body = sentence
                let replacements = [
                    "正在改变": "正逐步重塑",
                    "过去，": "以往，",
                    "现在，": "如今，",
                    "不过，": "与此同时，",
                    "因此，": "所以，",
                    "真正有效的工作流，是": "更有效的工作方式，是"
                ]
                for (from, to) in replacements { body = body.replacingOccurrences(of: from, with: to) }
                return "\(heading)\n\(body)"
            }.joined(separator: "\n\n")
        case .spoken:
            revised = sentences.enumerated().map { offset, sentence in
                offset == 0 ? "先说结论：\(sentence)" : (offset == sentences.count - 1 ? "最后，\(sentence)" : "接着看，\(sentence)")
            }.joined(separator: "\n\n")
        case .social:
            revised = sentences.joined(separator: "\n\n")
        case .channel:
            revised = sentences.enumerated().map { $0 == 0 ? "先看重点：\($1)" : $1 }.joined(separator: "\n\n")
                + "\n\n你更关注哪一点？"
        }
        let structuredRevision = restoreProtectedHeading(heading, to: revised.isEmpty ? fallbackRevision(bodySource, language: language) : revised)
        return ParsedRewriteChunk(
            corrected: source,
            corrections: corrections,
            suggestion: RevisionSuggestion(
                original: original,
                suggestion: language.normalize("重组本段层次，替换重复连接词，并为核心判断、变化、风险和做法建立清楚结构。"),
                reason: language.normalize("小模型连续两次未产生有效改写，因此启用确定性的本机质量兜底；保留事实顺序和限定条件，不补充新结论。"),
                imagePlacement: language.normalize("第 \(index) 段核心观点之后"),
                imageSuggestion: language.normalize("生成一张能够直接说明本段核心事实的真实场景图，主体明确，有纵深的中景构图，自然光，纪实编辑摄影风格，统一配色；画面比例 9:16；不要出现文字、字幕、二维码、水印、品牌标志、宣传海报或无关人物。")
            ),
            revised: language.normalize(structuredRevision)
        )
    }

    nonisolated static func restoringStructure(
        in result: ParsedRewriteChunk,
        from card: RewriteTaskCard,
        language: OutputLanguage
    ) -> ParsedRewriteChunk {
        guard let heading = card.protectedHeading else { return result }
        var restored = result
        restored.corrected = restoreProtectedHeading(
            heading,
            to: removingGeneratedHeading(from: result.corrected, expected: heading)
        )
        restored.revised = language.normalize(restoreProtectedHeading(
            heading,
            to: removingGeneratedHeading(from: result.revised, expected: heading)
        ))
        return restored
    }

    nonisolated static func combine(
        _ results: [ParsedRewriteChunk],
        original: String,
        language: OutputLanguage,
        index: Int
    ) -> ParsedRewriteChunk {
        guard let first = results.first else {
            return ParsedRewriteChunk(
                corrected: original,
                corrections: [],
                suggestion: RevisionSuggestion(
                    original: original,
                    suggestion: language.normalize("本段没有可处理的正文。"),
                    reason: language.normalize("保留原始结构。"),
                    imagePlacement: language.normalize("第 \(index) 段后"),
                    imageSuggestion: language.normalize("生成一张概括本段主题的纪实场景图；画面比例 9:16；不要出现文字、二维码、水印或品牌标志。")
                ),
                revised: original
            )
        }
        return ParsedRewriteChunk(
            corrected: results.map(\.corrected).joined(separator: "\n\n"),
            corrections: results.flatMap(\.corrections),
            suggestion: RevisionSuggestion(
                original: original,
                suggestion: language.normalize(results.map(\.suggestion.suggestion).joined(separator: "；")),
                reason: language.normalize("原任务连续两次未达到改写标准，已拆成 \(results.count) 个小任务逐一深度改写并通过质量检查。"),
                imagePlacement: first.suggestion.imagePlacement,
                imageSuggestion: first.suggestion.imageSuggestion
            ),
            revised: results.map(\.revised).joined(separator: "\n\n")
        )
    }

    nonisolated static func taskBoard(_ text: String, maximumCharacters: Int) -> [RewriteTaskCard] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [(heading: String?, body: [String])] = []
        var currentHeading: String?
        var currentBody: [String] = []

        func flush() {
            guard currentHeading != nil || currentBody.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
            sections.append((currentHeading, currentBody))
            currentHeading = nil
            currentBody = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isProtectedHeading(trimmed) {
                flush()
                currentHeading = trimmed
            } else {
                currentBody.append(line)
            }
        }
        flush()

        var cards: [RewriteTaskCard] = []
        for section in sections {
            let body = section.body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let available = max(80, maximumCharacters - (section.heading?.count ?? 0) - 1)
            let bodyChunks = body.isEmpty ? [""] : chunks(body, maximumCharacters: available)
            for (index, bodyChunk) in bodyChunks.enumerated() {
                let heading = index == 0 ? section.heading : nil
                let source = restoreProtectedHeading(heading, to: bodyChunk)
                if !source.isEmpty { cards.append(RewriteTaskCard(source: source, protectedHeading: heading)) }
            }
        }
        return cards.isEmpty ? [RewriteTaskCard(source: text, protectedHeading: nil)] : cards
    }

    nonisolated static func structuralMarkers(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isProtectedHeading)
    }

    nonisolated private static func protectedHeading(in text: String) -> String? {
        guard let first = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines),
              isProtectedHeading(first) else { return nil }
        return first
    }

    nonisolated private static func removingProtectedHeading(from text: String, heading: String?) -> String {
        guard let heading else { return text }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == heading else { return text }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func restoreProtectedHeading(_ heading: String?, to body: String) -> String {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let heading else { return cleanBody }
        return cleanBody.isEmpty ? heading : heading + "\n" + cleanBody
    }

    nonisolated private static func removingGeneratedHeading(from text: String, expected: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return text }
        if first == expected || isProtectedHeading(first) {
            return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    nonisolated private static func isProtectedHeading(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 80 else { return false }
        if line.prefix(4).unicodeScalars.contains("\u{20E3}") { return true }
        let patterns = [
            #"^[一二三四五六七八九十百]+[、.．]?$"#,
            #"^[一二三四五六七八九十百]+[、.．]\s*\S.+$"#,
            #"^第[一二三四五六七八九十百0-9]+[章节部分]([：:].*)?$"#,
            #"^\d{1,2}[、.．]?$"#,
            #"^\d{1,2}[、.．)]\s*\S.+$"#,
            #"^[（(]\d{1,2}[）)]\s*\S*.*$"#
        ]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    nonisolated static func outputTitle(for material: SourceMaterial, revisedBody: String) -> String {
        let genericTitles = ["", "粘贴文稿", "网页正文"]
        guard genericTitles.contains(material.title) else { return material.title }
        let fallbackHeadings = Set(["核心判断", "变化正在发生", "能力边界", "需要注意的风险", "为什么仍需人工复核", "更合理的协作方式"])
        let firstLine = revisedBody
            .split(whereSeparator: { $0 == "\n" || "。！？!?".contains($0) })
            .map(String.init)
            .first { !fallbackHeadings.contains($0) && !$0.hasPrefix("补充信息 ") } ?? revisedBody
        let title = String(firstLine.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return title.isEmpty ? "未命名文稿" : title
    }

    nonisolated private static func comparisonText(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return simplified.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    nonisolated private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let a = Array(lhs)
        let b = Array(rhs)
        var previous = Array(0...b.count)
        for (indexA, charA) in a.enumerated() {
            var current = [indexA + 1] + Array(repeating: 0, count: b.count)
            for (indexB, charB) in b.enumerated() {
                current[indexB + 1] = min(
                    current[indexB] + 1,
                    previous[indexB + 1] + 1,
                    previous[indexB] + (charA == charB ? 0 : 1)
                )
            }
            previous = current
        }
        let distance = previous[b.count]
        return 1 - Double(distance) / Double(max(a.count, b.count, 1))
    }

    nonisolated static func fallbackRevision(_ original: String, language: OutputLanguage) -> String {
        let cleaned = OfflineRewritePipeline.clean(original)
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var revised = lines.joined(separator: "，")
        revised = revised.replacingOccurrences(of: #"[，,]{2,}"#, with: "，", options: .regularExpression)
        if !revised.isEmpty, !"。！？!?".contains(revised.last!) { revised += "。" }
        return language.normalize(revised)
    }

    nonisolated static func chunks(_ text: String, maximumCharacters: Int) -> [String] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var result: [String] = []
        var current = ""
        for paragraph in paragraphs.isEmpty ? [text] : paragraphs {
            if paragraph.count > maximumCharacters {
                if !current.isEmpty { result.append(current); current = "" }
                var remaining = paragraph[...]
                while !remaining.isEmpty {
                    let end = remaining.index(remaining.startIndex, offsetBy: min(maximumCharacters, remaining.count))
                    result.append(String(remaining[..<end]))
                    remaining = remaining[end...]
                }
            } else if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 1 <= maximumCharacters {
                current += "\n" + paragraph
            } else {
                result.append(current)
                current = paragraph
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }
}

actor AdaptiveRewritePipeline: RewriteProcessing {
    private let onlineModel: OpenRouterRewritePipeline
    private let verifier: any TerminologyVerifying

    init(
        onlineModel: OpenRouterRewritePipeline = OpenRouterRewritePipeline(),
        verifier: any TerminologyVerifying = WikipediaTerminologyVerifier()
    ) {
        self.onlineModel = onlineModel
        self.verifier = verifier
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
        var output = try await onlineModel.rewrite(
            material: material,
            style: style,
            language: language,
            modelMode: .onlinePreferred,
            onlineCorrection: onlineCorrection,
            contextLimit: contextLimit,
            progress: progress
        )
        try Task.checkCancellation()
        if onlineCorrection, !output.corrections.isEmpty {
            progress(RewriteProgress(completed: 1, total: 1, message: "正在联网核验候选专有名词…"))
            output.corrections = await verifier.verify(output.corrections)
            output.notes += " 联网核验仅发送候选专有名词，未发送完整原稿。"
        } else if onlineCorrection {
            output.notes += " 本次没有候选专有名词，因此未发起联网查询。"
        }
        return output
    }

}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
