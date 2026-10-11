import Foundation

/// `{{system.x}}` — the values the engine computes rather than reads, made
/// with the fetch's own `now` so a test can fix it (ENGINE_DESIGN §2.9).
/// One row per value: a new value is a new row, never a branch elsewhere.
struct SystemValues: Sendable {
    let now: Date
    var timeZone: TimeZone = .current
    var osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion

    /// The value of `system.<name>`, or nil when the engine computes no such value.
    func value(_ name: String) -> String? {
        Self.rows.lazy.compactMap { $0(self, name) }.first
    }

    private typealias Row = @Sendable (SystemValues, String) -> String?

    private static let rows: [Row] = [
        // The Mac's time zone, as a browser would send it.
        { system, name in name == "timeZone" ? system.timeZone.identifier : nil },
        { system, name in
            guard name == "osVersion" else { return nil }
            let version = system.osVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        },
        // `now.<format>`.
        { system, name in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "now" else { return nil }
            return Format(rawValue: String(parts[1]))?.text(system.now)
        },
        // `day.<format>`, `day-29.<format>`, `day+1.<format>`: that day's UTC midnight.
        { system, name in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].hasPrefix("day"), let format = Format(rawValue: String(parts[1])) else { return nil }
            let offset = parts[0].dropFirst(3)
            guard let days = offset.isEmpty ? 0 : Int(offset), offset.isEmpty || "+-".contains(offset.first!) else { return nil }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            guard let day = utc.date(byAdding: .day, value: days, to: utc.startOfDay(for: system.now)) else { return nil }
            return format.text(day)
        },
        // `month.<format>`: the first of this month, at UTC midnight.
        { system, name in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "month", let format = Format(rawValue: String(parts[1])) else { return nil }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            guard let first = utc.dateInterval(of: .month, for: system.now)?.start else { return nil }
            return format.text(first)
        },
    ]

    private enum Format: String {
        case epoch, iso8601, date

        func text(_ date: Date) -> String {
            switch self {
            case .epoch:
                return String(Int(date.timeIntervalSince1970))
            case .iso8601:
                return ISO8601DateFormatter().string(from: date)
            case .date:
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                return formatter.string(from: date)
            }
        }
    }
}
