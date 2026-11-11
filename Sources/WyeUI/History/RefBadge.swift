import SwiftUI

/// A branch or tag name, shown beside the commit it points at. A local
/// branch whose remote branch is at the same commit shows a cloud in front
/// of its name, standing for that remote branch, rather than a second badge.
struct RefBadge: View {
    var label: RefLabel

    var body: some View {
        HStack(spacing: 0) {
            if !label.remotes.isEmpty {
                remoteSegment
                // A short rule, well inside the badge's height, so the two
                // parts read as one name with a qualifier.
                Capsule()
                    .fill(foreground.opacity(0.5))
                    .frame(width: 1, height: 7)
                    .padding(.horizontal, 3.5)
                    .accessibilityHidden(true)
            }
            Text(label.name)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .foregroundStyle(foreground)
        .background {
            if label.kind == .head {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.secondary, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(background)
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.spokenDescription)
    }

    /// One cloud per remote, or a cloud and a count when there are more
    /// than two: the badge stays short.
    private var remoteSegment: some View {
        HStack(spacing: 1) {
            if label.remotes.count <= 2 {
                ForEach(label.remotes, id: \.self) { _ in cloud }
            } else {
                cloud
                Text(label.remotes.count.formatted())
                    .monospacedDigit()
            }
        }
        .help("Also \(label.remotes.formatted(.list(type: .and))), at the same commit")
    }

    private var cloud: some View {
        Image(systemName: "cloud.fill")
            .imageScale(.small)
    }

    private var help: String {
        switch label.kind {
        case .head: "HEAD is detached at this commit"
        default: label.name
        }
    }

    private var background: Color {
        switch label.kind {
        case .head: .clear
        case .branch: .blue
        case .tag: .yellow
        case .remote: .gray
        }
    }

    private var foreground: Color {
        switch label.kind {
        case .head: .secondary
        case .tag: .black
        case .branch, .remote: .white
        }
    }
}
