import Foundation
import GitKit
import Observation

/// A name and email to commit as, with how its commits are signed.
struct AuthorProfile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var email: String
    /// The SSH key in the Keychain its commits are signed with, by its
    /// `SSHKeyStore` ID; `nil` for the app-wide signing key.
    var signingKeyID: String?
    /// Whether its commits are signed; `nil` follows the app-wide setting.
    var signsCommits: Bool?

    var identity: GitIdentity { GitIdentity(name: name, email: email) }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !email.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// How a commit is to be signed, worked out from the settings.
struct SigningPlan: Hashable {
    var signs: Bool
    /// The key, when signing; `nil` when no key is chosen or kept.
    var keyID: String?
}

/// The identities the user commits as, which one is the default, how
/// commits are signed, and whose signatures are trusted.
///
/// Kept in the user defaults. The default identity is also written to the
/// app's global git configuration, so that every commit the app makes
/// without asking (merges, rebases, cherry-picks) is by it, and so that a
/// repository's own `user.name` still wins over it, as in git.
@MainActor
@Observable
final class AuthorProfiles {
    static let shared = AuthorProfiles()

    private enum Key {
        static let stored = "authorProfiles"
    }

    private struct Stored: Codable {
        var version = 1
        var profiles: [AuthorProfile] = []
        var defaultID: UUID?
        var signsCommits = false
        var signingKeyID: String?
        var allowedSigners: [AllowedSigner] = []
    }

    private(set) var profiles: [AuthorProfile] = []
    private(set) var defaultID: UUID?
    /// Whether commits are signed, unless an identity or a repository says otherwise.
    var signsCommits = false {
        didSet { save() }
    }
    /// The key commits are signed with, unless an identity names its own.
    var signingKeyID: String? {
        didSet { save() }
    }
    /// Other people's keys, trusted to sign as them.
    var allowedSigners: [AllowedSigner] = [] {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let writeGlobalIdentity: (GitIdentity) throws -> Void
    @ObservationIgnored private var isLoading = false

    /// - Parameters:
    ///   - globalIdentity: The identity in the global git configuration,
    ///     which becomes the first profile when there are none yet.
    ///   - writeGlobalIdentity: Writes the default identity there.
    init(
        defaults: UserDefaults = .standard,
        globalIdentity: () -> GitIdentity? = { GitEnvironment.globalIdentity() },
        writeGlobalIdentity: @escaping (GitIdentity) throws -> Void = { try GitEnvironment.setGlobalIdentity($0) }
    ) {
        self.defaults = defaults
        self.writeGlobalIdentity = writeGlobalIdentity
        isLoading = true
        defer { isLoading = false }
        if let data = defaults.data(forKey: Key.stored),
           let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1 {
            profiles = stored.profiles
            defaultID = stored.defaultID
            signsCommits = stored.signsCommits
            signingKeyID = stored.signingKeyID
            allowedSigners = stored.allowedSigners
        }
        // The one identity the app had before profiles becomes the first.
        if profiles.isEmpty, let identity = globalIdentity() {
            let profile = AuthorProfile(name: identity.name, email: identity.email)
            profiles = [profile]
            defaultID = profile.id
            isLoading = false
            save()
        }
    }

    var defaultProfile: AuthorProfile? {
        profiles.first { $0.id == defaultID } ?? profiles.first
    }

    func profile(id: UUID?) -> AuthorProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    // MARK: Changing

    /// Adds or replaces a profile. The first one becomes the default.
    func save(_ profile: AuthorProfile) throws {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if defaultID == nil || self.profile(id: defaultID) == nil {
            defaultID = profile.id
        }
        save()
        if profile.id == defaultProfile?.id, profile.isComplete {
            try writeGlobalIdentity(profile.identity)
        }
    }

    func remove(_ profile: AuthorProfile) throws {
        profiles.removeAll { $0.id == profile.id }
        if defaultID == profile.id {
            defaultID = profiles.first?.id
            if let next = defaultProfile, next.isComplete { try writeGlobalIdentity(next.identity) }
        }
        save()
    }

    func makeDefault(_ profile: AuthorProfile) throws {
        defaultID = profile.id
        save()
        if profile.isComplete { try writeGlobalIdentity(profile.identity) }
    }

    /// Takes in an identity written to the global configuration some other
    /// way, as the default profile's, so the two do not drift apart.
    func adoptGlobalIdentity(_ identity: GitIdentity?) {
        guard let identity else { return }
        if var profile = defaultProfile {
            guard profile.identity != identity else { return }
            profile.name = identity.name
            profile.email = identity.email
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        } else {
            let profile = AuthorProfile(name: identity.name, email: identity.email)
            profiles = [profile]
            defaultID = profile.id
        }
        save()
    }

    // MARK: Working out a commit

    /// The profile a commit is made as: one picked for that commit, or the
    /// repository's, or `nil` for whatever the repository's configuration
    /// says, which is the default profile unless it sets its own.
    func chosenProfile(forCommit commitID: UUID?, repository repositoryID: UUID?) -> AuthorProfile? {
        profile(id: commitID) ?? profile(id: repositoryID)
    }

    /// Whether and with which key a commit by `profile` is signed. A
    /// repository's choice wins over the profile's, and the profile's over
    /// the app-wide setting.
    func signingPlan(for profile: AuthorProfile?, repositorySigns: Bool?) -> SigningPlan {
        let profile = profile ?? defaultProfile
        let signs = repositorySigns ?? profile?.signsCommits ?? signsCommits
        return SigningPlan(signs: signs, keyID: signs ? (profile?.signingKeyID ?? signingKeyID) : nil)
    }

    /// Who is trusted to sign: the allowed signers, and the app's own keys
    /// as the identities that sign with them.
    func trustedSigners(ownKeys: [StoredSSHKey]) -> [AllowedSigner] {
        var signers = allowedSigners
        for key in ownKeys {
            let line = key.publicKeyLine.split(separator: " ").prefix(2).joined(separator: " ")
            let users = profiles.filter { ($0.signingKeyID ?? signingKeyID) == key.id }.map(\.email)
            let principal = users.isEmpty ? (key.comment.isEmpty ? "your \(key.kind.displayName) key" : key.comment)
                : users.joined(separator: ",")
            signers.append(AllowedSigner(principal: principal, publicKey: line))
        }
        return signers
    }

    // MARK: Storage

    private func save() {
        guard !isLoading else { return }
        let stored = Stored(
            profiles: profiles, defaultID: defaultID, signsCommits: signsCommits,
            signingKeyID: signingKeyID, allowedSigners: allowedSigners
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Key.stored)
        }
    }
}
