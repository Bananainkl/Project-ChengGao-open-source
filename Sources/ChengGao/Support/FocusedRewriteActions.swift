import SwiftUI

struct RewriteActions {
    let primaryTitle: String
    let canStart: Bool
    let canCancel: Bool
    let canPaste: Bool
    let canClear: Bool
    let start: () -> Void
    let cancel: () -> Void
    let clear: () -> Void
    let paste: () -> Void
    let navigate: (WorkspaceSection) -> Void
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
    @AppStorage(ManuscriptTextSize.storageKey) private var textSize = ManuscriptTextSize.standard

    var body: some Commands {
        CommandMenu("文稿") {
            Button(actions?.primaryTitle ?? "开始处理") { actions?.start() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.canStart != true)
            Button("取消当前任务") { actions?.cancel() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(actions?.canCancel != true)
            Divider()
            Button("从剪贴板粘贴素材") { actions?.paste() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(actions?.canPaste != true)
            Button("清空当前文稿…") { actions?.clear() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.canClear != true)
        }
        CommandMenu("前往") {
            ForEach(Array(WorkspaceSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { actions?.navigate(section) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(actions == nil)
            }
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("放大文稿文字") { textSize = textSize.adjusted(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(textSize == .extraLarge)
            Button("缩小文稿文字") { textSize = textSize.adjusted(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(textSize == .small)
            Button("恢复标准文稿字号") { textSize = .standard }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(textSize == .standard)
        }
    }
}
