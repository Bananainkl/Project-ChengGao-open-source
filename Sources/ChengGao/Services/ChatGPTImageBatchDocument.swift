import Foundation

enum ChatGPTImageBatchDocument {
    static let batchSize = 10

    static func render(output: RewriteOutput) -> String {
        let shots = VisualShotPlanner.shots(for: output)
        let count = shots.count
        let width = max(2, String(count).count)
        let ratio = aspectRatio(for: output.style)
        let batches = stride(from: 0, to: count, by: batchSize).map { start in
            start..<min(start + batchSize, count)
        }
        let batchQueue = batches.enumerated().map { batchOffset, range in
            let start = number(range.lowerBound + 1, width: width)
            let end = number(range.upperBound, width: width)
            let trigger = batchOffset == 0 ? "首次读取自动执行" : "口令：继续第 \(batchOffset + 1) 批"
            return "- [ ] 第 \(batchOffset + 1) 批：图片 \(start)–\(end)（\(range.count) 张；\(trigger)）"
        }.joined(separator: "\n")
        let batchSections = batches.enumerated().map { batchOffset, range in
            let batchNumber = batchOffset + 1
            let start = number(range.lowerBound + 1, width: width)
            let end = number(range.upperBound, width: width)
            let trigger = batchOffset == 0
                ? "首次上传本文档时自动执行本批。"
                : "只有当用户回复“继续第 \(batchNumber) 批”或在上一批后回复“继续”时，才执行本批。"
            let tasks = range.map { offset in
                taskSection(shot: shots[offset], offset: offset, width: width, ratio: ratio)
            }.joined(separator: "\n\n---\n\n")
            let checklist = range.map { offset in
                "- [ ] 图片 \(number(offset + 1, width: width))"
            }.joined(separator: "\n")
            let completion: String
            if batchNumber < batches.count {
                completion = "本批全部生成后立即停止，不要提前执行下一批。回复：‘第 \(batchNumber) 批已完成（图片 \(start)–\(end)）。请回复：继续第 \(batchNumber + 1) 批。’"
            } else {
                completion = "本批全部生成后回复：‘全部 \(count) 张图片已完成。’不要漏报或把未生成的图片标记为完成。"
            }
            return """
            ## 第 \(batchNumber) 批｜图片 \(start)–\(end)

            \(trigger)

            ### 本批清单

            \(checklist)

            \(tasks)

            ### 本批结束指令

            \(completion)
            """
        }.joined(separator: "\n\n---\n\n")

        return """
        # \(flatten(output.title))｜ChatGPT 批量生图任务

        这是一份需要实际执行的生图队列，共 \(count) 张图片、\(batches.count) 批，每批最多 \(batchSize) 张。首次读取本文档时只执行第 1 批；不要尝试在一个回复中生成全部批次，也不要只总结、改写或复述提示词。

        ## 必须遵守的批次协议

        1. 单轮只执行当前批次，最多生成 \(batchSize) 张；完成本批后必须停止并提示下一批口令。
        2. 用户回复“继续”时，读取本文档的批次队列，从下一批的第一个编号继续；不得从图片 01 重来。
        3. 每个编号生成一张独立图片，严格对应各自的完整提示词。
        4. 禁止把多个编号合并成拼图、九宫格、分镜表、联系表或一张多面板图片。
        5. 全部图片统一采用 \(ratio) 和“\(output.effectiveVisualStyle.rawValue)”画面风格；同一人物、空间、配色、材质与整体视觉语言应尽量连续，但不得牺牲单张提示词中的具体要求。
        6. 当前批次内按编号连续生成，不要在每张图片前向用户重复询问或等待确认。
        7. 每完成一张，就标记“已完成图片 XX”；未实际生成的编号不得勾选或声称完成。
        8. 如果当前批次中途受额度、耗时或工具限制中断，明确写出最后完成编号；用户回复“继续”时先补完当前批次，再进入下一批。
        9. 不要在画面中额外添加任务编号、提示词、字幕、水印、二维码或文件名。

        ## 统一参数

        - 内容标题：\(flatten(output.title))
        - 内容类型：\(output.style.rawValue)
        - 画面风格：\(output.effectiveVisualStyle.rawValue)
        - 风格规范：\(output.effectiveVisualStyle.promptInstruction)
        - 图片总数：\(count)
        - 统一比例：\(ratio)
        - 输出方式：每项一张独立图片

        ## 批次队列

        \(batchQueue)

        ---

        \(batchSections)
        """
    }

    static func suggestedDocumentFilename(for output: RewriteOutput) -> String {
        let title = filenameComponent(output.title)
        return "\(title.isEmpty ? "澄稿配图" : title)-ChatGPT-批量生图.md"
    }

    private static func aspectRatio(for style: RewriteStyle) -> String {
        switch style {
        case .spoken, .channel: "9:16 竖版"
        case .article: "16:9 横版"
        case .social: "3:4 竖版"
        }
    }

    private static func suggestedFilename(number: String, timecode: String) -> String {
        let label = filenameComponent(timecode)
        return label.isEmpty ? "\(number).png" : "\(number)-\(label).png"
    }

    private static func taskSection(
        shot: VisualShot,
        offset: Int,
        width: Int,
        ratio: String
    ) -> String {
        let imageNumber = number(offset + 1, width: width)
        let filename = suggestedFilename(number: imageNumber, timecode: shot.timecode)
        return """
        ### 图片 \(imageNumber)｜\(flatten(shot.timecode))

        - 建议文件名：`\(filename)`
        - 画面比例：\(ratio)
        - 时间／位置：\(flatten(shot.timecode))

        #### 对应文案

        \(blockquote(shot.spokenContext))

        #### 完整生图提示词

        \(blockquote(shot.prompt))
        """
    }

    private static func number(_ value: Int, width: Int) -> String {
        String(format: "%0*d", width, value)
    }

    private static func filenameComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let pieces = value
            .components(separatedBy: invalid.union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
        return pieces.joined(separator: "-")
    }

    private static func flatten(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blockquote(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "> （无）" }
        return clean.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }
}
