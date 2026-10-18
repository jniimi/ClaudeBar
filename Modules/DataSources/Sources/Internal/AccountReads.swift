import Foundation

// What an added account's sign-in reaches (#577): each piece of a definition
// keeps the reads that name the account — `{{account.x}}`, a pasted setting —
// and leaves out the rest, which read what every program on this Mac sees:
// the default account's. None of them knows what an account is.

extension CredentialLookup {
    /// This lookup without what it reads of this Mac — `nil` when nothing of
    /// the login's own is left. A pasted key is always the login's: its vault
    /// is already scoped to it.
    func accountReads() -> CredentialLookup? {
        switch self {
        case .environment, .browserCookies, .browserStorage:
            nil
        case .setting:
            self
        case .jsonFile(let file):
            file.accountReads().map(CredentialLookup.jsonFile)
        case .keychain(let item):
            AccountValues.used(by: item.service) ? self : nil
        case .sqlite(let database):
            database.path.accountReads() == nil ? nil : self
        case .refined(let lookup, let refinement):
            lookup.accountReads().map { .refined($0, refinement) }
        case .refreshing(let lookup, let refresh):
            lookup.accountReads().map { .refreshing($0, refresh) }
        case .firstOf(let lookups):
            Optional(lookups.compactMap { $0.accountReads() }).flatMap { $0.isEmpty ? nil : .firstOf($0) }
        }
    }
}

extension JSONFileCredential {
    /// The file in the login's own places only.
    func accountReads() -> JSONFileCredential? {
        path.accountReads().map {
            JSONFileCredential(path: $0, fields: fields, alternatives: alternatives, record: record, defaults: defaults)
        }
    }
}

extension Recovery {
    /// The recovery, on the account's own file only.
    func accountReads() -> Recovery? {
        switch self {
        case .patchJSONFile(let path, let keys, let value):
            path.accountReads().map { .patchJSONFile(path: $0, keys: keys, value: value) }
        }
    }
}

extension PathPattern {
    /// The places that use an account value — a list keeps its own entries.
    func accountReads() -> PathPattern? {
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
    func accountReads() -> Fetch? {
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
    func accountReads() -> DataSourceDefinition? {
        var credential = self.credential
        if let lookup = self.credential {
            guard let own = lookup.accountReads() else { return nil }
            credential = own
        }
        guard let fetch = fetch.accountReads() else { return nil }
        return changing { parts in
            parts.credential = credential
            parts.fetch = fetch
            parts.context = parts.context.compactMapValues { $0.accountReads() }
            parts.recover = parts.recover.compactMapValues { $0.accountReads() }
            parts.requiresFiles = parts.requiresFiles.filter(AccountValues.used(by:))
        }
    }
}

extension UsageLog.Definition {
    /// The usage history an added login reads: its own logs, without the
    /// other apps on this Mac — `nil` when the logs are this Mac's.
    func accountReads() -> UsageLog.Definition? {
        guard AccountValues.used(by: records) else { return nil }
        let apps = otherApps?.filter { AccountValues.used(by: $0.records) }
        return UsageLog.Definition(
            records: records, prices: prices,
            freeWhen: freeWhen?.localEndpoint.flatMap { rule in
                rule.file.accountReads().map { UsageLog.FreeWhen(localEndpoint: UsageLog.LocalEndpointRule(file: $0, url: rule.url)) }
            },
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
