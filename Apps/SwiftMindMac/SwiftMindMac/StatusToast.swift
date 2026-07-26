import SwiftUI

/// Quiet transient status (Apple: confirm meaningful actions without modal noise).
struct StatusToast: Equatable {
    enum Kind: Equatable {
        case info
        case success
        case error
    }

    var message: String
    var kind: Kind = .info
    var id = UUID()
}

struct StatusToastBanner: View {
    let toast: StatusToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
    }

    private var iconName: String {
        switch toast.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.kind {
        case .info: return .secondary
        case .success: return .green
        case .error: return .orange
        }
    }
}
