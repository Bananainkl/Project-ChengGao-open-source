import AppKit
import Foundation

enum CoverArtworkPlanner {
    static func artworks(for output: RewriteOutput) -> [CoverArtwork] {
        let saved = (output.coverArtworks ?? []).reduce(into: [CoverFormat: CoverArtwork]()) {
            $0[$1.format] = $1
        }
        return CoverFormat.allCases.map { format in
            saved[format] ?? CoverArtwork(
                format: format,
                prompt: prompt(for: output, format: format)
            )
        }
    }

    static func prompt(for output: RewriteOutput, format: CoverFormat) -> String {
        let title = flatten(output.title)
        let body = flatten(output.subtitleReadyBody)
        let theme = String(body.prefix(420))
        let composition = switch format {
        case .douyinPortrait:
            "主体位于画面上半部，使用醒目的单主体或单一视觉隐喻，下半部和中央保留大面积低细节安全区供标题排版；缩略图尺寸下仍能一眼识别。"
        case .douyinLandscape:
            "主体位于画面右侧三分之一，左侧保留大面积低细节安全区供标题排版；构图简洁、有横向延展感，缩略图尺寸下仍能一眼识别。"
        }
        return """
        生成一张可直接作为\(format.title)背景的主视觉。内容标题：『\(title)』。成稿核心内容：『\(theme)』。先理解标题与正文的核心矛盾、人物处境和情绪钩子，再只选择一个最有传播力且不歪曲事实的视觉瞬间；画面必须与正文主题直接相关，不能使用空泛科技光效或无关人物。\(composition)统一画面风格：\(output.effectiveVisualStyle.promptInstruction) 画面比例：\(format.aspectRatioLabel)，高细节，强主次关系和清晰轮廓。背景图中不要生成任何文字、字母、数字、字幕、二维码、水印、品牌标志或界面元素；准确标题将由澄稿在本机排版。
        """
    }

    private static func flatten(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CoverArtworkRenderer {
    static func render(
        backgroundData: Data,
        title: String,
        format: CoverFormat
    ) throws -> Data {
        guard let source = NSImage(data: backgroundData) else {
            throw ImageGenerationError.invalidImageData
        }
        let size = format.canvasSize
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ImageGenerationError.invalidImageData
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: CGRect(origin: .zero, size: size),
            from: sourceCropRect(sourceSize: source.size, targetSize: size),
            operation: .copy,
            fraction: 1
        )

        let gradient = NSGradient(
            colors: [NSColor.black.withAlphaComponent(0.04), NSColor.black.withAlphaComponent(0.68)]
        )
        let overlayRect = switch format {
        case .douyinPortrait:
            CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.64)
        case .douyinLandscape:
            CGRect(x: 0, y: 0, width: size.width * 0.68, height: size.height)
        }
        gradient?.draw(in: overlayRect, angle: format == .douyinPortrait ? 90 : 0)

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let textRect = switch format {
        case .douyinPortrait:
            CGRect(x: 92, y: 112, width: size.width - 184, height: size.height * 0.45)
        case .douyinLandscape:
            CGRect(x: 92, y: 105, width: size.width * 0.53, height: size.height - 210)
        }
        drawTitle(cleanTitle.isEmpty ? "未命名短视频" : cleanTitle, in: textRect, format: format)

        context.flushGraphics()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageGenerationError.invalidImageData
        }
        return png
    }

    private static func sourceCropRect(sourceSize: CGSize, targetSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let targetRatio = targetSize.width / targetSize.height
        let sourceRatio = sourceSize.width / sourceSize.height
        if sourceRatio > targetRatio {
            let width = sourceSize.height * targetRatio
            return CGRect(x: (sourceSize.width - width) / 2, y: 0, width: width, height: sourceSize.height)
        }
        let height = sourceSize.width / targetRatio
        return CGRect(x: 0, y: (sourceSize.height - height) / 2, width: sourceSize.width, height: height)
    }

    private static func drawTitle(_ title: String, in rect: CGRect, format: CoverFormat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = format == .douyinPortrait ? 10 : 6
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.78)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -4)

        let maximum = format == .douyinPortrait ? 104.0 : 82.0
        let minimum = format == .douyinPortrait ? 58.0 : 46.0
        var fontSize = maximum
        var attributed = attributedTitle(title, fontSize: fontSize, paragraph: paragraph, shadow: shadow)
        while fontSize > minimum,
              attributed.boundingRect(
                with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
              ).height > rect.height {
            fontSize -= 4
            attributed = attributedTitle(title, fontSize: fontSize, paragraph: paragraph, shadow: shadow)
        }
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private static func attributedTitle(
        _ title: String,
        fontSize: CGFloat,
        paragraph: NSParagraphStyle,
        shadow: NSShadow
    ) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
                .shadow: shadow,
                .strokeColor: NSColor.black.withAlphaComponent(0.35),
                .strokeWidth: -2.2
            ]
        )
    }
}
