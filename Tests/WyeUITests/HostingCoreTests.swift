import Foundation
import GitKit
import Testing
@testable import WyeUI

/// The shared parts of the hosting services: requests, errors, paging,
/// dates, host detection.
@Suite struct HostingClientTests {
    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.example.com")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func error(_ status: Int, _ body: String, _ headers: [String: String] = [:]) -> HostingError? {
        HostingClient.error(status: status, data: Data(body.utf8), headers: response(status, headers), host: "example.com")
    }

    @Test func readsTheNextLink() {
        let header = #"<https://api.example.com/x?page=3>; rel="next", <https://api.example.com/x?page=9>; rel="last""#
        #expect(HostingClient.nextLink(in: header)?.absoluteString == "https://api.example.com/x?page=3")
        #expect(HostingClient.nextLink(in: #"<https://api.example.com/x?page=1>; rel="prev""#) == nil)
    }

    @Test func mapsStatuses() {
        #expect(error(401, #"{"message":"Bad credentials"}"#) == .unauthorized(host: "example.com"))
        #expect(error(403, #"{"message":"Resource not accessible by personal access token"}"#)
            == .forbidden(host: "example.com", message: "Resource not accessible by personal access token"))
        #expect(error(403, #"{"message":"API rate limit exceeded"}"#, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000000"])
            == .rateLimited(host: "example.com", reset: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(error(429, "{}", ["RateLimit-Reset": "1700000000"])
            == .rateLimited(host: "example.com", reset: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(error(404, "{}") == .notFound(host: "example.com"))
        #expect(error(422, #"{"message":"Validation Failed","errors":[{"resource":"Repository","code":"custom","field":"name","message":"name already exists on this account"}]}"#)
            == .rejected(message: "Validation Failed. name already exists on this account"))
        #expect(error(500, "<html>oops</html>") == .server(status: 500, message: nil))
        #expect(error(200, "{}") == nil)
    }

    @Test func readsEachServicesErrorShape() {
        func message(_ json: String) -> String? { HostingClient.errorMessage(in: Data(json.utf8)) }
        #expect(message(#"{"message":{"name":["has already been taken"]}}"#) == "name has already been taken")
        #expect(message(#"{"message":["Branch cannot be merged"]}"#) == "Branch cannot be merged")
        #expect(message(#"{"error":"insufficient_scope","error_description":"The request requires higher privileges."}"#)
            == "The request requires higher privileges.")
        #expect(message(#"{"type":"error","error":{"message":"Repository not found"}}"#) == "Repository not found")
    }

    @Test func offlineIsSaidPlainly() async {
        let client = HostingClient(
            apiBase: URL(string: "https://api.example.com")!, host: "example.com",
            tokens: FixedToken(value: .none), transport: OfflineTransport()
        )
        await #expect(throws: HostingError.offline) {
            try await client.sendRaw(.get, client.url("/user"))
        }
    }

    @Test func buildsURLsAndHeaders() async throws {
        let client = HostingClient(
            apiBase: URL(string: "https://host.example/api/v4/")!, host: "host.example",
            tokens: FixedToken(value: .token("abc")), transport: StubTransport()
        )
        let url = client.url("/projects/a%2Fb", query: ["search": "c++ x", "page": nil])
        #expect(url.absoluteString == "https://host.example/api/v4/projects/a%2Fb?search=c%2B%2B%20x")
        let request = try await client.request(.post, url, json: ["a": 1])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token abc")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(HostingAuthorization.basic(username: "me@example.com", password: "t").headerValue
            == "Basic " + Data("me@example.com:t".utf8).base64EncodedString())
    }

    @Test func readsDates() throws {
        let expected = Date(timeIntervalSince1970: 1_714_557_600)
        #expect(HostingDates.parse("2024-05-01T10:00:00Z") == expected)
        #expect(HostingDates.parse("2024-05-01T12:00:00+02:00") == expected)
        let fractional = try #require(HostingDates.parse("2024-05-01T10:00:00.123Z"))
        #expect(abs(fractional.timeIntervalSince(expected) - 0.123) < 0.001)
        let micro = try #require(HostingDates.parse("2024-05-01T10:00:00.123456+00:00"))
        #expect(abs(micro.timeIntervalSince(expected) - 0.123) < 0.001)
        #expect(HostingDates.parse("yesterday") == nil)
    }

    @Test func endpointsPerService() {
        #expect(HostingEndpoints.apiBase(kind: .github, host: "github.com").absoluteString == "https://api.github.com")
        #expect(HostingEndpoints.apiBase(kind: .github, host: "GHE.example.com").absoluteString == "https://ghe.example.com/api/v3")
        #expect(HostingEndpoints.apiBase(kind: .gitlab, host: "git.example.com:8443").absoluteString == "https://git.example.com:8443/api/v4")
        #expect(HostingEndpoints.apiBase(kind: .bitbucket, host: "bitbucket.org").absoluteString == "https://api.bitbucket.org/2.0")
        #expect(HostingEndpoints.apiBase(kind: .gitea, host: "codeberg.org", scheme: "http").absoluteString == "http://codeberg.org/api/v1")
    }
}

@Suite struct HostDetectionTests {
    @Test func knowsThePublicHosts() {
        let cases: [(String, HostedRepository.Kind)] = [
            ("git@github.com:o/p.git", .github),
            ("https://github.example.com/o/p", .github),
            ("https://acme.ghe.com/o/p", .github),
            ("https://gitlab.com/g/s/p.git", .gitlab),
            ("ssh://git@gitlab.example.com:2222/g/p.git", .gitlab),
            ("https://bitbucket.org/w/p.git", .bitbucket),
            ("https://codeberg.org/o/p.git", .gitea),
            ("https://code.forgejo.org/o/p", .gitea),
            ("https://git.example.com/o/p", .other)
        ]
        for (url, kind) in cases {
            #expect(HostedRepository(remoteURL: url, knownHosts: [:])?.kind == kind, "\(url)")
        }
    }

    @Test func accountsTeachSelfHostedServices() {
        let known: [String: HostedRepository.Kind] = ["git.example.com": .gitlab, "code.example.com:3000": .gitea]
        #expect(HostedRepository(remoteURL: "git@git.example.com:team/app.git", knownHosts: known)?.kind == .gitlab)
        #expect(HostedRepository(remoteURL: "https://code.example.com:3000/team/app", knownHosts: known)?.kind == .gitea)
    }

    @Test func pathsAndKeys() throws {
        let https = try #require(HostedRepository(remoteURL: "https://gitlab.com/group/sub/project.git"))
        let ssh = try #require(HostedRepository(remoteURL: "git@gitlab.com:Group/sub/project.git"))
        #expect(https.repositoryPath == RepositoryPath(owner: "group/sub", name: "project"))
        #expect(https.host == "gitlab.com")
        #expect(https.key == ssh.key)
        #expect(HostedRepository(remoteURL: "http://git.example.com:3000/team/app.git")?.host == "git.example.com:3000")
        #expect(HostingKind(HostedRepository.Kind.sourcehut) == nil)
    }
}

@Suite struct AccountStoreTests {
    private func makeStore() -> (AccountStore, MemorySecretStore) {
        let secrets = MemorySecretStore()
        return (AccountStore(secrets: secrets, preferences: MemoryAccountPreferences()), secrets)
    }

    @Test func movesTokensSavedPerHostIntoAccounts() throws {
        let (store, secrets) = makeStore()
        try secrets.set(
            SecretItem(account: "github.com", generic: Data("octo".utf8), data: Data("ghp_old".utf8)),
            label: "Wye: github.com", service: AccountStore.legacyService
        )
        try secrets.set(
            SecretItem(account: "git.example.com", generic: Data("me".utf8), data: Data("tok".utf8)),
            label: "Wye: git.example.com", service: AccountStore.legacyService
        )
        let accounts = try store.accounts()
        #expect(accounts.map(\.host) == ["git.example.com", "github.com"])
        let github = try #require(accounts.first { $0.host == "github.com" })
        #expect(github.kind == .github)
        #expect(github.signIn == .gitPrompt)
        #expect(try store.secret(for: github.id)?.token == "ghp_old")
        #expect(accounts.first { $0.host == "git.example.com" }?.kind == nil)
        #expect(try secrets.items(service: AccountStore.legacyService).isEmpty)
        // Git keeps getting the same credential.
        let credential = store.credential(forURL: "https://github.com/octo/p.git", host: "github.com")
        #expect(credential == Credential(username: "octo", token: "ghp_old"))
        #expect(store.defaultAccount(forHost: "github.com")?.id == github.id)
    }

    @Test func migrationSkipsWhatWasAlreadyMoved() throws {
        let (store, secrets) = makeStore()
        let item = SecretItem(account: "github.com", generic: Data("octo".utf8), data: Data("t".utf8))
        try secrets.set(item, label: "", service: AccountStore.legacyService)
        _ = try store.accounts()
        // As if deleting the old item had failed last time.
        try secrets.set(item, label: "", service: AccountStore.legacyService)
        try store.migrateLegacyTokens()
        #expect(try secrets.items(service: AccountStore.service).count == 1)
        #expect(try secrets.items(service: AccountStore.legacyService).isEmpty)
    }

    @Test func severalAccountsPerHostWithDefaultsAndChoices() throws {
        let (store, _) = makeStore()
        let work = HostingAccount(kind: .github, host: "github.com", login: "work", signIn: .token)
        let home = HostingAccount(kind: .github, host: "github.com", login: "home", signIn: .token)
        try store.save(work, secret: HostingSecret(token: "w"))
        try store.save(home, secret: HostingSecret(token: "h"))
        #expect(store.accounts(forHost: "github.com").count == 2)
        // The first one saved for a host is its default.
        #expect(store.credential(forURL: "https://github.com/a/b", host: "github.com")?.token == "w")
        store.setDefault(home.id, forHost: "github.com")
        #expect(store.credential(forURL: "https://github.com/a/b", host: "github.com")?.token == "h")
        // A repository's own choice wins, whatever its address's form.
        store.setAccount(work.id, forRemoteURL: "git@github.com:a/b.git")
        #expect(store.credential(forURL: "https://github.com/a/b.git", host: "github.com")?.token == "w")
        #expect(store.credential(forURL: "https://github.com/a/other", host: "github.com")?.token == "h")
        try store.remove(work.id)
        #expect(store.credential(forURL: "https://github.com/a/b.git", host: "github.com")?.token == "h")
        store.setAccount(nil, forRemoteURL: "https://github.com/a/b")
        #expect(try store.accounts().count == 1)
    }

    @Test func promptAnswersUpdateTheSameLogin() throws {
        let (store, _) = makeStore()
        let first = try store.storeGitCredential(Credential(username: "me", token: "one"), forHost: "GitLab.com")
        let second = try store.storeGitCredential(Credential(username: "me", token: "two"), forHost: "gitlab.com")
        #expect(first.id == second.id)
        #expect(first.kind == .gitlab)
        #expect(store.credential(forURL: "https://gitlab.com/g/p", host: "gitlab.com") == Credential(username: "me", token: "two"))
        let other = try store.storeGitCredential(Credential(username: "bot", token: "three"), forHost: "gitlab.com")
        #expect(store.accounts(forHost: "gitlab.com").count == 2)
        #expect(store.defaultAccount(forHost: "gitlab.com")?.id == other.id)
    }

    @Test func gitUsernamePerService() {
        #expect(HostingAccount(kind: .gitlab, host: "gitlab.com", login: "me", signIn: .oauth).gitCredentialUsername == "oauth2")
        #expect(HostingAccount(kind: .gitlab, host: "gitlab.com", login: "me", signIn: .token).gitCredentialUsername == "me")
        let bitbucket = HostingAccount(kind: .bitbucket, host: "bitbucket.org", login: "me", email: "me@example.com", signIn: .token)
        #expect(bitbucket.gitCredentialUsername == "me")
        #expect(bitbucket.authorization(token: "t") == .basic(username: "me@example.com", password: "t"))
        #expect(HostingAccount(kind: .gitea, host: "codeberg.org", login: "me", signIn: .token).authorization(token: "t") == .token("t"))
    }

    @Test func gitPromptAccountsDoNotReachTheService() {
        let account = HostingAccount(kind: .github, host: "github.com", login: "me", signIn: .gitPrompt)
        #expect(!account.usesService)
        #expect(throws: HostingError.self) { _ = try account.service(store: makeStore().0) }
    }

    @Test func signingInChecksTheTokenAndKeepsTheAccount() async throws {
        let (store, _) = makeStore()
        _ = try store.storeGitCredential(Credential(username: "octo", token: "old"), forHost: "github.com")
        let stub = StubTransport()
        stub.on("GET", "api.github.com/user", json: #"{"login":"octo","name":"Octo","avatar_url":"https://a.example/o"}"#)
        let account = try await HostingSignIn.signIn(
            kind: .github, host: "github.com", secret: HostingSecret(token: "new"), method: .token,
            store: store, transport: stub
        )
        #expect(account.login == "octo")
        #expect(account.usesService)
        // The token kept from a prompt became this account.
        #expect(try store.accounts().count == 1)
        #expect(try store.secret(for: account.id)?.token == "new")
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer new")

        let refused = StubTransport()
        refused.on("GET", "/user", status: 401, json: #"{"message":"Bad credentials"}"#)
        await #expect(throws: HostingError.unauthorized(host: "github.com")) {
            try await HostingSignIn.signIn(
                kind: .github, host: "github.com", secret: HostingSecret(token: "bad"), method: .token,
                store: store, transport: refused
            )
        }
    }

    @Test func readsHosts() {
        #expect(HostingSignIn.parseHost("https://Git.Example.com/")! == ("https", "git.example.com"))
        #expect(HostingSignIn.parseHost("git.example.com:8443")! == ("https", "git.example.com:8443"))
        #expect(HostingSignIn.parseHost("http://intranet")! == ("http", "intranet"))
        #expect(HostingSignIn.parseHost("ftp://x") == nil)
        #expect(HostingSignIn.parseHost("git.example.com/path") == nil)
    }
}

@Suite struct DeviceFlowTests {
    @Test func clientIDsComeFromInfoPlist() {
        let info: [String: Any] = [OAuthConfiguration.infoKey: ["github.com": "Iv1.abc", "gitlab.com": " "]]
        #expect(OAuthConfiguration.clientID(forHost: "GitHub.com", info: info) == "Iv1.abc")
        #expect(OAuthConfiguration.clientID(forHost: "gitlab.com", info: info) == nil)
        #expect(OAuthConfiguration.clientID(forHost: "github.com", info: [:]) == nil)
        #expect(!OAuthConfiguration.supportsDeviceFlow(.gitea))
        #expect(!OAuthConfiguration.supportsDeviceFlow(.bitbucket))
    }

    @Test func gitHubFlow() async throws {
        let stub = StubTransport()
        stub.on("POST", "github.com/login/device/code", json: """
        {"device_code":"dev","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
        """)
        // GitHub says "pending" with 200.
        stub.on("POST", "/login/oauth/access_token", json: #"{"error":"authorization_pending"}"#, once: true)
        stub.on("POST", "/login/oauth/access_token", json: #"{"error":"slow_down","interval":10}"#, once: true)
        stub.on("POST", "/login/oauth/access_token", json: #"{"access_token":"gho_x","token_type":"bearer","scope":"repo,read:org"}"#)
        let flow = DeviceFlow(kind: .github, host: "github.com", clientID: "cid", transport: stub)
        let now = Date(timeIntervalSince1970: 0)
        let authorization = try await flow.start(now: now)
        #expect(authorization.userCode == "WDJB-MJHT")
        #expect(authorization.expiresAt == now.addingTimeInterval(900))
        let start = try #require(stub.last("POST", "device/code"))
        #expect(start.formBody == ["client_id": "cid", "scope": "repo read:org"])
        #expect(try await flow.poll(authorization) == .pending)
        #expect(try await flow.poll(authorization) == .slowDown(10))
        #expect(try await flow.poll(authorization) == .authorized(HostingSecret(token: "gho_x")))
        #expect(stub.last("POST", "access_token")?.formBody["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
    }

    @Test func gitLabFlowWithRefresh() async throws {
        let stub = StubTransport()
        stub.on("POST", "gitlab.example.com/oauth/authorize_device", json: """
        {"device_code":"d","user_code":"0A44L90H","verification_uri":"https://gitlab.example.com/oauth/device",
         "verification_uri_complete":"https://gitlab.example.com/oauth/device?user_code=0A44L90H","expires_in":300,"interval":5}
        """)
        // GitLab says "pending" with an error status.
        stub.on("POST", "/oauth/token", status: 400, json: #"{"error":"authorization_pending","error_description":"..."}"#, once: true)
        stub.on("POST", "/oauth/token", json: #"{"access_token":"a","token_type":"Bearer","expires_in":7200,"refresh_token":"r","created_at":1}"#)
        let flow = DeviceFlow(kind: .gitlab, host: "gitlab.example.com", clientID: "cid", transport: stub)
        let authorization = try await flow.start()
        #expect(authorization.completeVerificationURL?.query() == "user_code=0A44L90H")
        #expect(try await flow.poll(authorization) == .pending)
        let now = Date(timeIntervalSince1970: 1000)
        guard case .authorized(let secret) = try await flow.poll(authorization, now: now) else {
            Issue.record("Not authorized")
            return
        }
        #expect(secret == HostingSecret(token: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(7200)))
        #expect(secret.isExpiring(now: now.addingTimeInterval(7180)))
        #expect(!secret.isExpiring(now: now))
    }

    @Test func refusalsAndExpiry() async throws {
        let stub = StubTransport()
        stub.on("POST", "/login/oauth/access_token", json: #"{"error":"access_denied"}"#, once: true)
        stub.on("POST", "/login/oauth/access_token", json: #"{"error":"expired_token"}"#)
        let flow = DeviceFlow(kind: .github, host: "github.com", clientID: "cid", transport: stub)
        let authorization = DeviceAuthorization(
            deviceCode: "d", userCode: "u", verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture, interval: 5
        )
        await #expect(throws: CancellationError.self) { _ = try await flow.poll(authorization) }
        await #expect(throws: HostingError.self) { _ = try await flow.poll(authorization) }
    }
}

@Suite struct PullRequestHelperTests {
    private let target = HostingTarget(
        remote: "origin", remoteURL: "git@github.com:octo/project.git",
        hosted: HostedRepository(remoteURL: "git@github.com:octo/project.git")!, kind: .github,
        path: RepositoryPath(owner: "octo", name: "project")
    )

    private func pullRequest(head: RepositoryReference?) -> PullRequest {
        PullRequest(
            number: 12, title: "T", body: "", state: .open, isDraft: false,
            head: PullRequestBranch(name: "topic", sha: nil, repository: head),
            base: PullRequestBranch(name: "main", sha: nil, repository: RepositoryReference(path: RepositoryPath("octo/project")))
        )
    }

    @Test func sameRepositoryTracksTheRemoteBranch() throws {
        let plan = try #require(PullRequestCheckout.plan(
            for: pullRequest(head: RepositoryReference(path: RepositoryPath("octo/project"))), target: target,
            remotes: [], branches: [], headReference: "refs/pull/12/head"
        ))
        #expect(plan.addRemote == nil)
        #expect(plan.refspec == "+refs/heads/topic:refs/remotes/origin/topic")
        #expect(plan.localName == "topic")
        #expect(plan.tracks)
    }

    @Test func anotherRepositoryGetsARemoteNamedForItsOwner() throws {
        let head = RepositoryReference(
            path: RepositoryPath("mona/project"), httpsURL: "https://github.com/mona/project.git",
            sshURL: "git@github.com:mona/project.git"
        )
        let taken = Branch(id: "refs/heads/topic", name: "topic", target: OID(hex: String(repeating: "a", count: 40))!)
        let plan = try #require(PullRequestCheckout.plan(
            for: pullRequest(head: head), target: target,
            remotes: [Remote(name: "origin", url: target.remoteURL, branches: [])], branches: [taken], headReference: nil
        ))
        // SSH, as origin is.
        #expect(plan.addRemote == .init(name: "mona", url: "git@github.com:mona/project.git"))
        #expect(plan.fetchedReference == "refs/remotes/mona/topic")
        #expect(plan.localName == "mona/topic")

        let existing = Remote(name: "theirs", url: "https://github.com/mona/project", branches: [])
        let reused = try #require(PullRequestCheckout.plan(
            for: pullRequest(head: head), target: target, remotes: [existing], branches: [], headReference: nil
        ))
        #expect(reused.addRemote == nil)
        #expect(reused.fetchFrom == "theirs")
    }

    @Test func goneRepositoryFallsBackToThePullRequestReference() throws {
        var gone = pullRequest(head: nil)
        gone.head.repository = RepositoryReference(path: nil)
        let plan = try #require(PullRequestCheckout.plan(
            for: gone, target: target, remotes: [], branches: [], headReference: "refs/pull/12/head"
        ))
        #expect(plan.refspec == "+refs/pull/12/head:refs/remotes/origin/pr/12")
        #expect(plan.localName == "pr/12")
        #expect(!plan.tracks)
        #expect(PullRequestCheckout.plan(for: gone, target: target, remotes: [], branches: [], headReference: nil) == nil)
    }

    @Test func textFromCommits() {
        let one = PullRequestText.draft(commits: ["Add login\n\nWith a form."], branch: "feature/login")
        #expect(one.title == "Add login")
        #expect(one.body == "With a form.")
        let several = PullRequestText.draft(commits: ["Second\n\nx", "First"], branch: "feature/new-login")
        #expect(several.title == "New login")
        #expect(several.body == "- First\n- Second")
    }

    @Test func markdownBlocks() {
        let text = """
        # Title

        Some *text*
        on two lines.

        - one
        - [x] two
        1. first
        > quoted

        ```swift
        let x = 1
        ```
        ---
        """
        #expect(MarkdownBlock.blocks(in: text) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some *text*\non two lines."),
            .list(ordered: false, items: ["one", "[x] two"]),
            .list(ordered: true, items: ["first"]),
            .quote("quoted"),
            .code(language: "swift", text: "let x = 1"),
            .rule
        ])
        #expect(MarkdownView.taskText("[x] two") == "☑ two")
    }
}
