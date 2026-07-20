import Foundation
@preconcurrency import WebKit

struct ResolvedDouyinVideo: Equatable, Sendable {
    var title: String
    var durationSeconds: Int?
    var mediaURLs: [URL]
    var userAgent: String
}

enum DouyinVideoResolver {
    @MainActor
    static func resolve(videoID: String, contentURL: URL) async throws -> ResolvedDouyinVideo {
        let session = PlatformWebSessionPool.shared.session(for: .douyin)
        let webView = session.webView
        webView.frame = CGRect(x: 0, y: 0, width: 1_280, height: 1_600)

        if webView.url?.absoluteString != contentURL.absoluteString {
            session.navigationDelegate.beginNavigation()
            var request = URLRequest(url: contentURL, timeoutInterval: 20)
            request.setValue(SourceExtractor.userAgent, forHTTPHeaderField: "User-Agent")
            webView.load(request)
            try await waitForNavigation(session: session, webView: webView)
        }

        let userAgent = (try? await javascriptString("navigator.userAgent || ''", in: webView))
            .flatMap { $0.isEmpty ? nil : $0 } ?? SourceExtractor.userAgent
        let escapedID = quotedJavaScript(videoID)
        let startDetailRequestScript = """
        (() => {
          window.__chenggaoDouyinVideoDetail = '';
          fetch('/aweme/v1/web/aweme/detail/?aweme_id=' + \(escapedID), {
              method: 'GET', credentials: 'include', cache: 'no-store',
              headers: { 'Accept': 'application/json, text/plain, */*' }
          }).then(response => response.text())
            .then(text => { window.__chenggaoDouyinVideoDetail = text || ''; })
            .catch(() => { window.__chenggaoDouyinVideoDetail = ''; });
          return 'started';
        })()
        """

        for attempt in 0..<18 {
            try Task.checkCancellation()
            if attempt == 0 || attempt == 6 || attempt == 12 {
                _ = try? await javascriptString(startDetailRequestScript, in: webView)
            }
            let detail = (try? await javascriptString(
                "window.__chenggaoDouyinVideoDetail || ''",
                in: webView
            )) ?? ""
            if let resource = parse(payload: detail, videoID: videoID, userAgent: userAgent) {
                return resource
            }
            let captures = (try? await javascriptString(
                "JSON.stringify((window.__chenggaoCapturedSearchResponses || []).map(value => value.body))",
                in: webView
            )) ?? ""
            if let resource = parseCapturedPayload(captures, videoID: videoID, userAgent: userAgent) {
                return resource
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw SourceExtractionError.platformSessionRequired(ResearchPlatform.douyin.title)
    }

    @MainActor
    private static func waitForNavigation(session: PlatformWebSession, webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try Task.checkCancellation()
            switch session.navigationDelegate.phase {
            case .finished:
                return
            case .failed(let detail):
                throw WebKitResearchSearchError.navigationFailed(ResearchPlatform.douyin.title, detail)
            case .idle, .navigating:
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        webView.stopLoading()
        throw WebKitResearchSearchError.timedOut(ResearchPlatform.douyin.title)
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

    nonisolated static func parseCapturedPayload(
        _ payload: String,
        videoID: String,
        userAgent: String
    ) -> ResolvedDouyinVideo? {
        guard let data = payload.data(using: .utf8),
              let bodies = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        for body in bodies.reversed() {
            if let resource = parse(payload: body, videoID: videoID, userAgent: userAgent) {
                return resource
            }
        }
        return nil
    }

    nonisolated static func parse(
        payload: String,
        videoID: String,
        userAgent: String
    ) -> ResolvedDouyinVideo? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let detail = findVideoDetail(in: object, videoID: videoID) else { return nil }

        let title = firstString(in: detail, keys: ["desc", "title", "caption", "content_desc"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let video = (detail["video"] as? [String: Any])
            ?? (detail["video_info"] as? [String: Any])
            ?? [:]
        let rawDuration = integer(video["duration"]) ?? integer(detail["duration"])
        let duration = rawDuration.map { $0 > 600 ? Int(ceil(Double($0) / 1_000.0)) : $0 }

        var urlStrings: [String] = []
        for key in ["play_addr", "play_addr_h264", "play_addr_265", "download_addr"] {
            collectHTTPURLs(video[key], into: &urlStrings)
        }
        if let bitRates = video["bit_rate"] as? [[String: Any]] {
            for value in bitRates { collectHTTPURLs(value["play_addr"], into: &urlStrings) }
        }
        var seen = Set<String>()
        let urls = urlStrings.compactMap { value -> URL? in
            let normalized = value.hasPrefix("http://") ? "https://" + value.dropFirst(7) : value
            guard seen.insert(normalized).inserted else { return nil }
            return URL(string: normalized)
        }
        guard !urls.isEmpty else { return nil }
        return ResolvedDouyinVideo(
            title: (title?.isEmpty == false ? title! : "抖音视频"),
            durationSeconds: duration,
            mediaURLs: urls,
            userAgent: userAgent
        )
    }

    nonisolated private static func findVideoDetail(in value: Any, videoID: String) -> [String: Any]? {
        var inspected = 0
        func walk(_ value: Any) -> [String: Any]? {
            guard inspected < 80_000 else { return nil }
            inspected += 1
            if let dictionary = value as? [String: Any] {
                let identifier = firstString(
                    in: dictionary,
                    keys: ["aweme_id", "awemeId", "group_id", "item_id", "itemId"]
                )
                if identifier == videoID,
                   dictionary["video"] is [String: Any] || dictionary["video_info"] is [String: Any] {
                    return dictionary
                }
                for child in dictionary.values {
                    if let result = walk(child) { return result }
                }
            } else if let array = value as? [Any] {
                for child in array {
                    if let result = walk(child) { return result }
                }
            }
            return nil
        }
        return walk(value)
    }

    nonisolated private static func collectHTTPURLs(_ value: Any?, into values: inout [String]) {
        if let string = value as? String,
           string.hasPrefix("https://") || string.hasPrefix("http://") {
            values.append(string)
        } else if let array = value as? [Any] {
            for child in array { collectHTTPURLs(child, into: &values) }
        } else if let dictionary = value as? [String: Any] {
            for key in ["url_list", "urlList", "urls", "url"] {
                collectHTTPURLs(dictionary[key], into: &values)
            }
        }
    }

    nonisolated private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let value = dictionary[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    nonisolated private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    nonisolated private static func quotedJavaScript(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
