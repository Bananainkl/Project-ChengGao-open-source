import SwiftUI

struct SidebarView: View {
    @Bindable var store: RewriteStore
    @Binding var selection: WorkspaceSection
    let selectRecent: (RewriteHistoryItem) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("工作台") { destinations([.compose, .results, .research]) }
            Section("连接") { destinations([.onlineAI, .accounts]) }
            Section("资料库") {
                destinations([.history])
                ForEach(store.history.prefix(5)) { item in
                    Button { selectRecent(item) } label: {
                        Label {
                            Text(item.title).lineLimit(2)
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(item.title) · \(LocalizedRelativeDate.string(from: item.createdAt))")
                    .accessibilityLabel("打开文稿，\(item.title)")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("澄稿")
        .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .help("打开澄稿设置（⌘,）")
        }
    }

    private func destinations(_ sections: [WorkspaceSection]) -> some View {
        ForEach(sections) { section in
            Label(section.title, systemImage: section.systemImage)
                .badge(section == .results && store.hasUnreadResult ? 1 : 0)
                .tag(section)
        }
    }
}
