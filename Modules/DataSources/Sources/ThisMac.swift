import Foundation

// THIS MAC IS THE DEFAULT LOGIN'S (#577). A read that uses no account value —
// an environment variable, a fixed path or Keychain name, browser cookies, an
// app's own database or server — reads what every program on this Mac sees,
// so only the default login makes it. Each piece of a definition says which
// of its reads those are; none of them knows what a login is.

extension CredentialLookup {
    /// This lookup without what it reads of this Mac — `nil` when nothing of
    /// the login's own is left. A pasted key is always the login's: its vault
    /// is already scoped to it.
    public func withoutThisMac() -> CredentialLookup? {
        switch self {
        case .environment, .browserCookies, .browserStorage:
            nil
        case .setting:
            self
        case .jsonFile(let file):
            file.withoutThisMac().map(CredentialLookup.jsonFile)
        case .keychain(let item):
            AccountValues.used(by: item.service) ? self : nil
        case .sqlite(let database):
            database.path.withoutThisMac() == nil ? nil : self
        case .refined(let lookup, let refinement):
            lookup.withoutThisMac().map { .refined($0, refinement) }
        case .refreshing(let lookup, let refresh):
            lookup.withoutThisMac().map { .refreshing($0, refresh) }
        case .firstOf(let lookups):
            Optional(lookups.compactMap { $0.withoutThisMac() }).flatMap { $0.isEmpty ? nil : .firstOf($0) }
        }
    }
}

extension JSONFileCredential {
    /// The file in the login's own places only.
    public func withoutThisMac() -> JSONFileCredential? {
        path.withoutThisMac().map {
            JSONFileCredential(path: $0, fields: fields, alternatives: alternatives, record: record, defaults: defaults)
        }
    }
}

extension PathPattern {
    /// The places that use an account value — a list keeps its own entries.
    public func withoutThisMac() -> PathPattern? {
        let own = places.filter(AccountValues.used(by:))
        return own.isEmpty ? nil : PathPattern(own)
    }
}

extension Fetch {
    /// This fetch, when it reaches something of the login's own. A web request
    /// reaches what its key reaches. A CLI, a command or a script runs as the
    /// login only when it is pointed at the login's folder or handed its key;
    /// otherwise it answers as this Mac's login. A file, folder or database at
    /// a fixed path, and an app's server, are this Mac's.
    public func withoutThisMac() -> Fetch? {
        switch self {
        case .http, .httpSteps:
            self
        case .localServer:
            nil
        case .jsonRpc, .cli, .command:
            AccountValues.used(by: self, orToken: true) ? self : nil
        case .script(let call):
            !call.secrets.isEmpty || AccountValues.used(by: self, orToken: true) ? self : nil
        case .file, .directory, .sqlite, .cloudWatch:
            AccountValues.used(by: self) ? self : nil
        }
    }
}

extension DataSourceDefinition {
    /// This data source as an added login runs it: without this Mac's reads,
    /// or `nil` when its key or its fetch is only this Mac's. Context files,
    /// required files and recoveries at fixed places are left out with it.
    public func withoutThisMac() -> DataSourceDefinition? {
        var credential = self.credential
        if let lookup = self.credential {
            guard let own = lookup.withoutThisMac() else { return nil }
            credential = own
        }
        guard let fetch = fetch.withoutThisMac() else { return nil }
        return DataSourceDefinition(
            kind: kind, label: label, summary: summary, note: note, hidden: hidden,
            credential: credential, fetch: fetch, mapping: mapping,
            fallback: fallback, fallbackOn: fallbackOn, cache: cache,
            context: context.compactMapValues { $0.withoutThisMac() },
            recover: recover.filter { AccountValues.used(by: $0.value) },
            requiresFiles: requiresFiles.filter(AccountValues.used(by:)),
            identity: identity,
            verifyBeforeBackground: verifyBeforeBackground, unverifiedMessage: unverifiedMessage,
            errors: errors
        )
    }
}

extension UsageLog.Definition {
    /// The usage history an added login reads: its own logs, without the
    /// other apps on this Mac — `nil` when the logs are this Mac's.
    public func withoutThisMac() -> UsageLog.Definition? {
        guard AccountValues.used(by: records) else { return nil }
        let apps = otherApps?.filter { AccountValues.used(by: $0.records) }
        return UsageLog.Definition(
            records: records, prices: prices,
            freeWhen: freeWhen.flatMap { AccountValues.used(by: $0) ? $0 : nil },
            sessionGap: sessionGap,
            otherApps: apps?.isEmpty == false ? apps : nil
        )
    }
}

/// Whether a piece of a definition uses an account value — found the way
/// `{{account.x}}` is already found, never guessed from what a path looks like.
enum AccountValues {
    static func used(by text: String) -> Bool {
        !Placeholders.names(in: text, scope: "account").isEmpty
    }

    static func used(by value: some Encodable, orToken: Bool = false) -> Bool {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) else { return false }
        var found = false
        _ = json.mapStrings { text in
            if used(by: text) || (orToken && text.contains("{{token")) { found = true }
            return text
        }
        return found
    }
}
