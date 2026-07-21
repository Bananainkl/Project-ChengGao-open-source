import Foundation

struct ShortVideoExportPackageResult: Equatable, Sendable {
    let directoryURL: URL
    let manuscriptURL: URL
    let storyboardURL: URL
    let subtitleTextURL: URL?
    let copiedImageCount: Int
    let missingImageCount: Int
    let copiedCoverCount: Int
    let missingCoverCount: Int
}

enum ShortVideoExportPackageError: LocalizedError, Sendable {
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "所选位置不是可用的文件夹。"
        }
    }
}

enum ShortVideoExportPackage {
    static func export(
        output: RewriteOutput,
        to parentDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> ShortVideoExportPackageResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ShortVideoExportPackageError.invalidDestination
        }

        let folderName = packageFolderName(for: output.title)
        let finalDirectory = uniqueDirectory(
            named: folderName,
            in: parentDirectory,
            fileManager: fileManager
        )
        let stagingDirectory = parentDirectory.appending(
            path: ".chenggao-export-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let imageDirectory = stagingDirectory.appending(path: "图片", directoryHint: .isDirectory)
        let coverDirectory = stagingDirectory.appending(path: "封面", directoryHint: .isDirectory)
        let manuscriptURL = stagingDirectory.appending(path: "改写文稿.md")
        let storyboardURL = stagingDirectory.appending(path: "分镜与配图提示词.md")
        let subtitleTextURL = stagingDirectory.appending(path: "口播字幕.txt")

        do {
            try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
            let shots = VisualShotPlanner.shots(for: output)
            let covers = CoverArtworkPlanner.artworks(for: output)
            let width = max(2, String(shots.count).count)
            var exportedImages: [Int: String] = [:]
            var exportedCovers: [CoverFormat: String] = [:]

            for cover in covers {
                guard let path = cover.generatedImagePath else { continue }
                let sourceURL = URL(fileURLWithPath: path)
                let values = try? sourceURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey
                ])
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true else { continue }
                let filename = switch cover.format {
                case .douyinPortrait: "抖音竖版封面-3x4.png"
                case .douyinLandscape: "抖音横版封面-16x9.png"
                }
                let destinationURL = coverDirectory.appending(path: filename)
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    exportedCovers[cover.format] = "封面/\(filename)"
                } catch {
                    continue
                }
            }

            for (offset, shot) in shots.enumerated() {
                guard let path = shot.generatedImagePath else { continue }
                let sourceURL = URL(fileURLWithPath: path)
                let values = try? sourceURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey
                ])
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true else { continue }

                let fileExtension = safeImageExtension(sourceURL.pathExtension)
                let filename = "\(number(offset + 1, width: width)).\(fileExtension)"
                let destinationURL = imageDirectory.appending(path: filename)
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    exportedImages[offset] = "图片/\(filename)"
                } catch {
                    // A moved or unreadable historical image should not block
                    // the manuscript and storyboard from being exported.
                    continue
                }
            }

            try manuscriptMarkdown(output: output)
                .write(to: manuscriptURL, atomically: true, encoding: .utf8)
            try storyboardMarkdown(
                output: output,
                shots: shots,
                exportedImages: exportedImages,
                covers: covers,
                exportedCovers: exportedCovers
            ).write(to: storyboardURL, atomically: true, encoding: .utf8)
            if output.style == .spoken {
                try output.subtitleReadyBody
                    .write(to: subtitleTextURL, atomically: true, encoding: .utf8)
            }
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)

            return ShortVideoExportPackageResult(
                directoryURL: finalDirectory,
                manuscriptURL: finalDirectory.appending(path: manuscriptURL.lastPathComponent),
                storyboardURL: finalDirectory.appending(path: storyboardURL.lastPathComponent),
                subtitleTextURL: output.style == .spoken
                    ? finalDirectory.appending(path: subtitleTextURL.lastPathComponent)
                    : nil,
                copiedImageCount: exportedImages.count,
                missingImageCount: max(0, shots.count - exportedImages.count),
                copiedCoverCount: exportedCovers.count,
                missingCoverCount: max(0, covers.count - exportedCovers.count)
            )
        } catch {
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try? fileManager.removeItem(at: stagingDirectory)
            }
            throw error
        }
    }

    static func packageFolderName(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        let pieces = title
            .components(separatedBy: invalid)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = pieces.joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let fallback = joined.isEmpty ? "未命名短视频" : joined
        let shortened = String(fallback.prefix(80))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return shortened.isEmpty ? "未命名短视频" : shortened
    }

    static func manuscriptMarkdown(output: RewriteOutput) -> String {
        let bodyHeading = output.style == .spoken
            ? "字幕式口播稿（一句话一行）"
            : "改写后的完整文稿"
        return """
        # \(flatten(output.title))

        - 输出类型：\(output.style.rawValue)
        - 画面风格：\(output.effectiveVisualStyle.rawValue)

        ## \(bodyHeading)

        \(output.subtitleReadyBody.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    static func storyboardMarkdown(
        output: RewriteOutput,
        shots: [VisualShot]? = nil,
        exportedImages: [Int: String] = [:],
        covers: [CoverArtwork]? = nil,
        exportedCovers: [CoverFormat: String] = [:]
    ) -> String {
        let resolvedShots = shots ?? VisualShotPlanner.shots(for: output)
        let resolvedCovers = covers ?? CoverArtworkPlanner.artworks(for: output)
        let width = max(2, String(resolvedShots.count).count)
        let copied = exportedImages.count
        let sections = resolvedShots.enumerated().map { offset, shot in
            let imageStatus: String
            if let relativePath = exportedImages[offset] {
                imageStatus = "已输出：[\(relativePath)](\(relativePath))"
            } else {
                imageStatus = "未生成或原图片已不可用；请按下方提示词补充。"
            }
            return """
            ## 镜头 \(number(offset + 1, width: width))｜\(flatten(shot.timecode))

            - 图片状态：\(imageStatus)
            - 时间／位置：\(flatten(shot.timecode))

            ### 对应文案

            \(blockquote(shot.spokenContext))

            ### 完整生图提示词

            \(blockquote(shot.prompt))
            """
        }.joined(separator: "\n\n---\n\n")
        let coverSections = resolvedCovers.map { cover in
            let imageStatus: String
            if let relativePath = exportedCovers[cover.format] {
                imageStatus = "已输出：[\(relativePath)](\(relativePath))"
            } else {
                imageStatus = "未生成或原封面已不可用；请按下方提示词补充。"
            }
            return """
            ## \(cover.format.title)｜\(cover.format.aspectRatioLabel)

            - 封面状态：\(imageStatus)
            - 准确标题：\(flatten(output.title))
            - 说明：图片模型生成无字背景；澄稿内置生成会在本机排入准确标题。

            ### 完整封面提示词

            \(blockquote(cover.prompt))
            """
        }.joined(separator: "\n\n---\n\n")

        return """
        # \(flatten(output.title))｜分镜与配图提示词

        - 内容类型：\(output.style.rawValue)
        - 画面风格：\(output.effectiveVisualStyle.rawValue)
        - 封面规格：抖音竖版 3:4 + 横版 16:9
        - 已输出封面：\(exportedCovers.count)
        - 尚缺封面：\(max(0, resolvedCovers.count - exportedCovers.count))
        - 分镜总数：\(resolvedShots.count)
        - 已输出图片：\(copied)
        - 尚缺图片：\(max(0, resolvedShots.count - copied))

        # 封面

        \(coverSections)

        ---

        # 分镜

        \(sections)
        """
    }

    private static func uniqueDirectory(
        named baseName: String,
        in parentDirectory: URL,
        fileManager: FileManager
    ) -> URL {
        let first = parentDirectory.appending(path: baseName, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        for suffix in 2...999 {
            let candidate = parentDirectory.appending(
                path: "\(baseName) (\(suffix))",
                directoryHint: .isDirectory
            )
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return parentDirectory.appending(
            path: "\(baseName)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private static func safeImageExtension(_ value: String) -> String {
        let safe = value.lowercased().filter(\.isLetter)
        let supported = ["png", "jpg", "jpeg", "webp", "heic", "gif", "tiff", "bmp"]
        return supported.contains(safe) ? safe : "png"
    }

    private static func number(_ value: Int, width: Int) -> String {
        String(format: "%0*d", width, value)
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
