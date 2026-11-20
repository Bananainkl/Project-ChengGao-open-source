import SwiftUI
@preconcurrency import WebKit

struct WebAILoginView: View {
    @Bindable var store: RewriteStore
    let presentLogin: (WebAIProvider) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(WebAIProvider.allCases) { provider in
                    HStack(spacing: 12) {
                        Image(systemName: provider.systemImage).foregroundStyle(.tint).frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.title).font(.headline)
                            Text(provider == .qwen ? "qianwen.com" : "chat.deepseek.com")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.webAIProvider == provider && store.webAIEnabled {
                            Label("使用中", systemImage: "checkmark.circle").font(.callout)
                        }
                        Button("打开登录页") { presentLogin(provider) }
                            .disabled(store.webAILoginProvider != nil || store.isProcessing)
                            .accessibilityLabel("登录 \(provider.title)")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("网页改写服务")
            } footer: {
                Text("使用自己的网页账号登录。选择网页改写后，完整标题和正文将以 Markdown 发送到当前服务。")
            }
            Section("当前会话") {
                LabeledContent("状态") { Text(store.webAIStatus) }
                if store.webAIEnabled {
                    Button("停用网页 AI，切回 API", action: store.disableWebAI)
                        .disabled(store.isProcessing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct WebAILoginSheet: View {
    let provider: WebAIProvider
    @Bindable var store: RewriteStore
    @State private var authenticated = false
    @State private var ready = false

    var body: some View {
        WorkspaceLoginSheet(title: "登录 \(provider.title)",
                            state: authenticated ? "已检测到登录" : (ready ? "请完成账号登录" : "等待登录"),
                            authenticated: authenticated, confirmationTitle: "完成并用于改写") {
            store.finishWebAILogin(provider, authenticated: authenticated, ready: ready)
        } webContent: {
            WebAIWebView(provider: provider, authenticated: $authenticated, ready: $ready)
        }
    }
}

private struct WebAIWebView: NSViewRepresentable {
    let provider: WebAIProvider
    @Binding var authenticated: Bool
    @Binding var ready: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(provider: provider, authenticated: $authenticated, ready: $ready)
    }

    func makeNSView(context: Context) -> WKWebView {
        let session = WebAIWebSessionPool.shared.session(for: provider)
        context.coordinator.startMonitoring()
        session.loadChatHome()
        return session.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.authenticated = $authenticated
        context.coordinator.ready = $ready
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        let provider: WebAIProvider
        var authenticated: Binding<Bool>
        var ready: Binding<Bool>
        private var task: Task<Void, Never>?

        init(provider: WebAIProvider, authenticated: Binding<Bool>, ready: Binding<Bool>) {
            self.provider = provider
            self.authenticated = authenticated
            self.ready = ready
        }

        func startMonitoring() {
            task?.cancel()
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let session = WebAIWebSessionPool.shared.session(for: provider)
                    ready.wrappedValue = await session.isEditorReady()
                    authenticated.wrappedValue = await session.isAuthenticated()
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
        }

        func stopMonitoring() {
            task?.cancel()
            task = nil
        }
    }
}
