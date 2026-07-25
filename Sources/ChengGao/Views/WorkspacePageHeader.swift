import SwiftUI

struct WorkspacePageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.title, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
