import SwiftUI

struct AccountRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let statusText: String
    let statusColor: Color
    var iconColor: Color = .secondary
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)

            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            statusText.isEmpty ? title : "\(title), \(statusText)"
        )
    }
}
