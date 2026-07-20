import SwiftUI

struct SidebarView: View {
    @Bindable var store: RewriteStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("澄稿")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .accessibilityAddTraits(.isHeader)

            List(selection: $store.selectedSection) {
                Section("工作区") {
                    ForEach(WorkspaceSection.allCases) { section in
                        HStack {
                            Label(section.title, systemImage: section.systemImage)
                            Spacer()
                            if section == .results, store.hasUnreadResult {
                                Circle()
                                    .fill(.tint)
                                    .frame(width: 7, height: 7)
                                    .accessibilityLabel("有新的处理结果")
                            }
                        }
                            .tag(section)
                    }
                }

                if !store.history.isEmpty {
                    Section("最近") {
                        ForEach(store.history.prefix(5)) { item in
                            Button {
                                store.selectHistory(item)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.style.systemImage)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .lineLimit(1)
                                        Text(item.createdAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(.rect)
                            .accessibilityHint("打开这篇文稿的完整处理结果")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                    Text(store.privacySummary)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 0.5)
                .allowsHitTesting(false)
        }
    }
}
