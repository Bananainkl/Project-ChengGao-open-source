import Foundation

enum ResearchPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case bilibili
    case youtube
    case x
    case tiktok
    case douyin
    case xiaohongshu
    case facebook
    case wechatChannels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bilibili: "哔哩哔哩"
        case .youtube: "YouTube"
        case .x: "X"
        case .tiktok: "TikTok"
        case .douyin: "抖音"
        case .xiaohongshu: "小红书"
        case .facebook: "Facebook"
        case .wechatChannels: "视频号"
        }
    }

    var systemImage: String {
        switch self {
        case .bilibili: "play.tv"
        case .youtube: "play.rectangle.fill"
        case .x: "at"
        case .tiktok, .douyin: "music.note"
        case .xiaohongshu: "book.pages"
        case .facebook: "person.2"
        case .wechatChannels: "bubble.left.and.bubble.right"
        }
    }

    var searchAvailability: ResearchPlatformAvailability {
        switch self {
        case .bilibili: .ready
        case .youtube: .requiresAPIKey
        case .x: .requiresDeveloperAccess
        case .douyin: .requiresSpecialPermission
        case .tiktok: .researchOnly
        case .xiaohongshu, .facebook: .experimental
        case .wechatChannels: .manualLinkOnly
        }
    }

    var requiresAuthenticatedWebSearch: Bool {
        self == .douyin
    }

    func searchURLs(keyword: String) -> [URL] {
        if self == .douyin {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
            return ["general", "video"].compactMap { type in
                var components = URLComponents(string: "https://www.douyin.com/search/\(encoded)")
                components?.queryItems = [URLQueryItem(name: "type", value: type)]
                return components?.url
            }
        }
        var components: URLComponents?
        switch self {
        case .bilibili:
            components = URLComponents(string: "https://search.bilibili.com/video")
            components?.queryItems = [URLQueryItem(name: "keyword", value: keyword)]
        case .youtube:
            components = URLComponents(string: "https://www.youtube.com/results")
            components?.queryItems = [URLQueryItem(name: "search_query", value: keyword)]
        case .x:
            components = URLComponents(string: "https://x.com/search")
            components?.queryItems = [
                URLQueryItem(name: "q", value: keyword),
                URLQueryItem(name: "src", value: "typed_query"),
                URLQueryItem(name: "f", value: "top")
            ]
        case .tiktok:
            components = URLComponents(string: "https://www.tiktok.com/search/video")
            components?.queryItems = [URLQueryItem(name: "q", value: keyword)]
        case .douyin:
            return []
        case .xiaohongshu:
            components = URLComponents(string: "https://www.xiaohongshu.com/search_result/")
            components?.queryItems = [
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "source", value: "web_search_result_notes")
            ]
        case .facebook:
            components = URLComponents(string: "https://www.facebook.com/search/videos")
            components?.queryItems = [URLQueryItem(name: "q", value: keyword)]
        case .wechatChannels:
            return []
        }
        return components?.url.map { [$0] } ?? []
    }

    func searchURL(keyword: String) -> URL? {
        searchURLs(keyword: keyword).first
    }

    var loginURL: URL? {
        switch self {
        case .bilibili: URL(string: "https://passport.bilibili.com/login")
        case .youtube: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube")
        case .x: URL(string: "https://x.com/i/flow/login")
        case .tiktok: URL(string: "https://www.tiktok.com/login")
        case .douyin: URL(string: "https://www.douyin.com/user/self")
        case .xiaohongshu: URL(string: "https://www.xiaohongshu.com/explore")
        case .facebook: URL(string: "https://www.facebook.com/login")
        case .wechatChannels: nil
        }
    }

    var cookieIndicators: Set<String> {
        switch self {
        case .bilibili: ["SESSDATA", "DedeUserID"]
        case .youtube: ["SAPISID", "__Secure-3PAPISID", "SID"]
        case .x: ["auth_token"]
        case .tiktok: ["sessionid", "sessionid_ss"]
        case .douyin: ["sessionid", "sessionid_ss", "sid_guard"]
        case .xiaohongshu: ["web_session"]
        case .facebook: ["c_user"]
        case .wechatChannels: ["wxuin", "uin"]
        }
    }

    var cookieDomains: [String] {
        switch self {
        case .bilibili: ["bilibili.com"]
        case .youtube: ["youtube.com", "google.com"]
        case .x: ["x.com", "twitter.com"]
        case .tiktok: ["tiktok.com"]
        case .douyin: ["douyin.com"]
        case .xiaohongshu: ["xiaohongshu.com"]
        case .facebook: ["facebook.com"]
        case .wechatChannels: ["weixin.qq.com"]
        }
    }
}

enum ResearchPlatformAvailability: String, Codable, Sendable {
    case ready
    case requiresAPIKey
    case requiresDeveloperAccess
    case requiresSpecialPermission
    case researchOnly
    case experimental
    case manualLinkOnly

    var label: String {
        switch self {
        case .ready: "可搜索"
        case .requiresAPIKey: "API Key 或网页登录搜索"
        case .requiresDeveloperAccess: "登录后网页搜索"
        case .requiresSpecialPermission: "登录后网页搜索"
        case .researchOnly: "登录后网页搜索"
        case .experimental: "网页登录搜索（实验）"
        case .manualLinkOnly: "暂不支持关键词搜索 · 可粘贴分享链接"
        }
    }

    var canSearch: Bool { self != .manualLinkOnly }
}

enum ResearchPlatformSearchState: Equatable, Sendable {
    case ready(String)
    case loginRequired
    case verificationRequired
    case manualLinkOnly

    var label: String {
        switch self {
        case .ready(let source): source
        case .loginRequired: "需登录"
        case .verificationRequired: "需重新验证"
        case .manualLinkOnly: "仅支持链接"
        }
    }

    var canSelect: Bool { self != .manualLinkOnly }
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum ResearchLoginStatus: String, Codable, Sendable {
    case notLoggedIn
    case loggedIn
    case verificationRequired
    case unknown

    var label: String {
        switch self {
        case .notLoggedIn: "未登录"
        case .loggedIn: "已登录"
        case .verificationRequired: "需要验证"
        case .unknown: "待检查"
        }
    }
}

struct ResearchAccount: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var platform: ResearchPlatform
    var displayName: String
    var status: ResearchLoginStatus
    var lastCheckedAt: Date
    var createdAt: Date
    var updatedAt: Date
}

struct ResearchSearchInput: Equatable, Sendable {
    var keyword: String
    var platforms: Set<ResearchPlatform>
    var maxItems: Int
    var recentDays: Int
}

enum ResearchContentKind: String, Codable, Sendable {
    case video
    case imageText = "image_text"

    var label: String {
        switch self {
        case .video: "视频"
        case .imageText: "图文"
        }
    }
}

struct ResearchContent: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var platform: ResearchPlatform
    var platformContentID: String?
    var keyword: String
    var title: String
    var description: String?
    var authorName: String?
    var authorURL: URL?
    var contentURL: URL
    var coverURL: URL?
    var publishedAt: Date?
    var durationSeconds: Int?
    var viewCount: Int?
    var likeCount: Int?
    var commentCount: Int?
    var collectCount: Int?
    var shareCount: Int?
    var hotScore: Double
    var collectedAt: Date
    var contentKind: ResearchContentKind? = nil
    var imageURLs: [URL]? = nil

    var resolvedContentKind: ResearchContentKind {
        contentKind ?? .video
    }

    /// Xiaohongshu still returns plain-HTTP CDN links in otherwise secure pages.
    /// App Transport Security rejects those links, so normalize them before they
    /// reach AsyncImage, OCR downloads, or persistent storage.
    nonisolated static func normalizedRemoteURL(_ url: URL?, platform: ResearchPlatform) -> URL? {
        guard let url else { return nil }
        guard platform == .xiaohongshu, url.scheme?.lowercased() == "http" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    nonisolated static func normalizedRemoteURL(_ value: String?, platform: ResearchPlatform) -> URL? {
        normalizedRemoteURL(value.flatMap(URL.init), platform: platform)
    }

    var engagement: Double {
        Self.engagement(
            views: viewCount,
            likes: likeCount,
            comments: commentCount,
            collects: collectCount,
            shares: shareCount
        )
    }

    var metricConfidence: ResearchMetricConfidence {
        Self.metricConfidence(
            views: viewCount, likes: likeCount, comments: commentCount,
            collects: collectCount, shares: shareCount, publishedAt: publishedAt
        )
    }

    static func trustedMetric(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func score(
        views: Int?, likes: Int?, comments: Int?, collects: Int?, shares: Int?,
        publishedAt: Date?, now: Date = .now
    ) -> Double {
        let engagement = engagement(
            views: views, likes: likes, comments: comments, collects: collects, shares: shares
        )
        let freshness: Double
        if let publishedAt {
            let age = max(0, now.timeIntervalSince(publishedAt) / 86_400)
            freshness = exp(-age / 30)
        } else {
            // Unknown publication time is neutral, not falsely treated as brand new.
            freshness = 0.5
        }
        let knownMetrics = [views, likes, comments, collects, shares]
            .compactMap(trustedMetric)
            .count
        let coverage = 0.6 + 0.4 * (Double(knownMetrics) / 5)
        return engagement * (0.7 + 0.3 * freshness) * coverage
    }

    private static func engagement(
        views: Int?, likes: Int?, comments: Int?, collects: Int?, shares: Int?
    ) -> Double {
        log10(1 + Double(trustedMetric(views) ?? 0))
            + log10(1 + Double(trustedMetric(likes) ?? 0)) * 2
            + log10(1 + Double(trustedMetric(comments) ?? 0)) * 3
            + log10(1 + Double(trustedMetric(collects) ?? 0)) * 3
            + log10(1 + Double(trustedMetric(shares) ?? 0)) * 4
    }

    private static func metricConfidence(
        views: Int?, likes: Int?, comments: Int?, collects: Int?, shares: Int?, publishedAt: Date?
    ) -> ResearchMetricConfidence {
        let count = [views, likes, comments, collects, shares].compactMap(trustedMetric).count
        if count >= 4, publishedAt != nil { return .high }
        if count >= 2 { return .medium }
        return .low
    }
}

enum ResearchMetricConfidence: String, Codable, Sendable {
    case high = "高"
    case medium = "中"
    case low = "低"

    var explanation: String {
        switch self {
        case .high: "主要互动指标和发布时间较完整"
        case .medium: "仅取得部分公开指标"
        case .low: "公开指标不足，排名仅供初筛"
        }
    }
}

enum ResearchTaskStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled
}

struct ResearchTaskRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var keyword: String
    var platforms: [ResearchPlatform]
    var status: ResearchTaskStatus
    var progress: Double
    var errorMessage: String?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
}
