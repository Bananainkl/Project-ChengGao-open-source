import AppKit
import SwiftUI

enum WorkspaceLayout {
    static let detailHorizontalPadding: CGFloat = 24
    static let detailTopPadding: CGFloat = 14
    static let detailBottomPadding: CGFloat = 18
    static let headerContentSpacing: CGFloat = 12
}

enum WorkspaceMotion {
    static func transition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.26, bounce: 0)
    }
}

enum ManuscriptTextSize: String, CaseIterable, Identifiable {
    static let storageKey = "workspace.manuscriptTextSize"
    case small, standard, large, extraLarge

    var id: Self { self }

    var label: String {
        switch self {
        case .small: "小"
        case .standard: "标准"
        case .large: "大"
        case .extraLarge: "特大"
        }
    }

    var font: Font {
        switch self {
        case .small: .system(size: NSFont.systemFontSize - 1)
        case .standard: .body
        case .large: .system(size: NSFont.systemFontSize + 3)
        case .extraLarge: .system(size: NSFont.systemFontSize + 6)
        }
    }

    func adjusted(by offset: Int) -> Self {
        let sizes = Self.allCases
        guard let index = sizes.firstIndex(of: self) else { return self }
        return sizes[min(max(index + offset, 0), sizes.count - 1)]
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func workspaceToolbarPriority(high: Bool) -> some ToolbarContent {
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            visibilityPriority(high ? .high : .low)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    func workspaceMargins() -> some View {
        self
            .padding(.horizontal, WorkspaceLayout.detailHorizontalPadding)
            .padding(.top, WorkspaceLayout.detailTopPadding)
            .padding(.bottom, WorkspaceLayout.detailBottomPadding)
    }
}
