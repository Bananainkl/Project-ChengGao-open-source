import AppKit
import SwiftUI

struct ResultView: View {
    @Bindable var store: RewriteStore
    @Environment(\.openSettings) private var openSettings

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
                .workspaceGlassPanel(cornerRadius: WorkspaceLayout.panelRadiusSmall)
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
                        actions: OutputViewActions(
                            copyPage: { store.copyOutputPage($0, output: output) },
                            copyAll: { store.copyOutput(output) },
                            copyImagePrompt: store.copyImagePrompt,
                            exportImageMarkdown: { store.exportChatGPTImageMarkdown(output) },
                            exportPackage: { store.exportShortVideoPackage(output) },
                            saveDraft: { store.saveEditedDraft(title: $0, revisedBody: $1) },
                            generateImage: { store.generateImage(for: $0, in: output) },
                            generateCover: { store.generateCover($0, in: output) },
                            generateAllImages: { store.generateAllImages(in: output) },
                            cancelImageGeneration: store.cancelImageGeneration,
                            openGeneratedImage: store.openGeneratedImage,
                            revealGeneratedImage: store.revealGeneratedImage
                        ),
                        imageState: ImageGenerationState(
                            shotID: store.generatingImageShotID,
                            coverFormat: store.generatingCoverFormat,
                            isGeneratingAll: store.isGeneratingAllImages
                        ),
                        canGenerateImages: store.canGenerateImages,
                        imageGenerationStatus: store.onlineImageGenerationStatus
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("还没有处理结果", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("前往「新建文稿」粘贴文本或输入链接，开始 AI 改写。处理完成后，成稿会自动保存到这里。")
                } actions: {
                    Button("前往新建文稿") {
                        store.selectedSection = .compose
                    }
                    .buttonStyle(.borderedProminent)
                    Button("打开 AI 设置") {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .workspaceGlassPanel(cornerRadius: WorkspaceLayout.panelRadiusLarge, elevated: true)
            }
        }
        .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
        .padding(.top, WorkspaceLayout.detailTopPadding)
        .padding(.bottom, WorkspaceLayout.detailBottomPadding)
        .onAppear { store.markResultViewed() }
    }
}
