import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class RewriteStore {
    var selectedSection: WorkspaceSection = .compose
    var sourceKind: SourceKind = .text
    var style: RewriteStyle = .spoken
    var outputLanguage: OutputLanguage = .simplifiedChinese {
        didSet { defaults.set(outputLanguage.rawValue, forKey: "outputLanguage") }
    }
    var modelMode: ModelMode = .onlinePreferred {
        didSet { defaults.set(modelMode.rawValue, forKey: "modelMode") }
    }
    var onlineTerminologyCheck = false {
        didSet { defaults.set(onlineTerminologyCheck, forKey: "onlineTerminologyCheck") }
    }
    var onlineReasoningEffort: OnlineAIReasoningEffort = .automatic {
        didSet { onlineReasoningEffort.save(defaults: defaults) }
    }
    let contextLimit = 16_384
    var onlineProvider: OnlineAIProvider = .custom {
        didSet {
            defaults.set(onlineProvider.rawValue, forKey: "onlineAI.provider")
            reloadOnlineProviderConfiguration()
        }
    }
    var onlineEndpointDraft = ""
    var onlineModelDraft = ""
    var onlineAPIKeyDraft = ""
    var onlineImageEndpointDraft = ""
    var onlineImageModelDraft = ""
    var onlineImageSize: OnlineImageGenerationSize = .automatic
    var onlineImageQuality: OnlineImageGenerationQuality = .automatic
    private(set) var hasOnlineAPIKey = false
    private(set) var onlineAIStatus = "尚未配置"
    private(set) var onlineImageGenerationStatus = "尚未配置图片模型"
    private(set) var isTestingOnlineAI = false
    private(set) var onlineAvailableModels: [String] = []
    private(set) var onlineModelCatalogStatus = "尚未读取远程模型"
    private(set) var isLoadingOnlineModels = false
    var sourceText = ""
    var sourceURL = ""
    var output: RewriteOutput?
    private(set) var hasUnreadResult = false
    private(set) var history: [RewriteHistoryItem] = []
    var selectedHistoryID: UUID?
    var isProcessing = false
    var processingProgress: RewriteProgress?
    var statusMessage = "请配置在线 AI"
    var errorMessage: String?
    private(set) var generatingImageShotID: Int?
    private(set) var isGeneratingAllImages = false

    var effectiveContextLimit: Int {
        contextLimit
    }

    var runtimeModeLabel: String {
        "\(onlineProvider.displayName) · 在线全文处理"
    }

    var privacySummary: String {
        "通过 \(onlineProvider.displayName) 在线改写会发送完整标题与正文"
    }

    var selectedHistoryItem: RewriteHistoryItem? {
        guard let selectedHistoryID else { return nil }
        return history.first { $0.id == selectedHistoryID }
    }

    func prepareManualPlatformLink(_ platform: ResearchPlatform) {
        sourceKind = .link
        sourceURL = ""
        sourceText = ""
        selectedHistoryID = nil
        selectedSection = .compose
        errorMessage = nil
        statusMessage = "请粘贴\(platform.title)分享链接，然后开始处理"
    }

    var activeStyle: RewriteStyle {
        selectedHistoryItem?.style ?? style
    }

    var validSourceURL: String? {
        if let url = SourceExtractor.firstURL(in: sourceURL) {
            return url.absoluteString
        }
        // Compatibility path for documents created by 1.2.0, whose large
        // editor could place a link in sourceText while link mode was active.
        return SourceExtractor.firstURL(in: sourceText)?.absoluteString
    }

    private let pipeline: any RewriteProcessing
    private let visualPromptGenerator: any VisualPromptGenerating
    private let imageGenerator: any ImageGenerating
    private let extractor: any SourceExtracting
    private let defaults: UserDefaults
    private let historyURL: URL
    private var processingTask: Task<Void, Never>?
    private var imageGenerationTask: Task<Void, Never>?
    private var pendingResearchContent: ResearchContent?

    init(
        pipeline: any RewriteProcessing = AdaptiveRewritePipeline(),
        visualPromptGenerator: any VisualPromptGenerating = AdaptiveVisualPromptGenerator(),
        imageGenerator: any ImageGenerating = CompatibleImageGenerationClient(),
        extractor: any SourceExtracting = SourceExtractor(),
        defaults: UserDefaults = .standard,
        historyURL: URL? = nil
    ) {
        self.pipeline = pipeline
        self.visualPromptGenerator = visualPromptGenerator
        self.imageGenerator = imageGenerator
        self.extractor = extractor
        self.defaults = defaults
        let resolvedHistoryURL = historyURL ?? Self.defaultHistoryURL
        self.historyURL = resolvedHistoryURL
        self.outputLanguage = OutputLanguage(
            rawValue: defaults.string(forKey: "outputLanguage") ?? ""
        ) ?? .simplifiedChinese
        let savedModelMode = ModelMode(
            rawValue: defaults.string(forKey: "modelMode") ?? ""
        ) ?? .onlinePreferred
        self.modelMode = Self.normalizedLocalMode(savedModelMode)
        self.onlineTerminologyCheck = defaults.bool(forKey: "onlineTerminologyCheck")
        self.onlineReasoningEffort = OnlineAIReasoningEffort.load(defaults: defaults)
        self.onlineProvider = OnlineAIProvider(
            rawValue: defaults.string(forKey: "onlineAI.provider") ?? ""
        ) ?? .custom
        defaults.set(self.onlineProvider.rawValue, forKey: "onlineAI.provider")
        let onlineConfiguration = OnlineAIConfiguration.load(provider: self.onlineProvider, defaults: defaults)
        self.onlineEndpointDraft = onlineConfiguration.endpoint
        self.onlineModelDraft = onlineConfiguration.model
        let imageConfiguration = OnlineImageGenerationConfiguration.load(
            provider: self.onlineProvider,
            defaults: defaults
        )
        self.onlineImageEndpointDraft = imageConfiguration.endpoint
        self.onlineImageModelDraft = imageConfiguration.model
        self.onlineImageSize = imageConfiguration.size
        self.onlineImageQuality = imageConfiguration.quality
        self.onlineAvailableModels = Self.cachedOnlineModels(
            for: self.onlineProvider,
            defaults: defaults
        )
        self.hasOnlineAPIKey = OnlineAICredentialStore.load(for: self.onlineProvider) != nil
        self.onlineAIStatus = Self.credentialStatus(for: self.onlineProvider)
        self.onlineImageGenerationStatus = imageConfiguration.model.isEmpty
            ? "尚未配置图片模型"
            : "图片模型已配置 · \(imageConfiguration.model)"
        self.modelMode = .onlinePreferred
        defaults.set(ModelMode.onlinePreferred.rawValue, forKey: "modelMode")
        self.statusMessage = self.hasOnlineAPIKey
            ? "\(self.onlineProvider.displayName) 在线 AI 就绪"
            : "请先配置 \(self.onlineProvider.displayName) API Key"
        self.history = Self.loadHistory(from: resolvedHistoryURL, legacyDefaults: defaults)
    }

    var canProcess: Bool {
        let hasText = !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasLink = sourceKind == .link && validSourceURL != nil
        let hasRequiredInput = sourceKind == .link ? hasLink : hasText
        return hasRequiredInput && !isProcessing
    }

    var latestResultOutput: RewriteOutput? {
        output ?? history.first?.output
    }

    var canRegenerateVisualPrompts: Bool {
        latestResultOutput != nil && !isProcessing
    }

    static func resolvedModelMode(_ requested: ModelMode, hasOnlineKey: Bool) -> ModelMode {
        _ = requested
        _ = hasOnlineKey
        return .onlinePreferred
    }

    static func normalizedLocalMode(_ requested: ModelMode) -> ModelMode {
        _ = requested
        return .onlinePreferred
    }

    var sourceCharacterCount: Int {
        sourceKind == .link ? sourceURL.count : sourceText.count
    }

    func startRewrite() {
        guard canProcess else { return }
        processingTask?.cancel()
        isProcessing = true
        output = nil
        selectedHistoryID = nil
        processingProgress = RewriteProgress(completed: 0, total: 1, message: "正在准备素材…")
        errorMessage = nil
        statusMessage = "正在准备在线全文处理…"
        let inputKind = sourceKind
        let input = inputKind == .link ? "" : sourceText
        let inputURL = inputKind == .link ? (validSourceURL ?? sourceURL) : sourceURL
        let requestedStyle = style
        let requestedLanguage = outputLanguage
        let requestedModelMode = modelMode
        let requestedOnlineCorrection = onlineTerminologyCheck
        let requestedContextLimit = effectiveContextLimit
        let researchContent = pendingResearchContent
        pendingResearchContent = nil

        processingTask = Task {
            do {
                try Task.checkCancellation()
                if inputKind == .link {
                    let url = SourceExtractor.firstURL(in: inputURL)
                    statusMessage = url.map(SourceExtractor.isBilibili) == true
                        ? "正在提取完整字幕；无字幕时将转写音轨…"
                        : "正在读取并净化网页正文…"
                } else {
                    statusMessage = "正在读取原稿…"
                }
                let material: SourceMaterial
                if let researchContent,
                   let researchExtractor = extractor as? any ResearchSourceExtracting {
                    material = try await researchExtractor.content(from: researchContent)
                } else {
                    material = try await extractor.content(
                        kind: inputKind,
                        urlString: inputURL,
                        pastedText: input
                    )
                }
                try Task.checkCancellation()
                sourceText = material.transcript
                statusMessage = material.origin == .webArticle
                    ? "已取得净化后的正文，正在提炼重点并改写…"
                    : "已取得完整原稿，正在由在线 AI 通读全文并改写…"
                var result = try await pipeline.rewrite(
                    material: material,
                    style: requestedStyle,
                    language: requestedLanguage,
                    modelMode: requestedModelMode,
                    onlineCorrection: requestedOnlineCorrection,
                    contextLimit: requestedContextLimit,
                    progress: { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.isProcessing else { return }
                            self.processingProgress = update
                            self.statusMessage = update.message
                        }
                    }
                )
                result.sourceVisualReferences = material.visualReferences
                result.sourceContentKind = material.sourceContentKind
                try Task.checkCancellation()
                let visualResult = try await visualPromptGenerator.generate(
                    for: result,
                    modelMode: requestedModelMode,
                    language: requestedLanguage,
                    contextLimit: requestedContextLimit,
                    progress: { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.isProcessing else { return }
                            self.processingProgress = update
                            self.statusMessage = update.message
                        }
                    }
                )
                try Task.checkCancellation()
                result.visualShots = visualResult.shots
                result.visualDesignSource = visualResult.source
                result.notes += " 配图提示词来源：\(visualResult.source.label)。"
                output = result
                history.insert(
                    RewriteHistoryItem(title: result.title, style: requestedStyle, output: result),
                    at: 0
                )
                if history.count > 50 { history.removeLast(history.count - 50) }
                saveHistory()
                selectedHistoryID = nil
                hasUnreadResult = true
                if result.notes.contains("完成在线全文改写") {
                    statusMessage = "处理完成 · 请前往“处理结果”查看"
                } else if requestedOnlineCorrection {
                    statusMessage = "处理完成 · 请前往“处理结果”查看"
                } else {
                    statusMessage = "处理完成 · 请前往“处理结果”查看"
                }
            } catch is CancellationError {
                statusMessage = "处理已停止"
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "处理未完成"
            }
            isProcessing = false
            processingProgress = nil
            processingTask = nil
        }
    }

    func cancelProcessing() {
        guard isProcessing else { return }
        statusMessage = "正在停止处理…"
        processingTask?.cancel()
    }

    func clearDocument() {
        processingTask?.cancel()
        sourceText = ""
        sourceURL = ""
        output = nil
        errorMessage = nil
        selectedHistoryID = nil
        processingProgress = nil
        isProcessing = false
        statusMessage = hasOnlineAPIKey
            ? "\(onlineProvider.displayName) 在线 AI 就绪"
            : "请配置在线 AI"
        selectedSection = .compose
    }

    func openLatestResult() {
        guard latestResultOutput != nil else { return }
        selectedSection = .results
        hasUnreadResult = false
        selectedHistoryID = nil
    }

    func markResultViewed() {
        hasUnreadResult = false
    }

    func regenerateLatestVisualPrompts() {
        guard let current = latestResultOutput, !isProcessing else { return }
        processingTask?.cancel()
        isProcessing = true
        errorMessage = nil
        processingProgress = RewriteProgress(completed: 0, total: 1, message: "AI 正在重新理解口播并设计镜头…")
        statusMessage = "正在重新设计配图提示词…"
        let requestedModelMode = modelMode
        let requestedLanguage = outputLanguage
        let requestedContextLimit = effectiveContextLimit
        let historyID = history.first(where: { $0.output == current })?.id

        processingTask = Task {
            do {
                let visualResult = try await visualPromptGenerator.generate(
                    for: current,
                    modelMode: requestedModelMode,
                    language: requestedLanguage,
                    contextLimit: requestedContextLimit,
                    progress: { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.isProcessing else { return }
                            self.processingProgress = update
                            self.statusMessage = update.message
                        }
                    }
                )
                try Task.checkCancellation()
                var updated = current
                updated.visualShots = visualResult.shots
                updated.visualDesignSource = visualResult.source
                updated.notes = Self.replacingVisualSourceNote(in: updated.notes, with: visualResult.source)
                output = updated
                if let historyID, let index = history.firstIndex(where: { $0.id == historyID }) {
                    let old = history[index]
                    history[index] = RewriteHistoryItem(
                        id: old.id,
                        title: old.title,
                        style: old.style,
                        createdAt: old.createdAt,
                        output: updated
                    )
                    saveHistory()
                }
                statusMessage = "配图提示词已由 \(visualResult.source.label) 重新设计"
            } catch is CancellationError {
                statusMessage = "配图重新设计已停止"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "配图重新设计未完成"
            }
            isProcessing = false
            processingProgress = nil
            processingTask = nil
        }
    }

    func generateImage(for shotID: Int, in current: RewriteOutput, historyID: UUID? = nil) {
        guard !isGeneratingImages else { return }
        let configuration = currentImageGenerationConfiguration
        guard configuration.isValid(fallbackChatEndpoint: onlineEndpointDraft) else {
            errorMessage = ImageGenerationError.invalidConfiguration.localizedDescription
            onlineImageGenerationStatus = "图片生成设置不完整"
            return
        }
        guard let key = OnlineAICredentialStore.load(for: onlineProvider), !key.isEmpty else {
            errorMessage = ImageGenerationError.missingAPIKey.localizedDescription
            onlineImageGenerationStatus = "当前提供商没有 API Key"
            return
        }
        guard let shot = VisualShotPlanner.shots(for: current).first(where: { $0.id == shotID }) else {
            return
        }

        let fallbackChatEndpoint = onlineEndpointDraft
        let resolvedHistoryID = historyID ?? history.first(where: { $0.output == current })?.id
        let storageID = resolvedHistoryID ?? UUID()
        let updatesCurrentOutput = historyID == nil || output == current
        generatingImageShotID = shotID
        onlineImageGenerationStatus = "正在生成第 \(shotID + 1) 张图片…"
        errorMessage = nil

        imageGenerationTask = Task {
            do {
                let payload = try await imageGenerator.generate(
                    prompt: shot.prompt,
                    style: current.style,
                    configuration: configuration,
                    fallbackChatEndpoint: fallbackChatEndpoint,
                    apiKey: key
                )
                try Task.checkCancellation()
                let path = try saveGeneratedImage(payload, historyID: storageID, shotID: shotID)
                var updated = current
                var shots = VisualShotPlanner.shots(for: current)
                if let index = shots.firstIndex(where: { $0.id == shotID }) {
                    shots[index].generatedImagePath = path
                }
                updated.visualShots = shots
                persistGeneratedImages(
                    updated,
                    historyID: resolvedHistoryID,
                    updateCurrentOutput: updatesCurrentOutput
                )
                onlineImageGenerationStatus = "第 \(shotID + 1) 张图片已生成并保存"
            } catch is CancellationError {
                onlineImageGenerationStatus = "图片生成已停止"
            } catch {
                errorMessage = error.localizedDescription
                onlineImageGenerationStatus = "第 \(shotID + 1) 张图片生成失败"
            }
            generatingImageShotID = nil
            imageGenerationTask = nil
        }
    }

    func generateAllImages(in current: RewriteOutput, historyID: UUID? = nil) {
        guard !isGeneratingImages else { return }
        let configuration = currentImageGenerationConfiguration
        guard configuration.isValid(fallbackChatEndpoint: onlineEndpointDraft) else {
            errorMessage = ImageGenerationError.invalidConfiguration.localizedDescription
            onlineImageGenerationStatus = "图片生成设置不完整"
            return
        }
        guard let key = OnlineAICredentialStore.load(for: onlineProvider), !key.isEmpty else {
            errorMessage = ImageGenerationError.missingAPIKey.localizedDescription
            onlineImageGenerationStatus = "当前提供商没有 API Key"
            return
        }
        let originalShots = VisualShotPlanner.shots(for: current)
        guard !originalShots.isEmpty else { return }

        let fallbackChatEndpoint = onlineEndpointDraft
        let resolvedHistoryID = historyID ?? history.first(where: { $0.output == current })?.id
        let storageID = resolvedHistoryID ?? UUID()
        let updatesCurrentOutput = historyID == nil || output == current
        isGeneratingAllImages = true
        errorMessage = nil
        onlineImageGenerationStatus = "准备批量生成 \(originalShots.count) 张图片…"

        imageGenerationTask = Task {
            var updated = current
            var shots = originalShots
            var completed = 0
            var failures: [String] = []
            for (index, shot) in shots.enumerated() {
                do {
                    try Task.checkCancellation()
                    if let path = shot.generatedImagePath,
                       FileManager.default.fileExists(atPath: path) {
                        completed += 1
                        continue
                    }
                    generatingImageShotID = shot.id
                    onlineImageGenerationStatus = "正在生成第 \(index + 1)/\(shots.count) 张图片…"
                    let payload = try await imageGenerator.generate(
                        prompt: shot.prompt,
                        style: current.style,
                        configuration: configuration,
                        fallbackChatEndpoint: fallbackChatEndpoint,
                        apiKey: key
                    )
                    let path = try saveGeneratedImage(payload, historyID: storageID, shotID: shot.id)
                    shots[index].generatedImagePath = path
                    updated.visualShots = shots
                    persistGeneratedImages(
                        updated,
                        historyID: resolvedHistoryID,
                        updateCurrentOutput: updatesCurrentOutput
                    )
                    completed += 1
                } catch is CancellationError {
                    onlineImageGenerationStatus = "批量图片生成已停止 · 已完成 \(completed) 张"
                    generatingImageShotID = nil
                    isGeneratingAllImages = false
                    imageGenerationTask = nil
                    return
                } catch {
                    failures.append("第 \(index + 1) 张：\(error.localizedDescription)")
                }
            }
            generatingImageShotID = nil
            isGeneratingAllImages = false
            imageGenerationTask = nil
            if failures.isEmpty {
                onlineImageGenerationStatus = "全部图片已生成并保存 · 共 \(completed) 张"
            } else {
                onlineImageGenerationStatus = "批量完成 \(completed)/\(shots.count) 张"
                errorMessage = failures.joined(separator: "\n")
            }
        }
    }

    func cancelImageGeneration() {
        imageGenerationTask?.cancel()
        onlineImageGenerationStatus = "正在停止图片生成…"
    }

    func openGeneratedImage(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "生成的图片文件已被移动或删除。"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealGeneratedImage(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "生成的图片文件已被移动或删除。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func saveGeneratedImage(
        _ payload: GeneratedImagePayload,
        historyID: UUID,
        shotID: Int
    ) throws -> String {
        let directory = historyURL.deletingLastPathComponent()
            .appending(path: "GeneratedImages", directoryHint: .isDirectory)
            .appending(path: historyID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeExtension = payload.fileExtension.lowercased().filter(\.isLetter)
        let filename = String(format: "image-%03d-%@.%@", shotID + 1, UUID().uuidString, safeExtension.isEmpty ? "png" : safeExtension)
        let fileURL = directory.appending(path: filename)
        try payload.data.write(to: fileURL, options: .atomic)
        return fileURL.path
    }

    private func persistGeneratedImages(
        _ updated: RewriteOutput,
        historyID: UUID?,
        updateCurrentOutput: Bool
    ) {
        if updateCurrentOutput { output = updated }
        if let historyID, let index = history.firstIndex(where: { $0.id == historyID }) {
            let old = history[index]
            history[index] = RewriteHistoryItem(
                id: old.id,
                title: old.title,
                style: old.style,
                createdAt: old.createdAt,
                output: updated
            )
            saveHistory()
        }
    }

    private static func replacingVisualSourceNote(in notes: String, with source: VisualDesignSource) -> String {
        let cleaned = notes.replacingOccurrences(
            of: #"\s*配图提示词来源：[^\u3002]+。"#,
            with: "",
            options: .regularExpression
        )
        return cleaned + " 配图提示词来源：\(source.label)。"
    }

    func pasteFromClipboard() {
        if let value = NSPasteboard.general.string(forType: .string) {
            if let url = SourceExtractor.firstURL(in: value) {
                sourceURL = url.absoluteString
                sourceText = ""
                sourceKind = .link
            } else {
                sourceText = value
                sourceURL = ""
                sourceKind = .text
            }
        }
    }

    func processResearchContent(_ content: ResearchContent) {
        guard !isProcessing else { return }
        sourceKind = .link
        sourceURL = content.contentURL.absoluteString
        sourceText = ""
        pendingResearchContent = content
        selectedSection = .compose
        statusMessage = content.resolvedContentKind == .imageText
            ? "已选择图文素材，正在读取文字与原图，将生成\(style.rawValue)…"
            : "已选择 \(content.platform.title) 视频，正在取得真实字幕或音轨，将生成\(style.rawValue)…"
        startRewrite()
    }

    var currentOnlineConfiguration: OnlineAIConfiguration {
        OnlineAIConfiguration(
            provider: onlineProvider,
            endpoint: onlineEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            model: onlineModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var currentImageGenerationConfiguration: OnlineImageGenerationConfiguration {
        OnlineImageGenerationConfiguration(
            provider: onlineProvider,
            endpoint: onlineImageEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            model: onlineImageModelDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            size: onlineImageSize,
            quality: onlineImageQuality
        )
    }

    var canGenerateImages: Bool {
        hasOnlineAPIKey
            && currentImageGenerationConfiguration.isValid(fallbackChatEndpoint: onlineEndpointDraft)
            && generatingImageShotID == nil
            && !isGeneratingAllImages
    }

    var isGeneratingImages: Bool {
        generatingImageShotID != nil || isGeneratingAllImages
    }

    var onlineModelChoices: [String] {
        var choices = onlineAvailableModels
        let current = onlineModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    var selectedOnlineModelLabel: String {
        let model = onlineModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "先配置模型" : model
    }

    func selectOnlineModelForProcessing(_ model: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        onlineModelDraft = trimmedModel
        let configuration = currentOnlineConfiguration
        if configuration.isValid {
            configuration.save(defaults: defaults)
            onlineAIStatus = "已选择模型 · \(trimmedModel)"
        }
    }

    var resolvedOnlineEndpointDescription: String {
        guard let endpoint = currentOnlineConfiguration.endpointURL else {
            return "请输入有效的 HTTP(S) 地址"
        }
        return "实际请求：\(endpoint.absoluteString)"
    }

    var resolvedImageGenerationEndpointDescription: String {
        guard let endpoint = currentImageGenerationConfiguration.endpointURL(
            fallbackChatEndpoint: onlineEndpointDraft
        ) else {
            return "请输入有效的图片 API 地址，或先填写聊天接口地址"
        }
        return "实际图片请求：\(endpoint.absoluteString)"
    }

    func saveOnlineImageGenerationConfiguration() {
        let configuration = currentImageGenerationConfiguration
        guard configuration.isValid(fallbackChatEndpoint: onlineEndpointDraft) else {
            onlineImageGenerationStatus = "请填写图片模型，并确认图片 API 地址"
            return
        }
        configuration.save(defaults: defaults)
        onlineImageGenerationStatus = "图片生成设置已保存 · 复用 \(onlineProvider.displayName) Key"
    }

    var onlineCredentialEntryHint: String {
        if hasOnlineAPIKey {
            return "Key 已安全保存；输入框留空会继续使用现有 Key，输入新 Key 可替换。"
        }
        return "请输入完整的 \(onlineProvider.displayName) API Key。"
    }

    func saveOnlineAIConfiguration() {
        let configuration = currentOnlineConfiguration
        guard configuration.isValid else {
            onlineAIStatus = "请填写有效的接口地址和模型名称"
            return
        }
        let trimmedKey = onlineAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty, !onlineProvider.acceptsAPIKey(trimmedKey) {
            onlineAIStatus = "API Key 格式不正确，请粘贴完整的 \(onlineProvider.keyPlaceholder)"
            return
        }
        do {
            configuration.save(defaults: defaults)
            var storage = OnlineAICredentialStore.storage(for: onlineProvider)
            if !trimmedKey.isEmpty {
                storage = try OnlineAICredentialStore.save(trimmedKey, for: onlineProvider)
                onlineAPIKeyDraft = ""
            }
            hasOnlineAPIKey = OnlineAICredentialStore.load(for: onlineProvider) != nil
            guard hasOnlineAPIKey else {
                onlineAIStatus = "接口与模型已保存；还需要填写 API Key"
                return
            }
            onlineAIStatus = "配置已保存到\(storage.map { "\($0.label)" } ?? "本机")；建议立即测试连接"
            modelMode = .onlinePreferred
        } catch {
            onlineAIStatus = error.localizedDescription
        }
    }

    func saveAndTestOnlineAIConfiguration() {
        saveOnlineAIConfiguration()
        guard hasOnlineAPIKey,
              onlineAIStatus.contains("已保存") else { return }
        testOnlineAIConnection()
    }

    func refreshOnlineModelCatalog() {
        guard !isLoadingOnlineModels else { return }
        let configuration = currentOnlineConfiguration
        guard configuration.endpointURL != nil else {
            onlineModelCatalogStatus = "请先填写有效的接口地址"
            return
        }
        let draftKey = onlineAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = draftKey.isEmpty ? OnlineAICredentialStore.load(for: onlineProvider) : draftKey
        guard let key, !key.isEmpty else {
            onlineModelCatalogStatus = OnlineAIModelCatalogError.missingAPIKey.localizedDescription
            return
        }
        isLoadingOnlineModels = true
        onlineModelCatalogStatus = "正在读取 \(onlineProvider.displayName) 的模型列表…"
        Task {
            await loadOnlineModelCatalog(configuration: configuration, key: key)
        }
    }

    func testOnlineAIConnection() {
        guard !isTestingOnlineAI else { return }
        let configuration = currentOnlineConfiguration
        guard configuration.isValid else {
            onlineAIStatus = "请先填写有效的接口地址和模型名称"
            return
        }
        let draftKey = onlineAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = draftKey.isEmpty ? OnlineAICredentialStore.load(for: onlineProvider) : draftKey
        guard let key, !key.isEmpty else {
            onlineAIStatus = "请先填写或保存 API Key"
            return
        }
        isTestingOnlineAI = true
        onlineAIStatus = "正在测试 \(onlineProvider.displayName) 连接…"
        Task {
            do {
                let client = OpenRouterAPIClient(
                    configurationProvider: { configuration },
                    apiKeyProvider: { key },
                    reasoningEffortProvider: { .automatic }
                )
                let completion = try await client.testConnection()
                onlineAIStatus = "连接成功 · \(completion.model)"
                await loadOnlineModelCatalog(configuration: configuration, key: key)
            } catch {
                onlineAIStatus = error.localizedDescription
            }
            isTestingOnlineAI = false
        }
    }

    func selectModelMode(_ mode: ModelMode) {
        _ = mode
        errorMessage = nil
        modelMode = .onlinePreferred
        statusMessage = hasOnlineAPIKey
            ? "\(onlineProvider.displayName) 在线全文处理已启用"
            : "请先配置 \(onlineProvider.displayName) API Key"
    }

    func deleteOnlineAIKey() {
        do {
            let storage = OnlineAICredentialStore.storage(for: onlineProvider)
            try OnlineAICredentialStore.delete(for: onlineProvider)
            onlineAPIKeyDraft = ""
            hasOnlineAPIKey = false
            onlineAvailableModels = []
            onlineModelCatalogStatus = "尚未读取远程模型"
            onlineAIStatus = "已从\(storage?.label ?? "本机凭证存储")删除 \(onlineProvider.displayName) API Key"
            onlineImageGenerationStatus = "图片设置已保留；生成前需重新配置 API Key"
            modelMode = .onlinePreferred
        } catch {
            onlineAIStatus = error.localizedDescription
        }
    }

    func restoreOnlineProviderDefaults() {
        onlineEndpointDraft = onlineProvider.defaultEndpoint
        onlineModelDraft = onlineProvider.defaultModel
        onlineAIStatus = "已恢复 \(onlineProvider.displayName) 推荐参数，尚未保存"
    }

    private func reloadOnlineProviderConfiguration() {
        let configuration = OnlineAIConfiguration.load(provider: onlineProvider, defaults: defaults)
        let imageConfiguration = OnlineImageGenerationConfiguration.load(
            provider: onlineProvider,
            defaults: defaults
        )
        onlineEndpointDraft = configuration.endpoint
        onlineModelDraft = configuration.model
        onlineImageEndpointDraft = imageConfiguration.endpoint
        onlineImageModelDraft = imageConfiguration.model
        onlineImageSize = imageConfiguration.size
        onlineImageQuality = imageConfiguration.quality
        onlineAPIKeyDraft = ""
        hasOnlineAPIKey = OnlineAICredentialStore.load(for: onlineProvider) != nil
        onlineAIStatus = Self.credentialStatus(for: onlineProvider)
        onlineImageGenerationStatus = imageConfiguration.model.isEmpty
            ? "尚未配置图片模型"
            : "图片模型已配置 · \(imageConfiguration.model)"
        onlineAvailableModels = Self.cachedOnlineModels(for: onlineProvider, defaults: defaults)
        onlineModelCatalogStatus = "尚未读取远程模型"
        modelMode = .onlinePreferred
    }

    private func loadOnlineModelCatalog(configuration: OnlineAIConfiguration, key: String) async {
        isLoadingOnlineModels = true
        defer { isLoadingOnlineModels = false }
        do {
            let models = try await OnlineAIModelCatalogClient().fetchModels(
                configuration: configuration,
                apiKey: key
            )
            onlineAvailableModels = models
            defaults.set(models, forKey: Self.onlineModelCatalogKey(for: onlineProvider))
            if onlineModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = models.first {
                onlineModelDraft = first
            }
            onlineModelCatalogStatus = "已读取 \(models.count) 个可用模型"
        } catch {
            onlineAvailableModels = []
            onlineModelCatalogStatus = error.localizedDescription
        }
    }

    private static func credentialStatus(for provider: OnlineAIProvider) -> String {
        guard let storage = OnlineAICredentialStore.storage(for: provider) else {
            return "尚未配置 API Key"
        }
        return "API Key 已保存到\(storage.label)"
    }

    private static func onlineModelCatalogKey(for provider: OnlineAIProvider) -> String {
        "onlineAI.\(provider.rawValue).availableModels"
    }

    private static func cachedOnlineModels(
        for provider: OnlineAIProvider,
        defaults: UserDefaults
    ) -> [String] {
        defaults.stringArray(forKey: onlineModelCatalogKey(for: provider)) ?? []
    }

    func copyOutput() {
        guard let output else { return }
        copyOutput(output)
    }

    func copyOutput(_ output: RewriteOutput) {
        copyToPasteboard(allText(for: output))
    }

    func copyOutputPage(_ page: OutputPage) {
        guard let output else { return }
        copyOutputPage(page, output: output)
    }

    func copyOutputPage(_ page: OutputPage, output: RewriteOutput) {
        let value: String
        switch page {
        case .original:
            value = "\(originalHeading(for: output))\n\n\(output.originalTranscript)"
        case .suggestions:
            value = suggestionsText(for: output)
        case .revised:
            value = "修改后的完整文稿\n\n\(output.revisedBody)"
        case .visuals:
            value = visualsText(for: output)
        }
        copyToPasteboard(value)
    }

    func copyImagePrompt(_ prompt: String) {
        copyToPasteboard(prompt)
    }

    func exportChatGPTImageMarkdown(_ output: RewriteOutput) {
        let shots = VisualShotPlanner.shots(for: output)
        guard !shots.isEmpty else {
            errorMessage = "当前结果没有可导出的配图提示词。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出给 ChatGPT"
        panel.prompt = "导出 Markdown"
        panel.nameFieldStringValue = ChatGPTImageBatchDocument.suggestedDocumentFilename(for: output)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ChatGPTImageBatchDocument.render(output: output)
                .write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
            statusMessage = "已导出 ChatGPT 生图队列 · 共 \(shots.count) 张 · 每 10 张一批"
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func saveEditedDraft(title: String, revisedBody: String, historyID: UUID? = nil) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = revisedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanBody.isEmpty else {
            errorMessage = "标题和成稿内容不能为空。"
            return
        }
        let targetID = historyID ?? history.first(where: { $0.output == latestResultOutput })?.id
        guard let current = targetID.flatMap({ id in history.first(where: { $0.id == id })?.output })
                ?? latestResultOutput else { return }
        var edited = current
        edited.title = cleanTitle
        edited.revisedBody = cleanBody
        if !edited.notes.contains("用户手动编辑") {
            edited.notes += " 成稿已由用户手动编辑。"
        }
        if let targetID, let index = history.firstIndex(where: { $0.id == targetID }) {
            let old = history[index]
            history[index] = RewriteHistoryItem(
                id: old.id, title: cleanTitle, style: old.style,
                createdAt: old.createdAt, output: edited
            )
            saveHistory()
        }
        if output == current || historyID == nil {
            output = edited
        }
        errorMessage = nil
        statusMessage = "成稿修改已保存"
    }

    private func allText(for output: RewriteOutput) -> String {
        let suggestions = suggestionsText(for: output)
        let visuals = visualsText(for: output)
        let corrections = output.corrections.map { item in
            "\(item.original) → \(item.corrected)：\(item.reason)（\(item.verification.label)）"
        }.joined(separator: "\n")
        return """
        第一部分：\(originalHeading(for: output))
        \(output.originalTranscript)

        专有名词与同音词校对记录
        \(corrections.isEmpty ? "未发现高置信度纠错项" : corrections)

        未经校对的原始内容
        \(output.rawTranscript)

        第二部分：对应修改建议
        \(suggestions)

        第三部分：修改后的完整文稿
        \(output.revisedBody)

        第四部分：配图建议
        \(visuals)
        """
    }

    private func suggestionsText(for output: RewriteOutput) -> String {
        let suggestions = output.suggestions.enumerated().map { index, item in
            "建议 \(index + 1)\n原文：\(item.original)\n修改建议：\(item.suggestion)\n原因：\(item.reason)"
        }.joined(separator: "\n\n")
        return suggestions
    }

    private func visualsText(for output: RewriteOutput) -> String {
        VisualShotPlanner.shots(for: output).enumerated().map { index, shot in
            "镜头 \(index + 1)\n时间：\(shot.timecode)\n对应口播：\(shot.spokenContext)\nAI 绘图提示词：\(shot.prompt)"
        }.joined(separator: "\n\n")
    }

    private func originalHeading(for output: RewriteOutput) -> String {
        switch output.style {
        case .spoken, .channel: "校对后的完整口播稿"
        case .article: "净化并校对后的文章正文"
        case .social: "整理并校对后的原始文案"
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func selectHistory(_ item: RewriteHistoryItem) {
        selectedHistoryID = item.id
        selectedSection = .history
    }

    func closeHistoryDetail() {
        selectedHistoryID = nil
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        do {
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: historyURL, options: .atomic)
            defaults.removeObject(forKey: "rewriteHistory")
        } catch {
            // History persistence is non-critical; the current session remains usable.
        }
    }

    private static func loadHistory(from url: URL, legacyDefaults: UserDefaults) -> [RewriteHistoryItem] {
        let data = (try? Data(contentsOf: url)) ?? legacyDefaults.data(forKey: "rewriteHistory")
        guard let data,
              let items = try? JSONDecoder().decode([RewriteHistoryItem].self, from: data) else { return [] }
        return Array(items.prefix(50))
    }

    private static var defaultHistoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "com.itou.chenggao", directoryHint: .isDirectory)
            .appending(path: "history.json")
    }
}
