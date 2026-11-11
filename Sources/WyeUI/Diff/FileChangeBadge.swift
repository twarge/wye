import GitKit
import SwiftUI

/// A one-letter badge for how a file changed.
struct FileChangeBadge: View {
    var change: FileChange

    var body: some View {
        Text(letter)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(color, in: .rect(cornerRadius: 4))
            .accessibilityLabel(change.title)
    }

    private var letter: String {
        switch change {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "?"
        case .conflicted: "!"
        }
    }

    private var color: Color {
        switch change {
        case .added: .green
        case .modified: .blue
        case .deleted: .red
        case .renamed, .copied: .purple
        case .typeChanged: .teal
        case .untracked: .gray
        case .conflicted: .orange
        }
    }
}

extension FileChange {
    var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }
}
