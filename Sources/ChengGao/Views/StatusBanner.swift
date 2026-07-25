import SwiftUI

struct StatusBanner: View {
    enum Severity {
        case error, warning, success, info

        var color: Color {
            switch self {
            case .error: .red
            case .warning: .orange
            case .success: .green
            case .info: .blue
            }
        }

        var systemImage: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .warning: "exclamationmark.triangle"
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    let message: String
    let severity: Severity
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: severity.systemImage)
                .font(.caption)
                .foregroundStyle(severity.color)
            Spacer()
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(severity.color.opacity(0.08), in: .rect(cornerRadius: WorkspaceLayout.statusRadius))
    }
}
