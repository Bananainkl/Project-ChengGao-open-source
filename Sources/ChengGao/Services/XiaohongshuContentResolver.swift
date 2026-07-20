import AppKit
import Foundation
import Vision
@preconcurrency import WebKit

struct ResolvedXiaohongshuContent: Sendable {
    var title: String
    var text: String
    var kind: ResearchContentKind
    var imageURLs: [URL]
    var videoURL: URL?
    var durationSeconds: Int?
    var userAgent: String
}

enum XiaohongshuContentResolver {
    @MainActor
    static func resolve(content: ResearchContent) async throws -> ResolvedXiaohongshuContent {
        let session = PlatformWebSessionPool.shared.session(for: .xiaohongshu)
        let webView = session.webView
        webView.frame = CGRect(x: 0, y: 0, width: 1_280, height: 1_600)
        session.navigationDelegate.beginNavigation()
        var request = URLRequest(url: content.contentURL, timeoutInterval: 45)
        request.setValue(SourceExtractor.userAgent, forHTTPHeaderField: "User-Agent")
        webView.load(request)
        try await waitForNavigation(session: session, webView: webView)

        let userAgent = (try? await javascriptString("navigator.userAgent || ''", in: webView))
            .flatMap { $0.isEmpty ? nil : $0 } ?? SourceExtractor.userAgent
        var lastPayload = ""
        for attempt in 0..<24 {
            try Task.checkCancellation()
            lastPayload = (try? await javascriptString(detailExtractionScript, in: webView)) ?? ""
            if let failure = pageFailure(from: lastPayload), attempt >= 2 {
                throw failure
            }
            if let resolved = parse(
                payload: lastPayload,
                fallback: content,
                userAgent: userAgent
            ), resolved.kind == .video ? resolved.videoURL != nil : !resolved.text.isEmpty {
                return resolved
            }
            if attempt == 5 || attempt == 12 {
                _ = try? await javascriptString("window.scrollTo(0, 600); 'scrolled'", in: webView)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        if let resolved = parse(payload: lastPayload, fallback: content, userAgent: userAgent) {
            return resolved
        }
        throw SourceExtractionError.platformSessionRequired(ResearchPlatform.xiaohongshu.title)
    }

    nonisolated static func pageFailure(from payload: String) -> SourceExtractionError? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch root["pageStatus"] as? String {
        case "unavailable":
            return .platformLinkUnavailable(ResearchPlatform.xiaohongshu.title)
        case "logged_out":
            return .platformSessionRequired(ResearchPlatform.xiaohongshu.title)
        default:
            return nil
        }
    }

    nonisolated static func parse(
        payload: String,
        fallback: ResearchContent,
        userAgent: String
    ) -> ResolvedXiaohongshuContent? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = ((root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? fallback.title
        let body = ((root["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? fallback.description ?? ""
        let rawType = (root["type"] as? String)?.lowercased() ?? ""
        let videoURL = ResearchContent.normalizedRemoteURL(
            root["videoURL"] as? String,
            platform: .xiaohongshu
        )
        let kind: ResearchContentKind = videoURL != nil || rawType.contains("video")
            ? .video
            : (fallback.contentKind ?? .imageText)
        var seen = Set<String>()
        let extractedImages = (root["imageURLs"] as? [String] ?? []).compactMap { value -> URL? in
            guard let url = ResearchContent.normalizedRemoteURL(value, platform: .xiaohongshu),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
        let fallbackImages = (fallback.imageURLs ?? fallback.coverURL.map { [$0] } ?? []).compactMap {
            ResearchContent.normalizedRemoteURL($0, platform: .xiaohongshu)
        }
        let images = extractedImages.isEmpty ? fallbackImages : extractedImages
        let duration = (root["duration"] as? NSNumber).map { value in
            let raw = value.intValue
            return raw > 600 ? Int(ceil(Double(raw) / 1_000.0)) : raw
        }
        guard kind == .video ? videoURL != nil : (!body.isEmpty || !images.isEmpty) else { return nil }
        return ResolvedXiaohongshuContent(
            title: title, text: body, kind: kind, imageURLs: images,
            videoURL: videoURL, durationSeconds: duration, userAgent: userAgent
        )
    }

    @MainActor
    private static func waitForNavigation(
        session: PlatformWebSession,
        webView: WKWebView
    ) async throws {
        let deadline = Date().addingTimeInterval(50)
        while Date() < deadline {
            try Task.checkCancellation()
            switch session.navigationDelegate.phase {
            case .finished: return
            case .failed(let detail):
                let length = (try? await javascriptString("String(document.body?.innerText?.length || 0)", in: webView)) ?? "0"
                if (Int(length) ?? 0) > 100 { return }
                throw WebKitResearchSearchError.navigationFailed(ResearchPlatform.xiaohongshu.title, detail)
            case .idle, .navigating:
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        webView.stopLoading()
        throw WebKitResearchSearchError.timedOut(ResearchPlatform.xiaohongshu.title)
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

    private static let detailExtractionScript = #"""
    (() => {
      const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
      const unwrap = value => {
        let current = value;
        for (let index = 0; index < 4 && current && typeof current === 'object'; index += 1) {
          if (current._value && typeof current._value === 'object') current = current._value;
          else if (current.value && typeof current.value === 'object') current = current.value;
          else break;
        }
        return current;
      };
      const contentID = (location.pathname.match(/\/(?:explore|discovery\/item)\/([^/?#]+)/) || [])[1] || '';
      const pageText = clean(document.body?.innerText || '');
      const unavailable = /\/404(?:\/|$)/.test(location.pathname)
        || /页面不见了|当前笔记暂时无法浏览|page isn't available right now/i.test(pageText);
      const firstText = selectors => {
        for (const selector of selectors) {
          const node = document.querySelector(selector);
          const value = clean(node?.innerText || node?.textContent);
          if (value.length > 1) return value;
        }
        return '';
      };

      const state = unwrap(window.__INITIAL_STATE__ || window.__INITIAL_SSR_STATE__ || {});
      const visited = new WeakSet();
      const findCurrentNote = (value, depth = 0) => {
        value = unwrap(value);
        if (!value || typeof value !== 'object' || depth > 12 || visited.has(value)) return null;
        visited.add(value);
        if (!Array.isArray(value)) {
          const identifier = clean(value.noteId || value.note_id || value.id);
          if (contentID && identifier === contentID) return unwrap(value.note || value.noteCard || value);
          for (const child of Object.values(value)) {
            const match = findCurrentNote(child, depth + 1);
            if (match) return match;
          }
        } else {
          for (const child of value) {
            const match = findCurrentNote(child, depth + 1);
            if (match) return match;
          }
        }
        return null;
      };
      const noteMap = unwrap(unwrap(state?.note)?.noteDetailMap);
      const mapped = contentID && noteMap ? unwrap(noteMap[contentID]) : null;
      let currentNote = unwrap(mapped?.note || mapped) || findCurrentNote(state);
      if (!currentNote && contentID) {
        for (const captured of (window.__chenggaoCapturedSearchResponses || [])) {
          if (!String(captured.body || '').includes(contentID)) continue;
          try {
            currentNote = findCurrentNote(JSON.parse(captured.body || '{}'));
            if (currentNote) break;
          } catch (_) {}
        }
      }

      let title = firstText(['#detail-title', '.note-title', '[class*="note-title"]', 'h1']);
      let text = firstText(['#detail-desc', '.note-content', '.note-text', '[class*="note-content"]', '[class*="note-text"]']);
      if (!title) title = clean(currentNote?.title || currentNote?.displayTitle || currentNote?.display_title);
      if (!text) text = clean(currentNote?.desc || currentNote?.description || currentNote?.content);
      if (text.length > 12000) text = text.slice(0, 12000);

      const detailRoot = [
        '#noteContainer', '.note-detail-mask', '.note-container', '.media-container',
        '[class*="note-detail"]', '[class*="media-container"]', '[class*="swiper-container"]'
      ].map(selector => document.querySelector(selector)).find(node => node);
      const video = detailRoot?.querySelector('video') || null;
      let videoURL = video ? (video.currentSrc || video.src || video.querySelector('source')?.src || '') : '';
      const duration = video && Number.isFinite(video.duration) ? Math.round(video.duration) : null;
      const urls = [];
      const seen = new Set();
      const detailImages = detailRoot ? detailRoot.querySelectorAll('img') : [];
      for (const image of detailImages) {
        const url = image.currentSrc || image.src || '';
        const width = image.naturalWidth || image.width || 0;
        const height = image.naturalHeight || image.height || 0;
        if (!/^https?:/.test(url) || seen.has(url) || width < 300 || height < 300) continue;
        if (!/(xhscdn|xiaohongshu)/i.test(url) || /(avatar|head|logo)/i.test(url)) continue;
        seen.add(url); urls.push(url);
      }

      const candidates = [];
      const inspect = (value, parentPath = '', depth = 0) => {
        value = unwrap(value);
        if (depth > 12 || candidates.length > 3000 || value == null) return;
        if (typeof value === 'string') {
          if (/^https?:/.test(value)) candidates.push({ path: parentPath.toLowerCase(), url: value });
          return;
        }
        if (Array.isArray(value)) {
          for (const child of value) inspect(child, parentPath, depth + 1);
          return;
        }
        if (typeof value !== 'object') return;
        for (const [key, child] of Object.entries(value)) inspect(child, `${parentPath}.${key}`, depth + 1);
      };
      try { if (currentNote) inspect(currentNote, 'note'); } catch (_) {}
      if (!/^https?:/.test(videoURL)) {
        const media = candidates.find(item =>
          /(video|play|stream|master|origin)/.test(item.path) &&
          /(sns-video|xhscdn|xiaohongshu|\.mp4(?:\?|$)|\.m3u8(?:\?|$))/i.test(item.url)
        );
        videoURL = media ? media.url : '';
      }
      if (urls.length === 0) {
        for (const item of candidates) {
          if (urls.length >= 20) break;
          if (!/(image|cover|url|list)/.test(item.path) || /(video|avatar|head|logo)/.test(item.path)) continue;
          if (!/(xhscdn|xiaohongshu)/i.test(item.url) || /(avatar|head|logo)/i.test(item.url)) continue;
          if (seen.has(item.url)) continue;
          seen.add(item.url); urls.push(item.url);
        }
      }

      const noteType = clean(currentNote?.type || currentNote?.noteType || currentNote?.note_type).toLowerCase();
      const hasCurrentContent = !!currentNote || !!title || !!text || urls.length > 0 || /^https?:/.test(videoURL);
      const hasLoginControl = Array.from(document.querySelectorAll('button, a'))
        .some(element => clean(element.innerText || element.textContent) === '登录');
      const pageStatus = unavailable ? 'unavailable' : (!hasCurrentContent && hasLoginControl ? 'logged_out' : 'ready');
      const isVideo = /^https?:/.test(videoURL) || noteType.includes('video');
      return JSON.stringify({
        title, text, type: isVideo ? 'video' : 'image_text', imageURLs: urls,
        videoURL: isVideo ? videoURL : '', duration, pageStatus, contentID,
        matchedContentID: clean(currentNote?.noteId || currentNote?.note_id || currentNote?.id)
      });
    })()
    """#
}

actor OnlineSourceVisualAnalyzer {
    private let client: OpenRouterAPIClient

    init(client: OpenRouterAPIClient = OpenRouterAPIClient()) {
        self.client = client
    }

    func analyze(images: [(URL, Data)], postText: String) async throws -> [SourceVisualReference] {
        guard !images.isEmpty else { return [] }
        let preparedSources: [(URL, Data)] = images.prefix(9).compactMap { source in
            Self.jpegData(from: source.1).map { (source.0, $0) }
        }
        guard !preparedSources.isEmpty else { return [] }
        let prepared = preparedSources.map(\.1)
        let prompt = """
        请逐张识别这些小红书原图，并为重新创作提供结构化资料。正文仅用于理解语境：\(String(postText.prefix(3000)))

        每张图都必须给出：visibleText（准确抄录可见文字，没有则空）、sceneDescription（人物/物体/动作/环境/信息关系）、composition（景别、视角、布局、光线、色彩）、redesignDirection（保留信息意图但更换主体表现、构图和视觉语言的新图方向，禁止照搬原图）。
        只输出 JSON：{"images":[{"index":1,"visibleText":"","sceneDescription":"","composition":"","redesignDirection":""}]}
        """
        let completion: OpenRouterCompletion
        do {
            completion = try await client.completeWithImages(prompt: prompt, jpegImages: prepared)
        } catch let error as OpenRouterError where Self.isUnsupportedVisionRequest(error) {
            // Text-only compatible endpoints (including the current DeepSeek
            // models) reject OpenAI's image_url message part. Keep the link
            // workflow usable by extracting visible text and broad subjects
            // with Apple's on-device Vision framework, then let the configured
            // text model rewrite that evidence and design the new prompts.
            return await Self.localReferences(from: preparedSources)
        }
        let cleaned = EmbeddedModelRuntime.assistantPayload(from: completion.content)
        guard let root = EmbeddedModelRuntime.parseJSONObject(from: cleaned),
              let values = root["images"] as? [[String: Any]] else {
            throw OpenRouterError.invalidResponse
        }
        let source = preparedSources
        return values.compactMap { value in
            let rawIndex = (value["index"] as? NSNumber)?.intValue ?? 0
            guard rawIndex >= 1, rawIndex <= source.count else { return nil }
            return SourceVisualReference(
                index: rawIndex,
                imageURL: source[rawIndex - 1].0,
                recognizedText: value["visibleText"] as? String ?? "",
                sceneDescription: value["sceneDescription"] as? String ?? "",
                composition: value["composition"] as? String ?? "",
                redesignDirection: value["redesignDirection"] as? String ?? ""
            )
        }.sorted { $0.index < $1.index }
    }

    nonisolated private static func jpegData(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let maximum: CGFloat = 1_280
        let ratio = min(1, maximum / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        let target = NSImage(size: size)
        target.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }

    nonisolated static func isUnsupportedVisionRequest(_ error: OpenRouterError) -> Bool {
        guard case .requestFailed(let status, let message) = error,
              status == 400 || status == 422 else { return false }
        let detail = message.lowercased()
        return detail.contains("image_url")
            || detail.contains("image url")
            || detail.contains("expected `text`")
            || detail.contains("multimodal")
            || detail.contains("vision")
    }

    nonisolated static func localReferences(
        from images: [(URL, Data)]
    ) async -> [SourceVisualReference] {
        await Task.detached(priority: .userInitiated) {
            images.enumerated().compactMap { offset, source in
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
                let classification = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(data: source.1)
                try? handler.perform([request, classification])

                let visibleText = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                let subjects = (classification.results ?? [])
                    .filter { $0.confidence >= 0.12 }
                    .prefix(6)
                    .map(\.identifier)
                let size = NSImage(data: source.1)?.size ?? .zero
                let orientation: String
                if size.width > size.height * 1.15 { orientation = "横向画面" }
                else if size.height > size.width * 1.15 { orientation = "竖向画面" }
                else { orientation = "近方形画面" }
                let subjectText = subjects.isEmpty ? "未能高置信识别主体" : subjects.joined(separator: "、")
                return SourceVisualReference(
                    index: offset + 1,
                    imageURL: source.0,
                    recognizedText: visibleText,
                    sceneDescription: "本机 Vision 识别的画面主体：\(subjectText)",
                    composition: "\(orientation)，原图尺寸 \(Int(size.width))×\(Int(size.height))",
                    redesignDirection: "保留可见文字的信息意图，结合正文重新设计主体、构图和视觉语言，不复制原图"
                )
            }
        }.value
    }
}
