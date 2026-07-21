import SwiftUI

struct SettingsView: View {
    @Bindable var store: RewriteStore

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }
            onlineAISettings
                .tabItem { Label("AI 服务", systemImage: "network") }
        }
        .frame(width: 720, height: 620)
        .scenePadding()
        .containerBackground(.clear, for: .window)
        .background {
            ZStack {
                WorkspaceAmbientBackground()
                    .ignoresSafeArea()
                WindowGlassConfigurator()
                    .frame(width: 0, height: 0)
            }
        }
    }

    private var generalSettings: some View {
        Form {
            Section("处理") {
                Toggle("联网核验专有名词", isOn: $store.onlineTerminologyCheck)
                Text("开启后只向中文维基百科查询候选专有名词，不发送完整原稿。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("隐私") {
                Label(store.privacySummary, systemImage: "lock.shield")
                Text(privacyDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("视频转写") {
                LabeledContent("本机模型", value: "Whisper Small Q5_1")
                Text("只有平台没有字幕时才在本机识别音轨；识别完成后，完整原稿交给在线 AI 全文处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var onlineAISettings: some View {
        Form {
            Section("在线 AI 提供商") {
                Picker("提供商", selection: $store.onlineProvider) {
                    ForEach(OnlineAIProvider.allCases) { provider in
                        Label(provider.displayName, systemImage: provider.systemImage)
                            .tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("当前提供商") {
                    Label(store.onlineProvider.displayName, systemImage: store.onlineProvider.systemImage)
                }
                Text("不同提供商分别保存 API Key。应用不访问 macOS 钥匙串，Key 只保存在权限为 0600、仅当前用户可读的本地凭证文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("连接参数") {
                TextField("API 地址（可填写中转站根地址）", text: $store.onlineEndpointDraft)
                    .textFieldStyle(.roundedBorder)
                Text(store.resolvedOnlineEndpointDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("模型名称") {
                    TextField("可手动输入模型 ID", text: $store.onlineModelDraft)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    if !store.onlineAvailableModels.isEmpty {
                        Picker("远程可用模型", selection: $store.onlineModelDraft) {
                            if !store.onlineModelDraft.isEmpty,
                               !store.onlineAvailableModels.contains(store.onlineModelDraft) {
                                Text("当前：\(store.onlineModelDraft)").tag(store.onlineModelDraft)
                            }
                            ForEach(store.onlineAvailableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Button("读取远程模型", action: store.refreshOnlineModelCatalog)
                        .disabled(store.isLoadingOnlineModels)
                    if store.isLoadingOnlineModels {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(store.onlineModelCatalogStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("API Key") {
                    SecureField(
                        store.hasOnlineAPIKey ? "已保存；输入新 Key 可替换" : store.onlineProvider.keyPlaceholder,
                        text: $store.onlineAPIKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)
                }
                Label(
                    store.onlineCredentialEntryHint,
                    systemImage: store.hasOnlineAPIKey ? "checkmark.shield.fill" : "key"
                )
                .font(.caption)
                .foregroundStyle(store.hasOnlineAPIKey ? .green : .secondary)

                HStack {
                    if store.onlineProvider != .custom {
                        Button("恢复推荐参数", action: store.restoreOnlineProviderDefaults)
                    }
                    if let documentationURL = store.onlineProvider.documentationURL {
                        Link("查看官方文档", destination: documentationURL)
                    }
                    Spacer()
                    if store.hasOnlineAPIKey {
                        Button("删除当前 Key", role: .destructive, action: store.deleteOnlineAIKey)
                    }
                }
            }

            Section("图片生成（可选）") {
                TextField(
                    "图片 API 地址；留空则从聊天接口自动推导",
                    text: $store.onlineImageEndpointDraft
                )
                .textFieldStyle(.roundedBorder)
                Text(store.resolvedImageGenerationEndpointDescription)
                    .font(.caption)
                    .foregroundStyle(
                        OnlineImageGenerationConfiguration.looksLikeCredential(store.onlineImageEndpointDraft)
                            ? Color.red
                            : Color.secondary
                    )

                LabeledContent("图片 API Key") {
                    SecureField(
                        store.hasOnlineImageAPIKey ? "已独立保存；输入新 Key 可替换" : "图片接口 Bearer API Key",
                        text: $store.onlineImageAPIKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)
                }
                Label(
                    store.onlineImageCredentialEntryHint,
                    systemImage: store.hasOnlineImageAPIKey ? "checkmark.shield.fill" : "key"
                )
                .font(.caption)
                .foregroundStyle(store.hasOnlineImageAPIKey ? .green : .secondary)

                LabeledContent("图片模型") {
                    TextField("例如 gpt-image-1 或中转站提供的模型 ID", text: $store.onlineImageModelDraft)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    if !store.onlineImageAvailableModels.isEmpty {
                        Picker("图片接口可用模型", selection: $store.onlineImageModelDraft) {
                            if store.onlineImageModelDraft.isEmpty {
                                Text("请选择图片模型").tag("")
                            } else if !store.onlineImageAvailableModels.contains(store.onlineImageModelDraft) {
                                Text("当前：\(store.onlineImageModelDraft)").tag(store.onlineImageModelDraft)
                            }
                            ForEach(store.onlineImageAvailableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Button("读取图片模型", action: store.refreshOnlineImageModelCatalog)
                        .disabled(store.isLoadingOnlineImageModels)
                    if store.isLoadingOnlineImageModels {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(store.onlineImageModelCatalogStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Picker("画面尺寸", selection: $store.onlineImageSize) {
                        ForEach(OnlineImageGenerationSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    Picker("图片质量", selection: $store.onlineImageQuality) {
                        ForEach(OnlineImageGenerationQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                }

                HStack {
                    Button("保存图片生成设置", action: store.saveOnlineImageGenerationConfiguration)
                        .buttonStyle(.borderedProminent)
                    if store.hasOnlineImageAPIKey {
                        Button("删除图片 Key", role: .destructive, action: store.deleteOnlineImageAPIKey)
                    }
                    Spacer()
                    Label(store.onlineImageGenerationStatus, systemImage: "photo.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("图片 Key 与聊天 Key 分开保存、互不覆盖；读取图片模型和实际生图只使用图片 Key。兼容中转站返回 image_url、url 或 b64_json；只有读取模型或在处理结果页点击生成时才会调用图片接口，并可能产生费用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("保存与诊断") {
                HStack {
                    Button("保存并测试连接", action: store.saveAndTestOnlineAIConfiguration)
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isTestingOnlineAI)
                    Button("仅保存", action: store.saveOnlineAIConfiguration)
                        .disabled(store.isTestingOnlineAI)
                    Button("重新测试", action: store.testOnlineAIConnection)
                        .disabled(store.isTestingOnlineAI)
                    if store.isTestingOnlineAI { ProgressView().controlSize(.small) }
                    Spacer()
                    Label(store.onlineAIStatus, systemImage: onlineStatusImage)
                        .font(.caption)
                        .foregroundStyle(onlineStatusColor)
                }
                Text("保存并测试后会明确显示连接成功或具体错误；测试只发送一条不含原稿的 OK 消息。正式处理会把完整标题、全文和编辑指令一次性交给所选在线 AI；请求失败时会直接显示错误。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("处理方式") {
                LabeledContent("改写引擎", value: "在线 AI · 全文处理")
                Text("不再使用本地千问模型，也不把文章拆成小段分别改写。初稿未通过事实覆盖和实质改写检查时，会把全文与问题清单再次交给在线 AI 统一重写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var onlineStatusImage: String {
        if store.onlineAIStatus.contains("成功") { return "checkmark.circle.fill" }
        if store.onlineAIStatus.contains("失败") || store.onlineAIStatus.contains("错误") || store.onlineAIStatus.contains("不正确") { return "xmark.octagon.fill" }
        return store.hasOnlineAPIKey ? "checkmark.shield.fill" : "key"
    }

    private var onlineStatusColor: Color {
        if store.onlineAIStatus.contains("成功") { return .green }
        if store.onlineAIStatus.contains("失败") || store.onlineAIStatus.contains("错误") || store.onlineAIStatus.contains("不正确") { return .red }
        return .secondary
    }

    private var privacyDetail: String {
        "完整标题、原稿和改写提示会发送给 \(store.onlineProvider.displayName)。视频音轨仍只在本机使用 Whisper 转写，不上传原始音频。"
    }
}
