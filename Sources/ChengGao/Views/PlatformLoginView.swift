import SwiftUI
@preconcurrency import WebKit

struct PlatformLoginSheet: View {
    let platform: ResearchPlatform
    @Bindable var store: ResearchStore
    @Environment(\.dismiss) private var dismiss
    @State private var detectedLoggedIn = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录 \(platform.title)")
                        .font(.headline)
                    Text("请自行输入密码、扫码或完成人机验证；澄稿不会读取这些内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(detectedLoggedIn ? "检测到登录状态" : "等待登录", systemImage: detectedLoggedIn ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(detectedLoggedIn ? .green : .secondary)
            }
            .padding(16)

            Divider()

            PlatformWebLoginView(platform: platform, detectedLoggedIn: $detectedLoggedIn)

            Divider()

            HStack {
                Text("遇到验证码或异常访问提示时，请在此窗口手动处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("我已完成登录") {
                    store.finishLogin(platform, detected: detectedLoggedIn)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!detectedLoggedIn)
            }
            .padding(14)
        }
        .frame(minWidth: 860, minHeight: 640)
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
