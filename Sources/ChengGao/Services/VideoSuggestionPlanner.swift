import Foundation

struct VideoSuggestion: Identifiable, Equatable, Sendable {
    let id: Int
    let timecode: String
    let durationSeconds: Int
    let spokenContext: String
    let prompt: String
}

enum VideoSuggestionPlanner {
    static func suggestions(for output: RewriteOutput) -> [VideoSuggestion] {
        let cleanText = output.revisedBody
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }

        let characterCount = cleanText.filter { !$0.isWhitespace }.count
        let duration = max(1, output.durationSeconds ?? Int(ceil(Double(characterCount) / 4.5)))
        let count = max(1, Int(ceil(Double(duration) / 10.0)))
        let contexts = contexts(from: VisualShotPlanner.shots(for: output), fallback: cleanText, count: count)
        let style = output.effectiveVisualStyle.promptInstruction
        let continuity = "全片连续性设定：核心主体的身份、面部特征、发型、服装、道具保持一致；空间关系、时代环境、主色调、材质、光线方向、景深和镜头语言统一。"

        return (0..<count).map { index in
            let start = index * 10
            let end = min(duration, start + 10)
            let segmentDuration = max(1, end - start)
            let transition = index == 0
                ? "本段负责建立核心主体、环境方位和运动方向，为后续片段固定视觉基准。"
                : "首帧严格承接上一段末帧，保持主体位置、朝向、动作趋势、环境陈设和光线连续，不跳轴、不瞬移、不更换人物造型。"
            let ending = index == count - 1
                ? "结尾完成动作并形成明确收束。"
                : "末帧保留清楚的动作趋势和构图锚点，供下一段无缝续接。"
            let prompt = """
            生成一段 \(segmentDuration) 秒、9:16 竖版的连续短视频。对应口播：『\(contexts[index])』。\
            \(continuity)统一视觉风格：\(style) \
            \(transition)将口播信息转化为一个连续可见的动作过程，明确主体动作、环境变化、镜头景别、机位运动和节奏；动作自然，物理关系稳定，画面内不要突然新增或消失人物与物件。\
            \(ending)不要文字、字幕、数字标注、二维码、水印、品牌标志或界面元素。
            """
            return VideoSuggestion(
                id: index,
                timecode: "\(format(start))–\(format(end))",
                durationSeconds: segmentDuration,
                spokenContext: contexts[index],
                prompt: prompt
            )
        }
    }

    private static func contexts(from shots: [VisualShot], fallback: String, count: Int) -> [String] {
        guard !shots.isEmpty else { return split(fallback, count: count) }
        return (0..<count).map { index in
            let lower = index * shots.count / count
            let upper = max(lower + 1, (index + 1) * shots.count / count)
            return shots[lower..<min(upper, shots.count)]
                .map(\.spokenContext)
                .joined(separator: "；")
        }
    }

    private static func split(_ text: String, count: Int) -> [String] {
        let characters = Array(text)
        return (0..<count).map { index in
            let lower = index * characters.count / count
            let upper = (index + 1) * characters.count / count
            return String(characters[lower..<upper])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
    }

    private static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
