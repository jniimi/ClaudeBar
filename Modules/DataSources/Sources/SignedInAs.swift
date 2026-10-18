import Foundation

/// *Signed in as …* — the file a vendor keeps who is signed in, and its
/// fields: `id`, and any of `email`, `organization`, `billingType` … Said once
/// for a provider and read by every data source of every account (#577): the
/// pill's email when an answer names none, `$signedInAs.<field>` in a
/// mapping, and the person an added folder account must still be.
///
/// `{ "file": "{{account.folder}}/auth.json", "id": "$.tokens.account_id",
///    "email": "$.tokens.id_token#jwt.email" }` — `file` may be a list where
/// the vendor keeps the default account somewhere else.
public struct SignedInAs: Sendable, Equatable, Codable {
    /// How a mapping and an identity name it.
    static let name = "signedInAs"

    public let file: PathPattern
    /// Field → JSON path in the file.
    public let fields: [String: String]

    public init(file: PathPattern, fields: [String: String]) {
        self.file = file
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TagKey.self)
        file = try container.decode(PathPattern.self, forKey: TagKey("file"))
        var fields: [String: String] = [:]
        for key in container.allKeys where key.stringValue != "file" {
            fields[key.stringValue] = try container.decode(String.self, forKey: key)
        }
        self.fields = fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TagKey.self)
        try container.encode(file, forKey: TagKey("file"))
        for (name, path) in fields { try container.encode(path, forKey: TagKey(name)) }
    }

    /// Who is signed in, as an identity reads it.
    public var id: IdentityField { .context(file: Self.name, field: "id") }
    /// The email the pill shows.
    public var email: IdentityField { .context(file: Self.name, field: "email") }

    var contextFile: JSONFileCredential { JSONFileCredential(path: file, fields: fields) }
}

extension DataSourceDefinition {
    /// What the screen says when a folder now signs in to someone else.
    static let someoneElse = "This folder is now signed in to someone else. Sign in again as this account, or remove it and add the new one."

    /// The data source knowing who is signed in: its mapping may read
    /// `$signedInAs.<field>`, and its usage names the email when the answer
    /// doesn't.
    public func knowing(_ who: SignedInAs) -> DataSourceDefinition {
        changing { $0.context[SignedInAs.name] = who.contextFile }
    }

    /// The data source refusing to run while any of `files` is missing —
    /// *Key needed*: a folder an account was given that is gone holds no
    /// login.
    public func requiring(_ files: [String]) -> DataSourceDefinition {
        changing { parts in parts.requiresFiles += files.filter { !parts.requiresFiles.contains($0) } }
    }

    /// Every fetch must still be signed in as `id`, in the file `knowing`
    /// reads — another person fails closed, and a missing file is not signed
    /// in.
    public func checkingSignedIn(is id: String, hint: String? = nil) -> DataSourceDefinition {
        changing { parts in
            parts.requiresFiles += parts.context[SignedInAs.name]?.path.places ?? []
            parts.identity = Identity(field: .context(file: SignedInAs.name, field: "id"), equals: id,
                                      hint: hint ?? Self.someoneElse)
        }
    }
}
