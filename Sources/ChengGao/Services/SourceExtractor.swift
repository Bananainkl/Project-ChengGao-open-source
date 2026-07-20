import Foundation

protocol SourceExtracting: Sendable {
    func content(kind: SourceKind, urlString: String, pastedText: String) async throws -> SourceMaterial
}

protocol ResearchSourceExtracting: Sendable {
    func content(from researchContent: ResearchContent) async throws -> SourceMaterial
}

enum SourceExtractionError: LocalizedError {
    case invalidURL
    case requestFailed
    case malformedResponse
    case unsupportedPage
    case transcriptUnavailable
    case platformSessionRequired(String)
    case platformLinkUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入完整的 http:// 或 https:// 链接。"
        case .requestFailed: "无法读取这个链接，请检查网络、链接权限或稍后再试。"
        case .malformedResponse: "平台返回了无法识别的数据。"
        case .unsupportedPage: "这个网页没有提供可直接读取的正文。"
        case .transcriptUnavailable: "没有取得完整字幕或音轨，因此已停止改写，避免只根据标题或简介生成内容。"
        case .platformSessionRequired(let platform):
            "\(platform)没有返回可转写的视频数据。请先在“平台账号”里重新登录并完成验证，再重试这条链接。"
        case .platformLinkUnavailable(let platform):
            "\(platform)没有返回这条内容。链接可能已经过期、内容已删除，或只对部分账号可见。请在平台中重新打开内容并复制最新分享链接后再试。"
        }
    }
}

actor SourceExtractor: SourceExtracting, ResearchSourceExtracting {
    private let transcriber: any SpeechTranscribing
    private let visualAnalyzer: OnlineSourceVisualAnalyzer

    init(
        transcriber: any SpeechTranscribing = LocalSpeechTranscriber(),
        visualAnalyzer: OnlineSourceVisualAnalyzer = OnlineSourceVisualAnalyzer()
    ) {
        self.transcriber = transcriber
        self.visualAnalyzer = visualAnalyzer
    }

    func content(from researchContent: ResearchContent) async throws -> SourceMaterial {
        guard researchContent.platform == .xiaohongshu else {
            return try await content(
                kind: .link,
                urlString: researchContent.contentURL.absoluteString,
                pastedText: ""
            )
        }
        let resolved = try await XiaohongshuContentResolver.resolve(content: researchContent)
        if resolved.kind == .video {
            guard let mediaURL = resolved.videoURL else { throw SourceExtractionError.transcriptUnavailable }
            let localVideo = try await download(
                mediaURL,
                referer: researchContent.contentURL.absoluteString,
                userAgent: resolved.userAgent,
                fileExtension: mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension
            )
            defer { try? FileManager.default.removeItem(at: localVideo) }
            let transcript = try await transcriber.transcribe(
                audioURL: localVideo,
                expectedDuration: resolved.durationSeconds
            )
            guard Self.isPlausibleTranscript(transcript, duration: resolved.durationSeconds) else {
                throw SourceExtractionError.transcriptUnavailable
            }
            return SourceMaterial(
                title: resolved.title,
                transcript: transcript,
                origin: .localSpeechRecognition,
                durationSeconds: resolved.durationSeconds,
                sourceContentKind: .video
            )
        }

        let text = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !resolved.imageURLs.isEmpty else {
            throw SourceExtractionError.unsupportedPage
        }
        var downloaded: [(URL, Data)] = []
        for imageURL in resolved.imageURLs.prefix(9) {
            if let data = try? await requestData(
                url: imageURL,
                referer: researchContent.contentURL.absoluteString
            ), data.count > 4_000 {
                downloaded.append((imageURL, data))
            }
        }
        guard !downloaded.isEmpty else {
            throw SourceExtractionError.platformSessionRequired("小红书图文图片")
        }
        let references = try await visualAnalyzer.analyze(images: downloaded, postText: text)
        guard !references.isEmpty else { throw OpenRouterError.invalidResponse }
        let recognizedImageText = references.compactMap { reference -> String? in
            let value = reference.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : "原图 \(reference.index)：\(value)"
        }.joined(separator: "\n")
        let rewriteSource = [
            text.nonEmptySourceValue,
            recognizedImageText.isEmpty ? nil : "【图片内文字识别，仅作全文改写依据】\n\(recognizedImageText)"
        ].compactMap { $0 }.joined(separator: "\n\n")
        guard !rewriteSource.isEmpty else { throw SourceExtractionError.unsupportedPage }
        return SourceMaterial(
            title: resolved.title,
            transcript: rewriteSource,
            origin: .socialImageText,
            durationSeconds: nil,
            visualReferences: references,
            sourceContentKind: .imageText
        )
    }

    func content(kind: SourceKind, urlString: String, pastedText: String) async throws -> SourceMaterial {
        let pasted = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .text {
            guard !pasted.isEmpty else { throw RewritePipelineError.emptyInput }
            return SourceMaterial(title: "粘贴文稿", transcript: pasted, origin: .pastedText, durationSeconds: nil)
        }

        // Share sheets commonly provide "video title + URL". That text is only
        // a link carrier and must never be treated as the spoken transcript.
        let candidate = Self.firstURL(in: urlString) ?? Self.firstURL(in: pasted)
        guard var url = candidate else { throw SourceExtractionError.invalidURL }

        if url.host?.lowercased() == "b23.tv" {
            url = try await resolvedURL(url)
        }
        if Self.isDouyin(url), Self.douyinVideoID(in: url) == nil {
            url = try await resolvedURL(url)
        }

        if Self.isBilibili(url), let bvid = Self.bilibiliBVID(in: url.absoluteString) {
            return try await bilibiliMaterial(bvid: bvid)
        }
        if Self.isYouTube(url), let videoID = Self.youtubeVideoID(in: url) {
            return try await youtubeMaterial(videoID: videoID)
        }
        if Self.isDouyin(url), let videoID = Self.douyinVideoID(in: url) {
            return try await douyinMaterial(videoID: videoID, contentURL: url)
        }
        if let xiaohongshuContent = Self.xiaohongshuContent(for: url) {
            // A pasted Xiaohongshu link must use the same authenticated detail
            // resolver as an item opened from Research. Treating it as a plain
            // article only extracts the web shell and sends navigation noise to
            // the rewrite model instead of the note text and images.
            return try await content(from: xiaohongshuContent)
        }
        return try await articleMaterial(url: url)
    }

    private func douyinMaterial(videoID: String, contentURL: URL) async throws -> SourceMaterial {
        let resource = try await DouyinVideoResolver.resolve(videoID: videoID, contentURL: contentURL)
        var localVideo: URL?
        for mediaURL in resource.mediaURLs.prefix(6) {
            localVideo = try? await download(
                mediaURL,
                referer: contentURL.absoluteString,
                userAgent: resource.userAgent,
                fileExtension: mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension
            )
            if localVideo != nil { break }
        }
        guard let localVideo else { throw SourceExtractionError.transcriptUnavailable }
        defer { try? FileManager.default.removeItem(at: localVideo) }
        let transcript = try await transcriber.transcribe(
            audioURL: localVideo,
            expectedDuration: resource.durationSeconds
        )
        guard Self.isPlausibleTranscript(transcript, duration: resource.durationSeconds) else {
            throw SourceExtractionError.transcriptUnavailable
        }
        return SourceMaterial(
            title: resource.title,
            transcript: transcript,
            origin: .localSpeechRecognition,
            durationSeconds: resource.durationSeconds,
            sourceContentKind: .video
        )
    }

    private func youtubeMaterial(videoID: String) async throws -> SourceMaterial {
        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=zh-CN")!
        let html = String(decoding: try await requestData(url: watchURL, referer: nil), as: UTF8.self)
        let webPlayer = Self.youtubePlayerResponse(from: html)
        var apiPlayer: [String: Any]?
        if let apiKey = Self.youtubeConfigurationValue("INNERTUBE_API_KEY", in: html) {
            do {
                apiPlayer = try await youtubePlayerAPIResponse(
                    videoID: videoID,
                    apiKey: apiKey,
                    visitorData: Self.youtubeConfigurationValue("VISITOR_DATA", in: html)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                apiPlayer = nil
            }
        }
        var players: [(payload: [String: Any], userAgent: String)] = []
        if let webPlayer { players.append((webPlayer, Self.userAgent)) }
        if let apiPlayer { players.append((apiPlayer, Self.youtubeAndroidUserAgent)) }
        guard let details = players.compactMap({ $0.payload["videoDetails"] as? [String: Any] }).first else {
            throw SourceExtractionError.malformedResponse
        }
        let title = details["title"] as? String ?? "YouTube 视频"
        let duration = Self.integer(details["lengthSeconds"])

        for player in players {
            do {
                if let transcript = try await youtubeCaptionTranscript(
                    player: player.payload,
                    watchURL: watchURL,
                    userAgent: player.userAgent
                ), Self.isPlausibleTranscript(transcript, duration: duration) {
                    return SourceMaterial(
                        title: title, transcript: transcript, origin: .platformSubtitle,
                        durationSeconds: duration, sourceContentKind: .video
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        for player in players.reversed() {
            guard let audio = Self.youtubeAudioResource(from: player.payload) else { continue }
            do {
                let localAudio = try await download(
                    audio.url,
                    referer: watchURL.absoluteString,
                    userAgent: player.userAgent,
                    fileExtension: audio.fileExtension
                )
                defer { try? FileManager.default.removeItem(at: localAudio) }
                let transcript = try await transcriber.transcribe(
                    audioURL: localAudio,
                    expectedDuration: duration
                )
                if Self.isPlausibleTranscript(transcript, duration: duration) {
                    return SourceMaterial(
                        title: title, transcript: transcript, origin: .localSpeechRecognition,
                        durationSeconds: duration, sourceContentKind: .video
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw SourceExtractionError.transcriptUnavailable
    }

    private func youtubeCaptionTranscript(
        player: [String: Any],
        watchURL: URL,
        userAgent: String
    ) async throws -> String? {
        guard let captions = player["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let tracks = renderer["captionTracks"] as? [[String: Any]],
              let selected = tracks.first(where: { ($0["languageCode"] as? String)?.hasPrefix("zh") == true })
                ?? tracks.first,
              let baseURL = selected["baseUrl"] as? String,
              var components = URLComponents(string: baseURL) else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "fmt" }
        queryItems.append(URLQueryItem(name: "fmt", value: "json3"))
        components.queryItems = queryItems
        guard let captionURL = components.url else { return nil }
        let captionData = try await requestData(
            url: captionURL,
            referer: watchURL.absoluteString,
            userAgent: userAgent
        )
        return Self.youtubeTranscript(fromCaptionData: captionData)
    }

    private func youtubePlayerAPIResponse(
        videoID: String,
        apiKey: String,
        visitorData: String?
    ) async throws -> [String: Any] {
        guard var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/player") else {
            throw SourceExtractionError.malformedResponse
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw SourceExtractionError.malformedResponse }
        var client: [String: Any] = [
            "clientName": "ANDROID_VR",
            "clientVersion": Self.youtubeAndroidClientVersion,
            "androidSdkVersion": 32,
            "osName": "Android",
            "osVersion": "12",
            "hl": "zh-CN",
            "gl": "US"
        ]
        if let visitorData, !visitorData.isEmpty { client["visitorData"] = visitorData }
        let body: [String: Any] = [
            "context": ["client": client],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.youtubeAndroidUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK" else {
                throw SourceExtractionError.requestFailed
            }
            return payload
        } catch let error as SourceExtractionError {
            throw error
        } catch {
            throw SourceExtractionError.requestFailed
        }
    }

    nonisolated static func youtubeTranscript(fromCaptionData captionData: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: captionData) as? [String: Any],
              let events = payload["events"] as? [[String: Any]] else { return nil }
        let lines = events.compactMap { event -> String? in
            guard let segments = event["segs"] as? [[String: Any]] else { return nil }
            let line = segments.compactMap { $0["utf8"] as? String }.joined()
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
        let transcript = lines.joined(separator: "\n")
        return transcript.isEmpty ? nil : transcript
    }

    private func bilibiliMaterial(bvid: String) async throws -> SourceMaterial {
        let viewURL = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)")!
        let viewJSON = try await json(from: viewURL, referer: "https://www.bilibili.com/video/\(bvid)/")
        guard let data = viewJSON["data"] as? [String: Any],
              let title = data["title"] as? String,
              let cid = Self.integer(data["cid"]) else {
            throw SourceExtractionError.malformedResponse
        }
        let duration = Self.integer(data["duration"])
        let referer = "https://www.bilibili.com/video/\(bvid)/"

        if let subtitle = try await bilibiliSubtitle(bvid: bvid, cid: cid, referer: referer),
           Self.isPlausibleTranscript(subtitle, duration: duration) {
            return SourceMaterial(
                title: title, transcript: subtitle, origin: .platformSubtitle,
                durationSeconds: duration, sourceContentKind: .video
            )
        }

        guard let audioURL = try await bilibiliAudioURL(bvid: bvid, cid: cid, referer: referer) else {
            throw SourceExtractionError.transcriptUnavailable
        }
        let localAudio = try await download(audioURL, referer: referer)
        defer { try? FileManager.default.removeItem(at: localAudio) }
        let transcript = try await transcriber.transcribe(audioURL: localAudio, expectedDuration: duration)
        guard Self.isPlausibleTranscript(transcript, duration: duration) else {
            throw SourceExtractionError.transcriptUnavailable
        }
        return SourceMaterial(
            title: title, transcript: transcript, origin: .localSpeechRecognition,
            durationSeconds: duration, sourceContentKind: .video
        )
    }

    private func bilibiliSubtitle(bvid: String, cid: Int, referer: String) async throws -> String? {
        let url = URL(string: "https://api.bilibili.com/x/player/v2?bvid=\(bvid)&cid=\(cid)")!
        let response = try await json(from: url, referer: referer)
        guard let data = response["data"] as? [String: Any],
              let subtitle = data["subtitle"] as? [String: Any],
              let subtitles = subtitle["subtitles"] as? [[String: Any]],
              let first = subtitles.first,
              var subtitleURL = first["subtitle_url"] as? String else { return nil }
        if subtitleURL.hasPrefix("//") { subtitleURL = "https:" + subtitleURL }
        guard let url = URL(string: subtitleURL) else { return nil }
        let payload = try await json(from: url, referer: referer)
        guard let body = payload["body"] as? [[String: Any]] else { return nil }
        let lines = body.compactMap { ($0["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func bilibiliAudioURL(bvid: String, cid: Int, referer: String) async throws -> URL? {
        let url = URL(string: "https://api.bilibili.com/x/player/playurl?bvid=\(bvid)&cid=\(cid)&fnval=16&qn=80")!
        let json = try await json(from: url, referer: referer)
        guard let data = json["data"] as? [String: Any],
              let dash = data["dash"] as? [String: Any],
              let audio = dash["audio"] as? [[String: Any]] else { return nil }
        let best = audio.max { Self.integer($0["bandwidth"]) ?? 0 < Self.integer($1["bandwidth"]) ?? 0 }
        let value = best?["baseUrl"] as? String ?? best?["base_url"] as? String
        return value.flatMap(URL.init(string:))
    }

    private func articleMaterial(url: URL) async throws -> SourceMaterial {
        let data = try await requestData(url: url, referer: nil)
        let html = String(decoding: data, as: UTF8.self)
        let extracted = Self.articleText(fromHTML: html)
        guard extracted.count >= 80 else { throw SourceExtractionError.unsupportedPage }
        let title = Self.htmlTitle(from: html) ?? url.host ?? "网页正文"
        return SourceMaterial(title: title, transcript: extracted, origin: .webArticle, durationSeconds: nil)
    }

    private func json(from url: URL, referer: String?) async throws -> [String: Any] {
        let data = try await requestData(url: url, referer: referer)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceExtractionError.malformedResponse
        }
        if let code = Self.integer(json["code"]), code != 0 { throw SourceExtractionError.requestFailed }
        return json
    }

    private func requestData(
        url: URL,
        referer: String?,
        userAgent: String = SourceExtractor.userAgent
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode else {
                throw SourceExtractionError.requestFailed
            }
            return data
        } catch let error as SourceExtractionError {
            throw error
        } catch {
            throw SourceExtractionError.requestFailed
        }
    }

    private func resolvedURL(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let resolved = response.url else { throw SourceExtractionError.requestFailed }
            return resolved
        } catch let error as SourceExtractionError {
            throw error
        } catch {
            throw SourceExtractionError.requestFailed
        }
    }

    private func download(
        _ url: URL,
        referer: String,
        userAgent: String = SourceExtractor.userAgent,
        fileExtension: String = "m4s"
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let temporaryURL: URL
        do {
            let (downloadedURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode else {
                throw SourceExtractionError.requestFailed
            }
            temporaryURL = downloadedURL
        } catch let error as SourceExtractionError {
            throw error
        } catch {
            throw SourceExtractionError.requestFailed
        }
        guard let values = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 16_000 else {
            throw SourceExtractionError.transcriptUnavailable
        }
        let safeExtension = fileExtension.range(of: #"^[A-Za-z0-9]{1,8}$"#, options: .regularExpression) == nil
            ? "media" : fileExtension
        let target = FileManager.default.temporaryDirectory
            .appending(path: "chenggao-\(UUID().uuidString).\(safeExtension)")
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: target)
            return target
        } catch {
            throw SourceExtractionError.requestFailed
        }
    }

    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
    nonisolated static let youtubeAndroidClientVersion = "1.65.10"
    nonisolated static let youtubeAndroidUserAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12; zh_CN; Quest 3 Build/SQ3A.220605.009.A1) gzip"

    nonisolated static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, range: range)?.url
    }

    nonisolated static func isBilibili(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "b23.tv" || host == "bilibili.com" || host.hasSuffix(".bilibili.com")
    }

    nonisolated static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    nonisolated static func isDouyin(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "douyin.com" || host.hasSuffix(".douyin.com")
    }

    nonisolated static func isXiaohongshu(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com")
    }

    nonisolated static func xiaohongshuContent(for url: URL) -> ResearchContent? {
        guard isXiaohongshu(url) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        let contentID = components.firstIndex(of: "explore").flatMap { index -> String? in
            let next = components.index(after: index)
            guard next < components.endIndex else { return nil }
            let value = components[next].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return ResearchContent(
            id: "xiaohongshu:direct:\(contentID ?? url.absoluteString)",
            platform: .xiaohongshu,
            platformContentID: contentID,
            keyword: "直接链接",
            title: "小红书内容",
            description: nil,
            authorName: nil,
            authorURL: nil,
            contentURL: url,
            coverURL: nil,
            publishedAt: nil,
            durationSeconds: nil,
            viewCount: nil,
            likeCount: nil,
            commentCount: nil,
            collectCount: nil,
            shareCount: nil,
            hotScore: 0,
            collectedAt: .now,
            contentKind: .imageText,
            imageURLs: nil
        )
    }

    nonisolated static func douyinVideoID(in url: URL) -> String? {
        let value = url.absoluteString
        guard let range = value.range(of: #"/video/([0-9]+)"#, options: .regularExpression) else {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { ["modal_id", "aweme_id", "awemeId"].contains($0.name) })?.value
                .flatMap(validDouyinVideoID)
        }
        let match = String(value[range])
        return match.split(separator: "/").last.map(String.init).flatMap(validDouyinVideoID)
    }

    nonisolated static func validDouyinVideoID(_ value: String) -> String? {
        value.range(of: #"^[0-9]{8,30}$"#, options: .regularExpression) == nil ? nil : value
    }

    nonisolated static func youtubeVideoID(in url: URL) -> String? {
        if url.host?.lowercased() == "youtu.be" {
            return url.pathComponents.dropFirst().first.flatMap(validYouTubeID)
        }
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "v" })?.value.flatMap(validYouTubeID) {
            return value
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        if let marker = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }), parts.indices.contains(marker + 1) {
            return validYouTubeID(parts[marker + 1])
        }
        return nil
    }

    nonisolated static func validYouTubeID(_ value: String) -> String? {
        value.range(of: #"^[0-9A-Za-z_-]{11}$"#, options: .regularExpression) == nil ? nil : value
    }

    nonisolated static func youtubePlayerResponse(from html: String) -> [String: Any]? {
        let markers = ["ytInitialPlayerResponse = ", "ytInitialPlayerResponse =", #"\"ytInitialPlayerResponse\":"#]
        for marker in markers {
            guard let markerRange = html.range(of: marker),
                  let opening = html[markerRange.upperBound...].firstIndex(of: "{") else { continue }
            var depth = 0
            var inString = false
            var escaped = false
            var cursor = opening
            while cursor < html.endIndex {
                let character = html[cursor]
                if inString {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = html.index(after: cursor)
                        let data = Data(html[opening..<end].utf8)
                        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    }
                }
                cursor = html.index(after: cursor)
            }
        }
        return nil
    }

    nonisolated static func youtubeConfigurationValue(_ key: String, in html: String) -> String? {
        let marker = "\"\(key)\":\""
        guard let range = html.range(of: marker) else { return nil }
        var cursor = range.upperBound
        var escaped = false
        while cursor < html.endIndex {
            let character = html[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let value = String(html[range.upperBound..<cursor])
                return value.isEmpty ? nil : value
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    nonisolated static func youtubeAudioResource(from player: [String: Any]) -> (url: URL, fileExtension: String)? {
        guard let streaming = player["streamingData"] as? [String: Any] else { return nil }
        let formats = (streaming["adaptiveFormats"] as? [[String: Any]] ?? [])
            + (streaming["formats"] as? [[String: Any]] ?? [])
        let audio = formats.filter { format in
            guard let mime = format["mimeType"] as? String,
                  mime.hasPrefix("audio/"),
                  let value = format["url"] as? String,
                  URL(string: value) != nil else { return false }
            return true
        }
        let mp4 = audio.filter { (($0["mimeType"] as? String) ?? "").hasPrefix("audio/mp4") }
        guard let best = (mp4.isEmpty ? audio : mp4).max(by: {
            (integer($0["bitrate"]) ?? 0) < (integer($1["bitrate"]) ?? 0)
        }), let value = best["url"] as? String, let url = URL(string: value) else { return nil }
        let mime = (best["mimeType"] as? String) ?? ""
        return (url, mime.hasPrefix("audio/mp4") ? "m4a" : "media")
    }

    nonisolated static func bilibiliBVID(in value: String) -> String? {
        guard let range = value.range(of: #"BV[0-9A-Za-z]{10}"#, options: .regularExpression) else { return nil }
        return String(value[range])
    }

    nonisolated static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    nonisolated static func isPlausibleTranscript(_ text: String, duration: Int?) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        let minimum = min(200, max(40, (duration ?? 80) / 2))
        return compact.count >= minimum
    }

    nonisolated static func htmlTitle(from html: String) -> String? {
        guard let range = html.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression) else { return nil }
        return readableText(fromHTML: String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts the editorial body before converting HTML to text. WeChat pages
    /// place it in `#js_content`; generic sites usually use `article` or `main`.
    /// Scoping first prevents navigation, recommendations and page chrome from
    /// being mistaken for article content.
    nonisolated static func articleText(fromHTML html: String) -> String {
        let scopedHTML = preferredArticleContainer(in: html) ?? html
        return cleanArticleBoilerplate(readableText(fromHTML: scopedHTML))
    }

    nonisolated static func preferredArticleContainer(in html: String) -> String? {
        let candidates: [(tag: String, pattern: String)] = [
            ("div", #"(?is)<div\b[^>]*\bid\s*=\s*[\"']js_content[\"'][^>]*>"#),
            ("article", #"(?is)<article\b[^>]*>"#),
            ("main", #"(?is)<main\b[^>]*>"#)
        ]
        for candidate in candidates {
            guard let opening = html.range(of: candidate.pattern, options: .regularExpression) else { continue }
            if let element = balancedElement(in: html, openingRange: opening, tag: candidate.tag) {
                return element
            }
        }
        return nil
    }

    nonisolated static func balancedElement(
        in html: String,
        openingRange: Range<String.Index>,
        tag: String
    ) -> String? {
        let tail = html[openingRange.lowerBound...]
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        guard let expression = try? NSRegularExpression(
            pattern: "(?is)</?\\s*\(escapedTag)\\b[^>]*>",
            options: []
        ) else { return nil }
        let fullRange = NSRange(tail.startIndex..<tail.endIndex, in: tail)
        let matches = expression.matches(in: String(tail), range: fullRange)
        var depth = 0
        for match in matches {
            guard let range = Range(match.range, in: tail) else { continue }
            let token = tail[range]
            if token.range(of: #"(?is)^<\s*/"#, options: .regularExpression) != nil {
                depth -= 1
                if depth == 0 {
                    return String(html[openingRange.lowerBound..<range.upperBound])
                }
            } else if !token.hasSuffix("/>") {
                depth += 1
            }
        }
        return nil
    }

    /// Removes short interaction prompts and promotional boilerplate while
    /// leaving normal prose intact. The length guard is deliberate: an article
    /// sentence that discusses "点赞" remains content rather than being dropped.
    nonisolated static func cleanArticleBoilerplate(_ text: String) -> String {
        let exactNoise = #"^(微信扫一扫|扫一扫|长按识别二维码|识别二维码|关注我们|点击关注|点赞|点个赞|在看|点亮在看|分享|收藏|转发|阅读原文|点击阅读原文|完整服务|广告|推广|继续滑动看下一个|轻触阅读原文|预览时标签不可点)$"#
        let shortNoise = #"微信扫一扫|扫码(关注|咨询|添加)|长按.{0,8}二维码|识别.{0,8}二维码|关注.{0,12}公众号|点赞.{0,8}在看|分享.{0,8}收藏|商务合作|联系我们|完整服务|点击蓝字|设为星标|星标.{0,8}公众号|更多精彩内容|点击下方|戳阅读原文"#
        var seen = Set<String>()
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.range(of: exactNoise, options: .regularExpression) != nil { return false }
                if line.count <= 60, line.range(of: shortNoise, options: [.regularExpression, .caseInsensitive]) != nil {
                    return false
                }
                if seen.contains(line) { return false }
                seen.insert(line)
                return true
            }
        return lines.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func readableText(fromHTML html: String) -> String {
        var value = html
        let removalPatterns = [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript>"#,
            #"(?is)<svg\b[^>]*>.*?</svg>"#
        ]
        for pattern in removalPatterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        value = value.replacingOccurrences(
            of: #"(?i)</?(p|div|article|section|main|h[1-6]|li|br)\b[^>]*>"#,
            with: "\n", options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&mdash;": "—", "&hellip;": "…"]
        for (entity, replacement) in entities { value = value.replacingOccurrences(of: entity, with: replacement) }
        value = value.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nonEmptySourceValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
