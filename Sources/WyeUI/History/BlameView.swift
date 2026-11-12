import GitKit
import SwiftUI

/// A file with who last changed each line. The gutter names the commit of
/// each run of lines; selecting one picks out all of that commit's lines and
/// offers to show it.
struct BlameView: View {
    var model: RepositoryModel
    var path: String
    var commitID: OID

    @State private var blame: Blame?
    @State private var selection: OID?
    @State private var syntax = TextSyntaxLoader()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if let blame {
                let gutter = CGFloat(String(max(blame.lineCount, 10)).count) * AppearancePreferences.shared.digitWidth + 6
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(blame.runs) { run in
                            // One row per line keeps the stack lazy for a file
                            // that is a single long run.
                            ForEach(run.lines.indices, id: \.self) { offset in
                                BlameLineRow(
                                    run: run,
                                    offset: offset,
                                    numberWidth: gutter,
                                    isCompact: sizeClass == .compact,
                                    isSelected: run.commitID == selection,
                                    tokens: syntax.tokens(forLine: run.startLine - 1 + offset)
                                ) {
                                    selection = selection == run.commitID ? nil : run.commitID
                                }
                                .id(FindRow(group: "", line: run.startLine - 1 + offset))
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .findInLines(blame.runs.flatMap(\.lines))
                .task(id: blame.commitID) { syntax.load(blame.runs.flatMap(\.lines), path: path) }
                .safeAreaInset(edge: .bottom) {
                    if let run = blame.runs.first(where: { $0.commitID == selection }) {
                        SelectedRunBar(run: run, path: path) {
                            model.showInHistory(run.commitID)
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(path.splitPath.name)
        .navigationSubtitle("Blame at \(commitID.abbreviated())")
        .task(id: commitID) {
            do {
                blame = try await model.repository.blame(of: path, at: commitID)
            } catch {
                model.report(error)
            }
        }
    }
}

private struct BlameLineRow: View {
    var run: Blame.Run
    var offset: Int
    var numberWidth: CGFloat
    var isCompact: Bool
    var isSelected: Bool
    var tokens: [SyntaxToken] = []
    var select: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Button(action: select) {
                annotation
                    .frame(width: isCompact ? 110 : 260, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
            .help(offset == 0 ? "\(run.summary)\n\(run.author.nameAndEmail)" : "")
            Text(String(run.startLine + offset))
                .foregroundStyle(.tertiary)
                .frame(width: numberWidth, alignment: .trailing)
                .padding(.horizontal, 8)
            CodeLineText(text: run.lines[offset], tokens: tokens, findRow: FindRow(group: "", line: run.startLine - 1 + offset))
                .fixedSize()
                .padding(.trailing, 12)
        }
        .font(AppearancePreferences.shared.codeFont)
        .padding(.vertical, 1)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
        .overlay(alignment: .top) {
            if offset == 0 {
                Divider()
            }
        }
    }

    /// The run's commit, written beside its first line only.
    @ViewBuilder
    private var annotation: some View {
        if offset == 0 {
            HStack(spacing: 6) {
                Text(run.commitID.abbreviated(to: 7))
                    .foregroundStyle(.secondary)
                if !isCompact {
                    Text(run.summary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(run.author.name)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 80, alignment: .trailing)
                }
            }
            .font(.smallCode)
        } else {
            Text(" ")
                .font(.smallCode)
        }
    }
}

private struct SelectedRunBar: View {
    var run: Blame.Run
    var path: String
    var showCommit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.summary)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(run.commitID.abbreviated()) · \(run.author.name) · \(run.author.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if run.originalPath != path {
                    Text("As \(run.originalPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Show Commit", action: showCommit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
