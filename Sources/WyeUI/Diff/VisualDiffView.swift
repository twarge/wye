import CoreGraphics
import GitKit
import ImageIO
import SwiftUI

extension EnvironmentValues {
    /// The repository whose diffs are shown, for the views that read more
    /// of a file than its diff holds, such as an image's two sides.
    @Entry var diffRepository: Repository?
}

/// A change shown as pictures: what a file looked like before and after,
/// side by side, with a slider that swipes one over the other, or one faded
/// over the other. An added or deleted file shows its one side.
///
/// Wye draws image files itself. Any other file, and a document package,
/// Quick Look draws, by the extensions Finder uses, including those apps
/// install for their own files; where it has nothing better than the
/// file's icon, the view says so through `onUnavailable`.
struct VisualDiffView: View {
    enum Subject: Hashable, Sendable {
        /// An image file, which Wye decodes.
        case image(FileDiff)
        /// A file that is not text, which Quick Look may have a picture of,
        /// such as a PDF, a Keynote presentation or a font.
        case quickLook(FileDiff)
        /// A document package, written out whole on each side.
        case package(PackageChange)
    }

    var subject: Subject
    /// Called when Quick Look has no picture of either side.
    var onUnavailable: (() -> Void)?

    @Environment(\.diffRepository) private var repository
    @Environment(\.quickLook) private var quickLook
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: Loaded?
    @State private var failure: String?
    @State private var isUnavailable = false
    @State private var mode = Mode.sideBySide
    @State private var split = 0.5
    @State private var opacity = 0.5

    /// Image sides larger than this are measured but not read.
    static let sizeLimit = 32 << 20
    /// The size Quick Look is asked to draw each side at, in points.
    static let quickLookSize = CGSize(width: 900, height: 900)

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico", "icns", "avif", "pdf"
    ]

    /// How a changed file is shown as pictures, if it is: an image the
    /// system can decode, drawn by Wye; any other file that is not text,
    /// by Quick Look, where it has a picture of that kind of file. SVG is
    /// text, and shows as a text diff.
    static func subject(for file: FileDiff) -> Subject? {
        guard file.isBinary, file.submodule == nil else { return nil }
        if imageExtensions.contains((file.path as NSString).pathExtension.lowercased()) {
            return .image(file)
        }
        guard file.oldItem != nil || file.newItem != nil,
              !QuickLookTypes.hasNoPreview(QuickLookTypes.key(for: file.path, isFolder: false)) else { return nil }
        return .quickLook(file)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case swipe = "Swipe"
        case onionSkin = "Onion Skin"

        var id: Self { self }
    }

    struct Side: @unchecked Sendable {
        /// `nil` when the side is too large to read, or can't be drawn.
        var image: CGImage?
        /// Pixels to a point: 1 for an image file, the screen's for Quick Look.
        var scale: CGFloat = 1
        var byteSize: Int
        var isTooLarge: Bool
        /// The copy Quick Look drew, which its panel can show in full.
        var url: URL?

        var pixelSize: CGSize? {
            image.map { CGSize(width: $0.width, height: $0.height) }
        }

        var pointSize: CGSize? {
            pixelSize.map { CGSize(width: $0.width / scale, height: $0.height / scale) }
        }
    }

    struct Loaded: Sendable {
        var old: Side?
        var new: Side?
        /// What the copies for Quick Look were written into, kept while
        /// they show.
        var folder: PreviewFolder?
    }

    var body: some View {
        if isUnavailable {
            if case .quickLook = subject {
                Text("Binary file")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let loaded {
                    if loaded.old != nil, loaded.new != nil {
                        Picker("Compare", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    content(loaded)
                } else if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: subject) { await load() }
        }
    }

    private var isImage: Bool {
        if case .image = subject { true } else { false }
    }

    private var maximumHeight: CGFloat {
        isImage ? 320 : 440
    }

    @ViewBuilder
    private func content(_ loaded: Loaded) -> some View {
        switch (loaded.old, loaded.new) {
        case (let old?, let new?):
            switch mode {
            case .sideBySide:
                HStack(alignment: .top, spacing: 12) {
                    pane(old, title: "Before", in: loaded)
                    pane(new, title: "After", in: loaded)
                }
            case .swipe:
                stacked(old, new, in: loaded) { size in
                    // The new side shows to the left of the line, the old to its right.
                    ImageLayer(side: new)
                        .frame(width: size.width, height: size.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: size.width * split)
                        }
                    Rectangle()
                        .fill(.tint)
                        .frame(width: 2, height: size.height)
                        .position(x: size.width * split, y: size.height / 2)
                }
                Slider(value: $split, in: 0...1) {
                    Text("Swipe")
                } minimumValueLabel: {
                    Text("Before").font(.caption)
                } maximumValueLabel: {
                    Text("After").font(.caption)
                }
                .frame(maxWidth: 360)
            case .onionSkin:
                stacked(old, new, in: loaded) { _ in
                    ImageLayer(side: new)
                        .opacity(opacity)
                }
                Slider(value: $opacity, in: 0...1) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Text("Before").font(.caption)
                } maximumValueLabel: {
                    Text("After").font(.caption)
                }
                .frame(maxWidth: 360)
            }
        case (let old?, nil):
            pane(old, title: "Deleted", in: loaded)
        case (nil, let new?):
            pane(new, title: "Added", in: loaded)
        case (nil, nil):
            (isImage ? Text("Neither side of this image can be read") : Text("Neither side can be read"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func pane(_ side: Side, title: LocalizedStringKey, in loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if side.image != nil {
                ImageLayer(side: side)
                    .background { Checkerboard() }
                    .frame(maxWidth: maximumSize(side).width, maxHeight: maximumHeight, alignment: .leading)
            } else {
                Text(missingPicture(side))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                caption(side)
                quickLookButton(for: side, in: loaded)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func missingPicture(_ side: Side) -> LocalizedStringKey {
        if side.isTooLarge { return "Too large to show" }
        return isImage ? "Can’t be shown as an image" : "No preview"
    }

    /// Both sides in one box, the new drawn over the old by `top`.
    private func stacked<Top: View>(
        _ old: Side, _ new: Side, in loaded: Loaded, @ViewBuilder top: @escaping (CGSize) -> Top
    ) -> some View {
        let sizes = [old, new].filter { $0.image != nil }.map(maximumSize)
        let width = sizes.map(\.width).max() ?? 1
        let height = sizes.map(\.height).max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack {
                    Checkerboard()
                    ImageLayer(side: old)
                    top(proxy.size)
                }
            }
            .aspectRatio(width / max(height, 1), contentMode: .fit)
            .frame(maxWidth: min(width, 900), maxHeight: maximumHeight, alignment: .leading)
            .clipped()
            HStack(spacing: 16) {
                Text("Before: \(describe(old))")
                Text("After: \(describe(new))")
                quickLookButton(for: new, in: loaded)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// How large a side may be drawn: an image file up to twice its size,
    /// so small ones are seen; a Quick Look picture at its own.
    private func maximumSize(_ side: Side) -> CGSize {
        guard let size = side.pointSize else { return .zero }
        return isImage ? CGSize(width: size.width * 2, height: size.height * 2) : size
    }

    private func caption(_ side: Side) -> some View {
        Text(describe(side))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func describe(_ side: Side) -> String {
        let bytes = side.byteSize.formatted(.byteCount(style: .file))
        guard isImage, let size = side.pixelSize else { return bytes }
        return "\(Int(size.width).formatted()) × \(Int(size.height).formatted()) px · \(bytes)"
    }

    /// Opens the copies in the Quick Look panel, at this side, with the
    /// other side a step away, where they can be read in full.
    @ViewBuilder
    private func quickLookButton(for side: Side, in loaded: Loaded) -> some View {
        if let quickLook, let url = side.url {
            Button("Quick Look", systemImage: "eye") {
                let urls = [loaded.old?.url, loaded.new?.url].compactMap(\.self)
                quickLook.show(urls, selected: url, keeping: loaded.folder)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Show both sides in Quick Look")
        }
    }

    // MARK: Loading

    private func load() async {
        loaded = nil
        failure = nil
        guard let repository else {
            failure = String(localized: "The file can’t be read here")
            return
        }
        switch subject {
        case .image(let file):
            await loadImage(file, from: repository)
        case .quickLook(let file):
            await loadQuickLook(
                old: file.oldItem, new: file.newItem, key: QuickLookTypes.key(for: file.path, isFolder: false),
                from: repository
            )
        case .package(let package):
            await loadQuickLook(
                old: package.oldItem, new: package.newItem, key: QuickLookTypes.key(for: package.name, isFolder: true),
                from: repository
            )
        }
    }

    private func loadImage(_ file: FileDiff, from repository: Repository) async {
        do {
            let sides = try await repository.sides(of: file, limit: Self.sizeLimit)
            let path = file.path
            let decoded = await Task.detached(priority: .userInitiated) {
                Loaded(old: sides.old.map { Self.decode($0, path: path) }, new: sides.new.map { Self.decode($0, path: path) })
            }.value
            guard !Task.isCancelled else { return }
            loaded = decoded
        } catch {
            failure = error.localizedDescription
        }
    }

    private nonisolated static func decode(_ side: DiffSides.Side, path: String) -> Side {
        guard let data = side.data else { return Side(image: nil, byteSize: side.size, isTooLarge: true) }
        let image = path.lowercased().hasSuffix(".pdf") ? CGImage.firstPage(ofPDF: data) : CGImage.decoded(from: data)
        return Side(image: image, byteSize: side.size, isTooLarge: false)
    }

    /// Writes each side out where Quick Look can read it, under the file's
    /// own name, then has both drawn at once.
    private func loadQuickLook(old: PreviewItem?, new: PreviewItem?, key: String, from repository: Repository) async {
        guard !QuickLookTypes.hasNoPreview(key) else {
            setUnavailable()
            return
        }
        do {
            let folder = try PreviewFolder()
            let repositoryName = repository.url.lastPathComponent
            let scale = displayScale
            func location(_ item: PreviewItem, in subfolder: String) -> URL {
                folder.location(of: PreviewFiles.fileName(for: item.path, repositoryName: repositoryName), in: subfolder)
            }
            // One after the other, as the repository reads one thing at a time.
            var oldCopy: Copy?
            if let old {
                oldCopy = try await Self.write(old, to: location(old, in: "Before"), from: repository)
            }
            guard !Task.isCancelled else { return }
            var newCopy: Copy?
            if let new {
                newCopy = try await Self.write(new, to: location(new, in: "After"), from: repository)
            }
            guard !Task.isCancelled else { return }
            async let oldSide = Self.draw(oldCopy, scale: scale)
            async let newSide = Self.draw(newCopy, scale: scale)
            let sides = await (old: oldSide, new: newSide)
            guard !Task.isCancelled else { return }
            let present = [sides.old, sides.new].compactMap(\.self)
            // Only what Quick Look really drew counts: no picture of either
            // side means the file's type has none.
            if present.allSatisfy({ $0.image == nil && !$0.isTooLarge }) {
                if !present.isEmpty { QuickLookTypes.setHasNoPreview(key) }
                setUnavailable()
                return
            }
            loaded = Loaded(old: sides.old, new: sides.new, folder: folder)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func setUnavailable() {
        isUnavailable = true
        onUnavailable?()
    }

    /// A side written out: where, and how large; `nil` when the side has
    /// nothing there.
    private struct Copy: Sendable {
        var url: URL?
        var size: Int
        var isTooLarge: Bool
    }

    private nonisolated static func write(_ item: PreviewItem, to url: URL, from repository: Repository) async throws -> Copy? {
        do {
            guard let written = try await repository.export(
                item.path, from: item.source, to: url, limit: PreviewFiles.sizeLimit
            ) else { return nil }
            return Copy(url: written.url, size: written.size, isTooLarge: false)
        } catch is ExportTooLarge {
            return Copy(url: nil, size: PreviewFiles.sizeLimit, isTooLarge: true)
        }
    }

    private nonisolated static func draw(_ copy: Copy?, scale: CGFloat) async -> Side? {
        guard let copy else { return nil }
        guard let url = copy.url else { return Side(image: nil, byteSize: copy.size, isTooLarge: copy.isTooLarge) }
        let image = await QuickLookThumbnail.make(for: url, size: quickLookSize, scale: scale)
        return Side(image: image, scale: scale, byteSize: copy.size, isTooLarge: false, url: image == nil ? nil : url)
    }
}

/// One side's picture, fitted to the space it is given.
private struct ImageLayer: View {
    var side: VisualDiffView.Side

    var body: some View {
        if let image = side.image {
            Image(decorative: image, scale: side.scale)
                .resizable()
                // Pixel art and icons stay sharp when shown larger.
                .interpolation(image.width < 128 ? .none : .high)
                .aspectRatio(contentMode: .fit)
        }
    }
}

/// The grey squares that show where an image is transparent.
private struct Checkerboard: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 8
            let light = Color(white: scheme == .dark ? 0.32 : 1)
            let dark = Color(white: scheme == .dark ? 0.22 : 0.85)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            var path = Path()
            for row in 0..<Int((size.height / square).rounded(.up)) {
                for column in 0..<Int((size.width / square).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(path, with: .color(dark))
        }
        .accessibilityHidden(true)
    }
}

extension CGImage {
    /// The first page of a PDF, drawn at its own size up to 2,048 pixels
    /// on the longer side.
    static func firstPage(ofPDF data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(2, 2_048 / max(box.width, box.height))
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
