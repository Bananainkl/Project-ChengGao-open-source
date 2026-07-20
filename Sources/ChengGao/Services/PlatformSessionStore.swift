import Foundation
@preconcurrency import WebKit

enum PlatformSessionStore {
    @MainActor
    static func hasAuthenticatedCookies(for platform: ResearchPlatform) async -> Bool {
        let cookies = await allCookies()
        return hasAuthenticatedCookies(in: cookies, for: platform)
    }

    @MainActor
    static func hasAuthenticatedSession(
        for platform: ResearchPlatform,
        in webView: WKWebView
    ) async -> Bool {
        guard await hasAuthenticatedCookies(for: platform) else { return false }
        guard platform == .xiaohongshu else { return true }
        let script = #"""
        (() => {
          if (document.readyState !== 'complete' || !document.body || document.body.innerText.length < 100) {
            return 'loading';
          }
          const visible = (element) => {
            if (!element) return false;
            const style = getComputedStyle(element);
            return style.display !== 'none' && style.visibility !== 'hidden';
          };
          const hasLoginControl = Array.from(document.querySelectorAll('button, a'))
            .some(element => visible(element) && (element.innerText || '').trim() === '登录');
          return hasLoginControl ? 'logged_out' : 'logged_in';
        })()
        """#
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: error == nil && (value as? String) == "logged_in")
            }
        }
    }

    nonisolated static func hasAuthenticatedCookies(
        in cookies: [HTTPCookie], for platform: ResearchPlatform
    ) -> Bool {
        cookies.contains { cookie in
            platform.cookieIndicators.contains(cookie.name)
                && platform.cookieDomains.contains(where: { domainMatches(cookie.domain, expected: $0) })
                && !cookie.value.isEmpty
        }
    }

    @MainActor
    static func deleteCookies(for platform: ResearchPlatform) async {
        PlatformWebSessionPool.shared.discard(platform)
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await allCookies()
        for cookie in cookies where platform.cookieDomains.contains(where: { domainMatches(cookie.domain, expected: $0) }) {
            await withCheckedContinuation { continuation in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }

    @MainActor
    private static func allCookies() async -> [HTTPCookie] {
        let store = WKWebsiteDataStore.default().httpCookieStore
        return await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func domainMatches(_ cookieDomain: String, expected: String) -> Bool {
        let actual = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let wanted = expected.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return actual == wanted || actual.hasSuffix(".\(wanted)")
    }
}
