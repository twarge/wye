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
                    TextFileView(text: text)
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
                model.error = PresentedError(error)
            }
        }
    }
}

/// Text with line numbers, made a line at a time as it scrolls into view.
private struct TextFileView: View {
    let lines: [Substring]

    init(text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        self.lines = lines
    }

    var body: some View {
        let gutter = CGFloat(String(max(lines.count, 10)).count) * 8 + 6
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(String(index + 1))
                            .foregroundStyle(.tertiary)
                            .frame(width: gutter, alignment: .trailing)
                            .padding(.trailing, 10)
                        Text(lines[index].isEmpty ? " " : String(lines[index]))
                            .fixedSize()
                    }
                    .font(.code)
                    .padding(.vertical, 1)
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }
}

extension CGImage {
    /// The first image in some file data, or `nil` when it is not an image.
    static func decoded(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
