import DataSources
import Foundation
import Testing

/// A definition read for one account: its values fill `{{account.x}}` — one
/// definition, never a copy per account.
@Suite
struct DefinitionTemplateTests {
    private static let rpc = """
    {
      "kind": "rpc",
      "label": "RPC",
      "fetch": { "jsonRpc": { "cli": "codex", "args": ["app-server"], "call": "account/rateLimits/read" } },
      "mapping": { "json": { "quotas": [{ "kind": "session", "at": "$.result.primary", "usedPercent": "usedPercent" }] } },
      "requiresFiles": ["~/.codex/auth.json"],
      "verifyBeforeBackground": true,
      "fallback": "tty"
    }
    """

    private func definition(_ json: String = rpc) throws -> DataSourceDefinition {
        try JSONDecoder().decode(DataSourceDefinition.self, from: Data(json.utf8))
    }

    // MARK: - Round trip

    @Test
    func `should keep a definition when it is written out and read back`() throws {
        let rpc = try definition()

        let again = try JSONDecoder().decode(DataSourceDefinition.self, from: JSONEncoder().encode(rpc))

        #expect(again == rpc)
    }

    // MARK: - Filling an account's values

    @Test
    func `should fill every account placeholder with the account's own values`() throws {
        let template = try definition("""
        { "kind": "api", "requiresFiles": ["{{account.folder}}/auth.json"],
          "identity": { "field": "account", "equals": "{{account.accountId}}" },
          "fetch": { "http": { "url": "https://example.com" } }, "mapping": { "json": { "quotas": [] } } }
        """)

        let filled = try template.filled(["folder": "/Users/me/codex-work", "accountId": "acct-1"], scope: "account")

        #expect(filled.requiresFiles == ["/Users/me/codex-work/auth.json"])
        #expect(filled.identity?.equals == "acct-1")
        #expect(filled.unfilled(scope: "account").isEmpty)
    }

    @Test
    func `should leave placeholders other than the account's for the fetch to fill`() throws {
        let template = try definition("""
        { "kind": "api",
          "fetch": { "http": { "url": "https://example.com", "headers": { "Authorization": "Bearer {{token}}" } } },
          "mapping": { "json": { "quotas": [] } } }
        """)

        let filled = try template.filled(["folder": "/tmp"], scope: "account")

        guard case .http(let request) = filled.fetch else {
            Issue.record("Expected an http fetch")
            return
        }
        #expect(request.headers["Authorization"] == "Bearer {{token}}")
    }

    @Test
    func `should name a value the account doesn't have as unfilled`() throws {
        let template = try definition("""
        { "kind": "api", "requiresFiles": ["{{account.folder}}/auth.json"],
          "fetch": { "http": { "url": "https://example.com" } }, "mapping": { "json": { "quotas": [] } } }
        """)

        let filled = try template.filled([:], scope: "account")

        #expect(filled.unfilled(scope: "account") == ["folder"])
    }
}
