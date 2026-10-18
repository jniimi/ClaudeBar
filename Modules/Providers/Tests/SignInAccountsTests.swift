import DataSources
import Quotas
import Foundation
import Mockable
@testable import Providers
import Testing

/// *Sign in with browser*: the definition's login runs into a new folder, and
/// the provider checks it as *Choose Signed-in Folder* does. ClaudeBar
/// remembers that it made the folder, so *Remove* takes the folder with it;
/// a folder the person chose is theirs.
@MainActor
@Suite
struct SignInAccountsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("sign-in-accounts-\(UUID().uuidString)")

    /// A login that writes a Codex `auth.json` into the folder it is given.
    private func codexLogin(email: String?, accountId: String = "work", folders: InMemoryLoginFolders) -> AccountSignIn {
        let process = MockSignInProcess()
        given(process).run(executable: .any, arguments: .any, environment: .any, directory: .any, timeout: .any)
            .willProduce { @Sendable _, _, _, folder, _ in
                // The vendor's CLI writes its login into the folder it was given.
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if let email {
                    let claims = try JSONSerialization.data(withJSONObject: ["email": email])
                    let jwt = "h." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
                    let auth = ["tokens": ["access_token": "t", "account_id": accountId, "id_token": jwt]]
                    try JSONSerialization.data(withJSONObject: auth).write(to: folder.appendingPathComponent("auth.json"))
                }
                return 0
            }
        return AccountSignIn(process: process, folders: folders, locate: { _ in "/usr/local/bin/codex" })
    }

    private func signIn(_ login: AccountSignIn, into codex: Provider) async throws -> Account {
        try await codex.accounts.signIn(with: login, under: root)
    }


    // MARK: - Signing in

    @Test
    func `should add the login the new folder holds when the person signs in with the browser`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp(); try? FileManager.default.removeItem(at: root) }
        let codex = try stub.makeProvider("codex")

        let added = try await signIn(codexLogin(email: "work@example.com", folders: stub.folders), into: codex)

        let folder = try #require(added.folder)
        #expect(added.email == "work@example.com")
        #expect(added.values["accountId"] == "work")
        #expect(folder.madeBy == .signIn)
        #expect(folder.url.deletingLastPathComponent().lastPathComponent == "codex")
        #expect(stub.settings.accounts(forProvider: "codex").first?.madeBy == .signIn)
    }

    @Test
    func `should add no login and leave no folder when sign-in ends without a login`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp(); try? FileManager.default.removeItem(at: root) }
        let codex = try stub.makeProvider("codex")

        await #expect(throws: UsageError.self) { try await signIn(codexLogin(email: nil, folders: stub.folders), into: codex) }

        #expect(stub.folders.all.isEmpty)
        #expect(codex.accounts.count == 1)
    }

    @Test
    func `should leave no new folder when the person signs in to a login already listed`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp(); try? FileManager.default.removeItem(at: root) }
        let codex = try stub.makeProvider("codex")
        try await signIn(codexLogin(email: "work@example.com", folders: stub.folders), into: codex)

        await #expect(throws: UsageError.self) { try await signIn(codexLogin(email: "work@example.com", folders: stub.folders), into: codex) }

        #expect(stub.folders.all.count == 1)
    }

    // MARK: - Which folder goes with an account

    @Test
    func `should remove the folder with its login when ClaudeBar made it by signing in`() {
        let folder = SignedInFolder.forSignIn(to: "codex", under: root)

        #expect(folder.goesWithAccount)
    }

    @Test
    func `should keep a folder the person chose when its login is removed`() {
        let chosen = SignedInFolder(url: root.appendingPathComponent("codex/\(UUID().uuidString)"), madeBy: .folder)

        #expect(!chosen.goesWithAccount)
    }

    @Test
    func `should never delete a signed-in folder ClaudeBar did not name`() {
        let renamed = SignedInFolder(url: URL(fileURLWithPath: "/Users/me/.codex"), madeBy: .signIn)

        #expect(!renamed.goesWithAccount)
    }

    // MARK: - Adding and removing

    @Test
    func `should remember a login once it is added`() throws {
        let settings = InMemoryProviderSettings()
        let codex = try ProviderFactory.make("codex", settings: settings)
        let work = ProviderAccountConfig(accountId: "a", label: "", email: "w@example.com",
                                         probeConfig: ["folder": "/tmp/a", "accountId": "a"])

        codex.accounts.add(work)

        #expect(settings.accounts(forProvider: "codex") == [work])
    }

    @Test
    func `should delete the folder ClaudeBar made when its signed-in login is removed`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp(); try? FileManager.default.removeItem(at: root) }
        let codex = try stub.makeProvider("codex")
        let added = try await signIn(codexLogin(email: "work@example.com", folders: stub.folders), into: codex)

        codex.accounts.remove(added)

        #expect(stub.folders.all.isEmpty)
        #expect(stub.settings.accounts(forProvider: "codex").isEmpty)
    }

    @Test
    func `should keep the person's folder when its login is removed`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let claims = try JSONSerialization.data(withJSONObject: ["email": "me@example.com"])
        let jwt = "h." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
        let folder = stub.home.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "t", "account_id": "me", "id_token": jwt]])
            .write(to: folder.appendingPathComponent("auth.json"))
        try stub.folders.create(folder)
        let codex = try stub.makeProvider("codex")
        let added = try codex.accounts.add(signedInAt: folder)

        codex.accounts.remove(added)

        #expect(stub.folders.exists(folder))
    }

    // MARK: - Signing in again

    @Test
    func `should sign in again in the folder ClaudeBar made and then show fresh usage`() async throws {
        let stub = try StubbedProvider(dataSourceKind: "api", providerId: "codex")
        defer { stub.cleanUp(); try? FileManager.default.removeItem(at: root) }
        stub.answerHTTP(#"{"rate_limit":{"primary_window":{"used_percent":10}}}"#)
        let codex = try stub.makeProvider("codex")
        let added = try await signIn(codexLogin(email: "work@example.com", folders: stub.folders), into: codex)
        let launch = SignInLaunch()

        try await codex.accounts.signInAgain(added, with: launch.recording(folders: stub.folders))
        let usage = try await codex.refresh(added)

        #expect(launch.directory == added.folder?.url.path)
        #expect(usage.sessionQuota?.percentRemaining == 90)
        #expect(stub.folders.exists(try #require(added.folder).url))
    }

    @Test
    func `should refuse to sign in again in a folder the person chose`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let claims = try JSONSerialization.data(withJSONObject: ["email": "me@example.com"])
        let jwt = "h." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
        let folder = stub.home.appendingPathComponent("mine")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "t", "account_id": "me", "id_token": jwt]])
            .write(to: folder.appendingPathComponent("auth.json"))
        let codex = try stub.makeProvider("codex")
        let added = try codex.accounts.add(signedInAt: folder)
        let launch = SignInLaunch()

        await #expect(throws: UsageError.self) { try await codex.accounts.signInAgain(added, with: launch.recording(folders: stub.folders)) }

        #expect(launch.directory == nil)
    }

    // MARK: - The ways to add, from the definition

    @Test
    func `should offer Codex and Claude logins by browser sign-in first, then by choosing a folder`() throws {
        #expect(try ProviderFactory.builtIn("codex").accounts?.ways == [.signIn, .folder])
        #expect(try ProviderFactory.builtIn("claude").accounts?.ways == [.signIn, .folder])
    }

    @Test
    func `should sign Claude in with its own config folder and no inherited API key`() throws {
        let call = try #require(try ProviderFactory.builtIn("claude").signInCall(into: "/accounts/claude/new"))

        #expect(call.cli == "claude")
        #expect(call.args == ["auth", "login", "--claudeai"])
        #expect(call.environment.set == ["CLAUDE_CONFIG_DIR": "/accounts/claude/new"])
        #expect(call.environment.unset.contains("ANTHROPIC_API_KEY"))
    }

    @Test
    func `should refuse a provider whose browser sign-in has no way to check the folder`() {
        let json = #"{ "signIn": { "args": ["login"] } }"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProviderDefinition.Accounts.self, from: Data(json.utf8))
        }
    }
}

/// Where a login was run — for *Sign in again*, which runs in an existing folder.
private final class SignInLaunch: @unchecked Sendable {
    var directory: String?

    func recording(folders: InMemoryLoginFolders) -> AccountSignIn {
        let process = MockSignInProcess()
        given(process).run(executable: .any, arguments: .any, environment: .any, directory: .any, timeout: .any)
            .willProduce { @Sendable [self] _, _, _, folder, _ in
                directory = folder.path
                return 0
            }
        return AccountSignIn(process: process, folders: folders, locate: { _ in "/usr/local/bin/codex" })
    }
}
