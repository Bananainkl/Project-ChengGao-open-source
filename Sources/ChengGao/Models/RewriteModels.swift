import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case compose
    case results
    case research
    case accounts
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .compose: "新建文稿"
        case .results: "处理结果"
        case .research: "爆款研究"
        case .accounts: "平台账号"
        case .history: "最近处理"
        }
    }

    var systemImage: String {
        switch self {
        case .compose: "square.and.pencil"
        case .results: "doc.text.magnifyingglass"
        case .research: "chart.line.uptrend.xyaxis"
        case .accounts: "person.crop.circle.badge.checkmark"
        case .history: "clock"
        }
    }
}

enum SourceKind: String, CaseIterable, Identifiable {
    case text = "粘贴文本"
    case link = "内容链接"

    var id: Self { self }
}

enum RewriteStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case spoken = "短视频口播"
    case article = "公众号文章"
    case social = "小红书图文"
    case channel = "视频号文案"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .spoken: "waveform"
        case .article: "doc.text"
        case .social: "rectangle.grid.1x2"
        case .channel: "play.rectangle"
        }
    }
}

enum VisualStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = "自动匹配"
    case cinematicDocumentary = "电影纪实"
    case warmJapaneseAnimation = "温暖日系手绘动画"
    case westernFairytaleAnimation = "经典欧美童话动画"
    case retroAmericanComic = "复古美式印刷漫画"
    case slapstickChaseAnimation = "夸张追逐喜剧动画"
    case knittedPuppet = "毛线布偶"
    case clayStopMotion = "粘土定格动画"
    case handDrawnComic = "手绘漫画"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .cinematicDocumentary: "camera.aperture"
        case .warmJapaneseAnimation: "leaf"
        case .westernFairytaleAnimation: "sparkles"
        case .retroAmericanComic: "burst"
        case .slapstickChaseAnimation: "figure.run"
        case .knittedPuppet: "scissors"
        case .clayStopMotion: "hand.raised.fingers.spread"
        case .handDrawnComic: "pencil.and.outline"
        }
    }

    var summary: String {
        switch self {
        case .automatic: "按题材自动决定写实、历史还原或编辑插画"
        case .cinematicDocumentary: "真实材质、自然光与克制的电影摄影"
        case .warmJapaneseAnimation: "柔和线稿、水彩背景与温暖生活气息"
        case .westernFairytaleAnimation: "圆润造型、明快色彩与舞台式童话构图"
        case .retroAmericanComic: "粗黑墨线、网点印刷与有限复古色盘"
        case .slapstickChaseAnimation: "夸张形变、强动作线与追逐喜剧节奏"
        case .knittedPuppet: "针织纹理、毛线人物与微缩布艺场景"
        case .clayStopMotion: "手捏痕迹、粘土木偶与定格动画质感"
        case .handDrawnComic: "可见笔触、纸张纹理与手工上色"
        }
    }

    var promptInstruction: String {
        switch self {
        case .automatic:
            "根据文案题材自动选择最合适的视觉语言；现实题材保持可信，历史题材准确还原年代，抽象内容使用克制的编辑视觉隐喻。"
        case .cinematicDocumentary:
            "采用电影纪实风格：真实人物与材质，自然可信的动作，带方向性的环境光，克制电影调色，细腻景深与真实镜头质感，避免卡通化和塑料感。"
        case .warmJapaneseAnimation:
            "采用温暖日系手绘动画风格：柔和且略有手工抖动的线稿，透明水彩背景，朴素生活细节，空气感自然光，低饱和绿色、米色与暖橙色，二维赛璐璐人物；不得模仿特定工作室、作品或角色。"
        case .westernFairytaleAnimation:
            "采用经典欧美童话动画风格：圆润而富有表情的二维角色，清晰轮廓，丰富但协调的色彩，舞台式空间层次，柔和辉光与童话氛围；不得复刻任何已知电影、角色或品牌造型。"
        case .retroAmericanComic:
            "采用复古美式印刷漫画风格：粗黑墨线，明显的半色调网点和套色轻微错位，红黄蓝与奶油色有限色盘，戏剧性透视、速度线和强明暗块；保持单一完整画面，不制作多格漫画版面。"
        case .slapstickChaseAnimation:
            "采用夸张追逐喜剧动画风格：20 世纪中期美国影院动画般的手绘质感，鲜明轮廓，挤压与拉伸形变，夸张预备动作和速度线，明亮手绘背景与强节奏构图；不得出现可识别的经典猫鼠角色或其造型。"
        case .knittedPuppet:
            "采用毛线布偶微缩风格：人物、动物、建筑和道具都由针织毛线、钩织线圈、羊毛毡与布料制作，清楚可见针脚、纤维绒毛和缝线，手工布偶比例，微距摄影、柔和棚灯与浅景深；不要出现真实皮肤或光滑塑料。"
        case .clayStopMotion:
            "采用粘土定格动画风格：手捏粘土木偶、可见指纹与塑形工具痕迹，略带不对称的表情和关节，手工微缩布景，逐格动画姿态，柔和漫射棚灯与实体阴影；避免光滑三维渲染和真人皮肤。"
        case .handDrawnComic:
            "采用手绘漫画风格：可见铅笔草线与墨线变化，手工排线、干刷或水彩上色，保留纸张纤维和轻微颜料不均，构图有漫画张力但保持一张完整画面；避免照片写实、光滑三维建模和现成素材感。"
        }
    }

    func enforcing(_ prompt: String) -> String {
        guard self != .automatic else { return prompt }
        return "\(prompt) 统一画面风格：\(promptInstruction)"
    }
}

enum OutputLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case simplifiedChinese = "简体中文"
    case traditionalChinese = "繁体中文"

    var id: Self { self }

    var promptInstruction: String {
        switch self {
        case .simplifiedChinese: "无论原稿使用普通话、粤语、英语、日语或其他语言，都必须先按原语言准确理解；除 corrected 字段保留原语言纠错稿外，标题、修改建议、理由、配图建议和 revised 必须使用中国大陆规范简体中文。跨语言改写不能省略或改写原稿事实。"
        case .traditionalChinese: "无论原稿使用普通话、粤语、英语、日语或其他语言，都必须先按原语言准确理解；除 corrected 字段保留原语言纠错稿外，标题、修改建议、理由、配图建议和 revised 必须使用繁体中文。跨语言改写不能省略或改写原稿事实。"
        }
    }

    func normalize(_ text: String) -> String {
        let transform = switch self {
        case .simplifiedChinese: StringTransform("Traditional-Simplified")
        case .traditionalChinese: StringTransform("Simplified-Traditional")
        }
        return text.applyingTransform(transform, reverse: false) ?? text
    }
}

enum ModelMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case onlinePreferred = "在线 AI · 全文处理"
    // Legacy cases remain in the type so older call sites migrate safely, but
    // they are never offered or executed by the current application.
    case automatic = "旧版本地模式"
    case fast = "旧版极速模式"
    case enhanced = "旧版增强模式"

    var id: Self { self }

    static var allCases: [ModelMode] { [.onlinePreferred] }

    var displayName: String {
        switch self {
        case .onlinePreferred, .automatic, .fast, .enhanced: "在线 AI · 全文处理"
        }
    }

    var systemImage: String {
        switch self {
        case .onlinePreferred, .automatic, .fast, .enhanced: "network"
        }
    }
}

enum OutputPage: Int, CaseIterable, Identifiable {
    case original
    case suggestions
    case revised
    case visuals

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "1 原稿"
        case .suggestions: "2 修改建议"
        case .revised: "3 修改稿"
        case .visuals: "4 配图建议"
        }
    }
}

enum TranscriptOrigin: String, Equatable, Codable, Sendable {
    case pastedText
    case platformSubtitle
    case localSpeechRecognition
    case webArticle
    case socialImageText

    var label: String {
        switch self {
        case .pastedText: "粘贴的原稿"
        case .platformSubtitle: "平台字幕"
        case .localSpeechRecognition: "本机音频转写"
        case .webArticle: "网页正文"
        case .socialImageText: "小红书图文正文与图片识别"
        }
    }
}

struct SourceVisualReference: Equatable, Codable, Sendable {
    var index: Int
    var imageURL: URL?
    var recognizedText: String
    var sceneDescription: String
    var composition: String
    var redesignDirection: String

    var promptContext: String {
        [
            "原图可见内容：\(sceneDescription)",
            composition.isEmpty ? nil : "原图构图：\(composition)",
            recognizedText.isEmpty ? nil : "原图文字识别：\(recognizedText)",
            redesignDirection.isEmpty ? nil : "重构方向：\(redesignDirection)"
        ].compactMap { $0 }.joined(separator: "；")
    }
}

struct SourceMaterial: Equatable, Codable, Sendable {
    var title: String
    var transcript: String
    var origin: TranscriptOrigin
    var durationSeconds: Int?
    var visualReferences: [SourceVisualReference]? = nil
    var sourceContentKind: ResearchContentKind? = nil
}

struct RevisionSuggestion: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var original: String
    var suggestion: String
    var reason: String
    var imagePlacement: String
    var imageSuggestion: String

    init(
        id: UUID = UUID(),
        original: String,
        suggestion: String,
        reason: String,
        imagePlacement: String,
        imageSuggestion: String
    ) {
        self.id = id
        self.original = original
        self.suggestion = suggestion
        self.reason = reason
        self.imagePlacement = imagePlacement
        self.imageSuggestion = imageSuggestion
    }
}

enum ImagePromptBuilder {
    static func prompt(for suggestion: RevisionSuggestion, style: RewriteStyle) -> String {
        let supplied = suggestion.imageSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if supplied.hasPrefix("生成一张"), supplied.contains("画面比例"), supplied.contains("水印") {
            return supplied
        }
        let context = suggestion.original
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = String(context.prefix(160))
        let ratio = switch style {
        case .article: "16:9 横版"
        case .social: "3:4 竖版"
        case .spoken, .channel: "9:16 竖版"
        }
        return "生成一张可直接用于\(style.rawValue)的配图。画面主题：\(supplied)。参考文案：\(reference)。主体明确，采用有纵深的中景构图，真实自然光，层次清晰，统一配色，纪实编辑摄影风格，高细节。画面比例：\(ratio)。不要出现任何文字、字幕、二维码、水印、品牌标志、界面元素或无关人物。"
    }
}

struct VisualShot: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    let timecode: String
    let spokenContext: String
    let prompt: String
    var generatedImagePath: String? = nil
}

enum VisualShotPlanner {
    static func shots(for output: RewriteOutput) -> [VisualShot] {
        if let designed = output.visualShots, !designed.isEmpty {
            return designed
        }
        return plannedShots(for: output)
    }

    static func plannedShots(for output: RewriteOutput) -> [VisualShot] {
        let cleanText = output.revisedBody
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }

        switch output.style {
        case .social:
            return socialShots(for: output, cleanText: cleanText)
        case .article:
            return articleShots(for: output, cleanText: cleanText)
        case .spoken, .channel:
            break
        }

        let spokenCharacters = cleanText.filter { !$0.isWhitespace }.count
        let duration = max(3, output.durationSeconds ?? Int(ceil(Double(spokenCharacters) / 4.5)))
        let targetInterval = output.style == .channel ? 6.0 : 4.0
        let shotCount = max(1, Int((Double(duration) / targetInterval).rounded()))
        let contexts = splitContexts(cleanText, count: shotCount)
        let interval = Double(duration) / Double(shotCount)

        return (0..<shotCount).map { index in
            let context = contexts[index]
            let start = Double(index) * interval
            let end = min(Double(duration), Double(index + 1) * interval)
            return VisualShot(
                id: index,
                timecode: "\(format(seconds: start))–\(format(seconds: end))",
                spokenContext: context,
                prompt: videoPrompt(
                    context: context,
                    index: index + 1,
                    style: output.style,
                    visualStyle: output.effectiveVisualStyle
                )
            )
        }
    }

    private static func socialShots(for output: RewriteOutput, cleanText: String) -> [VisualShot] {
        let references = output.sourceVisualReferences ?? []
        let characterCount = cleanText.filter { !$0.isWhitespace }.count
        let count = references.isEmpty
            ? max(4, min(9, Int(ceil(Double(characterCount) / 180.0))))
            : references.count
        let contexts = splitContexts(cleanText, count: count)
        return (0..<count).map { index in
            let reference = references.indices.contains(index) ? references[index].promptContext : ""
            let context = [
                index == 0 ? "封面需要承担核心钩子" : "第 \(index + 1) 张图文卡片",
                "成稿对应内容：\(contexts[index])",
                reference.isEmpty ? nil : "原图可验证信息：\(reference)"
            ].compactMap { $0 }.joined(separator: "；")
            return VisualShot(
                id: index,
                timecode: index == 0 ? "图文 1 · 封面" : "图文 \(index + 1)",
                spokenContext: context,
                prompt: socialPrompt(
                    context: context,
                    index: index + 1,
                    visualStyle: output.effectiveVisualStyle
                )
            )
        }
    }

    private static func articleShots(for output: RewriteOutput, cleanText: String) -> [VisualShot] {
        let characterCount = cleanText.filter { !$0.isWhitespace }.count
        let count = max(3, min(6, Int(ceil(Double(characterCount) / 450.0))))
        let contexts = splitContexts(cleanText, count: count)
        let references = output.sourceVisualReferences ?? []
        return (0..<count).map { index in
            let reference = references.indices.contains(index) ? references[index].promptContext : ""
            let context = [
                "文章第 \(index + 1) 个核心部分：\(contexts[index])",
                reference.isEmpty ? nil : "可借鉴的原图证据：\(reference)"
            ].compactMap { $0 }.joined(separator: "；")
            return VisualShot(
                id: index,
                timecode: index == 0 ? "头图" : "第 \(index + 1) 节后",
                spokenContext: context,
                prompt: articlePrompt(
                    context: context,
                    index: index + 1,
                    visualStyle: output.effectiveVisualStyle
                )
            )
        }
    }

    private static func splitContexts(_ text: String, count: Int) -> [String] {
        let characters = Array(text)
        guard count > 1, characters.count > 1 else { return [text] }
        if count >= characters.count {
            return (0..<count).map { index in
                let center = min(characters.count - 1, index * characters.count / count)
                let lower = max(0, center - 6)
                let upper = min(characters.count, center + 7)
                return String(characters[lower..<upper])
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
        }
        let separators = Set("，。！？；、,!?; ")
        var boundaries = [0]
        var previous = 0
        for index in 1..<count {
            let ideal = index * characters.count / count
            let minimum = min(characters.count - (count - index), previous + 1)
            let maximum = max(minimum, characters.count - (count - index))
            let lower = max(minimum, ideal - 8)
            let upper = min(maximum, ideal + 8)
            let candidates = lower...upper
            let boundary = candidates
                .filter { $0 < characters.count && separators.contains(characters[$0]) }
                .min { abs($0 - ideal) < abs($1 - ideal) }
                .map { min(maximum, $0 + 1) }
                ?? min(maximum, max(minimum, ideal))
            boundaries.append(boundary)
            previous = boundary
        }
        boundaries.append(characters.count)
        return (0..<count).map { index in
            String(characters[boundaries[index]..<boundaries[index + 1]])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
    }

    private static func videoPrompt(
        context: String,
        index: Int,
        style: RewriteStyle,
        visualStyle: VisualStyle
    ) -> String {
        let historicalTerms = ["朝", "皇帝", "太后", "起义", "民国", "清军", "王朝", "古代", "历史"]
        let automaticStyle = historicalTerms.contains(where: context.contains)
            ? "电影级历史纪录片重现场景，准确还原对应年代的服装、建筑、器物与社会环境"
            : "真实纪实编辑摄影风格，场景可信，人物动作自然"
        let purpose = style == .channel ? "视频号第 \(index) 镜，镜头稳健、留出理解信息的时间" : "竖屏短视频第 \(index) 镜，画面紧凑、视觉重点鲜明"
        let base = "生成一张用于\(purpose)的画面。对应文案：『\(context)』。把核心信息转化为一个明确、可直接观看的视觉场景，主体突出，有前中后景层次，光线、色调与材质统一；\(visualStyle == .automatic ? automaticStyle : visualStyle.promptInstruction)，高细节。画面比例：9:16 竖版。不要出现任何文字、字幕、数字标注、二维码、水印、品牌标志、界面元素或无关人物；不得虚构文案没有提及的事实。"
        return base
    }

    private static func socialPrompt(context: String, index: Int, visualStyle: VisualStyle) -> String {
        "生成一张小红书图文第 \(index) 张的全新配图。信息依据：\(context)。将核心信息设计为一个主视觉和 2–4 个可见细节，主体、环境、道具和构图关系必须明确；与相邻图片的景别和视觉隐喻有区分。画面风格：\(visualStyle.promptInstruction) 画面比例：3:4 竖版，细节丰富，留出干净的标题排版空间但不直接生成文字。不复制原图、不捏造名人面孔或不可验证的事实；不要文字、字幕、数字标注、二维码、水印、品牌标志或界面元素。"
    }

    private static func articlePrompt(context: String, index: Int, visualStyle: VisualStyle) -> String {
        "生成一张公众号文章第 \(index) 张编辑配图。文章依据：\(context)。用真实可信的人物、物件、场所或象征性关系表达该节核心信息，写明主体动作、前中后景、拍摄角度、光线和主色调。画面风格：\(visualStyle.promptInstruction) 画面比例：16:9 横版。不得虚构没有依据的人物和事实；不要文字、字幕、数字标注、二维码、水印、品牌标志或界面元素。"
    }

    private static func format(seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

enum VisualDesignSource: String, Equatable, Codable, Sendable {
    case localAI
    case onlineAI
    case mixedAI
    case templateFallback

    var label: String {
        switch self {
        case .localAI: "本地 AI 逐镜设计"
        case .onlineAI: "在线 AI 逐镜设计"
        case .mixedAI: "AI 设计 · 个别镜头安全回退"
        case .templateFallback: "基础镜头模板"
        }
    }
}

struct VisualPromptGenerationResult: Equatable, Sendable {
    var shots: [VisualShot]
    var source: VisualDesignSource
}

enum VisualPromptDesigner {
    // Smaller batches leave enough output budget for genuinely detailed prompts
    // on the embedded 1.7B model while keeping only one model process in memory.
    static let batchSize = 6

    static func prompt(
        for shots: [VisualShot],
        style: RewriteStyle,
        language: OutputLanguage,
        visualStyle: VisualStyle = .automatic
    ) -> String {
        let payload = shots.map {
            """
            {"id":\($0.id),"timecode":"\($0.timecode)","spokenContext":"\(jsonEscaped($0.spokenContext))"}
            """
        }.joined(separator: ",\n")
        let ratio = switch style {
        case .article: "16:9 横版"
        case .social: "3:4 竖版"
        case .spoken, .channel: "9:16 竖版"
        }
        let visualBrief = switch style {
        case .spoken: "为短视频制作节奏鲜明、每 3–5 秒有明确信息点的竖屏分镜。"
        case .channel: "为视频号制作更稳健、信息完整、镜头停留稍长的竖屏画面。"
        case .article: "为公众号文章制作克制、可信、服务于段落论证的横版编辑配图。"
        case .social: "为小红书图文制作信息密度高、每张各有主题、可组成完整组图的 3:4 竖版画面。"
        }
        return """
        /no_think
        你是内容视觉导演和 AI 视觉提示词设计师。\(visualBrief)请先理解每个画面对应文案和原图证据的具体含义，再设计彼此不同、可以直接交给图像生成模型的中文提示词。

        全局画面风格“\(visualStyle.rawValue)”：\(visualStyle.promptInstruction)

        硬性要求：
        1. \(language.promptInstruction)
        2. 每条 prompt 必须明确写出：可见主体、主体动作或状态、具体环境与道具、景别和拍摄角度、构图关系、光线、主色调、视觉风格以及画面比例 \(ratio)。
        3. 抽象概念要转化为可观看的生活、工作、空间或象征场景；不得只说“呈现核心观点”“把口播转换成画面”。
        4. 不要复制口播全文，不要让所有镜头使用同一主体、同一办公室、同一中景或相同开头；相邻镜头必须在主体、空间、景别或视觉隐喻上有清楚变化。
        5. 不虚构口播没有的具体事实。真人外貌无可靠依据时，使用背影、手部、剪影、物件或环境叙事，不捏造名人面孔。
        6. 每条都必须落实全局画面风格的材质、造型、光线与色彩，不得改成其他风格，也不得引用或模仿具体工作室、影视作品、品牌或已知角色。
        7. 每条 90–260 个汉字。结尾统一写明：不要文字、字幕、数字标注、二维码、水印、品牌标志或界面元素。
        8. 只输出 JSON，不要 Markdown、解释或思考过程：
        {"shots":[{"id":0,"prompt":"具体完整提示词"}]}

        待设计镜头：
        [\(payload)]
        """
    }

    static func applying(
        rawResponse: String,
        to plannedShots: [VisualShot],
        language: OutputLanguage,
        visualStyle: VisualStyle = .automatic
    ) -> (shots: [VisualShot], designedCount: Int) {
        let cleaned = EmbeddedModelRuntime.assistantPayload(from: rawResponse)
        guard let root = EmbeddedModelRuntime.parseJSONObject(from: cleaned),
              let values = root["shots"] as? [[String: Any]] else {
            return (plannedShots, 0)
        }
        var prompts: [Int: String] = [:]
        for value in values {
            guard let id = integer(value["id"]),
                  let rawPrompt = value["prompt"] as? String else { continue }
            let prompt = language.normalize(rawPrompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSpecificPrompt(prompt) else { continue }
            prompts[id] = visualStyle.enforcing(prompt)
        }
        let result = plannedShots.map { shot in
            guard let prompt = prompts[shot.id] else { return shot }
            return VisualShot(
                id: shot.id,
                timecode: shot.timecode,
                spokenContext: shot.spokenContext,
                prompt: prompt
            )
        }
        let expectedIDs = Set(plannedShots.map(\.id))
        return (result, prompts.keys.filter(expectedIDs.contains).count)
    }

    static func isSpecificPrompt(_ prompt: String) -> Bool {
        let compact = prompt.filter { !$0.isWhitespace }
        guard compact.count >= 70 else { return false }
        let genericOnly = ["呈现核心观点", "转换成明确的信息场景", "把口播核心信息转化"]
        guard !genericOnly.contains(where: prompt.contains) else { return false }
        let detailSignals = ["主体", "人物", "双手", "物件", "环境", "空间", "前景", "背景", "近景", "中景", "全景", "俯拍", "仰拍", "侧面", "光", "色调", "构图"]
        return detailSignals.filter(prompt.contains).count >= 3
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else { return value }
        return String(encoded.dropFirst().dropLast())
    }
}

enum CorrectionVerification: String, Equatable, Codable, Sendable {
    case localContext
    case onlineVerified
    case onlineNotFound

    var label: String {
        switch self {
        case .localContext: "本机上下文判断"
        case .onlineVerified: "联网词条已核验"
        case .onlineNotFound: "联网未找到词条"
        }
    }
}

struct TranscriptCorrection: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var original: String
    var corrected: String
    var reason: String
    var verification: CorrectionVerification

    init(
        id: UUID = UUID(),
        original: String,
        corrected: String,
        reason: String,
        verification: CorrectionVerification = .localContext
    ) {
        self.id = id
        self.original = original
        self.corrected = corrected
        self.reason = reason
        self.verification = verification
    }
}

struct RewriteOutput: Equatable, Codable, Sendable {
    var title: String
    var rawTranscript: String
    var originalTranscript: String
    var corrections: [TranscriptCorrection]
    var suggestions: [RevisionSuggestion]
    var revisedBody: String
    var notes: String
    var transcriptOrigin: TranscriptOrigin
    var style: RewriteStyle
    var visualStyle: VisualStyle? = nil
    var durationSeconds: Int? = nil
    var visualShots: [VisualShot]? = nil
    var visualDesignSource: VisualDesignSource? = nil
    var sourceVisualReferences: [SourceVisualReference]? = nil
    var sourceContentKind: ResearchContentKind? = nil

    var body: String { revisedBody }
    var effectiveVisualStyle: VisualStyle { visualStyle ?? .automatic }
    var subtitleReadyBody: String {
        style == .spoken ? SpokenSubtitleFormatter.format(revisedBody) : revisedBody
    }
}

struct RewriteHistoryItem: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let title: String
    let style: RewriteStyle
    let createdAt: Date
    let output: RewriteOutput

    init(id: UUID = UUID(), title: String, style: RewriteStyle, createdAt: Date = .now, output: RewriteOutput) {
        self.id = id
        self.title = title
        self.style = style
        self.createdAt = createdAt
        self.output = output
    }
}

struct RewriteProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    let message: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}
