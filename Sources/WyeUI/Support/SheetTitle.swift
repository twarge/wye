import SwiftUI

/// The frame of a sheet with a title.
///
/// On iOS and visionOS it is a navigation stack, whose bar shows the title
/// and the toolbar's Cancel and confirming buttons. A Mac sheet has no bar:
/// in a navigation stack it gets an iOS-style one, its title set in past the
/// room for a back button and out of line with everything under it, and
/// buttons placed as primary actions do not show at all. So on macOS the
/// title is part of the content, lined up with it as in Apple's own sheets,
/// and the toolbar's Cancel and confirming buttons sit at the bottom.
struct SheetStack<Content: View>: View {
    enum Placement {
        /// At the head of the sheet's grouped form, where the form puts a
        /// `SheetTitleSection()` first.
        case form
        /// Above the content, set in by `inset` to line up with its text.
        case above(inset: CGFloat)
    }

    var title: Text
    var subtitle: String?
    var placement: Placement
    @ViewBuilder var content: Content

    /// A title written out, looked up in the string catalog.
    init(_ title: LocalizedStringKey, subtitle: String? = nil, placement: Placement = .form,
         @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.subtitle = subtitle
        self.placement = placement
        self.content = content()
    }

    /// A title made elsewhere, shown as it is.
    @_disfavoredOverload
    init(_ title: some StringProtocol, subtitle: String? = nil, placement: Placement = .form,
         @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.subtitle = subtitle
        self.placement = placement
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        switch placement {
        case .form:
            content
                .environment(\.sheetTitle, SheetTitle(title: title, subtitle: subtitle))
        case .above(let inset):
            VStack(alignment: .leading, spacing: 0) {
                SheetHeading(title: SheetTitle(title: title, subtitle: subtitle))
                    .padding(.horizontal, inset)
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                content
            }
        }
        #else
        NavigationStack {
            if let subtitle {
                content
                    .navigationTitle(title)
                    .navigationSubtitle(subtitle)
            } else {
                content
                    .navigationTitle(title)
            }
        }
        #endif
    }
}

/// The title of the sheet around it, as the first thing in its grouped form
/// on macOS, lined up with the labels and notes below. Nothing on iOS, where
/// the sheet's bar shows the title.
struct SheetTitleSection: View {
    @Environment(\.sheetTitle) private var title

    var body: some View {
        #if os(macOS)
        if let title {
            Section {
            } header: {
                SheetHeading(title: title)
            }
        }
        #endif
    }
}

private struct SheetTitle: Equatable {
    var title: Text
    var subtitle: String?
}

private struct SheetHeading: View {
    var title: SheetTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.title
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle = title.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    @Entry fileprivate var sheetTitle: SheetTitle?
}
