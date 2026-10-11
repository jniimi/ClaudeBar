import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `{{system.x}}` — values the engine computes, from the fetch's `now`
/// (ENGINE_DESIGN §2.9): the time zone, the OS version, now, and a day
/// N days away and the first of this month, at UTC midnight.
@Suite
struct SystemTemplateTests {
    /// 2026-10-05 14:30:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_791_210_600)
    private let system = SystemValues(now: Self.now, timeZone: TimeZone(identifier: "Asia/Shanghai")!,
                                      osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0))

    @Test
    func `should send the Mac's time zone even without a credential`() {
        #expect(Template.fill("tz={{system.timeZone}}", with: nil, system: system) == "tz=Asia/Shanghai")
    }

    @Test
    func `should send the Mac's version`() {
        #expect(Template.fill("{{system.osVersion}}", with: nil, system: system) == "27.1.0")
    }

    @Test
    func `should send now as epoch seconds or ISO 8601`() {
        #expect(Template.fill("{{system.now.epoch}}", with: nil, system: system) == "1791210600")
        #expect(Template.fill("{{system.now.iso8601}}", with: nil, system: system) == "2026-10-05T14:30:00Z")
    }

    @Test
    func `should send the start of a day N days away, at UTC midnight`() {
        #expect(Template.fill("{{system.day-29.epoch}}", with: nil, system: system) == "1788652800")
        #expect(Template.fill("{{system.day-29.date}}", with: nil, system: system) == "2026-09-06")
        #expect(Template.fill("{{system.day+1.iso8601}}", with: nil, system: system) == "2026-10-06T00:00:00Z")
        #expect(Template.fill("{{system.day.date}}", with: nil, system: system) == "2026-10-05")
    }

    @Test
    func `should send the first of this month, at UTC midnight`() {
        #expect(Template.fill("{{system.month.date}}", with: nil, system: system) == "2026-10-01")
        #expect(Template.fill("{{system.month.iso8601}}", with: nil, system: system) == "2026-10-01T00:00:00Z")
    }

    @Test(arguments: ["system.day-x.epoch", "system.now.week", "system.unknown", "system.day-29", "system.month", "system.month-1.date"])
    func `should leave a request unfilled when it names a value the engine doesn't compute`(_ name: String) {
        #expect(Template.fill("{{\(name)}}", with: nil, system: system) == nil)
    }

    @Test
    func `should not take a system value from the credential`() {
        let credential = Credential(["system.now.epoch": "forged", "token": "t"])
        #expect(Template.fill("{{system.now.epoch}}/{{token}}", with: credential, system: system) == "1791210600/t")
    }

    @Test
    func `should ask for the day from the fetch's own clock`() async throws {
        let network = MockNetworkClient()
        let seen = Seen()
        given(network).request(.any).willProduce { request in
            seen.url = request.url?.absoluteString
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let request = HTTPRequest(url: "https://api.example.com/costs?start_time={{system.day-29.epoch}}", method: "GET",
                                  headers: [:], body: nil, timeout: 5)
        _ = try await HTTPFetcher(request: request, network: network, now: { Self.now }).fetch(with: Credential(["token": "t"]))
        #expect(seen.url == "https://api.example.com/costs?start_time=1788652800")
    }

    final class Seen: @unchecked Sendable { var url: String? }
}
