import SwiftUI

struct ContentView: View {
    @Bindable var store: RewriteStore
    @Bindable var researchStore: ResearchStore

    var body: some View {
        GeometryReader { _ in
            ZStack {
                WorkspaceAmbientBackground()
                    .ignoresSafeArea()

                NavigationSplitView {
                    SidebarView(store: store)
                        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
                } detail: {
                    Group {
                        switch store.selectedSection {
                        case .compose:
                            ComposerView(store: store)
                        case .results:
                            ResultView(store: store)
                        case .research:
                            ResearchView(researchStore: researchStore, rewriteStore: store)
                        case .onlineAI:
                            WebAILoginView(store: store)
                        case .accounts:
                            ResearchAccountsView(store: researchStore)
                        case .history:
                            HistoryView(store: store)
                        }
                    }
                }
                .background(.clear)
            }
        }
        .containerBackground(.clear, for: .window)
        .background {
            WindowGlassConfigurator()
                .frame(width: 0, height: 0)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .focusedSceneValue(
            \.rewriteActions,
            RewriteActions(
                start: store.startRewrite,
                cancel: store.cancelProcessing,
                clear: store.clearDocument,
                paste: store.pasteFromClipboard
            )
        )
    }

}
