import GitKit
import SwiftUI

/// How every diff is read and drawn, in the working copy and in commit detail.
struct DiffSettingsSection: View {
    @Bindable private var preferences = DiffPreferences.shared

    var body: some View {
        Section {
            Picker("Context Lines", selection: $preferences.contextLines) {
                ForEach(DiffPreferences.contextChoices, id: \.self) { Text($0.formatted()).tag($0) }
            }
            Picker("Whitespace", selection: $preferences.whitespace) {
                ForEach(DiffOptions.Whitespace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show Invisible Characters", isOn: $preferences.showsInvisibles)
            Picker("Fold Files in a Commit", selection: $preferences.collapseThreshold) {
                ForEach(DiffPreferences.collapseChoices, id: \.self) { threshold in
                    Text(threshold.map { "When More Than \($0.formatted()) Change" } ?? "Never").tag(threshold)
                }
            }
        } header: {
            Text("Diffs")
        } footer: {
            Text("While whitespace changes are hidden, files are staged whole: single hunks and lines need the exact diff.")
        }
    }
}
