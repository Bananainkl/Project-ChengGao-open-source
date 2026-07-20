import Foundation

struct ResearchSearchOutcome: Sendable {
    var contents: [ResearchContent]
    var warnings: [String]
}

protocol ResearchSearching: Sendable {
    func search(
        input: ResearchSearchInput,
        progress: @escaping @Sendable (ResearchPlatform, Int, Int) -> Void
    ) async throws -> ResearchSearchOutcome
}

enum ResearchSearchError: LocalizedError {
    case emptyKeyword
    case noSearchablePlatform
    case unavailablePlatforms(String)
    case allPlatformsFailed(String)
    case youtubeKeyMissing
    case requestFailed(String)
    case malformedResponse(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .emptyKeyword: "请输入要研究的关键词。"
        case .noSearchablePlatform: "请选择至少一个当前可搜索的平台。"
        case .unavailablePlatforms(let detail): "所选平台尚不能执行搜索：\(detail)"
        case .allPlatformsFailed(let detail): "本次没有取得结果。\n\(detail)"
        case .youtubeKeyMissing: "YouTube 搜索需要先在账号管理中保存 Data API Key。"
        case .requestFailed(let platform): "\(platform)搜索请求失败，请检查网络或稍后重试。"
        case .malformedResponse(let platform): "\(platform)返回了无法识别的数据。"
        case .timedOut(let platform): "\(platform)搜索超过 30 秒，已自动停止。"
        }
    }
}

actor ResearchSearchService: ResearchSearching {
    private let session: URLSession
    private let youtubeAPIKey: @Sendable () -> String?
    private let browserSearch: @Sendable (ResearchPlatform, String, Int, Int) async throws -> [ResearchContent]
    private let preferBilibiliHTML: Bool

    init(
        session: URLSession = .shared,
        youtubeAPIKey: @escaping @Sendable () -> String? = { ResearchCredentialStore.loadYouTubeAPIKey() },
        preferBilibiliHTML: Bool = true,
        browserSearch: @escaping @Sendable (ResearchPlatform, String, Int, Int) async throws -> [ResearchContent] = {
            platform, keyword, maxItems, recentDays in
            try await WebKitResearchSearchService.search(
                platform: platform, keyword: keyword, maxItems: maxItems, recentDays: recentDays
            )
        }
    ) {
        self.session = session
        self.youtubeAPIKey = youtubeAPIKey
        self.preferBilibiliHTML = preferBilibiliHTML
        self.browserSearch = browserSearch
    }

    func search(
        input: ResearchSearchInput,
        progress: @escaping @Sendable (ResearchPlatform, Int, Int) -> Void
    ) async throws -> ResearchSearchOutcome {
        let keyword = input.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { throw ResearchSearchError.emptyKeyword }
        let requested = input.platforms.sorted { $0.rawValue < $1.rawValue }
        guard !requested.isEmpty else { throw ResearchSearchError.noSearchablePlatform }

        var all: [ResearchContent] = []
        var warnings: [String] = []
        var completed = 0
        progress(requested[0], 0, requested.count)
        for start in stride(from: 0, to: requested.count, by: 2) {
            let end = min(start + 2, requested.count)
            let batch = Array(requested[start..<end])
            try await withThrowingTaskGroup(of: PlatformSearchResult.self) { group in
                for platform in batch {
                    group.addTask { [self] in
                        do {
                            let values = try await withTimeout(platform: platform) {
                                try await self.searchPlatform(
                                    platform, keyword: keyword,
                                    maxItems: input.maxItems, recentDays: input.recentDays
                                )
                            }
                            return PlatformSearchResult(platform: platform, contents: values, warning: nil)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return PlatformSearchResult(
                                platform: platform, contents: [],
                                warning: "\(platform.title)：\(error.localizedDescription)"
                            )
                        }
                    }
                }
                for try await result in group {
                    completed += 1
                    progress(result.platform, completed, requested.count)
                    all.append(contentsOf: result.contents)
                    if let warning = result.warning { warnings.append(warning) }
                }
            }
        }
        let unique = Dictionary(grouping: all, by: \.id).compactMap(\.value.first)
        let sorted = unique.sorted { lhs, rhs in
            if lhs.hotScore == rhs.hotScore { return (lhs.viewCount ?? 0) > (rhs.viewCount ?? 0) }
            return lhs.hotScore > rhs.hotScore
        }
        if sorted.isEmpty, !warnings.isEmpty {
            throw ResearchSearchError.allPlatformsFailed(warnings.joined(separator: "\n"))
        }
        return ResearchSearchOutcome(contents: sorted, warnings: warnings)
    }

    private func searchPlatform(
        _ platform: ResearchPlatform,
        keyword: String,
        maxItems: Int,
        recentDays: Int
    ) async throws -> [ResearchContent] {
        switch platform {
        case .bilibili:
            let publicValues = try await searchBilibili(
                keyword: keyword, maxItems: maxItems, recentDays: recentDays
            )
            if !publicValues.isEmpty { return publicValues }
            return try await browserSearch(platform, keyword, maxItems, recentDays)
        case .youtube:
            if let key = youtubeAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return try await searchYouTube(
                    keyword: keyword, maxItems: maxItems, recentDays: recentDays, key: key
                )
            }
            return try await browserSearch(platform, keyword, maxItems, recentDays)
        default:
            return try await browserSearch(platform, keyword, maxItems, recentDays)
        }
    }

    private func searchBilibili(keyword: String, maxItems: Int, recentDays: Int) async throws -> [ResearchContent] {
        var values: [ResearchContent] = []
        let pages = max(1, Int(ceil(Double(min(maxItems, 100)) / 20)))
        for page in 1...pages {
            try Task.checkCancellation()
            let pageValues: [ResearchContent]
            if preferBilibiliHTML {
                do {
                    pageValues = try await bilibiliHTMLPage(keyword: keyword, page: page)
                } catch {
                    pageValues = try await bilibiliAPIPage(keyword: keyword, page: page)
                }
            } else {
                pageValues = try await bilibiliAPIPage(keyword: keyword, page: page)
            }
            values.append(contentsOf: pageValues)
            if pageValues.isEmpty || values.count >= maxItems { break }
        }
        let cutoff = Date().addingTimeInterval(-Double(max(1, recentDays)) * 86_400)
        return Array(values.filter { ($0.publishedAt ?? .distantPast) >= cutoff }.prefix(maxItems))
    }

    private func bilibiliAPIPage(keyword: String, page: Int) async throws -> [ResearchContent] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")!
        components.queryItems = [
            URLQueryItem(name: "search_type", value: "video"),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: "20")
        ]
        let object = try await json(url: components.url!, platform: .bilibili)
        guard Self.int(object["code"]) == 0,
              let data = object["data"] as? [String: Any],
              let results = data["result"] as? [[String: Any]] else {
            throw ResearchSearchError.malformedResponse(ResearchPlatform.bilibili.title)
        }
        return results.compactMap { Self.bilibiliContent($0, keyword: keyword) }
    }

    private func searchYouTube(
        keyword: String, maxItems: Int, recentDays: Int, key: String
    ) async throws -> [ResearchContent] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        let after = Date().addingTimeInterval(-Double(max(1, recentDays)) * 86_400).ISO8601Format()
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "order", value: "viewCount"),
            URLQueryItem(name: "publishedAfter", value: after),
            URLQueryItem(name: "maxResults", value: String(min(maxItems, 50))),
            URLQueryItem(name: "relevanceLanguage", value: "zh-Hans"),
            URLQueryItem(name: "key", value: key)
        ]
        let searchObject = try await json(url: components.url!, platform: .youtube)
        guard let items = searchObject["items"] as? [[String: Any]] else {
            throw ResearchSearchError.malformedResponse(ResearchPlatform.youtube.title)
        }
        let seeds: [(id: String, snippet: [String: Any])] = items.compactMap { item in
            guard let idObject = item["id"] as? [String: Any],
                  let id = idObject["videoId"] as? String,
                  let snippet = item["snippet"] as? [String: Any] else { return nil }
            return (id, snippet)
        }
        guard !seeds.isEmpty else { return [] }

        var statsComponents = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        statsComponents.queryItems = [
            URLQueryItem(name: "part", value: "statistics,contentDetails"),
            URLQueryItem(name: "id", value: seeds.map(\.id).joined(separator: ",")),
            URLQueryItem(name: "key", value: key)
        ]
        let statsObject = try await json(url: statsComponents.url!, platform: .youtube)
        let statsItems = statsObject["items"] as? [[String: Any]] ?? []
        let statsByID = Dictionary(uniqueKeysWithValues: statsItems.compactMap { item -> (String, [String: Any])? in
            guard let id = item["id"] as? String else { return nil }
            return (id, item)
        })
        let now = Date()
        return seeds.compactMap { seed in
            guard let url = URL(string: "https://www.youtube.com/watch?v=\(seed.id)") else { return nil }
            let statistics = statsByID[seed.id]?["statistics"] as? [String: Any]
            let details = statsByID[seed.id]?["contentDetails"] as? [String: Any]
            let published = (seed.snippet["publishedAt"] as? String).flatMap(Self.isoDate)
            let views = Self.int(statistics?["viewCount"])
            let likes = Self.int(statistics?["likeCount"])
            let comments = Self.int(statistics?["commentCount"])
            let thumbs = seed.snippet["thumbnails"] as? [String: Any]
            let high = thumbs?["high"] as? [String: Any] ?? thumbs?["default"] as? [String: Any]
            return ResearchContent(
                id: "youtube:\(seed.id)", platform: .youtube, platformContentID: seed.id,
                keyword: keyword, title: Self.decodeHTMLEntities(seed.snippet["title"] as? String ?? "YouTube 视频"),
                description: seed.snippet["description"] as? String,
                authorName: seed.snippet["channelTitle"] as? String, authorURL: nil,
                contentURL: url, coverURL: (high?["url"] as? String).flatMap(URL.init),
                publishedAt: published, durationSeconds: (details?["duration"] as? String).flatMap(Self.isoDuration),
                viewCount: views, likeCount: likes, commentCount: comments,
                collectCount: nil, shareCount: nil,
                hotScore: ResearchContent.score(
                    views: views, likes: likes, comments: comments, collects: nil, shares: nil,
                    publishedAt: published, now: now
                ),
                collectedAt: now
            )
        }
    }

    private func json(url: URL, platform: ResearchPlatform) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = platform == .bilibili ? 8 : 20
        request.setValue(SourceExtractor.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ResearchSearchError.requestFailed(platform.title)
        }
        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode), platform == .bilibili {
            return try await curlJSON(url: url, platform: platform)
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ResearchSearchError.requestFailed(platform.title)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if platform == .bilibili { return try await curlJSON(url: url, platform: platform) }
            throw ResearchSearchError.malformedResponse(platform.title)
        }
        return object
    }

    /// Bilibili's public search edge occasionally rejects URLSession's TLS
    /// fingerprint with HTTP 412 even though the same public endpoint accepts
    /// Safari. macOS ships curl, so use it as a narrow, argument-safe fallback;
    /// no shell, cookie, password or user content other than the encoded query
    /// is involved.
    private func curlJSON(url: URL, platform: ResearchPlatform) async throws -> [String: Any] {
        let data = try await curlData(url: url, platform: platform)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResearchSearchError.requestFailed(platform.title)
        }
        return object
    }

    private func curlData(url: URL, platform: ResearchPlatform) async throws -> Data {
        do {
            return try await Self.processData(
                executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: [
                    "--location", "--compressed", "--silent", "--show-error", "--max-time", "6",
                    "--user-agent", SourceExtractor.userAgent,
                    url.absoluteString
                ]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ResearchSearchError.requestFailed(platform.title)
        }
    }

    /// Drain both pipes while the child is running. Waiting for termination
    /// before reading can deadlock when a response exceeds the pipe buffer.
    nonisolated static func processData(
        executableURL: URL,
        arguments: [String]
    ) async throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        let box = SearchProcessBox(process)

        return try await withTaskCancellationHandler {
            try process.run()
            async let outputData = output.fileHandleForReading.readToEnd() ?? Data()
            async let errorData = errors.fileHandleForReading.readToEnd() ?? Data()
            let (data, _) = try await (outputData, errorData)
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw ResearchSearchProcessError.failed(process.terminationStatus)
            }
            return data
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    private func bilibiliHTMLPage(keyword: String, page: Int) async throws -> [ResearchContent] {
        var components = URLComponents(string: "https://search.bilibili.com/all")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components.url else { throw ResearchSearchError.requestFailed("哔哩哔哩") }
        let html = String(decoding: try await curlData(url: url, platform: .bilibili), as: UTF8.self)
        return Self.bilibiliContents(fromHTML: html, keyword: keyword)
    }

    private func withTimeout<T: Sendable>(
        platform: ResearchPlatform,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                let seconds = platform == .xiaohongshu ? 60 : (platform == .douyin ? 50 : 30)
                try await Task.sleep(for: .seconds(seconds))
                throw ResearchSearchError.timedOut(platform.title)
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
    }

    nonisolated static func bilibiliContent(_ item: [String: Any], keyword: String, now: Date = .now) -> ResearchContent? {
        guard let bvid = item["bvid"] as? String,
              let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else { return nil }
        let published = int(item["pubdate"]).map { Date(timeIntervalSince1970: Double($0)) }
        let views = int(item["play"])
        let comments = int(item["video_review"])
        let collects = int(item["favorites"])
        var cover = item["pic"] as? String
        if cover?.hasPrefix("//") == true { cover = "https:" + (cover ?? "") }
        let author = item["author"] as? String
        let mid = String(describing: item["mid"] ?? "")
        return ResearchContent(
            id: "bilibili:\(bvid)", platform: .bilibili, platformContentID: bvid,
            keyword: keyword,
            title: cleanSearchTitle(item["title"] as? String ?? "B站视频"),
            description: item["description"] as? String, authorName: author,
            authorURL: URL(string: "https://space.bilibili.com/\(mid)"), contentURL: url,
            coverURL: cover.flatMap(URL.init), publishedAt: published,
            durationSeconds: (item["duration"] as? String).flatMap(parseDuration),
            viewCount: views, likeCount: nil, commentCount: comments, collectCount: collects, shareCount: nil,
            hotScore: ResearchContent.score(
                views: views, likes: nil, comments: comments, collects: collects, shares: nil,
                publishedAt: published, now: now
            ),
            collectedAt: now
        )
    }

    nonisolated static func bilibiliContents(
        fromHTML html: String, keyword: String, now: Date = .now
    ) -> [ResearchContent] {
        let segments = html.components(separatedBy: "bili-video-card__wrap")
        var seen = Set<String>()
        return segments.compactMap { segment in
            guard let bvid = capture(#"/video/(BV[0-9A-Za-z]{10})"#, in: segment),
                  seen.insert(bvid).inserted,
                  let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else { return nil }
            let title = capture(#"bili-video-card__info--tit[^>]*title=\"([^\"]+)\""#, in: segment)
                .map(cleanSearchTitle) ?? "B站视频"
            var cover = capture(#"<img\s+src=\"([^\"]+)\""#, in: segment)
            if cover?.hasPrefix("//") == true { cover = "https:" + (cover ?? "") }
            let statPattern = #"(?s)bili-video-card__stats--item[^>]*>.*?<span[^>]*>([^<]+)</span>"#
            let stats = captures(statPattern, in: segment)
            let views = int(stats.first)
            let duration = capture(#"bili-video-card__stats__duration[^>]*>([^<]+)"#, in: segment)
                .flatMap(parseDuration)
            let author = capture(#"bili-video-card__info--author\"[^>]*>([^<]+)"#, in: segment)
            var authorURLString = capture(#"bili-video-card__info--owner[^>]*href=\"([^\"]+)\""#, in: segment)
            if authorURLString?.hasPrefix("//") == true { authorURLString = "https:" + (authorURLString ?? "") }
            let dateText = capture(#"bili-video-card__info--date\"[^>]*>\s*·\s*([^<]+)"#, in: segment)
            let published = dateText.flatMap { parseBilibiliSearchDate($0, now: now) }
            return ResearchContent(
                id: "bilibili:\(bvid)", platform: .bilibili, platformContentID: bvid,
                keyword: keyword, title: title, description: nil, authorName: author,
                authorURL: authorURLString.flatMap(URL.init), contentURL: url,
                coverURL: cover.flatMap(URL.init), publishedAt: published, durationSeconds: duration,
                viewCount: views, likeCount: nil, commentCount: nil, collectCount: nil, shareCount: nil,
                hotScore: ResearchContent.score(
                    views: views, likes: nil, comments: nil, collects: nil, shares: nil,
                    publishedAt: published, now: now
                ),
                collectedAt: now
            )
        }
    }

    nonisolated static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    nonisolated static func captures(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }

    nonisolated static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String {
            let cleaned = value.replacingOccurrences(of: ",", with: "").lowercased()
            if cleaned.hasSuffix("万"), let number = Double(cleaned.dropLast()) { return Int(number * 10_000) }
            if cleaned.hasSuffix("k"), let number = Double(cleaned.dropLast()) { return Int(number * 1_000) }
            if cleaned.hasSuffix("m"), let number = Double(cleaned.dropLast()) { return Int(number * 1_000_000) }
            return Int(cleaned)
        }
        return nil
    }

    nonisolated static func parseDuration(_ value: String) -> Int? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3_600 + parts[1] * 60 + parts[2] }
        return Int(value)
    }

    nonisolated static func isoDuration(_ value: String) -> Int? {
        let pattern = #"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func group(_ index: Int) -> Int {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: value) else { return 0 }
            return Int(value[range]) ?? 0
        }
        return group(1) * 3_600 + group(2) * 60 + group(3)
    }

    nonisolated static func isoDate(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }

    nonisolated static func parseBilibiliSearchDate(_ value: String, now: Date = .now) -> Date? {
        let cleaned = value
            .replacingOccurrences(of: "·", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar(identifier: .gregorian)
        if cleaned == "昨天" {
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        }
        if let hours = capture(#"^(\d+)小时前$"#, in: cleaned).flatMap(Int.init) {
            return calendar.date(byAdding: .hour, value: -hours, to: now)
        }
        if let days = capture(#"^(\d+)天前$"#, in: cleaned).flatMap(Int.init) {
            return calendar.date(byAdding: .day, value: -days, to: now)
        }
        if cleaned.range(of: #"^\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let parts = cleaned.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            var components = calendar.dateComponents([.year], from: now)
            components.month = parts[0]
            components.day = parts[1]
            return calendar.date(from: components)
        }
        if cleaned.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: cleaned)
        }
        return nil
    }

    nonisolated static func decodeHTMLEntities(_ value: String) -> String {
        SourceExtractor.readableText(fromHTML: value)
    }

    nonisolated static func cleanSearchTitle(_ value: String) -> String {
        SourceExtractor.readableText(fromHTML: value)
            .replacingOccurrences(
                of: #"(?<=[\p{Han}])\s+(?=[\p{Han}，。！？：；])"#,
                with: "",
                options: .regularExpression
            )
    }
}

private final class SearchProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private enum ResearchSearchProcessError: Error {
    case failed(Int32)
}

private struct PlatformSearchResult: Sendable {
    var platform: ResearchPlatform
    var contents: [ResearchContent]
    var warning: String?
}
