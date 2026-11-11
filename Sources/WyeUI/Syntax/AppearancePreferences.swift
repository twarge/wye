import CoreText
import Foundation
import Observation
import SwiftUI

/// How code is drawn in diffs, blame and the file viewer: its font, its size
/// and its colours. Kept in `UserDefaults`, and observable so that open
/// views follow a change at once.
@MainActor
@Observable
final class AppearancePreferences {
    static let shared = AppearancePreferences()

    static let sizeRange: ClosedRange<Double> = 8...28

    private enum Key {
        static let fontFamily = "appearance.codeFontFamily"
        static let fontSize = "appearance.codeFontSize"
        static let theme = "appearance.syntaxTheme"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// A fixed-pitch font family, or `nil` for the system's monospaced font.
    var fontFamily: String? {
        didSet { defaults.set(fontFamily, forKey: Key.fontFamily) }
    }

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    var themeID: SyntaxTheme.ID {
        didSet { defaults.set(themeID.rawValue, forKey: Key.theme) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontFamily = defaults.string(forKey: Key.fontFamily).flatMap { $0.isEmpty ? nil : $0 }
        let size = defaults.object(forKey: Key.fontSize) as? Double ?? Platform.defaultCodeFontSize
        fontSize = Self.sizeRange.contains(size) ? size : Platform.defaultCodeFontSize
        themeID = defaults.string(forKey: Key.theme).flatMap(SyntaxTheme.ID.init) ?? .system
    }

    var theme: SyntaxTheme { SyntaxTheme.theme(themeID) }

    /// Whether the font is the one Wye starts with, which on iOS also
    /// follows the reader's text size.
    var isDefaultFont: Bool {
        fontFamily == nil && fontSize == Platform.defaultCodeFontSize
    }

    /// The font for lines of code.
    var codeFont: Font {
        if isDefaultFont { return .code }
        return font(size: fontSize)
    }

    /// The font for line numbers and hunk headers beside the code.
    var smallCodeFont: Font {
        if isDefaultFont { return .smallCode }
        return font(size: max(Self.sizeRange.lowerBound, fontSize - 1))
    }

    private func font(size: Double) -> Font {
        if let fontFamily {
            return .custom(fontFamily, size: size)
        }
        return .system(size: size, design: .monospaced)
    }

    /// Roughly how wide a digit is, for sizing line number gutters.
    var digitWidth: CGFloat {
        CGFloat(fontSize) * 0.62
    }

    /// The installed font families whose characters are all one width,
    /// leaving out the system's hidden ones. Slow enough to call off the
    /// main actor.
    nonisolated static func fixedPitchFamilies() -> [String] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        guard let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
            return []
        }
        var families = Set<String>()
        for descriptor in descriptors {
            guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any],
                  let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value,
                  symbolic & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0,
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !family.hasPrefix(".") else { continue }
            families.insert(family)
        }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
