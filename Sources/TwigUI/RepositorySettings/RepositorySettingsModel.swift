import Foundation
import GitKit
import Observation

/// What the repository settings screen shows, read from the repository's
/// own configuration and written back to it.
@MainActor
@Observable
final class RepositorySettingsModel {
    let model: RepositoryModel

    /// The repository's own configuration, in the file's order.
    private(set) var localEntries: [ConfigurationEntry] = []
    /// Twig's configuration for every repository, which git reads after the
    /// repository's own.
    private(set) var appEntries: [ConfigurationEntry] = []
    private(set) var isLoaded = false

    init(model: RepositoryModel) {
        self.model = model
    }

    private var repository: Repository { model.repository }

    func reload() async {
        do {
            localEntries = try await repository.configurationEntries(at: .local)
            appEntries = (try? await repository.configurationEntries(at: .global)) ?? []
        } catch {
            model.error = PresentedError(error)
        }
        isLoaded = true
    }

    /// The last value of a key in the repository's own configuration.
    func localValue(_ name: String) -> String? {
        localEntries.last { $0.name == name }?.value
    }

    /// The last value of a key in Twig's configuration for every repository.
    func appValue(_ name: String) -> String? {
        appEntries.last { $0.name == name }?.value
    }

    /// Runs a change to the configuration, shows its error, and reads the
    /// configuration again.
    func change(_ title: String, _ operation: @escaping (Repository) async throws -> Void) async {
        await ActivityContext.$operationTitle.withValue(title) {
            await model.perform(operation)
        }
        await reload()
    }

    // MARK: Author

    /// Sets this repository's author once both halves are given, or clears
    /// it when both are empty; half an identity is no use to git.
    func saveAuthor(name: String, email: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        let email = email.trimmingCharacters(in: .whitespaces)
        let identity: GitIdentity?
        switch (name.isEmpty, email.isEmpty) {
        case (false, false): identity = GitIdentity(name: name, email: email)
        case (true, true): identity = nil
        default: return
        }
        guard identity?.name != localValue("user.name") || identity?.email != localValue("user.email") else { return }
        await change("Change Author") { try await $0.setLocalIdentity(identity) }
    }

    // MARK: Pull

    /// How the repository's own configuration says to pull; `nil` to use
    /// the app's setting.
    var pullMode: PullMode? {
        if localValue("pull.ff")?.lowercased() == "only" { return .fastForwardOnly }
        switch localValue("pull.rebase")?.lowercased() {
        case "true", "yes", "on", "1", "merges", "m", "interactive", "i": return .rebase
        case "false", "no", "off", "0": return .merge
        default: return nil
        }
    }

    func setPullMode(_ mode: PullMode?) async {
        guard mode != pullMode else { return }
        await change("Change Pull Setting") { try await $0.setConfiguredPullMode(mode) }
    }

    // MARK: Configuration editor

    /// Replaces the values of one key, which removes it when there are none.
    func setValues(_ values: [String], for name: String) async {
        await change("Edit Configuration") { try await $0.setConfigurationValues(values, for: name) }
    }

    /// The values a key has now, in order.
    func values(of name: String) -> [String] {
        localEntries.filter { $0.name == name }.map(\.value)
    }
}

/// Edits to a key's values, worked out before they are written, so one
/// value of a multi-valued key can change without disturbing the others.
enum ConfigurationEdit {
    /// `values` with the value at `index` replaced, or removed when
    /// `newValue` is `nil`.
    static func values(_ values: [String], replacingAt index: Int, with newValue: String?) -> [String] {
        guard values.indices.contains(index) else { return values }
        var values = values
        if let newValue {
            values[index] = newValue
        } else {
            values.remove(at: index)
        }
        return values
    }

    /// The entries with each one's position among its key's values, for
    /// telling the values of a multi-valued key apart.
    static func indexed(_ entries: [ConfigurationEntry]) -> [IndexedEntry] {
        var seen: [String: Int] = [:]
        let counts = Dictionary(entries.map { ($0.name, 1) }, uniquingKeysWith: +)
        return entries.map { entry in
            let index = seen[entry.name, default: 0]
            seen[entry.name] = index + 1
            return IndexedEntry(entry: entry, index: index, count: counts[entry.name] ?? 1)
        }
    }

    struct IndexedEntry: Identifiable, Hashable {
        var entry: ConfigurationEntry
        /// Which of the key's values this is, from 0.
        var index: Int
        /// How many values the key has.
        var count: Int

        var id: String { "\(entry.name)#\(index)" }
    }
}
