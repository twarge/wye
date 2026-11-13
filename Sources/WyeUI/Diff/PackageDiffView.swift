import GitKit
import SwiftUI

/// A document package's change, above the first of its changed files: a
/// header that folds it, then a picture of the package before and after
/// from Quick Look. Shows nothing when Quick Look has no picture of it,
/// as for a package type no app previews.
struct PackageDiffSection: View {
    var package: PackageChange
    /// Shown before the name, such as "Staged".
    var caption: String?

    @Environment(\.diffRepository) private var repository
    @State private var isCollapsed = false
    @State private var isUnavailable = false

    var body: some View {
        if !isUnavailable, !QuickLookTypes.hasNoPreview(QuickLookTypes.key(for: package.name, isFolder: true)) {
            header
            if !isCollapsed {
                VisualDiffView(subject: .package(package)) {
                    isUnavailable = true
                }
            }
        }
    }

    private var header: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(isCollapsed ? .zero : .degrees(90))
                FileChangeBadge(change: package.change)
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .foregroundStyle(.secondary)
                }
                Text(package.change == .renamed ? "\(package.oldPath) → \(package.name)" : package.name)
                    .font(.code)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Group {
                    if package.files.count == 1 {
                        Text("1 file changed")
                    } else {
                        Text("\(package.files.count.formatted()) files changed")
                    }
                }
                .foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("A preview of the whole package, which its changed files below are part of")
        .contextMenu {
            DiffQuickLookButtons(old: package.oldItem, new: package.newItem, name: package.name)
        }
        .fileDrag(dragged)
        .background(.fill.tertiary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Package \(package.name), \(package.change.title)")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .padding(.top, 10)
    }

    /// The package as the new side has it, or the old where it is gone.
    private var dragged: FileDrag? {
        guard let repository, let item = package.newItem ?? package.oldItem else { return nil }
        return FileDrag(repository: repository, path: item.path, source: item.source, isFolder: true)
    }
}

extension PackageChange {
    /// The package on the old side, where it was there.
    var oldItem: PreviewItem? {
        change == .added ? nil : oldSource.map { PreviewItem(path: oldPath, source: $0) }
    }

    /// The package on the new side, where it is still there.
    var newItem: PreviewItem? {
        change == .deleted ? nil : newSource.map { PreviewItem(path: path, source: $0) }
    }
}

extension FileDiff {
    /// The file on the old side, where it was there.
    var oldItem: PreviewItem? {
        change == .added || change == .untracked ? nil : oldSource.map { PreviewItem(path: oldPath, source: $0) }
    }

    /// The file on the new side, where it is still there.
    var newItem: PreviewItem? {
        change == .deleted ? nil : newSource.map { PreviewItem(path: path, source: $0) }
    }

    /// The file as the new side has it, or the old where it is gone, to drag out.
    func drag(in repository: Repository?) -> FileDrag? {
        guard let repository, submodule == nil, let item = newItem ?? oldItem else { return nil }
        return FileDrag(repository: repository, path: item.path, source: item.source)
    }
}

/// Quick Look for the two sides of a change, offered from a header's menu:
/// the panel opens at the new side, with the old a step away.
struct DiffQuickLookButtons: View {
    var old: PreviewItem?
    var new: PreviewItem?
    /// Named in the items when the menu is about something else, such as
    /// the package a file is in.
    var name: String?

    @Environment(\.quickLook) private var quickLook
    @Environment(\.diffRepository) private var repository

    private var title: LocalizedStringKey {
        if let name { "Quick Look “\(name)”" } else { "Quick Look" }
    }

    var body: some View {
        if let quickLook, let repository {
            let items = [old, new].compactMap(\.self)
            Section {
                if new != nil {
                    Button(title, systemImage: "eye") {
                        quickLook.open(items, selected: items.count - 1, in: repository)
                    }
                }
                if old != nil {
                    Button(new == nil ? title : "Quick Look Before", systemImage: new == nil ? "eye" : "clock.arrow.circlepath") {
                        quickLook.open(items, selected: 0, in: repository)
                    }
                }
            }
        }
    }
}
