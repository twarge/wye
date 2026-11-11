import SwiftUI

/// The colours given to each ``SyntaxRole``, for light and dark appearance.
/// Every theme has both, and the one shown follows the system's appearance.
struct SyntaxTheme: Identifiable, Hashable, Sendable {
    enum ID: String, CaseIterable, Hashable, Sendable {
        case system
        case classic
        case soft
        case highContrast
        case monochrome
        case plain
    }

    let id: ID
    let name: String
    private let light: [SyntaxRole: Color]
    private let dark: [SyntaxRole: Color]

    private init(_ id: ID, _ name: String, light: [SyntaxRole: Color], dark: [SyntaxRole: Color]? = nil) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark ?? light
    }

    /// The colour for a role, or `nil` to draw it as plain text.
    func color(for role: SyntaxRole, in scheme: ColorScheme) -> Color? {
        (scheme == .dark ? dark : light)[role]
    }

    static let all: [SyntaxTheme] = [.system, .classic, .soft, .highContrast, .monochrome, .plain]

    static func theme(_ id: ID) -> SyntaxTheme {
        all.first { $0.id == id } ?? .system
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private func palette(_ colors: [SyntaxRole: UInt32]) -> [SyntaxRole: Color] {
    colors.mapValues(Color.init(hex:))
}

extension SyntaxTheme {
    /// The system's own colours, which adapt to light and dark and to the
    /// increased contrast setting by themselves. The default.
    static let system = SyntaxTheme(.system, "System", light: [
        .comment: .secondary,
        .string: .red,
        .number: .indigo,
        .keyword: .pink,
        .literal: .purple,
        .type: .teal,
        .attribute: .orange,
        .property: .blue,
        .tag: .pink,
        .variable: .cyan,
        .heading: .blue,
        .emphasis: .purple,
        .link: .indigo
    ])

    static let classic = SyntaxTheme(.classic, "Classic", light: palette([
        .comment: 0x5D6C79,
        .string: 0xC41A16,
        .number: 0x1C00CF,
        .keyword: 0x9B2393,
        .literal: 0x9B2393,
        .type: 0x0B4F79,
        .attribute: 0x815F03,
        .property: 0x326D74,
        .tag: 0x9B2393,
        .variable: 0x3E8087,
        .heading: 0x0F68A0,
        .emphasis: 0x6C36A9,
        .link: 0x0E0EFF
    ]), dark: palette([
        .comment: 0x7F8C98,
        .string: 0xFC6A5D,
        .number: 0xD0BF69,
        .keyword: 0xFC5FA3,
        .literal: 0xFC5FA3,
        .type: 0x5DD8FF,
        .attribute: 0xFD8F3F,
        .property: 0x67B7A4,
        .tag: 0xFC5FA3,
        .variable: 0x67B7A4,
        .heading: 0x41A1C0,
        .emphasis: 0xD0A8FF,
        .link: 0x5482FF
    ]))

    static let soft = SyntaxTheme(.soft, "Soft", light: palette([
        .comment: 0x8E908C,
        .string: 0x718C00,
        .number: 0xF5871F,
        .keyword: 0x8959A8,
        .literal: 0xF5871F,
        .type: 0x4271AE,
        .attribute: 0xC82829,
        .property: 0x3E999F,
        .tag: 0xC82829,
        .variable: 0xC82829,
        .heading: 0x4271AE,
        .emphasis: 0x8959A8,
        .link: 0x3E999F
    ]), dark: palette([
        .comment: 0x969896,
        .string: 0xB5BD68,
        .number: 0xDE935F,
        .keyword: 0xB294BB,
        .literal: 0xDE935F,
        .type: 0x81A2BE,
        .attribute: 0xCC6666,
        .property: 0x8ABEB7,
        .tag: 0xCC6666,
        .variable: 0xCC6666,
        .heading: 0x81A2BE,
        .emphasis: 0xB294BB,
        .link: 0x8ABEB7
    ]))

    static let highContrast = SyntaxTheme(.highContrast, "High Contrast", light: palette([
        .comment: 0x3F6E00,
        .string: 0xA30000,
        .number: 0x0000C8,
        .keyword: 0x7A0091,
        .literal: 0x7A0091,
        .type: 0x00557A,
        .attribute: 0x7A4A00,
        .property: 0x00557A,
        .tag: 0x7A0091,
        .variable: 0x00557A,
        .heading: 0x0000C8,
        .emphasis: 0x7A0091,
        .link: 0x0000C8
    ]), dark: palette([
        .comment: 0x8FD16A,
        .string: 0xFF8A80,
        .number: 0xA6C8FF,
        .keyword: 0xFF8AF0,
        .literal: 0xFF8AF0,
        .type: 0x7FE0FF,
        .attribute: 0xFFD27F,
        .property: 0x7FE0FF,
        .tag: 0xFF8AF0,
        .variable: 0x7FE0FF,
        .heading: 0xA6C8FF,
        .emphasis: 0xFF8AF0,
        .link: 0xA6C8FF
    ]))

    /// Only comments and strings set apart, in greys, for those who find
    /// colour a distraction.
    static let monochrome = SyntaxTheme(.monochrome, "Monochrome", light: [
        .comment: .secondary,
        .string: Color(hex: 0x555555),
        .heading: .primary
    ], dark: [
        .comment: .secondary,
        .string: Color(hex: 0xBBBBBB),
        .heading: .primary
    ])

    static let plain = SyntaxTheme(.plain, "None", light: [:])
}
