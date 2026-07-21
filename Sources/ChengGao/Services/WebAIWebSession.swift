import AppKit
import Foundation
@preconcurrency import WebKit

enum WebAIWebError: LocalizedError, Equatable {
    case loginRequired(String)
    case editorUnavailable(String)
    case submissionFailed(String)
    case responseTimedOut(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired(let provider): "请先在“在线 AI 登录”中登录并启用\(provider)。"
        case .editorUnavailable(let provider): "\(provider) 网页已打开，但未找到可用的对话输入框；请重新登录后重试。"
        case .submissionFailed(let provider): "未能在 \(provider) 网页提交任务；页面可能已改版，请重新打开登录页后重试。"
        case .responseTimedOut(let provider): "等待 \(provider) 返回完整文档超时；请在登录页检查限额、验证码或网络状态。"
        case .invalidResponse(let provider): "\(provider) 已返回内容，但没有按澄稿 Markdown 协议输出完整结果。"
        }
    }
}

@MainActor
final class WebAIWebSession {
    let provider: WebAIProvider
    let webView: WKWebView
    private let navigationDelegate: WebAINavigationDelegate
    private var renderWindow: NSWindow?

    init(provider: WebAIProvider) {
        self.provider = provider
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_280, height: 1_600),
            configuration: configuration
        )
        let delegate = WebAINavigationDelegate(provider: provider)
        webView.navigationDelegate = delegate
        self.webView = webView
        self.navigationDelegate = delegate
    }

    func loadChatHome() {
        webView.load(URLRequest(url: provider.chatURL, timeoutInterval: 60))
    }

    func ensureBackgroundRendering() {
        guard webView.superview == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 1_000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderBack(nil)
        renderWindow = window
    }

    func releaseBackgroundRendering() {
        guard let renderWindow else { return }
        renderWindow.orderOut(nil)
        if renderWindow.contentView === webView { renderWindow.contentView = nil }
        self.renderWindow = nil
    }

    func isEditorReady() async -> Bool {
        let selectors = provider.editorSelectors
        let literal = Self.jsonLiteral(selectors)
        let script = "(() => (\(literal)).some(selector => document.querySelector(selector)))()"
        return (try? await javascriptBool(script)) == true
    }

    func isAuthenticated() async -> Bool {
        guard await isEditorReady() else { return false }
        switch provider {
        case .qwen:
            let script = #"""
            (() => !Array.from(document.querySelectorAll('button, a')).some(element => {
              const style = getComputedStyle(element);
              return style.display !== 'none' && style.visibility !== 'hidden'
                && (element.innerText || '').trim() === '登录';
            }))()
            """#
            return (try? await javascriptBool(script)) == true
        case .deepSeek:
            return webView.url?.path != "/sign_in"
        }
    }

    func complete(markdownTask: String, timeout: Duration = .seconds(480)) async throws -> String {
        ensureBackgroundRendering()
        defer { releaseBackgroundRendering() }
        loadChatHome()
        try await waitForEditor(timeout: .seconds(60))
        guard await isAuthenticated() else {
            throw WebAIWebError.loginRequired(provider.title)
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let begin = "CHENGGAO_RESULT_BEGIN_\(token)"
        let end = "CHENGGAO_RESULT_END_\(token)"
        let wrappedTask = Self.markdownEnvelope(task: markdownTask, begin: begin, end: end)
        let submitted = try await submit(wrappedTask)
        guard submitted else { throw WebAIWebError.submissionFailed(provider.title) }
        return try await waitForResponse(begin: begin, end: end, timeout: timeout)
    }

    func diagnosticSummary() async -> String {
        let script = """
        (() => JSON.stringify({
          url: location.href,
          editors: document.querySelectorAll('textarea, [contenteditable="true"]').length,
          qwenResponses: document.querySelectorAll('.qk-markdown, .qk-markdown-complete').length,
          deepSeekResponses: document.querySelectorAll('.ds-markdown').length,
          hasLoginPrompt: (document.body?.innerText || '').includes('登录')
        }))()
        """
        return (try? await javascriptString(script)) ?? "无法读取页面诊断"
    }

    nonisolated static func markdownEnvelope(task: String, begin: String, end: String) -> String {
        """
        # 澄稿在线 AI 任务

        \(task)

        ## 返回协议（必须严格执行）

        请只返回一份 Markdown 文档，不要在文档前后解释。文档必须严格以下面两行可见标记包围：

        \(begin)
        ```chenggao-result
        {"说明":"请在此代码块中输出任务要求的完整 JSON，不要省略字段"}
        ```
        \(end)
        """
    }

    nonisolated static func submissionScript(prompt: String, provider: WebAIProvider) -> String {
        let promptLiteral = jsonLiteral(prompt)
        let selectorsLiteral = jsonLiteral(provider.editorSelectors)
        let labelsLiteral = jsonLiteral(provider.sendButtonLabels)
        return """
        (() => {
          const prompt = \(promptLiteral);
          const selectors = \(selectorsLiteral);
          const labels = \(labelsLiteral);
          const editor = selectors.map(selector => document.querySelector(selector)).find(Boolean);
          if (!editor) return false;
          editor.focus();
          if (editor instanceof HTMLTextAreaElement || editor instanceof HTMLInputElement) {
            const descriptor = Object.getOwnPropertyDescriptor(
              editor instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,
              'value'
            );
            descriptor.set.call(editor, prompt);
          } else {
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(editor);
            selection.removeAllRanges();
            selection.addRange(range);
            document.execCommand('insertText', false, prompt);
          }
          editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: prompt }));
          editor.dispatchEvent(new Event('change', { bubbles: true }));
          const visible = element => {
            const style = getComputedStyle(element);
            return !element.disabled && style.display !== 'none' && style.visibility !== 'hidden';
          };
          const buttons = Array.from(document.querySelectorAll('button'));
          const send = buttons.find(button => visible(button) && labels.some(label =>
            (button.getAttribute('aria-label') || '').trim() === label
            || (button.getAttribute('title') || '').trim() === label
            || (button.innerText || '').trim() === label
          ));
          if (!send) return false;
          send.click();
          return true;
        })()
        """
    }

    nonisolated static func responseScript(selector: String, begin: String, end: String) -> String {
        let selectorLiteral = jsonLiteral(selector)
        let beginLiteral = jsonLiteral(begin)
        let endLiteral = jsonLiteral(end)
        return """
        (() => {
          const values = Array.from(document.querySelectorAll(\(selectorLiteral)))
            .map(element => (element.innerText || element.textContent || '').trim())
            .filter(Boolean);
          const marked = values.filter(text => text.includes(\(beginLiteral)) && text.includes(\(endLiteral)));
          return marked.length ? marked[marked.length - 1] : (values.length ? values[values.length - 1] : '');
        })()
        """
    }

    nonisolated static func focusEditorScript(provider: WebAIProvider) -> String {
        let selectorsLiteral = jsonLiteral(provider.editorSelectors)
        return """
        (() => {
          const editor = (\(selectorsLiteral)).map(selector => document.querySelector(selector)).find(Boolean);
          if (!editor) return false;
          editor.focus();
          if (editor instanceof HTMLTextAreaElement || editor instanceof HTMLInputElement) {
            editor.select();
          } else {
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(editor);
            selection.removeAllRanges();
            selection.addRange(range);
          }
          return true;
        })()
        """
    }

    nonisolated static func clickSendScript(provider: WebAIProvider) -> String {
        let labelsLiteral = jsonLiteral(provider.sendButtonLabels)
        return """
        (() => {
          const labels = \(labelsLiteral);
          const visible = element => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return !element.disabled && style.display !== 'none' && style.visibility !== 'hidden'
              && rect.width > 0 && rect.height > 0;
          };
          const send = Array.from(document.querySelectorAll('button')).find(button =>
            visible(button) && labels.some(label =>
              (button.getAttribute('aria-label') || '').trim() === label
              || (button.getAttribute('title') || '').trim() === label
              || (button.innerText || '').trim() === label
            )
          );
          if (!send) return false;
          send.click();
          return true;
        })()
        """
    }

    nonisolated static func sendButtonCenterScript(provider: WebAIProvider) -> String {
        let labelsLiteral = jsonLiteral(provider.sendButtonLabels)
        return """
        (() => {
          const labels = \(labelsLiteral);
          const visible = element => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return !element.disabled && style.display !== 'none' && style.visibility !== 'hidden'
              && rect.width > 0 && rect.height > 0;
          };
          const send = Array.from(document.querySelectorAll('button')).find(button =>
            visible(button) && labels.some(label =>
              (button.getAttribute('aria-label') || '').trim() === label
              || (button.getAttribute('title') || '').trim() === label
              || (button.innerText || '').trim() === label
            )
          );
          if (!send) return '';
          const rect = send.getBoundingClientRect();
          return JSON.stringify({x: rect.left + rect.width / 2,
            y: rect.top + rect.height / 2});
        })()
        """
    }

    private func waitForEditor(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if await isEditorReady() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        if webView.url?.path.contains("sign_in") == true {
            throw WebAIWebError.loginRequired(provider.title)
        }
        throw WebAIWebError.editorUnavailable(provider.title)
    }

    private func submit(_ prompt: String) async throws -> Bool {
        guard try await javascriptBool(Self.focusEditorScript(provider: provider)) else { return false }
        webView.window?.makeFirstResponder(webView)
        webView.insertText(prompt)
        try await Task.sleep(for: .milliseconds(200))
        webView.insertNewline(nil)
        let editorClearedScript = """
        (() => {
          const editor = (\(Self.jsonLiteral(provider.editorSelectors)))
            .map(selector => document.querySelector(selector)).find(Boolean);
          if (!editor) return true;
          return ((editor.value || editor.innerText || editor.textContent || '').trim().length === 0);
        })()
        """
        for _ in 0..<20 {
            try Task.checkCancellation()
            if try await javascriptBool(editorClearedScript) { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let point = try await sendButtonCenter() else { return false }
        clickWebView(at: point)
        for _ in 0..<20 {
            try Task.checkCancellation()
            if try await javascriptBool(editorClearedScript) { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func sendButtonCenter() async throws -> NSPoint? {
        let value = try await javascriptString(Self.sendButtonCenterScript(provider: provider))
        guard let data = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = object["x"], let y = object["y"] else { return nil }
        return NSPoint(x: x, y: webView.bounds.height - y)
    }

    private func clickWebView(at point: NSPoint) {
        guard let window = webView.window else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let common: (NSEvent.EventType) -> NSEvent? = { type in
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }
        if let down = common(.leftMouseDown) { webView.mouseDown(with: down) }
        if let up = common(.leftMouseUp) { webView.mouseUp(with: up) }
    }

    private func waitForResponse(begin: String, end: String, timeout: Duration) async throws -> String {
        let script = Self.responseScript(selector: provider.responseSelector, begin: begin, end: end)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var last = ""
        var stableCount = 0
        while clock.now < deadline {
            try Task.checkCancellation()
            let value = try await javascriptString(script)
            if !value.isEmpty {
                if value == last {
                    stableCount += 1
                    let hasProtocolMarkers = value.contains(begin) && value.contains(end)
                    let hasResultPayload = value.contains(#""revised""#)
                        && value.contains(#""suggestions""#)
                    if stableCount >= 2 && (hasProtocolMarkers || hasResultPayload) {
                        return value
                    }
                } else {
                    last = value
                    stableCount = 0
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        if !last.isEmpty { return last }
        throw WebAIWebError.responseTimedOut(provider.title)
    }

    private func javascriptBool(_ source: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as? Bool ?? false) }
            }
        }
    }

    private func javascriptString(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as? String ?? "") }
            }
        }
    }

    nonisolated private static func jsonLiteral<T>(_ value: T) -> String {
        let boxed = [value]
        guard JSONSerialization.isValidJSONObject(boxed),
              let data = try? JSONSerialization.data(withJSONObject: boxed),
              let literal = String(data: data, encoding: .utf8),
              literal.count >= 2 else { return "null" }
        return String(literal.dropFirst().dropLast())
    }
}

@MainActor
final class WebAINavigationDelegate: NSObject, WKNavigationDelegate {
    let provider: WebAIProvider

    init(provider: WebAIProvider) {
        self.provider = provider
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme) else {
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
}

@MainActor
final class WebAIWebSessionPool {
    static let shared = WebAIWebSessionPool()
    private var sessions: [WebAIProvider: WebAIWebSession] = [:]

    func session(for provider: WebAIProvider) -> WebAIWebSession {
        if let session = sessions[provider] { return session }
        let session = WebAIWebSession(provider: provider)
        sessions[provider] = session
        return session
    }

    func webView(for provider: WebAIProvider) -> WKWebView {
        session(for: provider).webView
    }

    func discard(_ provider: WebAIProvider) {
        guard let session = sessions.removeValue(forKey: provider) else { return }
        session.webView.stopLoading()
        session.webView.navigationDelegate = nil
    }
}
