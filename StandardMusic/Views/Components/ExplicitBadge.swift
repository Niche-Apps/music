import SwiftUI

/// The little "E" shown after an explicit song's title.
struct ExplicitBadge: View {
    var size: CGFloat = 11

    var body: some View {
        Text("E")
            .font(.system(size: size * 0.72, weight: .bold, design: .rounded))
            .foregroundStyle(.background)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(.secondary))
            .help("Explicit")
            .accessibilityLabel("Explicit")
    }
}

extension View {
    /// Puts an explicit badge after a title, aligned to its baseline.
    func explicitBadge(_ isExplicit: Bool, size: CGFloat = 11) -> some View {
        HStack(alignment: .center, spacing: 5) {
            self
            if isExplicit { ExplicitBadge(size: size).fixedSize() }
        }
    }
}
