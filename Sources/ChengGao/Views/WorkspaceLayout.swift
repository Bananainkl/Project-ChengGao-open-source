import SwiftUI

enum WorkspaceLayout {
    static let detailHorizontalPadding: CGFloat = 24
    static let detailTopPadding: CGFloat = 14
    static let detailBottomPadding: CGFloat = 18
    static let headerContentSpacing: CGFloat = 12
}

extension View {
    func workspaceMargins() -> some View {
        self
            .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
            .padding(.top, WorkspaceLayout.detailTopPadding)
            .padding(.bottom, WorkspaceLayout.detailBottomPadding)
    }
}
