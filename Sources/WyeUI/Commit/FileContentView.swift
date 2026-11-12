import GitKit
import ImageIO
import SwiftUI

/// A file as it is at a commit: text with line numbers, or an image.
struct FileContentView: View {
    var model: RepositoryModel
    var path: String
    var commitID: OID

    @State private var content: FileContent?
    @Environment(\.openCommitRoute) private var open

    var body: some View {
        Group {
            if let content {
                switch content.contents {
                case .text(let text):
                    TextFileView(text: text, path: path)
                case .binary(let data):
                    if let image = CGImage.decoded(from: data) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(decorative: image, scale: 1)
                                .padding()
                        }
                    } else {
                        ContentUnavailableView("Binary File", systemImage: "doc",
                                               description: Text(content.size.formatted(.byteCount(style: .file))))
                    }
                case .tooLarge:
                    ContentUnavailableView("File Too Large to Show", systemImage: "doc",
                                           description: Text(content.size.formatted(.byteCount(style: .file))))
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(path.splitPath.name)
        .navigationSubtitle(commitID.abbreviated())
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("History", systemImage: "clock.arrow.circlepath") {
                    open(.fileHistory(path: path, commit: commitID))
                }
                .help("Show the commits that changed this file")
                if case .text = content?.contents {
                    Button("Blame", systemImage: "person.text.rectangle") {
                        open(.blame(path: path, commit: commitID))
                    }
                    .help("Show who last changed each line")
                }
            }
        }
        .task(id: commitID) {
            do {
                content = try await model.repository.fileContent(at: path, in: commitID)
            } catch {
                model.report(error)
            }
        }
    }
}

/// Text with line numbers, made a line at a time as it scrolls into view.
private struct TextFileView: View {
    let lines: [String]
    /// For the syntax colours, chosen by the file's name.
    let path: String
    @State private var syntax = TextSyntaxLoader()

    init(text: String, path: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        self.lines = lines
        self.path = path
    }

    var body: some View {
        let gutter = CGFloat(String(max(lines.count, 10)).count) * AppearancePreferences.shared.digitWidth + 6
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(String(index + 1))
                            .foregroundStyle(.tertiary)
                            .frame(width: gutter, alignment: .trailing)
                            .padding(.trailing, 10)
                        CodeLineText(text: lines[index], tokens: syntax.tokens(forLine: index), findRow: FindRow(group: "", line: index))
                            .fixedSize()
                    }
                    .font(AppearancePreferences.shared.codeFont)
                    .padding(.vertical, 1)
                    .id(FindRow(group: "", line: index))
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .findInLines(lines)
        .task(id: lines) { syntax.load(lines, path: path) }
    }
}

extension CGImage {
    /// The first image in some file data, or `nil` when it is not an image.
    static func decoded(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
