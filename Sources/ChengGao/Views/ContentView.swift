import SwiftUI

struct ContentView: View {
    @Bindable var store: RewriteStore
    @Bindable var researchStore: ResearchStore
    @SceneStorage("workspace.section") private var section: WorkspaceSection = .compose
    @State private var historyID: UUID?
    @State private var login: WorkspaceLogin?
    @State private var confirmsClear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, selection: $section) { item in
                historyID = item.id
                section = .history
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 208, max: 270)
        } detail: {
            detail
                .navigationTitle(section.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $login) { request in
            switch request {
            case .platform(let platform):
                PlatformLoginSheet(platform: platform, store: researchStore)
                    .onDisappear { researchStore.loginPlatform = nil }
            case .webAI(let provider):
                WebAILoginSheet(provider: provider, store: store)
                    .onDisappear { store.webAILoginProvider = nil }
            }
        }
        .confirmationDialog("清空当前文稿？", isPresented: $confirmsClear) {
            Button("清空素材", role: .destructive, action: store.clearDocument)
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前输入的文字和链接将被移除。已保存的文稿可在“最近处理”中打开。")
        }
        .focusedSceneValue(\.rewriteActions, commands)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .compose:
            ComposerView(store: store, showResult: {
                store.openLatestResult()
                section = .results
            }, showWebLogin: openWebLogin)
        case .results:
            ResultView(store: store) { section = .compose }
        case .research:
            ResearchView(researchStore: researchStore, rewriteStore: store,
                         search: search, showComposer: { section = .compose })
        case .onlineAI:
            WebAILoginView(store: store, presentLogin: openWebLogin)
        case .accounts:
            ResearchAccountsView(store: researchStore, presentLogin: openPlatformLogin)
        case .history:
            HistoryView(store: store, selection: $historyID) { section = .compose }
        }
    }

    private func openWebLogin(_ provider: WebAIProvider) {
        guard store.webAILoginProvider == nil, !store.isProcessing else { return }
        store.webAILoginProvider = provider
        section = .onlineAI
        login = .webAI(provider)
    }

    private func openPlatformLogin(_ platform: ResearchPlatform) {
        guard researchStore.loginPlatform == nil else { return }
        researchStore.beginLogin(platform)
        login = .platform(platform)
    }

    private func search() {
        researchStore.startSearch(onLoginRequired: openPlatformLogin)
    }

    private var commands: RewriteActions {
        let isResearch = section == .research
        let isComposer = section == .compose
        return RewriteActions(
            primaryTitle: isResearch ? "搜索爆款" : "开始处理",
            canStart: isResearch ? researchStore.canSearch : isComposer && store.canProcess,
            canCancel: isResearch ? researchStore.isSearching : (isComposer || section == .results) && store.isProcessing,
            canPaste: isComposer && !store.isProcessing,
            canClear: isComposer && !store.isProcessing && (!store.sourceURL.isEmpty || !store.sourceText.isEmpty),
            start: isResearch ? search : store.startRewrite,
            cancel: isResearch ? researchStore.cancelSearch : store.cancelProcessing,
            clear: { confirmsClear = true }, paste: store.pasteFromClipboard,
            navigate: { destination in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { section = destination }
            }
        )
    }
}

private enum WorkspaceLogin: Hashable, Identifiable {
    case platform(ResearchPlatform)
    case webAI(WebAIProvider)

    var id: Self { self }
}
