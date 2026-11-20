import SwiftUI

enum SettingsPage: String {
    static let storageKey = "settings.page"
    case general, rewrite, images
}

struct SettingsView: View {
    @Bindable var store: RewriteStore
    @AppStorage(SettingsPage.storageKey) private var page = SettingsPage.general
    @AppStorage(ManuscriptTextSize.storageKey) private var textSize = ManuscriptTextSize.standard
    @State private var deleteKeyFor: SettingsPage?

    var body: some View {
        TabView(selection: $page) {
            Tab("通用", systemImage: "gearshape", value: SettingsPage.general) { generalSettings }
            Tab("改写 API", systemImage: "text.and.sparkles", value: SettingsPage.rewrite) { onlineAISettings }
            Tab("图片 API", systemImage: "photo", value: SettingsPage.images) { imageSettings }
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 440, idealHeight: 540)
        .confirmationDialog("删除已保存的 Key？", isPresented: Binding(
            get: { deleteKeyFor != nil }, set: { if !$0 { deleteKeyFor = nil } }
        ), presenting: deleteKeyFor) { target in
            Button("删除 Key", role: .destructive) {
                if target == .rewrite { store.deleteOnlineAIKey() } else { store.deleteOnlineImageAPIKey() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var generalSettings: some View {
        Form {
            Section("文稿显示") {
                Picker("文稿字号", selection: $textSize) {
                    ForEach(ManuscriptTextSize.allCases) { size in Text(size.label).tag(size) }
                }
                Text("写稿、校阅与历史文稿使用相同字号。")
                    .font(textSize.font)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("联网核验专有名词", isOn: $store.onlineTerminologyCheck)
            } header: {
                Text("处理")
            } footer: {
                Text("核验时只向中文维基百科发送候选专有名词。")
            }
            Section("隐私") {
                Label(store.privacySummary, systemImage: "lock.shield")
                Text(store.privacyDisclosure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("视频转写") {
                LabeledContent("本机模型", value: "Whisper Small Q5_1")
                Text("没有平台字幕时使用本机识别音轨，转写全文交给选定的改写服务。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var onlineAISettings: some View {
        Form {
            Section("服务连接") {
                Picker("提供商", selection: $store.onlineProvider) {
                    ForEach(OnlineAIProvider.allCases) { provider in Text(provider.displayName).tag(provider) }
                }
                .accessibilityLabel("改写服务提供商")
                LabeledContent("API 地址") {
                    TextField("改写 API 地址", text: $store.onlineEndpointDraft, prompt: Text("可填写服务根地址"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("改写 API 地址")
                }
                Text(store.resolvedOnlineEndpointDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.onlineProvider != .custom || store.onlineProvider.documentationURL != nil {
                    HStack {
                        if store.onlineProvider != .custom {
                            Button("恢复推荐参数", action: store.restoreOnlineProviderDefaults)
                        }
                        if let url = store.onlineProvider.documentationURL {
                            Link("查看官方文档", destination: url)
                        }
                    }
                }
            }
            Section("模型") {
                LabeledContent("模型名称") {
                    TextField("改写模型名称", text: $store.onlineModelDraft, prompt: Text("模型 ID"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("改写模型名称")
                }
                rewriteModelCatalog
            }
            Section {
                LabeledContent("API Key") {
                    SecureField(
                        "改写 API Key", text: $store.onlineAPIKeyDraft,
                        prompt: Text(store.hasOnlineAPIKey ? "输入新 Key 可替换" : store.onlineProvider.keyPlaceholder)
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("改写 API Key")
                }
                Label(store.onlineCredentialEntryHint, systemImage: store.hasOnlineAPIKey ? "checkmark.shield" : "key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.hasOnlineAPIKey {
                    Button("删除当前 Key…", role: .destructive) { deleteKeyFor = .rewrite }
                }
            } header: {
                Text("凭证")
            } footer: {
                Text("各提供商的 Key 分开保存在仅当前用户可读的本地文件。测试只发送一条不含原稿的 OK 消息。")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar(status: rewriteSaveStatus) {
                if store.isTestingOnlineAI { ProgressView().controlSize(.small).accessibilityLabel("正在测试连接") }
                Button("重新测试", action: store.testOnlineAIConnection)
                    .disabled(store.isTestingOnlineAI)
                Button("仅保存改写 API", action: store.saveOnlineAIConfiguration)
                    .disabled(store.isTestingOnlineAI)
                Button("保存并测试改写 API", action: store.saveAndTestOnlineAIConfiguration)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isTestingOnlineAI)
            }
        }
    }

    private var rewriteModelCatalog: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.onlineAvailableModels.isEmpty {
                Picker("远程可用模型", selection: $store.onlineModelDraft) {
                    if !store.onlineAvailableModels.contains(store.onlineModelDraft) {
                        Text(store.onlineModelDraft.isEmpty ? "请选择模型" : store.onlineModelDraft).tag(store.onlineModelDraft)
                    }
                    ForEach(store.onlineAvailableModels, id: \.self) { model in Text(model).tag(model) }
                }
            }
            HStack {
                Button("读取远程模型", action: store.refreshOnlineModelCatalog)
                    .disabled(store.isLoadingOnlineModels)
                if store.isLoadingOnlineModels { ProgressView().controlSize(.small) }
            }
            Text(store.onlineModelCatalogStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var imageSettings: some View {
        Form {
            Section("服务连接") {
                LabeledContent("图片 API 地址") {
                    TextField("图片 API 地址", text: $store.onlineImageEndpointDraft, prompt: Text("留空时从改写 API 地址推导"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("图片 API 地址")
                }
                Text(store.resolvedImageGenerationEndpointDescription)
                    .font(.callout)
                    .foregroundStyle(OnlineImageGenerationConfiguration.looksLikeCredential(store.onlineImageEndpointDraft)
                                     ? Color.red : Color.secondary)
            }
            Section("模型与画面") {
                LabeledContent("图片模型") {
                    TextField("图片模型名称", text: $store.onlineImageModelDraft, prompt: Text("图片模型 ID"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("图片模型名称")
                }
                imageModelCatalog
                Picker("画面尺寸", selection: $store.onlineImageSize) {
                    ForEach(OnlineImageGenerationSize.allCases) { size in Text(size.displayName).tag(size) }
                }
                Picker("图片质量", selection: $store.onlineImageQuality) {
                    ForEach(OnlineImageGenerationQuality.allCases) { quality in Text(quality.displayName).tag(quality) }
                }
            }
            Section {
                LabeledContent("图片 API Key") {
                    SecureField(
                        "图片 API Key", text: $store.onlineImageAPIKeyDraft,
                        prompt: Text(store.hasOnlineImageAPIKey ? "输入新 Key 可替换" : "图片接口 Bearer API Key")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("图片 API Key")
                }
                Label(store.onlineImageCredentialEntryHint, systemImage: store.hasOnlineImageAPIKey ? "checkmark.shield" : "key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.hasOnlineImageAPIKey {
                    Button("删除图片 Key…", role: .destructive) { deleteKeyFor = .images }
                }
            } header: {
                Text("凭证")
            } footer: {
                Text("图片服务使用独立的 Key。读取图片模型或点击生成时才会调用图片服务，可能产生费用。")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar(status: Label(store.onlineImageGenerationStatus, systemImage: "photo").foregroundStyle(.secondary)) {
                Button("保存图片生成设置", action: store.saveOnlineImageGenerationConfiguration)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var imageModelCatalog: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.onlineImageAvailableModels.isEmpty {
                Picker("图片接口可用模型", selection: $store.onlineImageModelDraft) {
                    if !store.onlineImageAvailableModels.contains(store.onlineImageModelDraft) {
                        Text(store.onlineImageModelDraft.isEmpty ? "请选择图片模型" : store.onlineImageModelDraft)
                            .tag(store.onlineImageModelDraft)
                    }
                    ForEach(store.onlineImageAvailableModels, id: \.self) { model in Text(model).tag(model) }
                }
            }
            HStack {
                Button("读取图片模型", action: store.refreshOnlineImageModelCatalog)
                    .disabled(store.isLoadingOnlineImageModels)
                if store.isLoadingOnlineImageModels { ProgressView().controlSize(.small) }
            }
            Text(store.onlineImageModelCatalogStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func saveBar<Status: View, Actions: View>(status: Status, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                status.font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    actions()
                }
            }
            .padding(14)
        }
        .background(.background)
    }

    private var onlineStatusImage: String {
        if store.onlineAIStatus.contains("成功") { return "checkmark.circle" }
        return store.hasOnlineAPIKey ? "checkmark.shield" : "key"
    }

    @ViewBuilder private var rewriteSaveStatus: some View {
        if ["失败", "错误", "不正确"].contains(where: { store.onlineAIStatus.contains($0) }) {
            WorkspaceIssueView(message: store.onlineAIStatus)
        } else {
            Label(store.onlineAIStatus, systemImage: onlineStatusImage)
                .foregroundStyle(store.onlineAIStatus.contains("成功") ? Color.green : Color.secondary)
        }
    }
}
