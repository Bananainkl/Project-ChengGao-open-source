import Foundation
@preconcurrency import WebKit

@MainActor
final class PlatformWebSession {
    let platform: ResearchPlatform
    let webView: WKWebView
    let navigationDelegate: PlatformNavigationDelegate
    var lastUsedAt = Date()

    init(platform: ResearchPlatform) {
        self.platform = platform
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Research pages run in a hidden rendering window. They must never
        // start audible media without a user gesture.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.mediaSilencingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        if platform == .douyin || platform == .xiaohongshu {
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.searchResponseCaptureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_280, height: 1_600),
            configuration: configuration
        )
        let navigationDelegate = PlatformNavigationDelegate(platform: platform)
        webView.navigationDelegate = navigationDelegate
        self.webView = webView
        self.navigationDelegate = navigationDelegate
    }

    static let mediaSilencingScript = #"""
    (() => {
      const silence = (element) => {
        if (!(element instanceof HTMLMediaElement)) return;
        try { element.muted = true; } catch (_) {}
        try { element.defaultMuted = true; } catch (_) {}
        try { element.volume = 0; } catch (_) {}
      };
      const silenceAll = (root) => {
        if (!root || !root.querySelectorAll) return;
        root.querySelectorAll('video, audio').forEach(silence);
      };
      document.addEventListener('play', event => silence(event.target), true);
      document.addEventListener('volumechange', event => silence(event.target), true);
      const observe = () => {
        silenceAll(document);
        if (!document.documentElement) return;
        new MutationObserver(records => {
          for (const record of records) {
            for (const node of record.addedNodes) {
              if (node instanceof HTMLMediaElement) silence(node);
              silenceAll(node);
            }
          }
        }).observe(document.documentElement, { childList: true, subtree: true });
      };
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', observe, { once: true });
      } else {
        observe();
      }
    })();
    """#

    static let searchResponseCaptureScript = #"""
    (() => {
      const key = '__chenggaoCapturedSearchResponses';
      window[key] = [];
      const relevant = (value) => /(?:search|aweme|feed|video|note|discover|item)/i.test(String(value || ''));
      const priority = (value) => {
        const url = String(value || '');
        if (/(?:search|discover)/i.test(url)) return 3;
        if (/(?:aweme|note|item)/i.test(url)) return 2;
        return 1;
      };
      const record = (url, body) => {
        if (!relevant(url) || typeof body !== 'string' || body.length < 2 || body.length > 8000000) return;
        const trimmed = body.trim();
        if (trimmed[0] !== '{' && trimmed[0] !== '[') return;
        const values = window[key] || (window[key] = []);
        values.push({ url: String(url || ''), body, at: Date.now(), priority: priority(url) });
        let total = values.reduce((sum, value) => sum + String(value.body || '').length, 0);
        while (values.length > 20 || total > 16000000) {
          const lowestPriority = values.reduce(
            (lowest, value) => Math.min(lowest, Number(value.priority || 0)),
            Number.POSITIVE_INFINITY
          );
          const removalIndex = Math.max(0, values.findIndex(value => Number(value.priority || 0) === lowestPriority));
          const removed = values.splice(removalIndex, 1)[0];
          total -= removed ? String(removed.body || '').length : 0;
        }
      };

      const originalFetch = window.fetch;
      if (typeof originalFetch === 'function') {
        window.fetch = function(...args) {
          const requestURL = args[0] && args[0].url ? args[0].url : args[0];
          return originalFetch.apply(this, args).then(response => {
            try {
              if (relevant(response.url || requestURL)) {
                response.clone().text().then(text => record(response.url || requestURL, text)).catch(() => {});
              }
            } catch (_) {}
            return response;
          });
        };
      }

      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        this.__chenggaoURL = url;
        return originalOpen.call(this, method, url, ...rest);
      };
      XMLHttpRequest.prototype.send = function(...args) {
        this.addEventListener('load', function() {
          try {
            if (!relevant(this.responseURL || this.__chenggaoURL)) return;
            const body = this.responseType === 'json' ? JSON.stringify(this.response) : this.responseText;
            record(this.responseURL || this.__chenggaoURL, body);
          } catch (_) {}
        }, { once: true });
        return originalSend.apply(this, args);
      };
    })();
    """#
}

@MainActor
final class PlatformNavigationDelegate: NSObject, WKNavigationDelegate {
    enum Phase: Equatable {
        case idle
        case navigating
        case finished
        case failed(String)
    }

    let platform: ResearchPlatform
    private(set) var phase: Phase = .idle

    init(platform: ResearchPlatform) {
        self.platform = platform
    }

    func beginNavigation() {
        phase = .navigating
    }

    nonisolated static func allowsNavigation(to url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return true }
        return ["http", "https", "about"].contains(scheme)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard Self.allowsNavigation(to: navigationAction.request.url) else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        phase = .navigating
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        phase = .finished
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        phase = .failed(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        phase = .failed(error.localizedDescription)
    }
}

@MainActor
final class PlatformWebSessionPool {
    static let shared = PlatformWebSessionPool()

    private let maximumRetainedSessions = 2
    private var sessions: [ResearchPlatform: PlatformWebSession] = [:]

    func session(for platform: ResearchPlatform) -> PlatformWebSession {
        if let existing = sessions[platform] {
            existing.lastUsedAt = .now
            return existing
        }
        evictIdleSessionIfNeeded()
        let session = PlatformWebSession(platform: platform)
        sessions[platform] = session
        return session
    }

    func webView(for platform: ResearchPlatform) -> WKWebView {
        session(for: platform).webView
    }

    func discard(_ platform: ResearchPlatform) {
        guard let session = sessions.removeValue(forKey: platform) else { return }
        session.webView.stopLoading()
        session.webView.navigationDelegate = nil
    }

    private func evictIdleSessionIfNeeded() {
        guard sessions.count >= maximumRetainedSessions else { return }
        let candidate = sessions.values
            .filter { $0.webView.superview == nil && !$0.webView.isLoading }
            .min { $0.lastUsedAt < $1.lastUsedAt }
        if let candidate { discard(candidate.platform) }
    }
}
