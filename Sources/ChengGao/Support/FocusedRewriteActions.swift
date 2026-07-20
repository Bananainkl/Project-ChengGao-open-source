import SwiftUI

struct RewriteActions {
    let start: () -> Void
    let cancel: () -> Void
    let clear: () -> Void
    let paste: () -> Void
}

private struct RewriteActionsKey: FocusedValueKey {
    typealias Value = RewriteActions
}

extension FocusedValues {
    var rewriteActions: RewriteActions? {
        get { self[RewriteActionsKey.self] }
        set { self[RewriteActionsKey.self] = newValue }
    }
}

struct RewriteCommands: Commands {
    @FocusedValue(\.rewriteActions) private var actions

    var body: some Commands {
        CommandMenu("文稿") {
            Button("开始处理") { actions?.start() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(actions == nil)

            Button("停止处理") { actions?.cancel() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(actions == nil)

            Button("从剪贴板粘贴") { actions?.paste() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(actions == nil)

            Divider()

            Button("清空当前文稿") { actions?.clear() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(actions == nil)
        }
    }
}
