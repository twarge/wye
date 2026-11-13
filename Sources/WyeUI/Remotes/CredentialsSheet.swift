import GitKit
import SwiftUI

/// Asks for a host's username and personal access token.
struct CredentialsSheet: View {
    let prompt: CredentialPrompt
    var broker: CredentialBroker

    @State private var username: String
    @State private var token = ""
    @State private var savesInKeychain = true
    @State private var error: Notice?

    init(prompt: CredentialPrompt, broker: CredentialBroker) {
        self.prompt = prompt
        self.broker = broker
        _username = State(initialValue: prompt.username)
    }

    var body: some View {
        SheetStack("Sign In") {
            Form {
                SheetTitleSection()
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                    SecureField("Access Token", text: $token)
                        .textContentType(.password)
                } header: {
                    Text(prompt.host)
                } footer: {
                    Text(explanation)
                }
                Section {
                    Toggle("Save in Keychain", isOn: $savesInKeychain)
                } footer: {
                    Text(savesInKeychain
                         ? "Wye uses it for every repository on \(prompt.host). Remove it in Settings."
                         : "Wye forgets it when it quits.")
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { broker.decline() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { answer() }
                        .disabled(!canAnswer)
                }
            }
        }
        .frame(minWidth: 380)
        .notice(for: $error)
    }

    private var explanation: String {
        let start = prompt.wasRejected
            ? "\(prompt.host) did not accept the username and token Wye had. "
            : "\(prompt.host) asks who you are. "
        return start + "Use a personal access token from the host’s settings rather than your password."
    }

    private var canAnswer: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !token.isEmpty
    }

    private func answer() {
        do {
            try broker.answer(
                Credential(username: username.trimmingCharacters(in: .whitespaces), token: token),
                saveInKeychain: savesInKeychain
            )
        } catch {
            self.error = Notice(error)
        }
    }
}
