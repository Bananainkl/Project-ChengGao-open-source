import SwiftUI

struct ResultView: View {
    @Bindable var store: RewriteStore

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.headerContentSpacing) {
            WorkspacePageHeader(title: "处理结果")

            if let progress = store.processingProgress {
                HStack(spacing: 12) {
                    ProgressView(value: progress.fraction)
                        .frame(maxWidth: 220)
                    Text(progress.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("停止", systemImage: "stop.fill") {
                        store.cancelProcessing()
                    }
                }
                .padding(12)
                .workspaceGlassPanel(cornerRadius: 14)
            }

            if let output = store.latestResultOutput {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(
                            output.visualDesignSource?.label ?? "旧版基础镜头",
                            systemImage: "wand.and.stars"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("重新设计配图提示词", systemImage: "wand.and.stars") {
                            store.regenerateLatestVisualPrompts()
                        }
                        .disabled(!store.canRegenerateVisualPrompts)
                        .help("让当前 AI 重新理解每段口播，并设计具体镜头、构图、光线和画面风格")
                    }

                    OutputView(
                        output: output,
                        copyPageAction: { store.copyOutputPage($0, output: output) },
                        copyAllAction: { store.copyOutput(output) },
                        copyImagePromptAction: store.copyImagePrompt,
                        exportImageMarkdownAction: { store.exportChatGPTImageMarkdown(output) },
                        saveDraftAction: { store.saveEditedDraft(title: $0, revisedBody: $1) },
                        canGenerateImages: store.canGenerateImages,
                        imageGenerationStatus: store.onlineImageGenerationStatus,
                        generatingImageShotID: store.generatingImageShotID,
                        isGeneratingAllImages: store.isGeneratingAllImages,
                        generateImageAction: { store.generateImage(for: $0, in: output) },
                        generateAllImagesAction: { store.generateAllImages(in: output) },
                        cancelImageGenerationAction: store.cancelImageGeneration,
                        openGeneratedImageAction: store.openGeneratedImage,
                        revealGeneratedImageAction: store.revealGeneratedImage
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("还没有处理结果", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("请先在“新建文稿”中提交素材。处理完成后，成稿会自动保存到这里。")
                } actions: {
                    Button("前往新建文稿") {
                        store.selectedSection = .compose
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .workspaceGlassPanel(cornerRadius: 22, elevated: true)
            }
        }
        .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
        .padding(.top, WorkspaceLayout.detailTopPadding)
        .padding(.bottom, WorkspaceLayout.detailBottomPadding)
        .onAppear { store.markResultViewed() }
    }
}
