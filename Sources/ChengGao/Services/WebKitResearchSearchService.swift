import AppKit
import Foundation
@preconcurrency import WebKit

enum WebKitResearchSearchError: LocalizedError {
    case missingSearchURL
    case timedOut(String)
    case loginRequired(String)
    case noRenderedResults(String)
    case navigationFailed(String, String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingSearchURL:
            "平台没有可用的网页搜索地址。"
        case .timedOut(let platform):
            "\(platform)网页加载超时，请检查网络或重新登录。"
        case .loginRequired(let platform):
            "\(platform)网页要求重新登录或完成人机验证。"
        case .noRenderedResults(let platform):
            "\(platform)网页已打开，但没有读到视频结果；页面结构可能已变化。"
        case .navigationFailed(let platform, let detail):
            "\(platform)网页加载失败：\(detail)"
        case .unsupported(let detail):
            detail
        }
    }
}

struct WebKitResearchSearchService {
    nonisolated static func capturedBodiesScript(platform: ResearchPlatform) -> String {
        let minimumPriority = platform == .douyin ? 3 : 1
        return """
        JSON.stringify((window.__chenggaoCapturedSearchResponses || [])
          .filter(value => Number(value.priority || 0) >= \(minimumPriority))
          .slice()
          .sort((left, right) => Number(right.priority || 0) - Number(left.priority || 0))
          .map(value => value.body))
        """
    }

    @MainActor
    static func search(
        platform: ResearchPlatform,
        keyword: String,
        maxItems: Int,
        recentDays: Int
    ) async throws -> [ResearchContent] {
        if platform == .wechatChannels {
            throw WebKitResearchSearchError.unsupported(
                "视频号没有可验证的公开网页关键词搜索入口；“视频号助手”只用于创作者管理。请在“新建文稿”粘贴视频号分享链接进行拆解。"
            )
        }
        let urls = platform.searchURLs(keyword: keyword)
        guard !urls.isEmpty else {
            throw WebKitResearchSearchError.missingSearchURL
        }
        var lastRecoverableError: Error?
        for url in urls {
            do {
                return try await searchPage(
                    platform: platform, url: url, keyword: keyword,
                    maxItems: maxItems, recentDays: recentDays
                )
            } catch WebKitResearchSearchError.noRenderedResults {
                lastRecoverableError = WebKitResearchSearchError.noRenderedResults(platform.title)
                continue
            } catch WebKitResearchSearchError.timedOut {
                lastRecoverableError = WebKitResearchSearchError.timedOut(platform.title)
                continue
            } catch WebKitResearchSearchError.navigationFailed(_, let detail) where platform == .douyin {
                lastRecoverableError = WebKitResearchSearchError.navigationFailed(platform.title, detail)
                continue
            }
        }
        throw lastRecoverableError ?? WebKitResearchSearchError.noRenderedResults(platform.title)
    }

    @MainActor
    private static func searchPage(
        platform: ResearchPlatform,
        url: URL,
        keyword: String,
        maxItems: Int,
        recentDays: Int
    ) async throws -> [ResearchContent] {
        let session = PlatformWebSessionPool.shared.session(for: platform)
        let webView = session.webView
        await webView.pauseAllMediaPlayback()
        webView.frame = CGRect(x: 0, y: 0, width: 1_280, height: 1_600)
        let renderWindow = backgroundRenderWindowIfNeeded(for: webView)
        defer {
            webView.stopLoading()
            webView.evaluateJavaScript(
                "document.querySelectorAll('video, audio').forEach(media => { try { media.muted = true; media.volume = 0; media.pause(); } catch (_) {} });"
            )
            Task { @MainActor in await webView.pauseAllMediaPlayback() }
            if let renderWindow {
                webView.removeFromSuperview()
                renderWindow.close()
            }
        }
        session.navigationDelegate.beginNavigation()
        _ = try? await javascriptString(
            "window.__chenggaoCapturedSearchResponses = []; 'cleared'",
            in: webView
        )
        let navigationTimeout: TimeInterval = platform == .xiaohongshu ? 45 : 15
        webView.load(URLRequest(url: url, timeoutInterval: navigationTimeout))

        let navigationDeadline = Date().addingTimeInterval(platform == .xiaohongshu ? 50 : 20)
        var navigationFinished = false
        while !navigationFinished, Date() < navigationDeadline {
            try Task.checkCancellation()
            switch session.navigationDelegate.phase {
            case .finished:
                navigationFinished = true
            case .failed(let detail):
                if platform == .xiaohongshu, await hasUsableDocument(in: webView) {
                    navigationFinished = true
                } else {
                    throw WebKitResearchSearchError.navigationFailed(platform.title, detail)
                }
            case .idle, .navigating:
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        guard navigationFinished else {
            webView.stopLoading()
            throw WebKitResearchSearchError.timedOut(platform.title)
        }

        var lastPageText = ""
        let attemptCount = platform == .douyin ? 40 : 24
        for attempt in 0..<attemptCount {
            try Task.checkCancellation()
            let pageText = (try? await javascriptString("document.body ? document.body.innerText.slice(0, 1200) : ''", in: webView)) ?? ""
            lastPageText = pageText
            if pageRequiresVerification(pageText, url: webView.url, platform: platform) {
                throw WebKitResearchSearchError.loginRequired(platform.title)
            }
            if platform == .douyin || platform == .xiaohongshu {
                let capturedPayload = (try? await javascriptString(
                    capturedBodiesScript(platform: platform),
                    in: webView
                )) ?? ""
                let capturedValues = capturedResponseContents(
                    payload: capturedPayload,
                    platform: platform,
                    keyword: keyword,
                    maxItems: maxItems,
                    recentDays: recentDays
                )
                if !capturedValues.isEmpty,
                   platform != .douyin || hasKeywordEvidence(capturedValues, keyword: keyword) {
                    return capturedValues
                }
            }
            let payload = try await javascriptString(extractionScript(platform: platform, maxItems: maxItems), in: webView)
            let values = renderedContents(
                payload: payload,
                platform: platform,
                keyword: keyword,
                maxItems: maxItems,
                recentDays: recentDays
            )
            if !values.isEmpty,
               platform != .douyin || hasKeywordEvidence(values, keyword: keyword) {
                return values
            }
            if attempt == 3 || attempt == 9 || (platform == .douyin && attempt == 19) {
                _ = try? await javascriptString(
                    "window.scrollTo(0, Math.min(document.body ? document.body.scrollHeight : 0, \(attempt == 3 ? 900 : 1800))); 'scrolled'",
                    in: webView
                )
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        if lastPageText.isEmpty {
            throw WebKitResearchSearchError.timedOut(platform.title)
        }
        throw WebKitResearchSearchError.noRenderedResults(platform.title)
    }

    nonisolated static func hasKeywordEvidence(
        _ values: [ResearchContent],
        keyword: String
    ) -> Bool {
        let normalizedKeyword = keyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedKeyword.isEmpty else { return false }
        let terms = normalizedKeyword
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 2 }
        let requiredTerms = terms.isEmpty ? [normalizedKeyword] : terms
        return values.contains { value in
            let evidence = "\(value.title)\n\(value.description ?? "")".lowercased()
            return requiredTerms.contains(where: evidence.contains)
        }
    }

    @MainActor
    private static func javascriptString(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as? String ?? "") }
            }
        }
    }

    @MainActor
    private static func backgroundRenderWindowIfNeeded(for webView: WKWebView) -> NSWindow? {
        guard webView.superview == nil else { return nil }
        let window = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 2, height: 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.alphaValue = 0.01
        let host = NSView(frame: window.contentView?.bounds ?? CGRect(x: 0, y: 0, width: 2, height: 2))
        window.contentView = host
        webView.autoresizingMask = []
        host.addSubview(webView)
        window.orderBack(nil)
        return window
    }

    nonisolated static func renderedContents(
        payload: String,
        platform: ResearchPlatform,
        keyword: String,
        maxItems: Int,
        recentDays: Int,
        now: Date = .now
    ) -> [ResearchContent] {
        guard let data = payload.data(using: .utf8),
              let records = try? JSONDecoder().decode([RenderedSearchRecord].self, from: data) else { return [] }
        var seen = Set<String>()
        return records.compactMap { record in
            guard let rawURL = URL(string: record.url),
                  let url = normalizedContentURL(platform: platform, url: rawURL),
                  let host = url.host?.lowercased(),
                  platform.cookieDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
                  seen.insert(url.absoluteString).inserted else { return nil }
            let identifier = platformContentID(platform: platform, url: url) ?? record.url
            let title = cleanTitle(record.title, context: record.context)
            guard title.count >= 2 else { return nil }
            let views = record.viewCount ?? metric(in: record.context, labels: ["播放", "观看", "views", "views"])
            let likes = record.likeCount ?? metric(in: record.context, labels: ["点赞", "赞", "likes"])
            let comments = record.commentCount ?? metric(in: record.context, labels: ["评论", "comments"])
            let collects = record.collectCount ?? metric(in: record.context, labels: ["收藏", "favorites", "saves"])
            let shares = record.shareCount ?? metric(in: record.context, labels: ["分享", "转发", "shares", "reposts"])
            return ResearchContent(
                id: "\(platform.rawValue):\(identifier)",
                platform: platform,
                platformContentID: identifier,
                keyword: keyword,
                title: title,
                description: nil,
                authorName: record.author?.trimmingCharacters(in: .whitespacesAndNewlines),
                authorURL: nil,
                contentURL: url,
                coverURL: ResearchContent.normalizedRemoteURL(record.coverURL, platform: platform),
                publishedAt: nil,
                durationSeconds: nil,
                viewCount: views,
                likeCount: likes,
                commentCount: comments,
                collectCount: collects,
                shareCount: shares,
                hotScore: ResearchContent.score(
                    views: views, likes: likes, comments: comments, collects: collects, shares: shares,
                    publishedAt: nil, now: now
                ),
                collectedAt: now,
                contentKind: record.contentKind,
                imageURLs: record.imageURLs?.compactMap {
                    ResearchContent.normalizedRemoteURL($0, platform: platform)
                }
            )
        }
        .prefix(maxItems)
        .map { $0 }
    }

    nonisolated static func capturedResponseContents(
        payload: String,
        platform: ResearchPlatform,
        keyword: String,
        maxItems: Int,
        recentDays: Int,
        now: Date = .now
    ) -> [ResearchContent] {
        guard let outerData = payload.data(using: .utf8),
              let bodies = try? JSONDecoder().decode([String].self, from: outerData) else { return [] }

        if platform == .xiaohongshu {
            return xiaohongshuCapturedContents(
                bodies: bodies, keyword: keyword, maxItems: maxItems,
                recentDays: recentDays, now: now
            )
        }
        guard platform == .douyin else { return [] }

        var records: [RenderedSearchRecord] = []
        var seen = Set<String>()
        var inspected = 0

        func walk(_ value: Any) {
            guard inspected < 80_000, records.count < max(1, maxItems) else { return }
            inspected += 1
            if let dictionary = value as? [String: Any] {
                let directIdentifier = firstString(in: dictionary, keys: [
                    "aweme_id", "awemeId", "aweme_id_str", "awemeIdStr",
                    "video_id", "videoId", "video_id_str", "videoIdStr"
                ])
                let hasVideoEvidence = dictionary["video"] != nil
                    || dictionary["video_info"] != nil
                    || dictionary["videoInfo"] != nil
                    || dictionary["statistics"] != nil
                    || dictionary["statistics_info"] != nil
                    || dictionary["statisticsInfo"] != nil
                let identifier = directIdentifier ?? (hasVideoEvidence ? firstString(
                    in: dictionary,
                    keys: [
                        "group_id", "groupId", "group_id_str", "groupIdStr",
                        "item_id", "itemId", "item_id_str", "itemIdStr", "id_str", "idStr"
                    ]
                ) : nil)
                let title = firstString(
                    in: dictionary,
                    keys: [
                        "desc", "title", "caption", "content_desc", "contentDesc",
                        "video_title", "videoTitle", "text"
                    ]
                )
                if let identifier,
                   identifier.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                   let title,
                   title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                   seen.insert(identifier).inserted {
                    let authorObject = (dictionary["author"] as? [String: Any])
                        ?? (dictionary["author_info"] as? [String: Any])
                        ?? (dictionary["user"] as? [String: Any])
                        ?? [:]
                    let videoObject = (dictionary["video"] as? [String: Any])
                        ?? (dictionary["video_info"] as? [String: Any])
                        ?? (dictionary["videoInfo"] as? [String: Any])
                        ?? [:]
                    let stats = (dictionary["statistics"] as? [String: Any])
                        ?? (dictionary["stats"] as? [String: Any])
                        ?? (dictionary["statistics_info"] as? [String: Any])
                        ?? (dictionary["statisticsInfo"] as? [String: Any])
                        ?? [:]
                    let coverValue = videoObject["cover"]
                        ?? videoObject["origin_cover"]
                        ?? videoObject["dynamic_cover"]
                        ?? dictionary["cover"]
                    records.append(RenderedSearchRecord(
                        url: "https://www.douyin.com/video/\(identifier)",
                        title: title,
                        coverURL: firstHTTPURL(in: coverValue),
                        author: firstString(in: authorObject, keys: ["nickname", "name", "unique_id"]),
                        context: title,
                        viewCount: firstInt(in: stats, keys: ["play_count", "playCount"]),
                        likeCount: firstInt(in: stats, keys: ["digg_count", "diggCount"]),
                        commentCount: firstInt(in: stats, keys: ["comment_count", "commentCount"]),
                        collectCount: firstInt(in: stats, keys: ["collect_count", "collectCount"]),
                        shareCount: firstInt(in: stats, keys: ["share_count", "shareCount"])
                    ))
                }
                for child in dictionary.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            } else if let string = value as? String,
                      string.count >= 2,
                      string.count <= 6_000_000,
                      let first = string.first,
                      first == "{" || first == "[",
                      let data = string.data(using: .utf8),
                      let embedded = try? JSONSerialization.jsonObject(with: data) {
                walk(embedded)
            }
        }

        for body in bodies {
            guard let object = capturedJSONObject(body) else { continue }
            walk(object)
            if records.count >= max(1, maxItems) { break }
        }
        guard let recordData = try? JSONEncoder().encode(records) else { return [] }
        return renderedContents(
            payload: String(decoding: recordData, as: UTF8.self),
            platform: platform,
            keyword: keyword,
            maxItems: maxItems,
            recentDays: recentDays,
            now: now
        )
    }

    nonisolated private static func capturedJSONObject(_ body: String) -> Any? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }),
              start < end,
              let data = String(trimmed[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    nonisolated private static func xiaohongshuCapturedContents(
        bodies: [String], keyword: String, maxItems: Int, recentDays: Int, now: Date
    ) -> [ResearchContent] {
        var records: [RenderedSearchRecord] = []
        var seen = Set<String>()
        var inspected = 0

        func walk(_ value: Any) {
            guard inspected < 80_000, records.count < max(1, maxItems) else { return }
            inspected += 1
            if let dictionary = value as? [String: Any] {
                let note = (dictionary["note_card"] as? [String: Any])
                    ?? (dictionary["noteCard"] as? [String: Any])
                    ?? dictionary
                let identifier = firstString(in: dictionary, keys: ["id", "note_id", "noteId"])
                    ?? firstString(in: note, keys: ["id", "note_id", "noteId"])
                let title = firstString(
                    in: note, keys: ["display_title", "displayTitle", "title", "desc"]
                )
                if let identifier,
                   identifier.range(of: #"^[0-9A-Za-z]{12,}$"#, options: .regularExpression) != nil,
                   let title,
                   title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                   seen.insert(identifier).inserted {
                    let user = (note["user"] as? [String: Any])
                        ?? (note["author"] as? [String: Any]) ?? [:]
                    let interactions = (note["interact_info"] as? [String: Any])
                        ?? (note["interactInfo"] as? [String: Any])
                        ?? (note["statistics"] as? [String: Any]) ?? [:]
                    let cover = note["cover"] ?? note["image_list"] ?? note["images_list"]
                    let rawType = firstString(
                        in: note, keys: ["type", "note_type", "noteType", "media_type", "mediaType"]
                    )?.lowercased() ?? ""
                    let isVideo = rawType.contains("video")
                        || note["video"] != nil || note["video_info"] != nil || note["videoInfo"] != nil
                    var imageURLs: [String] = []
                    collectHTTPURLs(
                        in: note["image_list"] ?? note["imageList"] ?? note["images_list"] ?? note["images"],
                        into: &imageURLs
                    )
                    var uniqueImageURLs = Array(NSOrderedSet(array: imageURLs)) as? [String] ?? imageURLs
                    if uniqueImageURLs.isEmpty, let coverURL = firstHTTPURL(in: cover) {
                        uniqueImageURLs = [coverURL]
                    }
                    let token = firstString(in: dictionary, keys: ["xsec_token", "xsecToken"])
                        ?? firstString(in: note, keys: ["xsec_token", "xsecToken"])
                    var components = URLComponents(
                        string: "https://www.xiaohongshu.com/explore/\(identifier)"
                    )
                    if let token {
                        components?.queryItems = [
                            URLQueryItem(name: "xsec_token", value: token),
                            URLQueryItem(name: "xsec_source", value: "pc_search")
                        ]
                    }
                    records.append(RenderedSearchRecord(
                        url: components?.url?.absoluteString
                            ?? "https://www.xiaohongshu.com/explore/\(identifier)",
                        title: title,
                        coverURL: firstHTTPURL(in: cover),
                        author: firstString(in: user, keys: ["nickname", "nick_name", "name"]),
                        context: title,
                        viewCount: nil,
                        likeCount: firstInt(in: interactions, keys: ["liked_count", "likedCount", "like_count"]),
                        commentCount: firstInt(in: interactions, keys: ["comment_count", "commentCount"]),
                        collectCount: firstInt(in: interactions, keys: ["collected_count", "collectedCount", "collect_count"]),
                        shareCount: firstInt(in: interactions, keys: ["shared_count", "sharedCount", "share_count"]),
                        contentKind: isVideo ? .video : .imageText,
                        imageURLs: uniqueImageURLs
                    ))
                }
                for child in dictionary.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }

        for body in bodies {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            walk(object)
            if records.count >= max(1, maxItems) { break }
        }
        guard let recordData = try? JSONEncoder().encode(records) else { return [] }
        return renderedContents(
            payload: String(decoding: recordData, as: UTF8.self),
            platform: .xiaohongshu, keyword: keyword, maxItems: maxItems,
            recentDays: recentDays, now: now
        )
    }

    nonisolated private static func firstString(
        in dictionary: [String: Any], keys: [String]
    ) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let value = dictionary[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    nonisolated private static func firstInt(
        in dictionary: [String: Any], keys: [String]
    ) -> Int? {
        for key in keys {
            if let value = ResearchSearchService.int(dictionary[key]) { return value }
        }
        return nil
    }

    nonisolated private static func firstHTTPURL(in value: Any?) -> String? {
        if let string = value as? String,
           string.hasPrefix("https://") || string.hasPrefix("http://") {
            return string
        }
        if let array = value as? [Any] {
            for child in array {
                if let url = firstHTTPURL(in: child) { return url }
            }
        }
        if let dictionary = value as? [String: Any] {
            for key in ["url_list", "urlList", "urls", "url", "url_default", "urlDefault"] {
                if let url = firstHTTPURL(in: dictionary[key]) { return url }
            }
        }
        return nil
    }

    nonisolated private static func collectHTTPURLs(in value: Any?, into urls: inout [String]) {
        if let string = value as? String,
           string.hasPrefix("https://") || string.hasPrefix("http://") {
            urls.append(string)
            return
        }
        if let array = value as? [Any] {
            for child in array { collectHTTPURLs(in: child, into: &urls) }
            return
        }
        guard let dictionary = value as? [String: Any] else { return }
        for (key, child) in dictionary where [
            "url", "url_list", "urlList", "urls", "url_default", "urlDefault",
            "info_list", "infoList", "trace_id", "traceId"
        ].contains(key) || child is [Any] || child is [String: Any] {
            collectHTTPURLs(in: child, into: &urls)
        }
    }

    nonisolated private static func normalizedContentURL(platform: ResearchPlatform, url: URL) -> URL? {
        if platform == .douyin {
            if let identifier = douyinContentID(url: url) {
                return URL(string: "https://www.douyin.com/video/\(identifier)")
            }
            return nil
        }
        if platform == .xiaohongshu, url.path.contains("/explore/") {
            return url
        }
        if platform == .xiaohongshu,
           let identifier = ResearchSearchService.capture(
                #"/(?:explore|search_result)/([^/?#]+)"#, in: url.absoluteString
           ) {
            return URL(string: "https://www.xiaohongshu.com/explore/\(identifier)")
        }
        return url
    }

    nonisolated private static func douyinContentID(url: URL) -> String? {
        if let value = ResearchSearchService.capture(#"/video/([0-9]+)"#, in: url.absoluteString) {
            return value
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first { item in
            ["modal_id", "aweme_id", "awemeId"].contains(item.name)
        }?.value.flatMap { value in
            value.range(of: #"^[0-9]+$"#, options: .regularExpression) == nil ? nil : value
        }
    }

    nonisolated private static func cleanTitle(_ title: String, context: String) -> String {
        let candidate = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.count >= 2 { return candidate }
        return context.split(separator: "\n").map(String.init).first { $0.count >= 2 } ?? ""
    }

    nonisolated private static func platformContentID(platform: ResearchPlatform, url: URL) -> String? {
        let value = url.absoluteString
        switch platform {
        case .douyin:
            return douyinContentID(url: url)
        case .x, .tiktok, .facebook, .wechatChannels:
            return ResearchSearchService.capture(#"/(?:status|video|videos|watch|feed)/([^/?#]+)"#, in: value)
        case .bilibili:
            return ResearchSearchService.capture(#"/video/(BV[0-9A-Za-z]+)"#, in: value)
        case .youtube:
            return ResearchSearchService.capture(#"[?&]v=([^&#]+)"#, in: value)
        case .xiaohongshu:
            return ResearchSearchService.capture(#"/(?:explore|search_result)/([^/?#]+)"#, in: value)
        }
    }

    nonisolated private static func metric(in text: String, labels: [String]) -> Int? {
        for label in labels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let patterns = [
                #"(?i)([0-9][0-9,]*(?:\.[0-9]+)?\s*[万亿wkmb]?)\s*(?:次\s*)?"# + escaped,
                #"(?i)"# + escaped + #"\s*([0-9][0-9,]*(?:\.[0-9]+)?\s*[万亿wkmb]?)"#
            ]
            for pattern in patterns {
                if let value = ResearchSearchService.capture(pattern, in: text) {
                    return ResearchSearchService.int(value.replacingOccurrences(of: " ", with: ""))
                }
            }
        }
        return nil
    }

    @MainActor
    private static func hasUsableDocument(in webView: WKWebView) async -> Bool {
        let value = (try? await javascriptString(
            "document.body ? String(document.body.innerText.length) : '0'", in: webView
        )) ?? "0"
        return (Int(value) ?? 0) > 100
    }

    nonisolated static func pageRequiresVerification(
        _ text: String, url: URL?, platform: ResearchPlatform
    ) -> Bool {
        let lowered = text.lowercased()
        let urlValue = url?.absoluteString.lowercased() ?? ""
        let lines = text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return urlValue.contains("login") || urlValue.contains("passport")
            || (platform == .douyin && lowered.contains("未登录"))
            || (platform == .xiaohongshu && lines.contains("登录"))
            || [
                "请登录", "登录后查看", "扫码登录", "verify you are human", "captcha",
                "安全验证", "完成验证", "验证后继续", "请完成下方验证", "访问过于频繁",
                "网络开小差了", "页面异常", "滑块验证"
            ]
                .contains(where: lowered.contains)
    }

    @MainActor
    static func extractionScript(platform: ResearchPlatform, maxItems: Int) -> String {
        let platformValue = quotedJavaScript(platform.rawValue)
        return """
        (() => {
          const platform = \(platformValue);
          const limit = \(max(1, maxItems));
          const douyinID = (u) => {
            const path = u.pathname.match(/\\/video\\/([0-9]+)/);
            return path ? path[1] : (u.searchParams.get('modal_id') || u.searchParams.get('aweme_id') || u.searchParams.get('awemeId'));
          };
          const matches = (u) => {
            const value = u.pathname + u.search;
            if (platform === 'bilibili') return /\\/video\\/BV[0-9A-Za-z]+/.test(value);
            if (platform === 'youtube') return u.pathname === '/watch' && u.searchParams.has('v');
            if (platform === 'x') return /\\/status\\/[0-9]+/.test(value);
            if (platform === 'tiktok') return /\\/video\\/[0-9]+/.test(value);
            if (platform === 'douyin') return /^[0-9]+$/.test(douyinID(u) || '');
            if (platform === 'xiaohongshu') return /\\/(explore|search_result)\\/[0-9A-Za-z]+/.test(value);
            if (platform === 'facebook') return /\\/(watch|videos)\\//.test(value) || u.pathname === '/watch';
            return /\\/(feed|finder)\\//.test(value);
          };
          const results = [];
          const seen = new Set();
          const append = (record) => {
            let url;
            try { url = new URL(record.url, location.href); } catch (_) { return; }
            if (!matches(url)) return;
            if (platform === 'douyin') url = new URL('/video/' + douyinID(url), 'https://www.douyin.com');
            if (seen.has(url.href)) return;
            const title = String(record.title || '').trim();
            const context = String(record.context || '').trim();
            if (title.length < 2 && context.length < 2) return;
            const number = (value) => value === null || value === undefined || value === '' || !Number.isFinite(Number(value)) ? null : Number(value);
            seen.add(url.href);
            results.push({
              url: url.href, title,
              coverURL: record.coverURL || null,
              author: record.author || null,
              context: context.slice(0, 1000),
              viewCount: number(record.viewCount), likeCount: number(record.likeCount),
              commentCount: number(record.commentCount), collectCount: number(record.collectCount),
              shareCount: number(record.shareCount)
            });
          };
          for (const anchor of document.querySelectorAll('a[href]')) {
            let url;
            try { url = new URL(anchor.href, location.href); } catch (_) { continue; }
            if (!matches(url)) continue;
            const card = anchor.closest('ytd-video-renderer, ytd-rich-item-renderer, ytd-compact-video-renderer, article, [data-e2e*="search"], [data-e2e*="video"], [class*="video-card"], [class*="search-result"], [class*="search-card"], li') || anchor.parentElement;
            const titled = anchor.closest('[title]') || anchor.querySelector('[title]') || (card && card.querySelector('[title]'));
            const heading = card && card.querySelector('h1, h2, h3, [role="heading"]');
            const title = (anchor.getAttribute('title') || anchor.getAttribute('aria-label') || (titled && titled.getAttribute('title')) || (heading && heading.innerText) || anchor.innerText || '').trim();
            const image = (card && card.querySelector('img')) || anchor.querySelector('img');
            const author = card && card.querySelector('ytd-channel-name a, #channel-name a, [class*="author"], [class*="owner"], [data-e2e*="user"]');
            const context = ((card && card.innerText) || anchor.innerText || '').trim();
            append({ url: url.href, title, coverURL: image ? (image.currentSrc || image.src || null) : null, author: author ? author.innerText.trim() : null, context });
            if (results.length >= limit) break;
          }
          if (platform === 'douyin' && results.length < limit) {
            const textValue = (value) => typeof value === 'string' ? value : '';
            const firstURL = (value) => {
              if (typeof value === 'string') return value;
              if (Array.isArray(value)) return value.find(item => typeof item === 'string') || null;
              return value && (firstURL(value.url_list) || firstURL(value.urlList) || firstURL(value.urls));
            };
            const visited = new WeakSet();
            let inspected = 0;
            const walk = (node) => {
              if (!node || typeof node !== 'object' || visited.has(node) || inspected > 80000 || results.length >= limit) return;
              visited.add(node);
              inspected += 1;
              const directID = textValue(node.aweme_id || node.awemeId || node.aweme_id_str || node.awemeIdStr || node.video_id || node.videoId || node.video_id_str || node.videoIdStr);
              const hasVideoEvidence = !!(node.video || node.video_info || node.videoInfo || node.statistics || node.statistics_info || node.statisticsInfo);
              const id = directID || (hasVideoEvidence ? textValue(node.group_id || node.groupId || node.group_id_str || node.groupIdStr || node.item_id || node.itemId || node.item_id_str || node.itemIdStr || node.id_str || node.idStr) : '');
              const title = textValue(node.desc || node.title || node.caption || node.content_desc || node.contentDesc || node.video_title || node.videoTitle || node.text);
              if (/^[0-9]+$/.test(id) && title.length >= 2) {
                const authorObject = node.author || node.author_info || node.user || {};
                const videoObject = node.video || node.video_info || node.videoInfo || {};
                const coverObject = videoObject.cover || videoObject.origin_cover || videoObject.dynamic_cover || node.cover;
                const stats = node.statistics || node.stats || node.statistics_info || node.statisticsInfo || {};
                append({
                  url: 'https://www.douyin.com/video/' + id,
                  title, coverURL: firstURL(coverObject),
                  author: textValue(authorObject.nickname || authorObject.name || authorObject.unique_id),
                  context: title,
                  viewCount: stats.play_count ?? stats.playCount,
                  likeCount: stats.digg_count ?? stats.diggCount,
                  commentCount: stats.comment_count ?? stats.commentCount,
                  collectCount: stats.collect_count ?? stats.collectCount,
                  shareCount: stats.share_count ?? stats.shareCount
                });
              }
              if (Array.isArray(node)) {
                for (const value of node) walk(value);
              } else {
                for (const key of Object.keys(node)) walk(node[key]);
              }
            };
            const idFromMarkup = (value) => {
              const patterns = [
                /(?:aweme_id|awemeId|aweme_id_str|awemeIdStr|modal_id|video_id|videoId)[^0-9]{0,24}([0-9]{12,})/,
                /\\/video\\/([0-9]{12,})/,
                /(?:group_id|groupId|item_id|itemId)[^0-9]{0,24}([0-9]{12,})/
              ];
              for (const pattern of patterns) {
                const match = String(value || '').match(pattern);
                if (match) return match[1];
              }
              return '';
            };
            const cardSelector = '[data-e2e*="search"], [data-e2e*="video"], [data-aweme-id], [data-item-id], [class*="search-result"], [class*="video-card"]';
            for (const card of document.querySelectorAll(cardSelector)) {
              if (results.length >= limit) break;
              const markup = Array.from(card.attributes || []).map(value => value.name + '=' + value.value).join(' ') + ' ' + card.outerHTML.slice(0, 12000);
              const id = idFromMarkup(markup);
              if (!id) continue;
              const titled = card.querySelector('[title], [aria-label], h1, h2, h3, [role="heading"]');
              const lines = String(card.innerText || '').split('\\n').map(value => value.trim()).filter(value => value.length >= 2);
              const title = String((titled && (titled.getAttribute('title') || titled.getAttribute('aria-label') || titled.innerText)) || lines[0] || '').trim();
              const image = card.querySelector('img');
              append({
                url: 'https://www.douyin.com/video/' + id,
                title, context: lines.slice(0, 8).join('\\n'),
                coverURL: image ? (image.currentSrc || image.src || null) : null
              });
            }
            [window._ROUTER_DATA, window.__INITIAL_STATE__, window.__NEXT_DATA__, window.__SSR_DATA__, window.__RENDER_DATA__].forEach(walk);
            for (const script of document.querySelectorAll('script[type="application/json"], script[id*="RENDER_DATA"], script[id*="NEXT_DATA"]')) {
              const raw = script.textContent || '';
              if (!raw || raw.length > 6000000) continue;
              const decoded = (() => { try { return decodeURIComponent(raw); } catch (_) { return ''; } })();
              for (const candidate of [raw, decoded]) {
                try { walk(JSON.parse(candidate)); break; } catch (_) {}
              }
              if (results.length >= limit) break;
            }
          }
          return JSON.stringify(results);
        })()
        """
    }

    nonisolated private static func quotedJavaScript(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

private struct RenderedSearchRecord: Codable, Sendable {
    var url: String
    var title: String
    var coverURL: String?
    var author: String?
    var context: String
    var viewCount: Int?
    var likeCount: Int?
    var commentCount: Int?
    var collectCount: Int?
    var shareCount: Int?
    var contentKind: ResearchContentKind? = nil
    var imageURLs: [String]? = nil
}
