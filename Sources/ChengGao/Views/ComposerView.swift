import SwiftUI

struct ComposerView: View {
    @Bindable var store: RewriteStore
    let showResult: () -> Void
    let showWebLogin: (WebAIProvider) -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsPage.storageKey) private var settingsPage = SettingsPage.general
    @FocusState private var editorFocused: Bool
    @State private var showsOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Label(store.sourceKind == .link ? "素材链接" : "原始素材",
                      systemImage: store.sourceKind == .link ? "link" : "text.alignleft")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Picker("素材来源", selection: $store.sourceKind) {
                    ForEach(SourceKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(store.isProcessing)
            }
            editor
            if let error = store.errorMessage {
                WorkspaceIssueView(message: error)
            }
            if store.hasUnreadResult, !store.isProcessing {
                HStack {
                    Label("成稿已保存", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("查看成稿", systemImage: "arrow.right", action: showResult)
                }
                .transition(.opacity)
            }
            Divider()
            footer
        }
        .workspaceMargins()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.hasUnreadResult)
        .onChange(of: store.sourceKind) { editorFocused = true }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("粘贴素材", systemImage: "doc.on.clipboard") {
                    store.pasteFromClipboard()
                    editorFocused = true
                }
                .disabled(store.isProcessing)
                .help("从剪贴板粘贴素材（⇧⌘V）")
                Button("改写选项", systemImage: "slider.horizontal.3") { showsOptions.toggle() }
                    .help("选择文稿格式、画面风格、输出语言和 AI 服务")
                    .popover(isPresented: $showsOptions, arrowEdge: .bottom) { options }
            }
        }
    }

    private var input: Binding<String> {
        store.sourceKind == .link ? $store.sourceURL : $store.sourceText
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: input)
                    .font(.body)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .disabled(store.isProcessing)
                    .accessibilityLabel(store.sourceKind == .link ? "素材链接输入区" : "原稿编辑区")
                if input.wrappedValue.isEmpty {
                    Text(store.sourceKind == .link ? "在此粘贴文章、视频链接或平台分享文字。" : "在此输入或粘贴字幕、文章或口播原稿。")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack(spacing: 8) {
                Label(store.style.rawValue, systemImage: store.style.systemImage)
                Text("·").accessibilityHidden(true)
                Text(store.outputLanguage.rawValue)
                Spacer()
                if store.sourceKind == .link, !store.sourceURL.isEmpty {
                    let valid = store.validSourceURL != nil
                    Label(valid ? "已识别链接" : "请输入完整网址", systemImage: valid ? "link" : "exclamationmark.triangle")
                        .foregroundStyle(valid ? Color.secondary : .primary)
                } else {
                    Text("\(store.sourceCharacterCount) 字").monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .workspaceEditorSurface(focused: editorFocused)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if let progress = store.processingProgress {
                    ProgressView(value: progress.fraction)
                        .frame(maxWidth: 250)
                        .accessibilityLabel("改写进度")
                    Text(progress.message).font(.callout)
                } else {
                    Label(store.privacySummary, systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !store.hasOnlineAPIKey && !store.webAIEnabled {
                        Button("配置改写服务…", action: configureAI)
                            .buttonStyle(.link)
                    } else {
                        Text(store.statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.isProcessing {
                Button("停止处理", systemImage: "stop", action: store.cancelProcessing)
            } else {
                Button(store.errorMessage == nil ? "开始处理" : "重新处理",
                       systemImage: "wand.and.stars", action: store.startRewrite)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!store.canProcess)
                    .help("提交当前素材（⌘↩）")
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("改写选项").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("完成") { showsOptions = false }
            }
            .padding(16)
            Divider()
            Form {
                Section("输出") {
                    Picker("文稿格式", selection: $store.style) {
                        ForEach(RewriteStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("画面风格", selection: $store.visualStyle) {
                        ForEach(VisualStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .help(store.visualStyle.summary)
                    Picker("输出语言", selection: $store.outputLanguage) {
                        ForEach(OutputLanguage.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("改写服务") {
                    LabeledContent("当前模型") {
                        Menu(store.selectedAIControllerLabel) { modelOptions }
                    }
                    Picker("推理深度", selection: $store.onlineReasoningEffort) {
                        ForEach(OnlineAIReasoningEffort.allCases) { Text($0.displayName).tag($0) }
                    }
                    .disabled(store.webAIEnabled)
                    Button("配置改写 API…", action: configureAI)
                }
            }
            .formStyle(.grouped)
            .disabled(store.isProcessing)
        }
        .frame(width: 350, height: 350)
    }

    @ViewBuilder private var modelOptions: some View {
        Section("网页 AI") {
            ForEach(WebAIProvider.allCases) { provider in
                Button(provider.title) {
                    showsOptions = false
                    showWebLogin(provider)
                }
            }
            if store.webAIEnabled {
                Button("切回改写 API", action: store.disableWebAI)
            }
        }
        Section("API 模型") {
            ForEach(store.onlineModelChoices, id: \.self) { model in
                Button(model) { store.selectOnlineModelForProcessing(model) }
            }
            Button("读取远程模型", action: store.refreshOnlineModelCatalog)
                .disabled(store.isLoadingOnlineModels)
        }
    }

    private func configureAI() {
        showsOptions = false
        settingsPage = .rewrite
        openSettings()
    }
}
