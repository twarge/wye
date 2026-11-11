import CoreGraphics
import GitKit
import ImageIO
import SwiftUI

extension EnvironmentValues {
    /// The repository whose diffs are shown, for the views that read more
    /// of a file than its diff holds, such as an image's two sides.
    @Entry var diffRepository: Repository?
}

/// An image file's change: what it looked like before and after, side by
/// side, with a slider that swipes one over the other, or one faded over
/// the other. An added or deleted image shows its one side.
struct ImageDiffView: View {
    var file: FileDiff

    @Environment(\.diffRepository) private var repository
    @State private var loaded: Loaded?
    @State private var failure: String?
    @State private var mode = Mode.sideBySide
    @State private var split = 0.5
    @State private var opacity = 0.5

    /// Sides larger than this are measured but not read.
    static let sizeLimit = 32 << 20
    private static let maximumHeight: CGFloat = 320

    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case swipe = "Swipe"
        case onionSkin = "Onion Skin"

        var id: Self { self }
    }

    private static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico", "icns", "avif", "pdf"
    ]

    /// Whether a changed file is an image the system can draw. SVG is text,
    /// and shows as a text diff.
    static func canShow(_ file: FileDiff) -> Bool {
        file.isBinary && extensions.contains((file.path as NSString).pathExtension.lowercased())
    }

    struct Side: @unchecked Sendable {
        /// `nil` when the bytes are too large to read or not an image.
        var image: CGImage?
        var byteSize: Int
        var isTooLarge: Bool

        var pixelSize: CGSize? {
            image.map { CGSize(width: $0.width, height: $0.height) }
        }
    }

    struct Loaded: Sendable {
        var old: Side?
        var new: Side?
    }

    var body: some View {
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
        .task(id: file) { await load() }
    }

    @ViewBuilder
    private func content(_ loaded: Loaded) -> some View {
        switch (loaded.old, loaded.new) {
        case (let old?, let new?):
            switch mode {
            case .sideBySide:
                HStack(alignment: .top, spacing: 12) {
                    pane(old, title: "Before")
                    pane(new, title: "After")
                }
            case .swipe:
                stacked(old, new) { size in
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
                stacked(old, new) { _ in
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
            pane(old, title: "Deleted")
        case (nil, let new?):
            pane(new, title: "Added")
        case (nil, nil):
            Text("Neither side of this image can be read")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func pane(_ side: Side, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if side.image != nil {
                ImageLayer(side: side)
                    .background { Checkerboard() }
                    .frame(maxWidth: maximumWidth(side), maxHeight: Self.maximumHeight, alignment: .leading)
            } else {
                Text(side.isTooLarge ? "Too large to show" : "Can’t be shown as an image")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            caption(side)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Both sides in one box, the new drawn over the old by `top`.
    private func stacked<Top: View>(_ old: Side, _ new: Side, @ViewBuilder top: @escaping (CGSize) -> Top) -> some View {
        let sizes = [old.pixelSize, new.pixelSize].compactMap(\.self)
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
            .frame(maxWidth: min(width * 2, 900), maxHeight: Self.maximumHeight, alignment: .leading)
            .clipped()
            HStack(spacing: 16) {
                Text("Before: \(describe(old))")
                Text("After: \(describe(new))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func maximumWidth(_ side: Side) -> CGFloat {
        // Small images are shown larger, up to twice their size.
        (side.pixelSize?.width ?? 0) * 2
    }

    private func caption(_ side: Side) -> some View {
        Text(describe(side))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func describe(_ side: Side) -> String {
        let bytes = side.byteSize.formatted(.byteCount(style: .file))
        guard let size = side.pixelSize else { return bytes }
        return "\(Int(size.width).formatted()) × \(Int(size.height).formatted()) px · \(bytes)"
    }

    private func load() async {
        guard let repository else {
            failure = "The image can’t be read here"
            return
        }
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
}

/// One side's image, fitted to the space it is given.
private struct ImageLayer: View {
    var side: ImageDiffView.Side

    var body: some View {
        if let image = side.image {
            Image(decorative: image, scale: 1)
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
