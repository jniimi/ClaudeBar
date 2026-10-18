import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// *Signed in as …* — who is signed in, said once for a provider and read by
/// every data source (#577): the pill's email, what a mapping reads, and the
/// person an added folder account must still be on every fetch.
@Suite
struct SignedInAsTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("signed-in-as-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func signIn(as account: String, email: String) throws {
        let file = #"{ "tokens": { "account_id": "\#(account)" }, "email": "\#(email)", "plan": "team" }"#
        try Data(file.utf8).write(to: folder.appendingPathComponent("auth.json"))
    }

    private var who: SignedInAs {
        get throws {
            try JSONDecoder().decode(SignedInAs.self, from: Data(#"""
            { "file": "\#(folder.path)/auth.json", "id": "$.tokens.account_id", "email": "$.email", "plan": "$.plan" }
            """#.utf8))
        }
    }

    private func source(_ mapping: String = #"{ "json": { "quotas": [] } }"#) throws -> DataSourceDefinition {
        try JSONDecoder().decode(DataSourceDefinition.self, from: Data(#"""
        { "kind": "api", "fetch": { "http": { "url": "https://api.example.com/usage" } }, "mapping": \#(mapping) }
        """#.utf8))
    }

    private func make(_ definition: DataSourceDefinition) -> DataSource {
        let network = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://api.example.com")!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        given(network).request(.any).willReturn((Data("{}".utf8), response))
        return DataSources.make(
            definition, providerId: "codex", cliExecutor: MockCLIExecutor(), network: network,
            makeTransport: { _, _, _, _ in MockRPCTransport() }, environment: { _ in nil },
            homeDirectory: FileManager.default.temporaryDirectory, now: { Date() }
        )
    }

    @Test
    func `should show who is signed in when the answer doesn't say`() async throws {
        try signIn(as: "acct-work", email: "mia@acme.com")

        let usage = try await make(source().knowing(who)).fetchUsage()

        #expect(usage.accountEmail == "mia@acme.com")
    }

    @Test
    func `should let a mapping read who is signed in`() async throws {
        try signIn(as: "acct-work", email: "mia@acme.com")
        let mapping = #"{ "json": { "quotas": [], "email": ["$signedInAs.plan"] } }"#

        let usage = try await make(source(mapping).knowing(who)).fetchUsage()

        #expect(usage.accountEmail == "team")
    }

    @Test
    func `should refuse the usage when someone else is now signed in to the folder`() async throws {
        try signIn(as: "acct-someone-else", email: "sam@acme.com")

        let checked = try source().knowing(who).checkingSignedIn(is: "acct-work")

        await #expect(throws: DataSourceError.self) { try await make(checked).fetchUsage() }
    }

    @Test
    func `should take a folder that no longer holds a login as not signed in`() async throws {
        let checked = try source().knowing(who).checkingSignedIn(is: "acct-work")

        #expect(checked.requiresFiles == ["\(folder.path)/auth.json"])
        await #expect(throws: DataSourceError.self) { try await make(checked).fetchUsage() }
    }

    @Test
    func `should show the usage of the person still signed in`() async throws {
        try signIn(as: "acct-work", email: "mia@acme.com")

        let usage = try await make(source().knowing(who).checkingSignedIn(is: "acct-work")).fetchUsage()

        #expect(usage.accountEmail == "mia@acme.com")
    }
}

/// How the vendor's CLI runs for an added account (`accounts.cli`): pointed at
/// its folder and blind to this Mac's login, on every run of that CLI.
@Suite
struct CLISetupTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private var setup: CLISetup {
        get throws {
            try decode(CLISetup.self, #"""
            { "environment": { "set": { "CODEX_HOME": "{{account.folder}}" }, "unset": ["OPENAI_API_KEY"] },
              "args": ["-c", "cli_auth_credentials_store=\"file\""] }
            """#)
        }
    }

    @Test
    func `should run the vendor's CLI pointed at the account's folder, blind to this Mac's key`() throws {
        let rpc = try decode(DataSourceDefinition.self, #"""
        { "kind": "rpc", "fetch": { "jsonRpc": { "cli": "codex", "args": ["app-server"], "call": "read",
                                                 "environment": { "unset": ["CODEX_HOME"] } } },
          "mapping": { "json": {} } }
        """#)

        let run = try rpc.runningCLI("codex", with: setup)

        guard case .jsonRpc(let call) = run.fetch else { Issue.record("expected the RPC"); return }
        #expect(call.args == ["-c", "cli_auth_credentials_store=\"file\"", "app-server"])
        #expect(call.environment.set == ["CODEX_HOME": "{{account.folder}}"])
        #expect(call.environment.unset == ["OPENAI_API_KEY"])
    }

    @Test
    func `should renew a login file with the CLI pointed at the account's folder`() throws {
        let api = try decode(DataSourceDefinition.self, #"""
        { "kind": "api",
          "credential": { "jsonFile": { "path": "{{account.home}}/.gemini/oauth_creds.json", "token": "$.access_token" },
                          "refresh": { "cli": { "cli": "gemini", "input": "/quit\n" } } },
          "fetch": { "http": { "url": "https://example.com" } }, "mapping": { "json": {} } }
        """#)
        let gemini = try decode(CLISetup.self, #"{ "environment": { "set": { "GEMINI_CLI_HOME": "{{account.home}}" } } }"#)

        let run = api.runningCLI("gemini", with: gemini)

        guard case .refreshing(_, .cli(let call)) = run.credential else { Issue.record("expected the renewal"); return }
        #expect(call.environment.set == ["GEMINI_CLI_HOME": "{{account.home}}"])
    }

    @Test
    func `should leave another program's runs as they are`() throws {
        let other = try decode(DataSourceDefinition.self,
            #"{ "kind": "cli", "fetch": { "command": { "cli": "amp", "args": ["usage"] } }, "mapping": { "json": {} } }"#)

        #expect(try other.runningCLI("codex", with: setup) == other)
    }
}
