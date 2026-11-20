import SwiftUI

struct DraftEditorSheet: View {
    let originalTitle: String
    let originalBody: String
    let save: (String, String) -> Void

    @State private var title: String
    @State private var draft: String
    @State private var confirmsDiscard = false
    @FocusState private var isBodyFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ManuscriptTextSize.storageKey) private var textSize = ManuscriptTextSize.standard

    init(title: String, body: String, save: @escaping (String, String) -> Void) {
        originalTitle = title
        originalBody = body
        self.save = save
        _title = State(initialValue: title)
        _draft = State(initialValue: body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑成稿").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            LabeledContent("成稿标题") {
                TextField("成稿标题", text: $title)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $draft)
                .font(textSize.font)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(8)
                .focused($isBodyFocused)
                .workspaceEditorSurface(focused: isBodyFocused)
                .accessibilityLabel("成稿正文")
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("保存修改") {
                    save(title, draft)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 620, minHeight: 340, idealHeight: 480)
        .defaultFocus($isBodyFocused, true)
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmsDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    private var hasChanges: Bool {
        title != originalTitle || draft != originalBody
    }

    private func cancel() {
        if hasChanges { confirmsDiscard = true } else { dismiss() }
    }
}
