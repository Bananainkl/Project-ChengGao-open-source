import Foundation

protocol RewriteProcessing: Sendable {
    func rewrite(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage,
        modelMode: ModelMode,
        onlineCorrection: Bool,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> RewriteOutput
}

extension RewriteProcessing {
    func rewrite(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage,
        modelMode: ModelMode,
        onlineCorrection: Bool
    ) async throws -> RewriteOutput {
        try await rewrite(
            material: material,
            style: style,
            language: language,
            modelMode: modelMode,
            onlineCorrection: onlineCorrection,
            contextLimit: 4_096,
            progress: { _ in }
        )
    }
}

enum RewritePipelineError: LocalizedError {
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .emptyInput: "请先粘贴需要处理的内容。"
        }
    }
}

/// The first functional pipeline is intentionally deterministic. The native
/// GGUF runtime will replace the final composition stage without changing the UI.
actor OfflineRewritePipeline: RewriteProcessing {
    func rewrite(
        material: SourceMaterial,
        style: RewriteStyle,
        language: OutputLanguage,
        modelMode: ModelMode,
        onlineCorrection: Bool,
        contextLimit: Int,
        progress: @escaping @Sendable (RewriteProgress) -> Void
    ) async throws -> RewriteOutput {
        try Task.checkCancellation()
        progress(RewriteProgress(completed: 0, total: 1, message: "正在执行基础整理…"))
        let cleaned = Self.clean(material.transcript)
        guard !cleaned.isEmpty else { throw RewritePipelineError.emptyInput }

        let sentences = Self.sentences(in: cleaned)
        let lead = sentences.first ?? cleaned
        let title = Self.makeTitle(from: lead, style: style)
        let body = Self.compose(sentences: sentences, fallback: cleaned, style: style)

        let genericTitles = ["", "粘贴文稿", "网页正文"]
        let output = RewriteOutput(
            title: genericTitles.contains(material.title) ? title : material.title,
            rawTranscript: material.transcript,
            originalTranscript: material.transcript,
            corrections: [],
            suggestions: [RevisionSuggestion(
                original: material.transcript,
                suggestion: language.normalize("删去口头填充词，调整断句和段落，并强化开头的信息密度。"),
                reason: language.normalize("让表达更紧凑，同时不改变原稿事实。"),
                imagePlacement: language.normalize("本段结尾后"),
                imageSuggestion: language.normalize("生成一张能够概括本段核心观点的真实场景图，主体明确，中景构图，自然光，纪实编辑摄影风格，统一配色；画面比例 9:16；不要出现文字、字幕、二维码、水印、品牌标志或无关装饰。")
            )],
            revisedBody: language.normalize(body),
            notes: language.normalize("原稿来源：\(material.origin.label)。当前使用离线规则完成基础整理。"),
            transcriptOrigin: material.origin,
            style: style,
            durationSeconds: material.durationSeconds
        )
        progress(RewriteProgress(completed: 1, total: 1, message: "基础整理完成"))
        return output
    }

    static func clean(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let fillerWords = ["嗯", "呃", "然后呢", "就是说", "你知道吗"]
        for word in fillerWords {
            value = value.replacingOccurrences(of: word, with: "")
        }

        value = value.replacingOccurrences(
            of: #"(^|[。！？!?])\s*[，,、；;：:]+\s*"#,
            with: "$1",
            options: .regularExpression
        )

        value = value.replacingOccurrences(
            of: #"[ \t]+"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sentences(in text: String) -> [String] {
        let terminators = CharacterSet(charactersIn: "。！？!?")
        var result: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            let scalar = character.unicodeScalars.first
            if let scalar, terminators.contains(scalar) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }

        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { result.append(remainder) }
        return result
    }

    private static func makeTitle(from lead: String, style: RewriteStyle) -> String {
        let compact = lead.replacingOccurrences(of: "\n", with: " ")
        let prefix = String(compact.prefix(26)).trimmingCharacters(in: .punctuationCharacters)
        return prefix.isEmpty ? style.rawValue : prefix
    }

    private static func compose(sentences: [String], fallback: String, style: RewriteStyle) -> String {
        guard !sentences.isEmpty else { return fallback }
        switch style {
        case .spoken:
            let hook = "先别急着下结论。"
            return ([hook] + sentences).joined(separator: "\n\n")
        case .article:
            return sentences.enumerated().map { index, sentence in
                index == 0 ? sentence : "\n\n\(sentence)"
            }.joined()
        case .social:
            return sentences.map { "• \($0)" }.joined(separator: "\n\n")
        case .channel:
            return sentences.joined(separator: "\n\n") + "\n\n你怎么看？欢迎留下你的判断。"
        }
    }
}
