@preconcurrency import AVFoundation
import Vision

enum VideoFrameTextExtractor {
    static func extract(from videoURL: URL, durationSeconds: Int?) async -> String {
        let asset = AVURLAsset(url: videoURL)
        let duration: Double
        if let durationSeconds, durationSeconds > 0 {
            duration = Double(durationSeconds)
        } else if let loaded = try? await asset.load(.duration), loaded.isNumeric {
            duration = loaded.seconds
        } else {
            return ""
        }
        guard duration > 0 else { return "" }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_280, height: 1_280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        let count = max(1, min(24, Int(ceil(duration))))
        var visibleText: [String] = []
        for index in 0..<count {
            try? Task.checkCancellation()
            let second = min(duration - 0.05, (Double(index) + 0.5) * duration / Double(count))
            let time = CMTime(seconds: max(0, second), preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: time) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            try? VNImageRequestHandler(cgImage: image).perform([request])
            visibleText.append((request.results ?? [])
                .filter { value in
                    let middle = value.boundingBox.midY
                    let horizontalCaption = value.boundingBox.width >= value.boundingBox.height * 1.5
                    return horizontalCaption && (middle <= 0.35 || middle >= 0.65)
                }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n"))
        }
        return mergedVisibleText(visibleText)
    }

    nonisolated static func mergedVisibleText(_ values: [String]) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for value in values {
            for rawLine in value.components(separatedBy: .newlines) {
                let line = rawLine
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let key = line.replacingOccurrences(of: " ", with: "")
                guard key.count >= 2,
                      !seen.contains(key),
                      !seen.contains(where: { isNearDuplicate(key, $0) }) else { continue }
                seen.insert(key)
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func isNearDuplicate(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count == rhs.count, lhs.count >= 4 else { return false }
        let differences = zip(lhs, rhs).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }
        return differences <= max(1, lhs.count / 6)
    }
}
