import SwiftUI
@preconcurrency import WebKit

struct WebAILoginView: View {
    @Bindable var store: RewriteStore

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.headerContentSpacing) {
            WorkspacePageHeader(title: "在线 AI 登录")
            VStack(alignment: .leading, spacing: 10) {
                Label("使用本人的网页账号改写", systemImage: "lock.shield")
                    .font(.headline)
                Text("登录由你在内置网页中完成。澄稿不读取密码，不导出 Cookie；处理时会把完整标题与正文组织为 Markdown 任务，在当前会话内提交并读回 Markdown 结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .workspaceGlassPanel(cornerRadius: 18, elevated: true)

            VStack(spacing: 0) {
                ForEach(WebAIProvider.allCases) { provider in
                    providerRow(provider)
                    if provider != WebAIProvider.allCases.last { Divider() }
                }
            }
            .workspaceGlassPanel(cornerRadius: 18, elevated: true)

            HStack(spacing: 12) {
                Label(store.webAIStatus, systemImage: store.webAIEnabled ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(store.webAIEnabled ? .green : .secondary)
                Spacer()
                if store.webAIEnabled {
                    Button("停用网页 AI", action: store.disableWebAI)
                }
            }
            .font(.caption)
            .padding(16)
            .workspaceGlassPanel(cornerRadius: 16)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
        .padding(.top, WorkspaceLayout.detailTopPadding)
        .padding(.bottom, WorkspaceLayout.detailBottomPadding)
        .frame(maxWidth: 940, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $store.webAILoginProvider) { provider in
            WebAILoginSheet(provider: provider, store: store)
        }
    }

    private func providerRow(_ provider: WebAIProvider) -> some View {
        HStack(spacing: 14) {
            Image(systemName: provider.systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(
                    store.webAIProvider == provider && store.webAIEnabled
                        ? Color.accentColor
                        : Color.secondary
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.title).font(.headline)
                Text(provider == .qwen ? "qianwen.com 网页会话" : "chat.deepseek.com 网页会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.webAIProvider == provider && store.webAIEnabled {
                Text("当前改写渠道")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button(store.webAIProvider == provider ? "打开／重新登录" : "选择并登录") {
                store.beginWebAILogin(provider)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct WebAILoginSheet: View {
    let provider: WebAIProvider
    @Bindable var store: RewriteStore
    @Environment(\.dismiss) private var dismiss
    @State private var authenticated = false
    @State private var ready = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录 \(provider.title)").font(.headline)
                    Text("请自行输入密码、扫码或完成验证；澄稿不读取这些内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    authenticated ? "已检测登录" : (ready ? "请完成账号登录" : "等待登录"),
                    systemImage: authenticated ? "checkmark.circle.fill" : "clock"
                )
                .foregroundStyle(authenticated ? .green : .secondary)
            }
            .padding(16)
            Divider()
            WebAIWebView(provider: provider, authenticated: $authenticated, ready: $ready)
            Divider()
            HStack {
                Text("登录后保持此网页会话，改写时可切回本页查看处理状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("完成并用于改写") {
                    store.finishWebAILogin(provider, authenticated: authenticated, ready: ready)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!authenticated)
            }
            .padding(14)
        }
        .frame(minWidth: 940, minHeight: 680)
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
