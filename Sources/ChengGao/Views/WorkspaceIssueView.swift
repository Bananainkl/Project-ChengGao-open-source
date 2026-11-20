import SwiftUI

/// Keeps the recovery action reachable even when a service returns an entire error page.
struct WorkspaceIssueView: View {
    let message: String
    var isWarning = false
    @State private var showsDetails = false

    private var summary: String {
        let firstLine = message.prefix { !$0.isNewline && $0 != "<" }.trimmingCharacters(in: .whitespaces)
        guard !firstLine.isEmpty else { return isWarning ? "部分素材需要进一步检查。" : "服务未能完成请求。" }
        if firstLine.count <= 76 { return firstLine }
        let sentence = firstLine.prefix { !"。；：".contains($0) }
        return sentence.isEmpty || sentence.count > 76 ? "请查看服务返回的详细信息。" : String(sentence)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(summary, systemImage: isWarning ? "exclamationmark.triangle" : "exclamationmark.octagon")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if summary != message {
                Button("查看详情") { showsDetails = true }
                    .popover(isPresented: $showsDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("服务详情").font(.headline)
                                Spacer()
                                Button("完成") { showsDetails = false }
                            }
                            ScrollView {
                                Text(message).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .frame(width: 380, height: 250)
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
