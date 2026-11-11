import GitKit
import SwiftUI

/// A commit message field that offers completions for the word at the
/// insertion point, in a list under it: changed files, people, issues, and
/// for a `fixup!` subject the commit it names. The list follows the arrow
/// keys and takes Return or Tab where there is a keyboard, and a tap or
/// click anywhere.
struct CompletingField<Field: View>: View {
    @Binding var text: String
    var isSubject: Bool
    var context: CompletionContext
    @ViewBuilder var field: (Binding<TextSelection?>) -> Field

    @State private var selection: TextSelection?
    @State private var highlighted = 0
    /// The text Escape was pressed at: no list until it changes.
    @State private var dismissedAt: String?

    var body: some View {
        let match = currentMatch
        VStack(alignment: .leading, spacing: 4) {
            field($selection)
                .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab, .escape]) { press in
                    handle(press, match)
                }
            if let match {
                CompletionList(suggestions: match.suggestions, highlighted: min(highlighted, match.suggestions.count - 1)) {
                    accept($0, in: match)
                }
            }
        }
        .onChange(of: text) {
            highlighted = 0
            if dismissedAt != text { dismissedAt = nil }
        }
    }

    private var currentMatch: CommitCompletion.Match? {
        guard dismissedAt == nil, let cursor else { return nil }
        return CommitCompletion.match(in: text, at: cursor, isSubject: isSubject, context: context)
    }

    /// The insertion point, when nothing is selected.
    private var cursor: String.Index? {
        guard case .selection(let range) = selection?.indices, range.isEmpty,
              range.lowerBound >= text.startIndex, range.lowerBound <= text.endIndex else { return nil }
        return range.lowerBound
    }

    private func handle(_ press: KeyPress, _ match: CommitCompletion.Match?) -> KeyPress.Result {
        guard let match, press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        let count = match.suggestions.count
        switch press.key {
        case .downArrow:
            highlighted = (min(highlighted, count - 1) + 1) % count
        case .upArrow:
            highlighted = (min(highlighted, count - 1) + count - 1) % count
        case .return, .tab:
            accept(match.suggestions[min(highlighted, count - 1)], in: match)
        case .escape:
            dismissedAt = text
        default:
            return .ignored
        }
        return .handled
    }

    private func accept(_ suggestion: CompletionSuggestion, in match: CommitCompletion.Match) {
        var updated = text
        let cursor = CommitCompletion.accept(suggestion, in: &updated, range: match.range)
        text = updated
        selection = TextSelection(insertionPoint: cursor)
        // A finished trailer key goes straight on to the people.
        dismissedAt = suggestion.kind == .trailer ? nil : updated
    }
}

/// The completions under a field: a short list, the highlighted one first
/// to be taken by Return.
private struct CompletionList: View {
    var suggestions: [CompletionSuggestion]
    var highlighted: Int
    var accept: (CompletionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    accept(suggestion)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: suggestion.kind.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(suggestion.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = suggestion.detail {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                    .background(index == highlighted ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(suggestion.detail.map { "\(suggestion.title), \($0)" } ?? suggestion.title)
                .accessibilityAddTraits(index == highlighted ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.background, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completions")
    }
}

/// "As <name>": who the commit is by, and a menu to commit this one as
/// another profile, to set this repository's profile, and its signing.
struct AuthorMenu: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        let profiles = AuthorProfiles.shared
        if let identity = model.composerIdentity {
            Menu {
                if !profiles.profiles.isEmpty {
                    Picker("This Commit As", selection: $model.workingCopy.commitProfile) {
                        Text("Repository’s Author").tag(UUID?.none)
                        ForEach(profiles.profiles) { profile in
                            Text("\(profile.name) <\(profile.email)>").tag(UUID?.some(profile.id))
                        }
                    }
                    .pickerStyle(.inline)
                    Picker("This Repository’s Author", selection: Binding {
                        model.interface.stored.authorProfile
                    } set: {
                        model.interface.setAuthorProfile($0)
                        model.updateCommitSigning()
                    }) {
                        Text(model.workingCopy.identity.map { "From Settings (\($0.name))" } ?? "From Settings").tag(UUID?.none)
                        ForEach(profiles.profiles) { profile in
                            Text(profile.name).tag(UUID?.some(profile.id))
                        }
                    }
                }
                Picker("Sign This Repository’s Commits", selection: Binding {
                    model.interface.stored.signsCommits
                } set: {
                    model.interface.setSignsCommits($0)
                    model.updateCommitSigning()
                }) {
                    Text("As Set in Settings").tag(Bool?.none)
                    Text("Always").tag(Bool?.some(true))
                    Text("Never").tag(Bool?.some(false))
                }
                Divider()
                SettingsButton {
                    Label("Edit Identities…", systemImage: "person.2")
                }
            } label: {
                HStack(spacing: 4) {
                    Text("As \(identity.name)")
                        .lineLimit(1)
                    if model.composerSigningPlan.signs {
                        Image(systemName: "signature")
                            .accessibilityLabel("Signed")
                    }
                }
                .font(.callout)
                .foregroundStyle(model.workingCopy.commitProfile == nil ? .secondary : .primary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Who this commit is by\(model.composerSigningPlan.signs ? ", signed with your SSH key" : "")")
        } else {
            SettingsButton {
                Label("Set your name and email to commit", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout)
            }
        }
    }
}
