import AppKit
import SwiftUI

struct ComposerView: View {
    @Bindable var store: RewriteStore
    @Environment(\.openSettings) private var openSettings
    @Namespace private var glassNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.headerContentSpacing) {
            WorkspacePageHeader(title: "素材改写")

            inputWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
        .padding(.top, WorkspaceLayout.detailTopPadding)
        .padding(.bottom, WorkspaceLayout.detailBottomPadding)
        .animation(.snappy, value: store.hasUnreadResult)
    }

    private var inputWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("素材与处理设置", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text(sourceInputStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(store.sourceKind == .link && store.validSourceURL != nil ? .green : .secondary)
            }

            HStack {
                Picker("来源", selection: $store.sourceKind) {
                    ForEach(SourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                Spacer()
                parameterControls
            }

            TextEditor(text: sourceInputBinding)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180, idealHeight: 260, maxHeight: 300)
                .disabled(store.isProcessing)
                .padding(10)
                .workspaceGlassInset(cornerRadius: 14)
                .overlay(alignment: .topLeading) {
                    if sourceInputBinding.wrappedValue.isEmpty {
                        Text(store.sourceKind == .link
                             ? "粘贴抖音、B站、YouTube、公众号、小红书或网页文章链接……"
                             : "粘贴字幕、文章或其他原始素材……")
                            .foregroundStyle(.tertiary)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }

            aiController

            if store.sourceKind == .link, !store.sourceURL.isEmpty, store.validSourceURL == nil {
                Label("没有识别到有效链接，请粘贴以 http:// 或 https:// 开头的完整地址。", systemImage: "link.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                if let progress = store.processingProgress {
                    ProgressView(value: progress.fraction)
                        .frame(maxWidth: 220)
                    Text(progress.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(store.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                executionControls
            }

            if store.hasUnreadResult, !store.isProcessing {
                HStack(spacing: 10) {
                    Label("文稿与 AI 镜头设计已完成，结果已保存。", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("前往处理结果", systemImage: "arrow.right.circle.fill") {
                        store.openLatestResult()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(.green.opacity(0.08), in: .rect(cornerRadius: 12))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: .rect(cornerRadius: 10))
            }
        }
        .padding(16)
        .workspaceGlassPanel(cornerRadius: 20, elevated: true)
    }

    private var sourceInputBinding: Binding<String> {
        Binding(
            get: { store.sourceKind == .link ? store.sourceURL : store.sourceText },
            set: { value in
                if store.sourceKind == .link { store.sourceURL = value }
                else { store.sourceText = value }
            }
        )
    }

    private var sourceInputStatus: String {
        if store.sourceKind == .link, store.validSourceURL != nil { return "链接已识别" }
        return "\(store.sourceCharacterCount) 字"
    }

    private var parameterControls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(RewriteStyle.allCases) { style in
                    Button { store.style = style } label: {
                        Label(style.rawValue, systemImage: style.systemImage)
                    }
                }
            } label: {
                Label(store.style.rawValue, systemImage: store.style.systemImage)
            }
            .glassEffectID("style", in: glassNamespace)

            Menu {
                ForEach(OutputLanguage.allCases) { language in
                    Button { store.outputLanguage = language } label: {
                        Label(language.rawValue, systemImage: store.outputLanguage == language ? "checkmark" : "character.bubble")
                    }
                }
            } label: {
                Label(store.outputLanguage.rawValue, systemImage: "character.bubble")
            }
            .glassEffectID("language", in: glassNamespace)

        }
    }

    private var aiController: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                aiControllerTitle
                Spacer(minLength: 12)
                aiControllerControls
            }
            VStack(alignment: .leading, spacing: 10) {
                aiControllerTitle
                aiControllerControls
            }
        }
        .padding(12)
        .workspaceGlassInset(
            cornerRadius: 14,
            tint: .accentColor,
            tintOpacity: 0.035
        )
    }

    private var aiControllerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("AI 控制器", systemImage: "cpu")
                .font(.subheadline.weight(.semibold))
            Text(store.onlineProvider.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aiControllerControls: some View {
        HStack(spacing: 10) {
            Menu {
                if store.onlineModelChoices.isEmpty {
                    Text("尚未读取可用模型")
                } else {
                    ForEach(store.onlineModelChoices, id: \.self) { model in
                        Button {
                            store.selectOnlineModelForProcessing(model)
                        } label: {
                            if model == store.onlineModelDraft {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
                Divider()
                Button {
                    store.refreshOnlineModelCatalog()
                } label: {
                    Label("刷新远程模型", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoadingOnlineModels)
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("配置 AI 服务…", systemImage: "gearshape")
                }
            } label: {
                Label(store.selectedOnlineModelLabel, systemImage: "cpu.fill")
                    .lineLimit(1)
                    .frame(maxWidth: 260)
            }
            .disabled(store.isProcessing)

            Picker("推理深度", selection: $store.onlineReasoningEffort) {
                ForEach(OnlineAIReasoningEffort.allCases) { effort in
                    Text(effort.displayName).tag(effort)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .disabled(store.isProcessing)
            .help("自动不发送额外参数；快速、标准、深入会请求相应推理深度。不支持该参数的兼容接口会自动回退。")
        }
    }

    private var executionControls: some View {
        HStack(spacing: 8) {
            Button { store.pasteFromClipboard() } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }
            .disabled(store.isProcessing)

            if store.isProcessing {
                Button { store.cancelProcessing() } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button { store.startRewrite() } label: {
                    Label("开始处理", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canProcess)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}
