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
            let openingEnd = min(2, max(1, segmentDuration / 3))
            let developmentEnd = max(openingEnd, segmentDuration - min(2, segmentDuration / 3))
            let beats = actionBeats(from: contexts[index])
            let transition = index == 0
                ? "首帧直接从动作发生前一刻开始，同时建立核心主体、环境方位和运动方向。"
                : "首帧就是上一段末帧的下一瞬间，主体位置、朝向、速度、动作惯性、环境陈设和光线完全连续。"
            let ending = index == count - 1
                ? "最后 2 秒让动作自然完成，人物呼吸、表情和衣物仍有细微运动，形成有生命力的收束。"
                : "最后 2 秒不要停住：主体继续向同一方向运动，末帧保留未完成动作、视线目标和镜头速度，让下一段可以无缝续接。"
            let prompt = """
            生成一段 \(segmentDuration) 秒、9:16 竖版、单一连续长镜头的动态短视频。对应口播：『\(contexts[index])』。\
            \(continuity)统一视觉风格：\(style) \(transition)

            动作时间轴：
            0–\(openingEnd) 秒：画面一开始主体就已经在行动，用明确的走动、转身、俯身、伸手、拿取、推动或交互动作呈现“\(beats[0])”；身体重心、手臂、视线、表情和衣物必须同步变化，禁止站着不动展示画面。
            \(openingEnd)–\(developmentEnd) 秒：不切镜，沿同一动作因果继续完成至少两个连续步骤，用“先发生 → 引起变化 → 主体立即回应”的过程呈现“\(beats[1])”；道具发生真实位移，头发、衣摆、灰尘、蒸汽、树叶或环境光影至少有一种持续动态反馈。
            \(developmentEnd)–\(segmentDuration) 秒：在运动中呈现“\(beats[2])”。\(ending)

            摄影机从开场构图持续跟随主体，先轻微前移，再沿动作方向平滑侧移或环绕，景别随动作自然收紧；全段只允许一次连续运镜，禁止切换机位、跳切、转场、定格、静态摆拍、幻灯片式推拉或只让镜头动而人物不动。动作速度自然，重力、惯性和物体接触可信；不得瞬移、变脸、换装、肢体变形或让人物与物件突然出现消失。不要文字、字幕、数字标注、二维码、水印、品牌标志或界面元素。
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

    private static func actionBeats(from context: String) -> [String] {
        let parts = context
            .split(whereSeparator: { "，。！？；、,!?;".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [context, context, context] }
        return (0..<3).map { index in
            let lower = index * parts.count / 3
            let upper = max(lower + 1, (index + 1) * parts.count / 3)
            return parts[lower..<min(upper, parts.count)].joined(separator: "，")
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
