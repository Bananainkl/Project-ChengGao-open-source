import SwiftUI

struct WorkspacePageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
