import GitKit
import SwiftUI

/// What a commit's signature says, as a small badge: verified and by whom,
/// signed by a key nobody vouches for, not matching, or signed in a way the
/// app cannot check. Nothing for an unsigned commit.
struct CommitSignatureBadge: View {
    var model: RepositoryModel
    var commitID: OID

    @State private var status: CommitSignatureStatus?

    var body: some View {
        Group {
            switch status {
            case .verified(let principal, let key)?:
                badge("Verified", systemImage: "checkmark.seal.fill", color: .green,
                      help: "Signed by \(principal) with the key \(key.fingerprint)")
            case .unknownKey(let key)?:
                badge("Signed, Unknown Key", systemImage: "seal", color: .orange,
                      help: "The signature is good, but the key \(key.fingerprint) is not one of yours or an allowed signer’s. Add it in Settings to trust it.")
            case .invalid(let reason)?:
                badge("Invalid Signature", systemImage: "xmark.seal.fill", color: .red, help: reason)
            case .unverifiable(let format)?:
                badge("Signed (\(format) — cannot verify)", systemImage: "seal", color: .secondary,
                      help: "Twig checks SSH signatures only.")
            case .unsigned?, nil:
                EmptyView()
            }
        }
        .task(id: commitID) {
            let trusted = AuthorProfiles.shared.trustedSigners(ownKeys: (try? SSHKeyStore.shared.keys()) ?? [])
            status = try? await model.repository.signatureStatus(of: commitID, trusting: trusted)
        }
    }

    private func badge(_ title: String, systemImage: String, color: Color, help: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: .capsule)
            .help(help)
            .accessibilityElement(children: .combine)
            .accessibilityHint(help)
            .padding(16)
    }
}
