import SwiftUI

/// One line of a file shown whole, in the file viewer or blame: syntax
/// colours, tabs at the chosen width, and find's matches marked. The row
/// that holds it carries `findRow` as its ID.
struct CodeLineText: View {
    var text: String
    var tokens: [SyntaxToken]
    var findRow: FindRow

    @Environment(FindModel.self) private var find: FindModel?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let renderer = CodeLineRenderer(
            tabWidth: DiffPreferences.shared.tabWidth,
            theme: AppearancePreferences.shared.theme,
            scheme: colorScheme
        )
        Text(renderer.render(text, tokens: tokens, marks: find?.marks(for: findRow) ?? []))
    }
}
