import SwiftUI
@preconcurrency import WebKit

struct PlatformLoginSheet: View {
    let platform: ResearchPlatform
    @Bindable var store: ResearchStore
    @State private var detectedLoggedIn = false

    var body: some View {
        WorkspaceLoginSheet(title: "登录 \(platform.title)",
                            state: detectedLoggedIn ? "已检测到登录" : "等待登录",
                            authenticated: detectedLoggedIn, confirmationTitle: "完成登录") {
            store.finishLogin(platform, detected: detectedLoggedIn)
        } webContent: {
            PlatformWebLoginView(platform: platform, detectedLoggedIn: $detectedLoggedIn)
        }
    }
}

private struct PlatformWebLoginView: NSViewRepresentable {
    let platform: ResearchPlatform
    @Binding var detectedLoggedIn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(platform: platform, detectedLoggedIn: $detectedLoggedIn)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = PlatformWebSessionPool.shared.webView(for: platform)
        context.coordinator.startMonitoring()
        if let url = platform.loginURL {
            webView.load(URLRequest(url: url, timeoutInterval: 60))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.detectedLoggedIn = $detectedLoggedIn
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        let platform: ResearchPlatform
        var detectedLoggedIn: Binding<Bool>
        private var monitoringTask: Task<Void, Never>?

        init(platform: ResearchPlatform, detectedLoggedIn: Binding<Bool>) {
            self.platform = platform
            self.detectedLoggedIn = detectedLoggedIn
        }

        func startMonitoring() {
            monitoringTask?.cancel()
            monitoringTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let webView = PlatformWebSessionPool.shared.webView(for: platform)
                    detectedLoggedIn.wrappedValue = await PlatformSessionStore.hasAuthenticatedSession(
                        for: platform,
                        in: webView
                    )
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        func stopMonitoring() {
            monitoringTask?.cancel()
            monitoringTask = nil
        }
    }
}
