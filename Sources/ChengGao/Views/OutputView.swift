import AppKit
import SwiftUI

struct OutputView: View {
    let output: RewriteOutput
    let copyPageAction: (OutputPage) -> Void
    let copyAllAction: () -> Void
    let copyImagePromptAction: (String) -> Void
    let exportImageMarkdownAction: () -> Void
    let saveDraftAction: (String, String) -> Void
    let canGenerateImages: Bool
    let imageGenerationStatus: String
    let generatingImageShotID: Int?
    let isGeneratingAllImages: Bool
    let generateImageAction: (Int) -> Void
    let generateAllImagesAction: () -> Void
    let cancelImageGenerationAction: () -> Void
    let openGeneratedImageAction: (String) -> Void
    let revealGeneratedImageAction: (String) -> Void

    @State private var selectedPage: OutputPage = .revised
    @State private var copyFeedback: String?
    @State private var isEditingDraft = false
    @State private var editedTitle = ""
    @State private var editedBody = ""
    @State private var showBatchImageConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(output.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    if let copyFeedback {
                        Label(copyFeedback, systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Button {
                        copyPageAction(selectedPage)
                        showCopyFeedback("已复制本页")
                    } label: {
                        Label("复制本页", systemImage: "doc.on.doc")
                    }
                    Menu {
                        Button("复制全部四部分") {
                            copyAllAction()
                            showCopyFeedback("已复制全部")
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("更多复制选项")
                    .help("复制全部四部分")
                }
            }

            Picker("结果分页", selection: $selectedPage) {
                ForEach(OutputPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            ScrollView(.vertical) {
                pageContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.trailing, 8)
            }
            .scrollIndicators(.visible)
            .frame(minHeight: 110, maxHeight: .infinity)
            .contentMargins(.vertical, 2, for: .scrollContent)
            .accessibilityLabel("\(selectedPage.title)内容滚动区")

            Divider()

            HStack {
                Button("上一页", systemImage: "chevron.left") {
                    movePage(by: -1)
                }
                .disabled(selectedPage == .original)

                Spacer()

                Button("下一页", systemImage: "chevron.right") {
                    movePage(by: 1)
                }
                .labelStyle(.titleAndIcon)
                .disabled(selectedPage == .visuals)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workspaceGlassPanel(cornerRadius: 24, elevated: true)
        .animation(.snappy, value: selectedPage)
        .onAppear { selectedPage = .revised }
        .onAppear { resetDraftEditor() }
        .onChange(of: output) { _, _ in
            resetDraftEditor()
        }
        .confirmationDialog(
            "批量生成 \(visualShots.count) 张图片？",
            isPresented: $showBatchImageConfirmation,
            titleVisibility: .visible
        ) {
            Button("开始批量生成") { generateAllImagesAction() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("每张图片都会调用一次当前中转站的图片生成接口，可能产生费用。已经保存到本机的图片会自动跳过。")
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .original:
            resultSection(
                number: "01",
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
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(.top, 8)
            }
            .transition(.opacity)

        case .suggestions:
            resultSection(number: "02", title: "修改建议", subtitle: "原文摘录 · 具体改法") {
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
                number: "03", title: "修改后的完整文稿",
                subtitle: isEditingDraft ? "正在编辑" : "已生成 · 可编辑保存"
            ) {
                if isEditingDraft {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("成稿标题", text: $editedTitle)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $editedBody)
                            .font(.body)
                            .lineSpacing(6)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 320)
                            .padding(10)
                            .workspaceGlassInset(
                                cornerRadius: 16,
                                tint: .accentColor,
                                tintOpacity: 0.055
                            )
                        HStack {
                            Spacer()
                            Button("取消") {
                                resetDraftEditor()
                                isEditingDraft = false
                            }
                            Button("保存修改") {
                                saveDraftAction(editedTitle, editedBody)
                                isEditingDraft = false
                                showCopyFeedback("已保存成稿")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 10) {
                        Button("编辑成稿", systemImage: "square.and.pencil") {
                            resetDraftEditor()
                            isEditingDraft = true
                        }
                        documentCard(output.revisedBody, emphasized: true)
                    }
                }
            }
            .transition(.opacity)

        case .visuals:
            resultSection(number: "04", title: "短视频镜头与配图", subtitle: visualSubtitle) {
                HStack(spacing: 10) {
                    Label(
                        imageGenerationStatus,
                        systemImage: isGeneratingAllImages ? "photo.stack.fill" : "photo.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if isGeneratingAllImages || generatingImageShotID != nil {
                        Button("停止生成", systemImage: "stop.fill", action: cancelImageGenerationAction)
                    } else {
                        Button("导出给 ChatGPT", systemImage: "square.and.arrow.up") {
                            exportImageMarkdownAction()
                        }
                        .disabled(visualShots.isEmpty)
                        .help("把全部提示词按每 10 张一批导出为可续跑的 Markdown 任务文档")
                        Button("批量生成全部", systemImage: "photo.stack") {
                            showBatchImageConfirmation = true
                        }
                        .disabled(!canGenerateImages || visualShots.isEmpty)
                        .help(canGenerateImages ? "逐张调用图片接口；会先要求确认" : "请先在 AI 设置中配置图片生成模型")
                    }
                }
                .padding(12)
                .workspaceGlassInset(
                    cornerRadius: 14,
                    tint: .accentColor,
                    tintOpacity: 0.045
                )

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
                                        generateImageAction(shot.id)
                                    }
                                    .controlSize(.small)
                                    .disabled(!canGenerateImages)
                                    .help(canGenerateImages ? "调用当前图片模型生成这一张图片" : "请先在 AI 设置中配置图片生成模型")
                                    Button("复制提示词", systemImage: "doc.on.doc") {
                                        copyImagePromptAction(shot.prompt)
                                        showCopyFeedback("已复制绘图提示词")
                                    }
                                    .controlSize(.small)
                                }
                                if generatingImageShotID == shot.id {
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
                                            Button("打开图片") { openGeneratedImageAction(path) }
                                                .controlSize(.small)
                                            Button("在访达中显示") { revealGeneratedImageAction(path) }
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
        }
    }

    @ViewBuilder
    private func resultSection<Content: View>(
        number: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(number)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func documentCard(_ text: String, emphasized: Bool = false) -> some View {
        Text(text)
            .textSelection(.enabled)
            .font(.body)
            .lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .workspaceGlassInset(
                cornerRadius: 16,
                tint: emphasized ? .accentColor : .clear,
                tintOpacity: emphasized ? 0.055 : 0
            )
    }

    private func suggestionCell(title: String, text: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(emphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(text)
                .font(.callout)
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

    private var visualSubtitle: String {
        let source = output.visualDesignSource?.label ?? "旧版基础镜头"
        if output.style == .spoken || output.style == .channel {
            return "\(output.effectiveVisualStyle.rawValue) · \(source) · 每 3–5 秒一镜 · 共 \(visualShots.count) 镜"
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

    private var rawSourceDisclosureTitle: String {
        switch output.transcriptOrigin {
        case .webArticle, .socialImageText: "查看净化前取得的网页正文"
        case .localSpeechRecognition, .platformSubtitle: "查看未经校对的原始识别稿"
        case .pastedText: "查看未经校对的原始内容"
        }
    }

    private func showCopyFeedback(_ message: String) {
        withAnimation { copyFeedback = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { copyFeedback = nil }
        }
    }

    private func resetDraftEditor() {
        editedTitle = output.title
        editedBody = output.revisedBody
    }
}
