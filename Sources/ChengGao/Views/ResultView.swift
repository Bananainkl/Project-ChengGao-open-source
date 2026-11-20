import SwiftUI

struct ResultView: View {
    @Bindable var store: RewriteStore
    let compose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = store.processingProgress {
                HStack {
                    ProgressView(value: progress.fraction) { Text(progress.message) }
                    Button("停止处理", action: store.cancelProcessing)
                }
                .workspaceMargins()
            }
            if let output = store.latestResultOutput {
                let historyID = store.history.first(where: { $0.output == output })?.id
                OutputView(store: store, output: output, historyID: historyID)
                    .id(historyID)
                    .toolbar {
                        ToolbarItem(placement: .secondaryAction) {
                            Button("重新设计配图提示词", systemImage: "wand.and.stars",
                                   action: store.regenerateLatestVisualPrompts)
                                .disabled(!store.canRegenerateVisualPrompts)
                        }
                        .workspaceToolbarPriority(high: false)
                    }
            } else if !store.isProcessing {
                ContentUnavailableView {
                    Label("还没有处理结果", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("在新建文稿中提交素材，完成后即可校阅、复制或导出成稿。")
                } actions: {
                    Button("前往新建文稿", action: compose)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Spacer()
            }
        }
        .onAppear { store.markResultViewed() }
        .onChange(of: store.hasUnreadResult) { _, unread in
            if unread { store.markResultViewed() }
        }
    }
}
