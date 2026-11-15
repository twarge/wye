import GitKit
import SwiftUI

/// How code looks in diffs, blame and the file viewer (font, size, tab width
/// and syntax colours), and how every diff is read and drawn, in the working
/// copy and in commit detail.
struct AppearanceSettingsSection: View {
    @Bindable private var appearance = AppearancePreferences.shared
    @Bindable private var diff = DiffPreferences.shared
    @State private var families: [String] = []

    var body: some View {
        Section("Code and Diffs") {
            Picker("Font", selection: $appearance.fontFamily) {
                Text("System Monospaced").tag(String?.none)
                if !families.isEmpty {
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(Optional(family))
                    }
                }
                // A family chosen before and since uninstalled stays named.
                if let chosen = appearance.fontFamily, !families.isEmpty, !families.contains(chosen) {
                    Text(chosen).tag(Optional(chosen))
                }
            }
            Stepper(value: $appearance.fontSize, in: AppearancePreferences.sizeRange, step: 1) {
                LabeledContent("Size", value: "\(Int(appearance.fontSize)) pt")
            }
            Picker("Tab Width", selection: $diff.tabWidth) {
                ForEach(DiffPreferences.tabWidthChoices, id: \.self) { Text($0.formatted()).tag($0) }
            }
            Picker("Syntax Colors", selection: $appearance.themeID) {
                ForEach(SyntaxTheme.all) { Text($0.name).tag($0.id) }
            }
            preview
            Picker("Context Lines", selection: $diff.contextLines) {
                ForEach(DiffPreferences.contextChoices, id: \.self) { Text($0.formatted()).tag($0) }
            }
            Picker("Whitespace", selection: $diff.whitespace) {
                ForEach(DiffOptions.Whitespace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show Invisible Characters", isOn: $diff.showsInvisibles)
            Picker("Fold Files in a Commit", selection: $diff.collapseThreshold) {
                ForEach(DiffPreferences.collapseChoices, id: \.self) { threshold in
                    Text(threshold.map { "When More Than \($0.formatted()) Change" } ?? "Never").tag(threshold)
                }
            }
        }
        .task {
            families = await Task.detached(priority: .utility) { AppearancePreferences.fixedPitchFamilies() }.value
        }
    }

    /// A few lines of Swift in the chosen font and colours.
    private var preview: some View {
        CodePreview(font: appearance.codeFont, theme: appearance.theme, tabWidth: diff.tabWidth)
    }
}

private struct CodePreview: View {
    var font: Font
    var theme: SyntaxTheme
    var tabWidth: Int
    @Environment(\.colorScheme) private var scheme

    private static let sample = [
        "// Greets each name in turn",
        "@MainActor func greet(_ names: [String]) {",
        "\tfor name in names where !name.isEmpty {",
        "\t\tprint(\"Hello, \\(name)\", 42, true)",
        "\t}",
        "}"
    ]

    var body: some View {
        let tokens = SyntaxTokenizer(.swift).tokenize(Self.sample)
        let renderer = CodeLineRenderer(tabWidth: tabWidth, theme: theme, scheme: scheme)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Self.sample.indices, id: \.self) { index in
                Text(renderer.render(Self.sample[index], tokens: tokens[index]))
                    .lineLimit(1)
            }
        }
        .font(font)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator)
        }
        .accessibilityHidden(true)
    }
}
