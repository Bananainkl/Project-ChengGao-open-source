import SwiftUI

struct ResearchAccountsView: View {
    @Bindable var store: ResearchStore

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.headerContentSpacing) {
            WorkspacePageHeader(title: "平台账号")
            youtubeAPISection
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ResearchPlatform.allCases) { platform in
                        platformRow(platform)
                        if platform != ResearchPlatform.allCases.last { Divider() }
                    }
                }
                .workspaceGlassPanel(cornerRadius: 18, elevated: true)
            }
            .scrollIndicators(.visible)
        }
        .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
        .padding(.top, WorkspaceLayout.detailTopPadding)
        .padding(.bottom, WorkspaceLayout.detailBottomPadding)
        .frame(maxWidth: 940, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $store.loginPlatform) { platform in
            PlatformLoginSheet(platform: platform, store: store)
        }
    }

    private var youtubeAPISection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("YouTube Data API", systemImage: "key.horizontal")
                    .font(.headline)
                Spacer()
                Text(store.youtubeKeyStatus)
                    .font(.caption)
                    .foregroundStyle(store.hasYouTubeAPIKey ? .green : .secondary)
            }
            Text("配置 Google Data API Key 时优先使用官方接口；没有 Key 时会复用下方 YouTube 网页登录会话进行搜索。Key 只保存在权限为 0600 的本地私有凭证文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("AIza…", text: $store.youtubeAPIKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("保存", action: store.saveYouTubeAPIKey)
                if store.hasYouTubeAPIKey {
                    Button("删除", role: .destructive, action: store.deleteYouTubeAPIKey)
                }
            }
        }
        .padding(18)
        .workspaceGlassPanel(cornerRadius: 18, elevated: true)
    }

    private func platformRow(_ platform: ResearchPlatform) -> some View {
        let account = store.account(for: platform)
        return HStack(spacing: 14) {
            Image(systemName: platform.systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(platform.title).font(.headline)
                Text(platform.searchAvailability.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(accountStatus(platform, account: account))
                .font(.caption)
                .foregroundStyle(account?.status == .loggedIn ? .green : .secondary)
            if platform != .wechatChannels {
                Button(account == nil ? "登录" : "重新登录") { store.beginLogin(platform) }
            }
            if account != nil {
                Button("移除", role: .destructive) { store.removeAccount(platform) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func accountStatus(_ platform: ResearchPlatform, account: ResearchAccount?) -> String {
        if platform == .wechatChannels { return "请在新建文稿粘贴视频号分享链接" }
        if let account { return account.status.label }
        return platform == .bilibili ? "公共搜索无需登录" : "未登录"
    }
}
