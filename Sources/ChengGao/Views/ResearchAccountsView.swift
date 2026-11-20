import SwiftUI

struct ResearchAccountsView: View {
    @Bindable var store: ResearchStore
    let presentLogin: (ResearchPlatform) -> Void
    @State private var accountToRemove: ResearchPlatform?
    @State private var confirmsKeyDeletion = false

    var body: some View {
        Form {
            Section("平台连接") {
                ForEach(ResearchPlatform.allCases) { platform in
                    platformRow(platform)
                }
            }
            Section("YouTube Data API") { youtubeAPISection }
        }
        .formStyle(.grouped)
        .confirmationDialog("删除 YouTube API Key？", isPresented: $confirmsKeyDeletion) {
            Button("删除 Key", role: .destructive, action: store.deleteYouTubeAPIKey)
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("移除平台账号？", isPresented: Binding(
            get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }
        ), presenting: accountToRemove) { platform in
            Button("移除\(platform.title)账号", role: .destructive) { store.removeAccount(platform) }
            Button("取消", role: .cancel) {}
        }
    }

    private var youtubeAPISection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("API Key") {
                SecureField("YouTube API Key", text: $store.youtubeAPIKeyDraft, prompt: Text("输入 Google Data API Key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("YouTube API Key")
            }
            Text("优先使用官方接口。未配置 Key 时使用 YouTube 网页登录会话，凭证只保存在本机。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Label(store.youtubeKeyStatus, systemImage: "key").font(.callout)
                Spacer()
                if store.hasYouTubeAPIKey {
                    Button("删除 Key…", role: .destructive) { confirmsKeyDeletion = true }
                }
                Button("保存", action: store.saveYouTubeAPIKey)
                    .disabled(store.youtubeAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    private func platformRow(_ platform: ResearchPlatform) -> some View {
        let account = store.account(for: platform)
        return AccountRow(title: platform.title, systemImage: platform.systemImage,
                          description: accountStatus(platform, account: account)) {
            HStack {
                if platform != .wechatChannels {
                    Button(account == nil ? "登录" : "重新登录") { presentLogin(platform) }
                        .disabled(store.loginPlatform != nil)
                        .accessibilityLabel("登录\(platform.title)")
                }
                if account != nil {
                    Button("移除…", role: .destructive) { accountToRemove = platform }
                        .accessibilityLabel("移除\(platform.title)账号")
                }
            }
        }
    }

    private func accountStatus(_ platform: ResearchPlatform, account: ResearchAccount?) -> String {
        if platform == .wechatChannels { return "在新建文稿中粘贴视频号分享链接" }
        if let account { return account.status.label }
        return platform == .bilibili ? "公共搜索无需登录" : "未登录 · \(platform.searchAvailability.label)"
    }
}
