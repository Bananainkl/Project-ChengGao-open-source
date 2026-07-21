import SwiftUI

struct HistoryView: View {
    @Bindable var store: RewriteStore

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.headerContentSpacing) {
            WorkspacePageHeader(title: "最近处理")
            Group {
                if let item = store.selectedHistoryItem {
                    historyDetail(item)
                } else if store.history.isEmpty {
                    ContentUnavailableView(
                        "还没有处理记录",
                        systemImage: "clock",
                        description: Text("完成第一篇文稿后，记录会保存在这里。")
                    )
                } else {
                    historyList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
        .padding(.top, WorkspaceLayout.detailTopPadding)
        .padding(.bottom, WorkspaceLayout.detailBottomPadding)
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("共 \(store.history.count) 篇 · 自动保留最近 50 篇")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)

            Divider()

            List(selection: $store.selectedHistoryID) {
                ForEach(store.history) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.style.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline).lineLimit(1)
                            Text(item.style.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.createdAt, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                    .tag(item.id)
                    .accessibilityHint("打开完整处理结果")
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
        .workspaceGlassPanel(cornerRadius: 18, elevated: true)
    }

    private func historyDetail(_ item: RewriteHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("返回最近处理", systemImage: "chevron.left") {
                store.closeHistoryDetail()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])

            OutputView(
                output: item.output,
                copyPageAction: { store.copyOutputPage($0, output: item.output) },
                copyAllAction: { store.copyOutput(item.output) },
                copyImagePromptAction: store.copyImagePrompt,
                exportImageMarkdownAction: { store.exportChatGPTImageMarkdown(item.output) },
                exportPackageAction: { store.exportShortVideoPackage(item.output) },
                saveDraftAction: {
                    store.saveEditedDraft(title: $0, revisedBody: $1, historyID: item.id)
                },
                canGenerateImages: store.canGenerateImages,
                imageGenerationStatus: store.onlineImageGenerationStatus,
                generatingImageShotID: store.generatingImageShotID,
                isGeneratingAllImages: store.isGeneratingAllImages,
                generateImageAction: { store.generateImage(for: $0, in: item.output, historyID: item.id) },
                generateAllImagesAction: { store.generateAllImages(in: item.output, historyID: item.id) },
                cancelImageGenerationAction: store.cancelImageGeneration,
                openGeneratedImageAction: store.openGeneratedImage,
                revealGeneratedImageAction: store.revealGeneratedImage
            )
        }
        .frame(maxWidth: 940, maxHeight: .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
