import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ChengGaoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = RewriteStore()
    @State private var researchStore = ResearchStore()

    var body: some Scene {
        WindowGroup("澄稿", id: "main") {
            ContentView(store: store, researchStore: researchStore)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1_180, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            RewriteCommands()
        }

        Settings {
            SettingsView(store: store)
        }
    }
}
