import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing

/// *CLI location* — where a provider's CLI lives on this Mac, when it isn't
/// the one ClaudeBar finds on its own (#210). One fact per provider: every
/// login, every CLI data source and Add Account's sign-in run it.
@MainActor
@Suite
struct CLILocationTests {
    private static let path = "/opt/tools/bin/codex-work"

    private func cli(of source: DataSource) -> String? {
        switch source.definition.fetch {
        case .cli(let call): call.cli
        case .jsonRpc(let call): call.cli
        default: nil
        }
    }

    private func login(_ id: String) -> ProviderAccountConfig {
        ProviderAccountConfig(accountId: id, label: "", email: "\(id)@example.com",
                              probeConfig: ["folder": "/tmp/\(id)", "accountId": id])
    }

    nonisolated private static let app = "/Applications/Codex.app/Contents/Resources/codex"

    @Test
    func `should run the CLI inside the app when it isn't on the PATH`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex", accounts: [login("work")], isExecutable: { $0 == Self.app },
                                          locate: { _ in nil })

        for account in codex.accounts {
            #expect(codex.dataSources(for: account).compactMap(cli).allSatisfy { $0 == Self.app })
        }
        #expect(codex.configuration.cliPath == nil)
    }

    @Test
    func `should run the CLI on the PATH even when the app carries one`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex", isExecutable: { _ in true }, locate: { _ in "/usr/local/bin/codex" })

        #expect(codex.dataSources(for: codex.defaultAccount).compactMap(cli).allSatisfy { $0 == "codex" })
    }

    @Test
    func `should never run the app's copy when the chosen location is missing`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        stub.settings.setCLIPath("/custom/missing/codex", forProvider: "codex")

        let codex = try stub.makeProvider("codex", isExecutable: { $0 == Self.app }, locate: { _ in nil })

        #expect(codex.dataSources(for: codex.defaultAccount).compactMap(cli).allSatisfy { $0 == "/custom/missing/codex" })
    }

    @Test
    func `should sign in with the CLI inside the app`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex", isExecutable: { $0 == Self.app }, locate: { _ in nil })
        let ran = Ran()
        let process = MockSignInProcess()
        given(process).run(executable: .any, arguments: .any, environment: .any, directory: .any, timeout: .any)
            .willProduce { @Sendable executable, _, _, _, _ in
                ran.executable = executable
                return 1
            }

        _ = try? await codex.accounts.signIn(with: AccountSignIn(process: process, folders: stub.folders, locate: { $0 }))

        #expect(ran.executable == Self.app)
    }

    private static func acme(cli: String) throws -> ProviderDefinition {
        try ProviderDefinition.parse(Data("""
        { "profile": { "id": "acme", "name": "Acme" }, "cli": \(cli), "enabledByDefault": true,
          "defaultDataSource": "cli",
          "dataSources": [ { "kind": "cli", "fetch": { "jsonRpc": { "cli": "acme", "call": "usage/read" } },
                             "mapping": { "json": { "quotas": [] } } } ] }
        """.utf8))
    }

    @Test func `should run the name listed first and keep the other places`() throws {
        let definition = try Self.acme(cli: #"["acme", "/Applications/Acme.app/acme"]"#)

        #expect(definition.cli == "acme")
        #expect(definition.cliPlaces == ["/Applications/Acme.app/acme"])
    }

    @Test func `should keep a CLI with no other place as one name`() throws {
        let definition = try Self.acme(cli: #""acme""#)

        let json = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)

        #expect(definition.cliPlaces.isEmpty)
        #expect(json.contains(#""cli":"acme""#))
    }

    @Test func `should refresh API credentials with the chosen CLI`() throws {
        let definition = try ProviderFactory.builtIn("gemini").runningCLI("/opt/tools/gemini")
        guard case .refreshing(_, .cli(let refresh)) = definition.dataSource("api")?.credential else {
            Issue.record("Expected a CLI credential refresh")
            return
        }
        #expect(refresh.cli == "/opt/tools/gemini")
        #expect(refresh.input == "/quit\n")
        #expect(refresh.environment.unset.contains("GEMINI_API_KEY"))
    }

    @Test func `should keep terminal input timing when the CLI location changes`() throws {
        let definition = try ProviderFactory.builtIn("kimi")
        guard case .cli(let before) = definition.dataSource("cli")?.fetch,
              case .cli(let after) = try definition.runningCLI("/opt/tools/kimi").dataSource("cli")?.fetch else {
            Issue.record("Expected the Kimi terminal call")
            return
        }
        #expect(before.inputDelay == 1.5)
        #expect(after.inputDelay == before.inputDelay)
    }

    @Test
    func `should run the CLI from the chosen location for every login`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex", accounts: [login("work")], isExecutable: { _ in true })

        try codex.configuration.setCLIPath(Self.path)

        for account in codex.accounts {
            let clis = codex.dataSources(for: account).compactMap(cli)
            #expect(!clis.isEmpty)
            #expect(clis.allSatisfy { $0 == Self.path })
        }
        #expect(codex.configuration.cliPath == Self.path)
        #expect(stub.settings.cliPath(forProvider: "codex") == Self.path)
    }

    @Test
    func `should go back to finding the CLI as usual when the location is cleared`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex", isExecutable: { _ in true })
        try codex.configuration.setCLIPath(Self.path)

        try codex.configuration.setCLIPath("  ")

        #expect(codex.configuration.cliPath == nil)
        #expect(codex.dataSources(for: codex.defaultAccount).compactMap(cli).allSatisfy { $0 == "codex" })
        #expect(stub.settings.cliPath(forProvider: "codex") == nil)
    }

    @Test
    func `should refuse a location that is not a program and change nothing`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex", isExecutable: { _ in false })

        #expect(throws: UsageError.self) { try codex.configuration.setCLIPath("/Users/me/notes.txt") }

        #expect(codex.configuration.cliPath == nil)
        #expect(codex.dataSources(for: codex.defaultAccount).compactMap(cli).allSatisfy { $0 == "codex" })
    }

    @Test
    func `should use the saved CLI location after a relaunch`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        try stub.makeProvider("codex", isExecutable: { _ in true }).configuration.setCLIPath(Self.path)

        let relaunched = try stub.makeProvider("codex")

        #expect(relaunched.dataSources(for: relaunched.defaultAccount).compactMap(cli).allSatisfy { $0 == Self.path })
    }

    @Test
    func `should sign in a new account with the CLI at the chosen location`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex", isExecutable: { _ in true })
        try codex.configuration.setCLIPath(Self.path)
        let ran = Ran()
        let process = MockSignInProcess()
        given(process).run(executable: .any, arguments: .any, environment: .any, directory: .any, timeout: .any)
            .willProduce { @Sendable executable, _, _, _, _ in
                ran.executable = executable
                return 1
            }

        _ = try? await codex.accounts.signIn(with: AccountSignIn(process: process, folders: stub.folders, locate: { $0 }))

        #expect(ran.executable == Self.path)
    }
}

private final class Ran: @unchecked Sendable {
    var executable: String?
}
