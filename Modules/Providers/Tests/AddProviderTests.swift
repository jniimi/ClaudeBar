import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// *Add Provider* (USER_JOURNEYS moments 5–9): the sheet's answers become a
/// definition — the same data the built-ins are — and run on the same
/// `Provider` and `DataSource`.
@MainActor
@Suite
struct AddProviderTests {
    /// Ken's OpenRouter: an API, his own key, money of a limit.
    private func openRouter() -> ProviderDraft {
        var draft = ProviderDraft(start: .api)
        draft.url = "https://openrouter.ai/api/v1/auth/key"
        draft.key = .apiKey
        draft.sentAs = .bearer
        draft.measure = .money(currency: "USD")
        draft.remaining = "$.data.limit_remaining"
        draft.limit = "$.data.limit"
        draft.name = "OpenRouter"
        draft.symbol = "dollarsign.circle"
        return draft
    }

    // MARK: - Start from API

    @Test
    func `should ask the API the person typed, with the key they saved, when they start from an API`() throws {
        let definition = try openRouter().definition(id: "custom-openrouter-1a2b3c")

        #expect(definition.id == "custom-openrouter-1a2b3c")
        #expect(definition.profile.name == "OpenRouter")
        #expect(definition.profile.origin == .custom)
        #expect(definition.profile.look.symbol == "dollarsign.circle")
        let source = try #require(definition.dataSources.first)
        #expect(definition.defaultDataSource == "api")
        #expect(source.credential == .setting("apiKey"))
        guard case .http(let request) = source.fetch else {
            Issue.record("Expected an http fetch")
            return
        }
        #expect(request.url == "https://openrouter.ai/api/v1/auth/key")
        #expect(request.headers == ["Authorization": "Bearer {{token}}", "Accept": "application/json"])
    }

    @Test
    func `should send a key from an environment variable in the header the person chose`() throws {
        var draft = openRouter()
        draft.key = .environment("OPENROUTER_API_KEY")
        draft.sentAs = .header("X-API-Key")

        let source = try #require(try draft.definition(id: "custom-x").dataSources.first)

        #expect(source.credential == .firstOf([.environment("OPENROUTER_API_KEY"), .setting("apiKey")]))
        guard case .http(let request) = source.fetch else { return }
        #expect(request.headers["X-API-Key"] == "{{token}}")
    }

    @Test
    func `should show money of its limit, with no reset, when the drafted provider is refreshed`() async throws {
        let network = MockNetworkClient()
        given(network).request(.matching { @Sendable in $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-1" })
            .willReturn((Data(#"{"data":{"limit_remaining":12.4,"limit":50}}"#.utf8),
                         HTTPURLResponse(url: URL(string: "https://openrouter.ai")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        let vault = MemoryVault(["custom-openrouter.apiKey": "sk-or-1"])
        let definition = try openRouter().definition(id: "custom-openrouter")
        let provider = Provider(definition: definition, settings: InMemoryProviderSettings(), makeDataSource: {
            DataSources.make($0, providerId: definition.id, cliExecutor: MockCLIExecutor(), network: network,
                             makeTransport: { _, _, _, _ in MockRPCTransport() }, secrets: vault,
                             environment: { _ in nil }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
        })

        let usage = try await provider.refreshPlain()

        let quota = try #require(usage.quotas.first)
        #expect(quota.left == .money(Money(Decimal(string: "12.4")!, currency: "USD"), of: Money(50, currency: "USD")))
        #expect(quota.resetsAt == nil)
    }

    @Test
    func `should show no percentage when the person maps no limit`() throws {
        var draft = openRouter()
        draft.limit = nil

        let mapping = try #require(try draft.definition(id: "custom-x").dataSources.first?.mapping)
        guard case .json(let json) = mapping else { return }

        #expect(json.quotas.first?.left == QuotaRule.MoneyLeft(money: .value([.path("$.data.limit_remaining")]), of: nil, currency: "USD"))
    }

    @Test
    func `should show a percentage used with its reset when the person maps both`() throws {
        var draft = openRouter()
        draft.measure = .percentUsed
        draft.used = "$.usage.percent"
        draft.resets = "$.usage.resets_at"
        draft.resetsFormat = .iso8601

        let mapping = try #require(try draft.definition(id: "custom-x").dataSources.first?.mapping)
        guard case .json(let json) = mapping else { return }

        #expect(json.quotas.first?.usedPercent == [.path("$.usage.percent")])
        #expect(json.quotas.first?.resetsAt == [.iso8601("$.usage.resets_at")])
    }

    // MARK: - Start from CLI · File

    @Test
    func `should run the command the person typed, from the dedicated folder, when they start from a CLI`() throws {
        var draft = ProviderDraft(start: .cli)
        draft.command = #"mytool usage --format "json""#
        draft.measure = .percentLeft
        draft.remaining = "$.left"
        draft.name = "My Tool"

        let source = try #require(try draft.definition(id: "custom-mytool").dataSources.first)

        #expect(source.kind == "cli")
        // A command a person types runs over pipes; only a TUI needs a terminal.
        guard case .command(let call) = source.fetch else {
            Issue.record("Expected a command fetch")
            return
        }
        #expect(call.cli == "mytool")
        #expect(call.args == ["usage", "--format", "json"])
        #expect(call.workingDirectory == .dedicated)
        #expect(source.credential == nil)
    }

    @Test
    func `should read a CLI's text by the line that names the number`() throws {
        var draft = ProviderDraft(start: .cli)
        draft.command = "mytool status"
        draft.measure = .percentLeft
        draft.textLabel = "Quota"
        draft.name = "My Tool"

        let mapping = try #require(try draft.definition(id: "custom-mytool").dataSources.first?.mapping)
        guard case .text(let text) = mapping else {
            Issue.record("Expected a text mapping")
            return
        }
        #expect(text.quotas.first?.label == "Quota")
        #expect(text.quotas.first?.leftPercent != nil)
    }

    @Test
    func `should read the file the person chose when they start from a file`() throws {
        var draft = ProviderDraft(start: .file)
        draft.path = "~/.mytool/usage.json"
        draft.measure = .percentUsed
        draft.used = "$.used"
        draft.name = "My Tool"

        let source = try #require(try draft.definition(id: "custom-mytool").dataSources.first)

        #expect(source.kind == "file")
        #expect(source.fetch == .file(FileCall(path: "~/.mytool/usage.json")))
    }

    @Test
    func `should say what is missing when a draft lacks what it needs`() {
        var draft = ProviderDraft(start: .api)
        draft.name = "Nameless"

        #expect(throws: ProviderDraft.Missing.self) { try draft.definition(id: "custom-x") }
    }

    // MARK: - Copy a provider

    @Test
    func `should run the same data sources under a new id and name, as custom, when a provider is copied`() throws {
        let codex = try ProviderFactory.builtIn("codex")
        var draft = ProviderDraft(start: .copy(codex))
        draft.name = "Codex (work)"

        let copy = try draft.definition(id: "custom-codex-work")

        #expect(copy.id == "custom-codex-work")
        #expect(copy.profile.name == "Codex (work)")
        #expect(copy.profile.origin == .custom)
        #expect(copy.dataSources == codex.dataSources)
        #expect(copy.profile.look == codex.profile.look)
    }

    // MARK: - Map fields

    @Test
    func `should offer each value of a response as a path to click`() {
        let fields = ResponseFields(Response(status: 200, body: Data(#"{"data":{"limit":50,"label":"key","items":[{"x":1}],"ok":true}}"#.utf8)))

        #expect(fields.map(\.path) == ["$.data.items.0.x", "$.data.label", "$.data.limit", "$.data.ok"])
        #expect(fields.first { $0.path == "$.data.limit" }?.value == "50")
        #expect(fields.first { $0.path == "$.data.limit" }?.isNumber == true)
        #expect(fields.first { $0.path == "$.data.label" }?.isNumber == false)
    }

    @Test
    func `should offer a response's lines when it is not JSON`() {
        let fields = ResponseFields(Response(text: "Quota: 42% left\nPlan: Pro"))

        #expect(fields.isEmpty)
        #expect(ResponseFields.lines(of: Response(text: "Quota: 42% left\nPlan: Pro")) == ["Quota: 42% left", "Plan: Pro"])
    }

    // MARK: - The catalog

    @Test
    func `should bring a saved provider back as custom until it is removed`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = ProviderCatalog(directory: folder)
        let definition = try openRouter().definition(id: catalog.mintId(for: "OpenRouter"))

        try catalog.add(definition)
        let saved = catalog.custom()
        try catalog.remove(definition.id)

        #expect(saved.map(\.id) == [definition.id])
        #expect(saved.first?.profile.origin == .custom)
        #expect(saved.first?.dataSources == definition.dataSources)
        #expect(catalog.custom().isEmpty)
    }

    @Test
    func `should mint an id that is never just the name and never a built-in's`() {
        let catalog = ProviderCatalog(directory: FileManager.default.temporaryDirectory)

        let first = catalog.mintId(for: "Codex")
        let second = catalog.mintId(for: "Codex")

        #expect(first.hasPrefix("custom-codex-"))
        #expect(first != second)
        #expect(ProviderFactory.builtInDefinitions[first] == nil)
    }

    @Test
    func `should keep no key in a saved provider's file`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = ProviderCatalog(directory: folder)
        let definition = try openRouter().definition(id: "custom-openrouter")

        try catalog.add(definition)
        let text = try String(contentsOf: folder.appendingPathComponent("custom-openrouter.json"), encoding: .utf8)

        #expect(text.contains("\"setting\" : \"apiKey\""))
        #expect(!text.contains("sk-"))
    }
}

/// A vault in memory, keyed `<provider>.<name>`.
final class MemoryVault: SecretVault, @unchecked Sendable {
    var secrets: [String: String]
    init(_ secrets: [String: String] = [:]) { self.secrets = secrets }
    func secret(_ name: String, provider: String) -> String? { secrets["\(provider).\(name)"] }
    func save(_ value: String, _ name: String, provider: String) { secrets["\(provider).\(name)"] = value }
    @discardableResult func delete(_ name: String, provider: String) -> Bool { secrets.removeValue(forKey: "\(provider).\(name)") != nil }
}

/// Screens that only hold an id find a custom provider's face and name too.
@Suite(.serialized)
struct CustomRegistryTests {
    @Test
    func `should find a registered custom provider by its lineup id until it is unregistered`() throws {
        var draft = ProviderDraft(start: .file)
        draft.path = "~/usage.json"
        draft.used = "$.used"
        draft.name = "Local Tool"
        let definition = try draft.definition(id: "custom-local-tool-abc123")

        ProviderFactory.register(custom: definition)
        let found = ProviderFactory.definition(forLineupId: "custom-local-tool-abc123")
        ProviderFactory.unregister(custom: definition.id)

        #expect(found?.profile.name == "Local Tool")
        #expect(ProviderFactory.definition(forLineupId: "custom-local-tool-abc123") == nil)
        #expect(ProviderFactory.definition(forLineupId: "codex.work")?.id == "codex")
    }
}

@Suite
struct DraftConnectionTests {
    @Test
    func `should let a connection be tested before anything is mapped`() throws {
        var draft = ProviderDraft(start: .api)
        draft.url = "https://example.com/usage"
        draft.name = "Example"

        let source = try draft.connection()

        #expect(source.credential == .setting("apiKey"))
        #expect(source.mapping == .json(JSONMapping(quotas: [])))
        #expect(throws: ProviderDraft.Missing.used) { try draft.definition(id: "x") }
    }
}
