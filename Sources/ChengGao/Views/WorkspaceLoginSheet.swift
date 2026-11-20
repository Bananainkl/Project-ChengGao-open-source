import SwiftUI

/// Common window chrome around the provider's actual WebKit login page.
struct WorkspaceLoginSheet<WebContent: View>: View {
    let title: String
    let state: String
    let authenticated: Bool
    let confirmationTitle: String
    let confirm: () -> Void
    @ViewBuilder let webContent: () -> WebContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("请在下方网页输入密码、扫码或完成平台验证。登录凭证由网页管理。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            webContent()
            Divider()
            HStack {
                Label(state, systemImage: authenticated ? "checkmark.circle" : "clock")
                    .font(.callout)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmationTitle) { confirm(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!authenticated)
            }
            .padding(14)
        }
        .frame(minWidth: 480, idealWidth: 740, minHeight: 360, idealHeight: 510)
    }
}
