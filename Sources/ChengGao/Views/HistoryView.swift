import SwiftUI

struct HistoryView: View {
    @Bindable var store: RewriteStore
    @Binding var selection: UUID?
    let compose: () -> Void
    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var matches: [RewriteHistoryItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.history.filter { term.isEmpty || $0.title.localizedStandardContains(term) }
    }

    var body: some View {
        if let item = store.history.first(where: { $0.id == selection }) {
            historyDetail(item)
                .id(item.id)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button("返回最近处理", systemImage: "chevron.left") { selection = nil }
                            .keyboardShortcut("[", modifiers: .command)
                    }
                }
        } else if store.history.isEmpty {
            ContentUnavailableView {
                Label("还没有文稿记录", systemImage: "clock")
            } description: {
                Text("完成改写后，可在这里找回文稿、分镜与导出文件。")
            } actions: {
                Button("新建文稿", action: compose)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("共 \(store.history.count) 篇 · 保留最近 50 篇")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(matches) { item in
                        Button {
                            withAnimation(WorkspaceMotion.transition(reduceMotion: reduceMotion)) { selection = item.id }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: item.style.systemImage)
                                    .foregroundStyle(.tint)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                                    Text(item.style.rawValue).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(LocalizedRelativeDate.string(from: item.createdAt))
                                    .font(.callout).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 7)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("打开文稿、分镜和导出操作")
                    }
                    .listStyle(.inset)
                }
            }
            .workspaceMargins()
            .searchable(text: $query, placement: .toolbar, prompt: "查找文稿标题")
        }
    }

    private func historyDetail(_ item: RewriteHistoryItem) -> some View {
        OutputView(
            store: store, output: item.output, historyID: item.id
        )
    }
}
