import DataSources
import Foundation
import Testing

/// This Mac is the default login's (#577): a read that uses no account value
/// — an environment variable, a fixed path, browser cookies, an app's own
/// database — is this Mac's, and an added login leaves it out. Each piece of a
/// definition says so about itself.
@Suite
struct ThisMacTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Where a key is looked up

    @Test
    func `should keep the key the person pasted for the login`() throws {
        let lookup = try decode(CredentialLookup.self, #"{ "setting": "apiKey" }"#)

        #expect(lookup.withoutThisMac() == lookup)
    }

    @Test
    func `should not read this Mac's environment variable for an added login`() throws {
        let lookup = try decode(CredentialLookup.self, #"{ "environment": "OPENAI_ADMIN_KEY" }"#)

        #expect(lookup.withoutThisMac() == nil)
    }

    @Test
    func `should not read this Mac's browser sign-in for an added login`() throws {
        let cookies = try decode(CredentialLookup.self, #"{ "browserCookies": { "domains": ["mistral.ai"], "names": ["ory_session_*"] } }"#)
        let storage = try decode(CredentialLookup.self,
            #"{ "browserStorage": { "origin": "https://app.devin.ai", "values": { "token": { "key": "*auth1_session" } } } }"#)

        #expect(cookies.withoutThisMac() == nil)
        #expect(storage.withoutThisMac() == nil)
    }

    @Test
    func `should keep a login file inside the login's own folder`() throws {
        let lookup = try decode(CredentialLookup.self,
            #"{ "jsonFile": { "path": "{{account.folder}}/auth.json", "token": "$.tokens.access_token" } }"#)

        #expect(lookup.withoutThisMac() == lookup)
    }

    @Test
    func `should not read a login file at a fixed path for an added login`() throws {
        let file = try decode(CredentialLookup.self,
            #"{ "jsonFile": { "path": "~/.local/share/opencode/auth.json", "token": "$.opencode.key" } }"#)
        let keychain = try decode(CredentialLookup.self,
            #"{ "keychain": { "service": "Claude Code-credentials", "token": "$.claudeAiOauth.accessToken" } }"#)
        let database = try decode(CredentialLookup.self,
            #"{ "sqlite": { "path": "~/Library/Application Support/Cursor/state.vscdb", "query": "SELECT value AS token FROM ItemTable", "fields": { "token": "$.token" } } }"#)

        #expect(file.withoutThisMac() == nil)
        #expect(keychain.withoutThisMac() == nil)
        #expect(database.withoutThisMac() == nil)
    }

    @Test
    func `should keep a Keychain item named after the login's folder`() throws {
        let lookup = try decode(CredentialLookup.self,
            #"{ "keychain": { "service": "{{account.credentialService}}", "token": "$.claudeAiOauth.accessToken" } }"#)

        #expect(lookup.withoutThisMac() == lookup)
    }

    @Test
    func `should look only in the login's own folder when a file may be in two places`() throws {
        let lookup = try decode(CredentialLookup.self, #"""
        { "jsonFile": { "path": ["{{account.folder}}/.claude.json", "${CLAUDE_CONFIG_DIR:-~}/.claude.json"],
                        "token": "$.oauthAccount.emailAddress" } }
        """#)
        let expected = try decode(CredentialLookup.self, #"""
        { "jsonFile": { "path": "{{account.folder}}/.claude.json", "token": "$.oauthAccount.emailAddress" } }
        """#)

        #expect(lookup.withoutThisMac() == expected)
    }

    @Test
    func `should name a folder's Keychain item as Claude Code does`() throws {
        let lookup = try decode(DataSourceDefinition.self, #"""
        { "kind": "api",
          "credential": { "keychain": { "service": "Claude Code-credentials-{{account.folder#sha256.8}}", "token": "$.claudeAiOauth.accessToken" } },
          "fetch": { "http": { "url": "https://api.anthropic.com/api/oauth/usage" } }, "mapping": { "json": {} } }
        """#)

        let filled = try lookup.filled(["folder": "/Users/me/work-claude"], scope: "account")

        let expected = try decode(CredentialLookup.self,
            #"{ "keychain": { "service": "Claude Code-credentials-91eb4f94", "token": "$.claudeAiOauth.accessToken" } }"#)
        #expect(filled.credential == expected)
        #expect(filled.unfilled(scope: "account").isEmpty)
    }

    @Test
    func `should try the login's own lookups in their order when this Mac's are left out`() throws {
        let lookup = try decode(CredentialLookup.self, #"""
        { "firstOf": [
          { "jsonFile": { "path": "{{account.folder}}/.credentials.json", "token": "$.claudeAiOauth.accessToken" } },
          { "environment": "CLAUDE_CODE_OAUTH_TOKEN" },
          { "setting": "token" }
        ] }
        """#)
        let expected = try decode(CredentialLookup.self, #"""
        { "firstOf": [
          { "jsonFile": { "path": "{{account.folder}}/.credentials.json", "token": "$.claudeAiOauth.accessToken" } },
          { "setting": "token" }
        ] }
        """#)

        #expect(lookup.withoutThisMac() == expected)
    }

    @Test
    func `should find no key for an added login when every lookup is this Mac's`() throws {
        let lookup = try decode(CredentialLookup.self, #"""
        { "firstOf": [ { "environment": "KIMI_AUTH_TOKEN" }, { "browserCookies": { "domains": ["kimi.com"], "names": ["kimi-auth"] } } ] }
        """#)

        #expect(lookup.withoutThisMac() == nil)
    }

    @Test
    func `should keep a pasted key's fixed values and its refresh`() throws {
        let refined = try decode(CredentialLookup.self,
            #"{ "setting": "apiKey", "with": { "baseURL": "https://{{setting.platform.host}}" } }"#)
        let refreshing = try decode(CredentialLookup.self, #"""
        { "jsonFile": { "path": "{{account.folder}}/auth.json", "token": "$.tokens.access_token" },
          "refresh": { "oauth2": { "tokenURL": "https://auth.openai.com/oauth/token", "clientId": "app" } } }
        """#)

        #expect(refined.withoutThisMac() == refined)
        #expect(refreshing.withoutThisMac() == refreshing)
    }

    // MARK: - How the bytes are fetched

    @Test
    func `should keep a web request, which reaches only what its key reaches`() throws {
        let fetch = try decode(Fetch.self, #"{ "http": { "url": "https://api.openai.com/v1/usage" } }"#)

        #expect(fetch.withoutThisMac() == fetch)
    }

    @Test
    func `should not read this Mac's own database or folder for an added login`() throws {
        let database = try decode(Fetch.self,
            #"{ "sqlite": { "path": "~/.local/share/opencode/opencode.db", "query": "SELECT 1" } }"#)
        let folder = try decode(Fetch.self, #"{ "directory": { "path": "~/.vibe/logs/session", "match": "^session_" } }"#)

        #expect(database.withoutThisMac() == nil)
        #expect(folder.withoutThisMac() == nil)
    }

    @Test
    func `should not run a CLI as this Mac's login for an added login`() throws {
        let fetch = try decode(Fetch.self, #"{ "command": { "cli": "amp", "args": ["usage", "--no-color"] } }"#)

        #expect(fetch.withoutThisMac() == nil)
    }

    @Test
    func `should run a CLI pointed at the login's folder`() throws {
        let fetch = try decode(Fetch.self, #"""
        { "jsonRpc": { "cli": "codex", "args": ["app-server"], "call": "account/rateLimits/read",
                       "environment": { "set": { "CODEX_HOME": "{{account.folder}}" } } } }
        """#)

        #expect(fetch.withoutThisMac() == fetch)
    }

    @Test
    func `should run a CLI handed the login's own key`() throws {
        let fetch = try decode(Fetch.self, #"""
        { "command": { "cli": "amp", "args": ["usage"], "environment": { "set": { "AMP_API_KEY": "{{token}}" } } } }
        """#)

        #expect(fetch.withoutThisMac() == fetch)
    }

    // MARK: - A data source

    @Test
    func `should leave out a data source whose key only this Mac has`() throws {
        let source = try decode(DataSourceDefinition.self, #"""
        { "kind": "api", "credential": { "environment": "OPENAI_ADMIN_KEY" },
          "fetch": { "http": { "url": "https://api.openai.com/v1/usage" } }, "mapping": { "json": {} } }
        """#)

        #expect(source.withoutThisMac() == nil)
    }

    @Test
    func `should leave out a data source that reads only this Mac's logs`() throws {
        let source = try decode(DataSourceDefinition.self, #"""
        { "kind": "logs", "fetch": { "directory": { "path": "~/.vibe/logs/session" } }, "mapping": { "json": {} } }
        """#)

        #expect(source.withoutThisMac() == nil)
    }

    @Test
    func `should keep a data source with only the login's own key`() throws {
        let source = try decode(DataSourceDefinition.self, #"""
        { "kind": "api", "credential": { "firstOf": [ { "environment": "OPENAI_ADMIN_KEY" }, { "setting": "apiKey" } ] },
          "fetch": { "http": { "url": "https://api.openai.com/v1/usage" } }, "mapping": { "json": {} } }
        """#)
        let expected = try decode(DataSourceDefinition.self, #"""
        { "kind": "api", "credential": { "firstOf": [ { "setting": "apiKey" } ] },
          "fetch": { "http": { "url": "https://api.openai.com/v1/usage" } }, "mapping": { "json": {} } }
        """#)

        #expect(source.withoutThisMac() == expected)
    }

    @Test
    func `should not read this Mac's account file beside an added login's data source`() throws {
        let source = try decode(DataSourceDefinition.self, #"""
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

        let kept = try #require(source.withoutThisMac())

        #expect(Array(kept.context.keys) == ["account"])
        #expect(kept.context["account"]?.path == "{{account.folder}}/.claude.json")
        #expect(kept.requiresFiles == ["{{account.folder}}/.claude.json"])
        #expect(kept.recover.isEmpty)
    }

    // MARK: - Usage history

    @Test
    func `should read an added login's history from its own folder, without this Mac's other apps`() throws {
        let history = try decode(UsageLog.Definition.self, #"""
        { "records": { "files": "{{account.folder}}/projects/**/*.jsonl", "at": "$.timestamp", "id": ["$.id"], "tokens": { "input": "$.input" } },
          "otherApps": [ { "label": "Claude Desktop",
                           "records": { "files": "~/Library/Application Support/Claude/usage/*.json", "format": "json", "at": "$.at", "id": ["$.id"], "tokens": { "total": "$.total" } } } ] }
        """#)

        let kept = try #require(history.withoutThisMac())

        #expect(kept.records == history.records)
        #expect(kept.otherApps == nil)
    }

    @Test
    func `should give an added login no history when its logs are this Mac's`() throws {
        let history = try decode(UsageLog.Definition.self, #"""
        { "records": { "sqlite": { "path": "~/.local/share/opencode/opencode.db", "query": "SELECT 1" },
                       "at": "$.at", "id": ["$.id"], "tokens": { "input": "$.input" } } }
        """#)

        #expect(history.withoutThisMac() == nil)
    }
}
