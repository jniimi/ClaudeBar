import DataSources
import Foundation
import Testing

/// An account shows only what its own sign-in reaches (#577, USER_JOURNEYS
/// F13). A definition is written once; read for an added account, a read that
/// names nothing of the account — an environment variable, a fixed path,
/// browser cookies, an app's own database — is this Mac's, and is not reached.
@Suite
struct AddedAccountTests {
    private static let work = ["folder": "/Users/mia/work-codex"]

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// A web data source looking its key up with `credential`.
    private func source(credential: String) throws -> DataSourceDefinition {
        try decode(DataSourceDefinition.self, #"""
        { "kind": "api", "credential": \#(credential),
          "fetch": { "http": { "url": "https://api.example.com/usage" } }, "mapping": { "json": {} } }
        """#)
    }

    private func key(of source: DataSourceDefinition?) throws -> CredentialLookup? {
        try #require(source).credential
    }

    // MARK: - Its key

    @Test
    func `should use the key Mia pasted for the account`() throws {
        let api = try source(credential: #"{ "setting": "apiKey" }"#)

        #expect(try key(of: api.forAccount(Self.work)) == api.credential)
    }

    @Test
    func `should not use this Mac's environment variable or browser sign-in for an added account`() throws {
        let environment = try source(credential: #"{ "environment": "OPENAI_ADMIN_KEY" }"#)
        let cookies = try source(credential: #"{ "browserCookies": { "domains": ["mistral.ai"], "names": ["ory_session_*"] } }"#)
        let storage = try source(credential:
            #"{ "browserStorage": { "origin": "https://app.devin.ai", "values": { "token": { "key": "*auth1_session" } } } }"#)

        #expect(try environment.forAccount(Self.work) == nil)
        #expect(try cookies.forAccount(Self.work) == nil)
        #expect(try storage.forAccount(Self.work) == nil)
    }

    @Test
    func `should read the login file in the account's own folder`() throws {
        let api = try source(credential: #"{ "jsonFile": { "path": "{{account.folder}}/auth.json", "token": "$.tokens.access_token" } }"#)

        let expected = try decode(CredentialLookup.self,
            #"{ "jsonFile": { "path": "/Users/mia/work-codex/auth.json", "token": "$.tokens.access_token" } }"#)
        #expect(try key(of: api.forAccount(Self.work)) == expected)
    }

    @Test
    func `should not read a login file, Keychain item or database at a fixed place for an added account`() throws {
        let file = try source(credential: #"{ "jsonFile": { "path": "~/.local/share/opencode/auth.json", "token": "$.opencode.key" } }"#)
        let keychain = try source(credential: #"{ "keychain": { "service": "Claude Code-credentials", "token": "$.claudeAiOauth.accessToken" } }"#)
        let database = try source(credential:
            #"{ "sqlite": { "path": "~/Library/Application Support/Cursor/state.vscdb", "query": "SELECT value AS token FROM ItemTable", "fields": { "token": "$.token" } } }"#)

        #expect(try file.forAccount(Self.work) == nil)
        #expect(try keychain.forAccount(Self.work) == nil)
        #expect(try database.forAccount(Self.work) == nil)
    }

    @Test
    func `should name the account's Keychain item as Claude Code names a folder's`() throws {
        let api = try source(credential:
            #"{ "keychain": { "service": "Claude Code-credentials-{{account.folder#sha256.8}}", "token": "$.claudeAiOauth.accessToken" } }"#)

        let read = try api.forAccount(["folder": "/Users/me/work-claude"])

        let expected = try decode(CredentialLookup.self,
            #"{ "keychain": { "service": "Claude Code-credentials-91eb4f94", "token": "$.claudeAiOauth.accessToken" } }"#)
        #expect(try key(of: read) == expected)
    }

    @Test
    func `should look only in the account's folder when a file may be in two places`() throws {
        let api = try source(credential: #"""
        { "jsonFile": { "path": ["{{account.folder}}/.claude.json", "${CLAUDE_CONFIG_DIR:-~}/.claude.json"],
                        "token": "$.oauthAccount.emailAddress" } }
        """#)

        let expected = try decode(CredentialLookup.self,
            #"{ "jsonFile": { "path": "/Users/mia/work-codex/.claude.json", "token": "$.oauthAccount.emailAddress" } }"#)
        #expect(try key(of: api.forAccount(Self.work)) == expected)
    }

    @Test
    func `should try the account's own lookups in their order, leaving this Mac's out`() throws {
        let api = try source(credential: #"""
        { "firstOf": [
          { "jsonFile": { "path": "{{account.folder}}/.credentials.json", "token": "$.claudeAiOauth.accessToken" } },
          { "environment": "CLAUDE_CODE_OAUTH_TOKEN" },
          { "setting": "token", "with": { "baseURL": "https://{{setting.platform.host}}" } }
        ] }
        """#)

        let expected = try decode(CredentialLookup.self, #"""
        { "firstOf": [
          { "jsonFile": { "path": "/Users/mia/work-codex/.credentials.json", "token": "$.claudeAiOauth.accessToken" } },
          { "setting": "token", "with": { "baseURL": "https://{{setting.platform.host}}" } }
        ] }
        """#)
        #expect(try key(of: api.forAccount(Self.work)) == expected)
    }

    @Test
    func `should keep a renewal of the account's own login file`() throws {
        let api = try source(credential: #"""
        { "jsonFile": { "path": "{{account.folder}}/auth.json", "token": "$.tokens.access_token" },
          "refresh": { "oauth2": { "tokenURL": "https://auth.openai.com/oauth/token", "clientId": "app" } } }
        """#)

        let read = try #require(try api.forAccount(Self.work))

        guard case .refreshing(_, .oauth2) = read.credential else {
            Issue.record("expected the renewal to stay: \(String(describing: read.credential))")
            return
        }
    }

    // MARK: - How it fetches

    @Test
    func `should not show this Mac's logs, database or app server under an added account`() throws {
        for fetch in [
            #"{ "directory": { "path": "~/.vibe/logs/session", "match": "^session_" } }"#,
            #"{ "sqlite": { "path": "~/.local/share/opencode/opencode.db", "query": "SELECT 1" } }"#,
        ] {
            let local = try decode(DataSourceDefinition.self, #"{ "kind": "local", "fetch": \#(fetch), "mapping": { "json": {} } }"#)
            #expect(try local.forAccount(Self.work) == nil)
        }
    }

    @Test
    func `should not run a CLI as this Mac's login for an added account`() throws {
        let cli = try decode(DataSourceDefinition.self,
            #"{ "kind": "cli", "fetch": { "command": { "cli": "amp", "args": ["usage"] } }, "mapping": { "json": {} } }"#)

        #expect(try cli.forAccount(Self.work) == nil)
    }

    @Test
    func `should run a CLI pointed at the account's folder or handed its key`() throws {
        let rpc = try decode(DataSourceDefinition.self, #"""
        { "kind": "rpc", "fetch": { "jsonRpc": { "cli": "codex", "args": ["app-server"], "call": "account/rateLimits/read",
                                                 "environment": { "set": { "CODEX_HOME": "{{account.folder}}" } } } },
          "mapping": { "json": {} } }
        """#)
        let keyed = try decode(DataSourceDefinition.self, #"""
        { "kind": "cli", "credential": { "setting": "apiKey" },
          "fetch": { "command": { "cli": "amp", "args": ["usage"], "environment": { "set": { "AMP_API_KEY": "{{token}}" } } } },
          "mapping": { "json": {} } }
        """#)

        let pointed = try #require(try rpc.forAccount(Self.work))
        guard case .jsonRpc(let call) = pointed.fetch else { Issue.record("expected the RPC"); return }
        #expect(call.environment.set["CODEX_HOME"] == "/Users/mia/work-codex")
        #expect(try keyed.forAccount(Self.work) != nil)
    }

    @Test
    func `should not read this Mac's account file, required files or recovery beside an added account's data source`() throws {
        let cli = try decode(DataSourceDefinition.self, #"""
        { "kind": "cli",
          "fetch": { "cli": { "cli": "claude", "args": ["/usage"], "environment": { "set": { "CLAUDE_CONFIG_DIR": "{{account.folder}}" } } } },
          "mapping": { "json": {} },
          "context": {
            "account": { "path": ["{{account.folder}}/.claude.json", "${CLAUDE_CONFIG_DIR:-~}/.claude.json"], "email": "$.oauthAccount.emailAddress" },
            "machine": { "path": "~/.claude.json", "email": "$.oauthAccount.emailAddress" }
          },
          "requiresFiles": ["{{account.folder}}/.claude.json", "~/.claude.json"],
          "recover": { "folderTrustRequired": { "patchJSONFile": { "path": "~/.claude.json", "keys": ["projects"], "value": true } } } }
        """#)

        let read = try #require(try cli.forAccount(Self.work))

        #expect(Array(read.context.keys) == ["account"])
        #expect(read.context["account"]?.path == "/Users/mia/work-codex/.claude.json")
        #expect(read.requiresFiles == ["/Users/mia/work-codex/.claude.json"])
        #expect(read.recover.isEmpty)
    }

    // MARK: - Its usage history

    @Test
    func `should read an added account's history from its own folder, without this Mac's other apps`() throws {
        let history = try decode(UsageLog.Definition.self, #"""
        { "records": { "files": "{{account.folder}}/sessions/**/*.jsonl", "at": "$.timestamp", "id": ["$.id"], "tokens": { "input": "$.input" } },
          "otherApps": [ { "label": "Claude Desktop",
                           "records": { "files": "~/Library/Application Support/Claude/usage/*.json", "format": "json", "at": "$.at", "id": ["$.id"], "tokens": { "total": "$.total" } } } ] }
        """#)

        let read = try #require(try history.forAccount(Self.work))

        guard case .files(let glob, _) = read.records.source else { Issue.record("expected files"); return }
        #expect(glob == "/Users/mia/work-codex/sessions/**/*.jsonl")
        #expect(read.otherApps == nil)
    }

    @Test
    func `should give an added account no history when the logs are this Mac's`() throws {
        let history = try decode(UsageLog.Definition.self, #"""
        { "records": { "sqlite": { "path": "~/.local/share/opencode/opencode.db", "query": "SELECT 1" },
                       "at": "$.at", "id": ["$.id"], "tokens": { "input": "$.input" } } }
        """#)

        #expect(try history.forAccount(Self.work) == nil)
    }
}
