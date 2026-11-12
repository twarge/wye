import Observation
import SwiftUI

/// Something elsewhere in the app that needs the settings shown, and what
/// they should draw attention to.
@MainActor
@Observable
final class SettingsFocus {
    static let shared = SettingsFocus()

    /// The row the SSH key notice sits in, to scroll the settings to.
    static let sshKeysAnchor = "sshKeys"

    /// An SSH server that wants a key Wye does not have, shown above the
    /// keys until the settings close.
    var sshKeyNotice: SSHKeyPrompt?
    /// Counts requests to show the settings, so each one is acted on.
    private(set) var requests = 0
    /// Whether the settings are on screen where they are a sheet.
    var isPresented = false

    /// Shows the settings, for a notice that says something there is missing.
    func show() {
        requests += 1
        isPresented = true
    }

    /// Shows the settings at the SSH keys, saying why a key is needed.
    func showSSHKeys(for prompt: SSHKeyPrompt) {
        sshKeyNotice = prompt
        requests += 1
        isPresented = true
    }
}
