import AppKit
import SwiftUI

struct OutputView: View {
    @Bindable var store: RewriteStore
    let output: RewriteOutput
    let historyID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ManuscriptTextSize.storageKey) private var textSize = ManuscriptTextSize.standard

    @State private var selectedPage: OutputPage = .revised
    @State private var copyFeedback: String?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var isEditingDraft = false
    @State private var showBatchImageConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            pageNavigation
            Divider()
            documentScrollView
        }
        .animation(WorkspaceMotion.transition(reduceMotion: reduceMotion), value: selectedPage)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑成稿", systemImage: "square.and.pencil") {
                    isEditingDraft = true
                }
                .help("修改成稿标题和正文")
            }
            .workspaceToolbarPriority(high: true)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("复制本页") { copyPage() }
                    Button("复制全部五部分") {
                        store.copyOutput(output)
                        showCopyFeedback("已复制全部")
                    }
                } label: {
                    Label("复制本页", systemImage: "doc.on.doc")
                } primaryAction: { copyPage() }
                .help("复制当前页；展开菜单可复制全部")
            }
            .workspaceToolbarPriority(high: false)
            ToolbarItem(placement: .primaryAction) {
                Button("输出文件包", systemImage: "square.and.arrow.up") {
                    store.exportShortVideoPackage(output)
                }
                .disabled(store.isGeneratingAllImages || store.generatingImageShotID != nil || store.generatingCoverFormat != nil)
                .help("选择目录，输出文稿、封面与分镜")
            }
            .workspaceToolbarPriority(high: true)
        }
        .sheet(isPresented: $isEditingDraft) {
            DraftEditorSheet(title: output.title, body: output.subtitleReadyBody) { title, draft in
                store.saveEditedDraft(title: title, revisedBody: draft, historyID: historyID)
                showCopyFeedback("已保存成稿")
            }
        }
        .onDisappear { feedbackTask?.cancel() }
        .confirmationDialog(
            "批量生成 \(visualShots.count + coverArtworks.count) 张配图与封面？",
            isPresented: $showBatchImageConfirmation,
            titleVisibility: .visible
        ) {
            Button("开始批量生成") { store.generateAllImages(in: output, historyID: historyID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包含抖音竖版、横版封面和全部分镜。每张图片都会调用一次当前中转站的图片生成接口，可能产生费用；已保存到本机的图片会自动跳过。")
        }
    }

    private var pageNavigation: some View {
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                pagePicker.pickerStyle(.segmented).fixedSize()
                pagePicker.pickerStyle(.menu)
            }
            Spacer(minLength: 6)
            if let copyFeedback {
                Label(copyFeedback, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            ControlGroup {
                Button("上一部分", systemImage: "chevron.left") { movePage(by: -1) }
                    .disabled(selectedPage == .original)
                    .help("上一部分（⌥⌘←）")
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                Button("下一部分", systemImage: "chevron.right") { movePage(by: 1) }
                    .disabled(selectedPage == .videos)
                    .help("下一部分（⌥⌘→）")
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
        .padding(.vertical, 10)
    }

    private var pagePicker: some View {
        Picker("结果分页", selection: $selectedPage) {
            ForEach(OutputPage.allCases) { page in Text(page.title).tag(page) }
        }
        .labelsHidden()
    }

    private var documentScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(output.title)
                    .font(.title.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                pageContent
            }
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.horizontal, WorkspaceLayout.detailHorizontalPadding, for: .scrollContent)
        .contentMargins(.vertical, 18, for: .scrollContent)
        .id(selectedPage)
        .accessibilityLabel("\(selectedPage.title)内容滚动区")
        .transition(.opacity)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .original:
            resultSection(
                title: originalPageTitle,
                subtitle: output.corrections.isEmpty ? output.transcriptOrigin.label : "已校正 \(output.corrections.count) 处"
            ) {
                documentCard(output.originalTranscript)
                if !output.corrections.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("专有名词与同音词校对记录", systemImage: "checkmark.bubble")
                            .font(.headline)
                        ForEach(output.corrections) { correction in
                            HStack(alignment: .top, spacing: 12) {
                                Text(correction.original)
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.tertiary)
                                Text(correction.corrected)
                                    .fontWeight(.semibold)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(correction.reason)
                                    Text(correction.verification.label)
                                        .foregroundStyle(
                                            correction.verification == .onlineVerified
                                                ? AnyShapeStyle(.green)
                                                : AnyShapeStyle(.tertiary)
                                        )
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .workspaceGlassInset(cornerRadius: 12)
                        }
                    }
                    .padding(.top, 8)
                }
                DisclosureGroup(rawSourceDisclosureTitle) {
                    Text(output.rawTranscript)
                        .font(textSize.font)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(.top, 8)
            }
            .transition(.opacity)

        case .suggestions:
            resultSection(title: "修改建议", subtitle: "原文摘录 · 具体改法") {
                VStack(spacing: 14) {
                    ForEach(Array(output.suggestions.enumerated()), id: \.element.id) { index, item in
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                suggestionCell(title: "第 \(index + 1) 段 · 对应原文", text: item.original)
                                    .frame(minWidth: 240)
                                suggestionCell(
                                    title: item.suggestion,
                                    text: item.reason,
                                    emphasized: true
                                )
                                .frame(minWidth: 240)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                Label("第 \(index + 1) 段", systemImage: "text.quote")
                                    .font(.headline)
                                suggestionCell(title: "对应原文", text: item.original)
                                suggestionCell(
                                    title: item.suggestion,
                                    text: item.reason,
                                    emphasized: true
                                )
                            }
                        }
                    }
                }
            }
            .transition(.opacity)

        case .revised:
            resultSection(
                title: revisedPageTitle,
                subtitle: isEditingDraft ? "正在编辑" : revisedPageSubtitle
            ) {
                documentCard(output.subtitleReadyBody)
            }
            .transition(.opacity)

        case .visuals:
            resultSection(title: "短视频镜头与配图", subtitle: visualSubtitle) {
                illustrationActions

                VStack(alignment: .leading, spacing: 12) {
                    Label("抖音双封面", systemImage: "rectangle.on.rectangle.angled")
                        .font(.headline)
                    Text("根据标题与完整成稿设计 3:4 竖版和 16:9 横版背景，再由澄稿在本机排入准确标题，避免图片模型生成乱码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(coverArtworks) { cover in
                        coverCard(cover)
                    }
                }

                Divider()

                Label("分镜配图", systemImage: "timeline.selection")
                    .font(.headline)

                LazyVStack(spacing: 12) {
                    ForEach(visualShots) { shot in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(shot.id + 1)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.tint)
                                .frame(width: 28, height: 28)
                                .background(.tint.opacity(0.1), in: .circle)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(shot.timecode, systemImage: "timeline.selection")
                                        .font(.headline)
                                    Spacer()
                                    Button(
                                        shot.generatedImagePath == nil ? "生成图片" : "重新生成",
                                        systemImage: shot.generatedImagePath == nil ? "photo.badge.plus" : "arrow.clockwise"
                                    ) {
                                        store.generateImage(for: shot.id, in: output, historyID: historyID)
                                    }
                                    .controlSize(.small)
                                    .disabled(!store.canGenerateImages)
                                    .help(store.canGenerateImages ? "调用当前图片模型生成这一张图片" : "请先在 AI 设置中配置图片接口、模型和独立 Key")
                                    Button("复制提示词", systemImage: "doc.on.doc") {
                                        store.copyImagePrompt(shot.prompt)
                                        showCopyFeedback("已复制绘图提示词")
                                    }
                                    .controlSize(.small)
                                }
                                if store.generatingImageShotID == shot.id {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("正在通过中转站生成图片…")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let path = shot.generatedImagePath,
                                   let image = NSImage(contentsOfFile: path) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxWidth: .infinity, maxHeight: 360)
                                            .background(.black.opacity(0.08), in: .rect(cornerRadius: 12))
                                            .clipShape(.rect(cornerRadius: 12))
                                        HStack {
                                            Label("图片已保存到本机", systemImage: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.green)
                                            Spacer()
                                            Button("打开图片") { store.openGeneratedImage(at: path) }
                                                .controlSize(.small)
                                            Button("在访达中显示") { store.revealGeneratedImage(at: path) }
                                                .controlSize(.small)
                                        }
                                    }
                                }
                                Text("AI 绘图提示词")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                                Text(shot.prompt)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                Text("对应口播：\(shot.spokenContext)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .workspaceGlassInset(cornerRadius: 16)
                    }
                }
            }
            .transition(.opacity)

        case .videos:
            resultSection(
                title: "视频建议",
                subtitle: "每 10 秒一段 · 连贯叙事 · 风格统一 · 共 \(videoSuggestions.count) 段"
            ) {
                LazyVStack(spacing: 12) {
                    ForEach(videoSuggestions) { suggestion in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(suggestion.id + 1)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.tint)
                                .frame(width: 28, height: 28)
                                .background(.tint.opacity(0.1), in: .circle)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(
                                        "\(suggestion.timecode) · \(suggestion.durationSeconds) 秒",
                                        systemImage: "video"
                                    )
                                    .font(.headline)
                                    Spacer()
                                    Button("复制提示词", systemImage: "doc.on.doc") {
                                        store.copyImagePrompt(suggestion.prompt)
                                        showCopyFeedback("已复制视频提示词")
                                    }
                                    .controlSize(.small)
                                }
                                Text(suggestion.prompt)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                Text("对应口播：\(suggestion.spokenContext)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .workspaceGlassInset(cornerRadius: 16)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func coverCard(_ cover: CoverArtwork) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("\(cover.format.title) · \(cover.format.aspectRatioLabel)", systemImage: "photo")
                    .font(.headline)
                Spacer()
                Button(
                    cover.generatedImagePath == nil ? "生成封面" : "重新生成",
                    systemImage: cover.generatedImagePath == nil ? "photo.badge.plus" : "arrow.clockwise"
                ) {
                    store.generateCover(cover.format, in: output, historyID: historyID)
                }
                .controlSize(.small)
                .disabled(!store.canGenerateImages)
                Button("复制提示词", systemImage: "doc.on.doc") {
                    store.copyImagePrompt(cover.prompt)
                    showCopyFeedback("已复制封面提示词")
                }
                .controlSize(.small)
            }
            if store.generatingCoverFormat == cover.format {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在生成背景并排入准确标题…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let path = cover.generatedImagePath,
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 390)
                    .background(.black.opacity(0.08), in: .rect(cornerRadius: 12))
                    .clipShape(.rect(cornerRadius: 12))
                HStack {
                    Label("准确标题已在本机排版", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("打开图片") { store.openGeneratedImage(at: path) }.controlSize(.small)
                    Button("在访达中显示") { store.revealGeneratedImage(at: path) }.controlSize(.small)
                }
            }
            Text("封面提示词")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(cover.prompt)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(16)
        .workspaceGlassInset(cornerRadius: 16)
    }

    @ViewBuilder
    private func resultSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    private var illustrationActions: some View {
        let status = Label(store.onlineImageGenerationStatus, systemImage: "photo")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                status.fixedSize(horizontal: true, vertical: false)
                Spacer()
                illustrationButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                status
                illustrationButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .workspaceGlassInset(cornerRadius: 12)
    }

    private var illustrationButtons: some View {
        ControlGroup {
            if store.isGeneratingAllImages || store.generatingImageShotID != nil {
                Button("停止生成", systemImage: "stop", action: store.cancelImageGeneration)
            } else {
                Button("导出给 ChatGPT", systemImage: "square.and.arrow.up") {
                    store.exportChatGPTImageMarkdown(output)
                }
                .disabled(visualShots.isEmpty)
                .help("每 10 张配图导出为一批 Markdown 任务")
                Button("批量生成封面与配图", systemImage: "photo.stack") {
                    showBatchImageConfirmation = true
                }
                .disabled(!store.canGenerateImages || visualShots.isEmpty)
                .help(store.canGenerateImages ? "生成前需要确认" : "在图片 API 设置中配置服务、模型和 Key")
            }
        }
    }

    private func documentCard(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .font(textSize.font)
            .lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionCell(title: String, text: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(emphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(text)
                .font(textSize.font)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
        .workspaceGlassInset(
            cornerRadius: 14,
            tint: emphasized ? .accentColor : .clear,
            tintOpacity: emphasized ? 0.055 : 0
        )
    }

    private func movePage(by offset: Int) {
        let pages = OutputPage.allCases
        guard let current = pages.firstIndex(of: selectedPage) else { return }
        let destination = min(max(0, current + offset), pages.count - 1)
        selectedPage = pages[destination]
    }

    private var visualShots: [VisualShot] {
        VisualShotPlanner.shots(for: output)
    }

    private var coverArtworks: [CoverArtwork] {
        CoverArtworkPlanner.artworks(for: output)
    }

    private var videoSuggestions: [VideoSuggestion] {
        VideoSuggestionPlanner.suggestions(for: output)
    }

    private var visualSubtitle: String {
        let source = output.visualDesignSource?.label ?? "旧版基础镜头"
        if output.style == .spoken || output.style == .channel {
            return "\(output.effectiveVisualStyle.rawValue) · \(source) · 每 2–3 秒一镜 · 共 \(visualShots.count) 镜"
        }
        return "\(output.effectiveVisualStyle.rawValue) · \(source) · 共 \(visualShots.count) 张 · 可直接复制给图像 AI"
    }

    private var originalPageTitle: String {
        switch output.style {
        case .spoken, .channel: "校对后的完整口播稿"
        case .article: "净化并校对后的文章正文"
        case .social: "整理并校对后的原始文案"
        }
    }

    private var revisedPageTitle: String {
        output.style == .spoken ? "字幕式口播稿" : "修改后的完整文稿"
    }

    private var revisedPageSubtitle: String {
        output.style == .spoken ? "一句话一行 · 可编辑保存" : "已生成 · 可编辑保存"
    }

    private var rawSourceDisclosureTitle: String {
        switch output.transcriptOrigin {
        case .webArticle, .socialImageText: "查看净化前取得的网页正文"
        case .localSpeechRecognition, .platformSubtitle: "查看未经校对的原始识别稿"
        case .pastedText: "查看未经校对的原始内容"
        }
    }

    private func copyPage() {
        store.copyOutputPage(selectedPage, output: output)
        showCopyFeedback("已复制本页")
    }

    private func showCopyFeedback(_ message: String) {
        feedbackTask?.cancel()
        copyFeedback = message
        feedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            withAnimation(WorkspaceMotion.transition(reduceMotion: reduceMotion)) { copyFeedback = nil }
        }
    }

}
