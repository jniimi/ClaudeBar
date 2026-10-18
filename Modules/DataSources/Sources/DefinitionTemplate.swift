import Crypto
import Foundation

/// A definition adapted to one login, as data: an RFC 7396 merge patch for
/// what differs, then the login's values for `{{account.x}}`. The definition
/// is written once; nothing is copied per login. A data source and a usage
/// history are both adapted this way.
public protocol DefinitionTemplate: Codable {}

extension DataSourceDefinition: DefinitionTemplate {}
extension UsageLog.Definition: DefinitionTemplate {}

extension DefinitionTemplate {
    /// The definition with `patch` merged in (RFC 7396): an object merges key
    /// by key, `null` removes a field, anything else replaces it.
    public func patched(with patch: JSONValue) throws -> Self {
        try Self.decoded(json().merged(with: patch))
    }

    /// The definition with every `{{<scope>.<name>}}` in its strings replaced
    /// by `values[name]`. Other placeholders — `{{token}}` — are left for the
    /// fetch; a name the values lack stays, and `unfilled(scope:)` reports it.
    public func filled(_ values: [String: String], scope: String) throws -> Self {
        try Self.decoded(json().mapStrings { Placeholders.fill($0, values, scope: scope) })
    }

    /// The `{{<scope>.<name>}}` names still in the definition, sorted.
    public func unfilled(scope: String) -> [String] {
        guard let json = try? json() else { return [] }
        var names = Set<String>()
        _ = json.mapStrings { text in
            names.formUnion(Placeholders.names(in: text, scope: scope).map { Placeholders.split($0).base })
            return text
        }
        return names.sorted()
    }

    private func json() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }

    private static func decoded(_ json: JSONValue) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(json))
    }
}

/// `{{<scope>.<name>}}` in a definition's strings.
enum Placeholders {
    static func fill(_ text: String, _ values: [String: String], scope: String) -> String {
        var text = text
        for name in names(in: text, scope: scope) {
            let (base, transform) = split(name)
            if let value = values[base], let filled = transformed(value, by: transform) {
                text = text.replacingOccurrences(of: "{{\(scope).\(name)}}", with: filled)
            }
        }
        return text
    }

    /// `folder#sha256.8` → the value's name and what is done to it.
    static func split(_ name: String) -> (base: String, transform: String?) {
        guard let mark = name.firstIndex(of: "#") else { return (name, nil) }
        return (String(name[..<mark]), String(name[name.index(after: mark)...]))
    }

    /// `sha256.N`: the first N hex digits of the value's SHA-256 — how Claude
    /// Code names a config folder's Keychain item. An unknown transform fills
    /// nothing, so the placeholder is reported as unfilled.
    private static func transformed(_ value: String, by transform: String?) -> String? {
        guard let transform else { return value }
        let parts = transform.split(separator: ".")
        guard parts.count == 2, parts[0] == "sha256", let digits = Int(parts[1]) else { return nil }
        let hash = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hash.prefix(max(0, digits)))
    }

    static func names(in text: String, scope: String) -> [String] {
        let opening = "{{\(scope)."
        var names: [String] = []
        var rest = text[...]
        while let start = rest.range(of: opening), let end = rest[start.upperBound...].range(of: "}}") {
            names.append(String(rest[start.upperBound..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        return names
    }
}

extension JSONValue {
    /// RFC 7396 JSON Merge Patch.
    public func merged(with patch: JSONValue) -> JSONValue {
        guard case .object(let changes) = patch else { return patch }
        var result: [String: JSONValue]
        if case .object(let fields) = self { result = fields } else { result = [:] }
        for (key, change) in changes {
            if case .null = change {
                result.removeValue(forKey: key)
            } else {
                result[key] = (result[key] ?? .null).merged(with: change)
            }
        }
        return .object(result)
    }

    /// The same value with `transform` applied to every string, keys excepted.
    func mapStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let text): .string(transform(text))
        case .object(let fields): .object(fields.mapValues { $0.mapStrings(transform) })
        case .array(let items): .array(items.map { $0.mapStrings(transform) })
        case .number, .bool, .null: self
        }
    }
}
