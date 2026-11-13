import AuthenticationServices
import SwiftUI

/// Adds an account: a service, its host, and a personal access token, or
/// the device flow where the service has one and Wye has a client id.
struct SignInSheet: View {
    var initialKind: HostingKind = .github
    var initialHost: String?
    var added: (HostingAccount) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    /// The sign-in page, shown over the sheet for as long as it is wanted.
    @State private var browser: Task<Void, Never>?

    @State private var kind: HostingKind = .github
    @State private var hostText = ""
    @State private var token = ""
    @State private var email = ""
    @State private var usesBrowser = false
    @State private var device: DeviceAuthorization?
    @State private var isWorking = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        SheetStack("Add Account") {
            Form {
                SheetTitleSection()
                Section {
                    Picker("Service", selection: $kind) {
                        ForEach(HostingKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    if kind.isSelfHostable {
                        TextField("Host", text: $hostText, prompt: Text(kind.defaultHost))
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .noAutocapitalization()
                    }
                } footer: {
                    if kind.isSelfHostable {
                        Text(hostFooter)
                    }
                }

                if canUseBrowser {
                    Section {
                        Picker("Sign In With", selection: $usesBrowser) {
                            Text("Access Token").tag(false)
                            Text("Browser").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if usesBrowser && canUseBrowser {
                    deviceSection
                } else {
                    tokenSection
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .groupedFormStyle()
            .disabled(isWorking && device == nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !(usesBrowser && canUseBrowser) {
                        Button("Sign In") { signInWithToken() }
                            .disabled(!canSignInWithToken || isWorking)
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 380)
        .onAppear {
            kind = initialKind
            hostText = initialHost ?? ""
        }
        .onChange(of: kind) {
            failure = nil
            device = nil
            task?.cancel()
        }
        .onDisappear {
            task?.cancel()
            browser?.cancel()
        }
    }

    // MARK: Sections

    private var tokenSection: some View {
        Section {
            if kind == .bitbucket {
                TextField("Atlassian Account Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
            }
            SecureField(kind == .bitbucket ? "API Token" : "Personal Access Token", text: $token)
                .textContentType(.password)
            if let host = parsedHost, let page = HostingEndpoints.newTokenPage(kind: kind, host: host.host, scheme: host.scheme) {
                Button("Make a Token on \(kind == .bitbucket ? "Atlassian" : host.host)…", systemImage: "safari") {
                    openURL(page)
                }
            }
        } header: {
            Text("Token")
        } footer: {
            Text(HostingEndpoints.tokenScopes(kind: kind)
                 + " Wye keeps the token in the Keychain and uses it for the service and for git over HTTPS.")
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if let device {
                LabeledContent("Code") {
                    HStack {
                        Text(device.userCode)
                            .font(.title2.monospaced().bold())
                            .textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") { Platform.copyToClipboard(device.userCode) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                Button("Open \(device.verificationURL.host() ?? "the Sign-In Page")", systemImage: "safari") {
                    showSignInPage(device.completeVerificationURL ?? device.verificationURL)
                }
                Button("Open in Browser Instead", systemImage: "arrow.up.forward.app") {
                    browser?.cancel()
                    openURL(device.completeVerificationURL ?? device.verificationURL)
                }
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to enter the code…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Get a Code") { startDeviceFlow() }
                    .disabled(isWorking || parsedHost == nil)
            }
        } header: {
            Text("Browser")
        } footer: {
            Text("Wye shows a code; enter it on \(parsedHost?.host ?? kind.defaultHost) in the browser to let Wye in. "
                 + "Wye asks for access to repositories and pull requests.")
        }
    }

    // MARK: State

    private var parsedHost: (scheme: String, host: String)? {
        guard kind.isSelfHostable else { return ("https", kind.defaultHost) }
        return HostingSignIn.parseHost(hostText.isEmpty ? kind.defaultHost : hostText)
    }

    private var hostFooter: String {
        switch kind {
        case .github: "github.com, or your GitHub Enterprise Server’s host."
        case .gitlab: "gitlab.com, or your own GitLab’s host."
        case .gitea: "codeberg.org, or the host of any Gitea or Forgejo server."
        case .bitbucket: ""
        }
    }

    private var clientID: String? {
        guard OAuthConfiguration.supportsDeviceFlow(kind), let host = parsedHost?.host else { return nil }
        return OAuthConfiguration.clientID(forHost: host)
    }

    private var canUseBrowser: Bool {
        clientID != nil
    }

    private var canSignInWithToken: Bool {
        parsedHost != nil && !token.trimmingCharacters(in: .whitespaces).isEmpty
            && (kind != .bitbucket || email.contains("@"))
    }

    // MARK: Signing in

    private func signInWithToken() {
        guard let host = parsedHost else { return }
        let secret = HostingSecret(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        run {
            try await HostingSignIn.signIn(
                kind: kind, host: host.host, scheme: host.scheme, secret: secret,
                email: kind == .bitbucket ? email : nil, method: .token,
                store: .shared, transport: URLSessionTransport()
            )
        }
    }

    private func startDeviceFlow() {
        guard let host = parsedHost, let clientID else { return }
        let flow = DeviceFlow(kind: kind, host: host.host, scheme: host.scheme, clientID: clientID, transport: URLSessionTransport())
        let kind = kind
        run {
            let authorization = try await flow.start()
            device = authorization
            showSignInPage(authorization.completeVerificationURL ?? authorization.verificationURL)
            // The page has nowhere to send the user back to: Wye learns of
            // the sign-in from the host, and closes the page itself.
            defer { browser?.cancel() }
            let secret = try await flow.waitForAuthorization(authorization)
            return try await HostingSignIn.signIn(
                kind: kind, host: host.host, scheme: host.scheme, secret: secret, method: .oauth,
                store: .shared, transport: URLSessionTransport()
            )
        }
    }

    /// Shows the host's sign-in page in the system's authentication sheet,
    /// which has the browser's own session, so someone already signed in
    /// there only confirms. Closing it leaves the code waiting to be
    /// entered some other way.
    private func showSignInPage(_ url: URL) {
        browser?.cancel()
        browser = Task {
            _ = try? await webAuthenticationSession.authenticate(
                using: url, callback: .customScheme("wye"), additionalHeaderFields: [:]
            )
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> HostingAccount) {
        failure = nil
        isWorking = true
        task = Task {
            defer {
                isWorking = false
                device = nil
            }
            do {
                let account = try await work()
                added(account)
                dismiss()
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// An account's picture, or its initial while there is none.
struct AccountAvatar: View {
    var url: URL?
    var name: String
    var size: CGFloat = 24

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(name.prefix(1).uppercased())
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
