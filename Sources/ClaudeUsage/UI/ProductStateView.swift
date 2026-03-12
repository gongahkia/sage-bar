import SwiftUI

struct ProductStateCardView: View {
    let card: ProductStateCard
    var onAction: (ProductStateActionKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: card.tone.systemImage)
                    .foregroundColor(card.tone.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.headline)
                    Text(card.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let detail = card.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button(card.primaryAction.title) {
                    onAction(card.primaryAction.kind)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if let secondary = card.secondaryAction {
                    Button(secondary.title) {
                        onAction(secondary.kind)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(card.tone.color.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(card.tone.color.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
