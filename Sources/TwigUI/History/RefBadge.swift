import SwiftUI

/// A branch or tag name, shown beside the commit it points at.
struct RefBadge: View {
    var label: RefLabel

    var body: some View {
        Text(label.name)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: 4))
            .accessibilityLabel(accessibilityLabel)
    }

    private var background: Color {
        switch label.kind {
        case .head: .accentColor
        case .branch: .blue
        case .tag: .yellow
        case .remote: .gray
        }
    }

    private var foreground: Color {
        label.kind == .tag ? .black : .white
    }

    private var accessibilityLabel: String {
        switch label.kind {
        case .head: "HEAD"
        case .branch: "Branch \(label.name)"
        case .tag: "Tag \(label.name)"
        case .remote: "Remote branch \(label.name)"
        }
    }
}
