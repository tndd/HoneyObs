import Foundation

@main struct GeoIPTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let geo = GeoIP(resources: root)
        precondition(geo.available)
        precondition(geo.country(for: "8.8.8.8") == "US")
        precondition(geo.country(for: "2001:4860:4860::8888") == "CA")
        precondition(geo.country(for: "::ffff:8.8.8.8") == "US")
        for ip in ["", "invalid", "8.8.8.8<script>", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.0.1", "100.64.0.1", "192.0.2.17", "198.51.100.12", "203.0.113.18", "224.0.0.1", "::1", "fc00::1", "fe80::1", "2001:db8::1", "3fff:fff::1"] {
            precondition(geo.country(for: ip) == nil, ip)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        precondition(!GeoIP(resources: temporary).available)
        // 隣接範囲の両端・隙間・IPv6のネットワークバイト順を独立fixtureで検証。
        try Data([8,0,0,0, 8,0,0,3, 85,83, 8,0,0,5, 8,0,0,9, 74,80]).write(to: temporary.appendingPathComponent("geo-v4.bin"))
        let first: [UInt8] = [0x26,0x06] + Array(repeating: 0, count: 14)
        var last = first; last[15] = 7
        try Data(first + last + [74,80]).write(to: temporary.appendingPathComponent("geo-v6.bin"))
        let fixture = GeoIP(resources: temporary)
        precondition(fixture.country(for: "8.0.0.0") == "US")
        precondition(fixture.country(for: "8.0.0.3") == "US")
        precondition(fixture.country(for: "8.0.0.4") == nil)
        precondition(fixture.country(for: "8.0.0.5") == "JP")
        precondition(fixture.country(for: "8.0.0.9") == "JP")
        precondition(fixture.country(for: "8.0.0.10") == nil)
        precondition(fixture.country(for: "2606::") == "JP")
        precondition(fixture.country(for: "2606::7") == "JP")
        precondition(fixture.country(for: "2606::8") == nil)
        let event = ObservedEvent(id: UInt64.max, time: "2026-10-15T00:00:00Z", method: "GET", path: "</script><img onerror=alert(1)>", ip: "8.8.8.8", status: 404, test: false)
        let presentation = event.presentation(geo: geo)
        precondition(presentation["id"] as? String == String(UInt64.max))
        precondition(presentation["countryCode"] as? String == "US")
        print("GeoIP・境界・予約IP・イベント変換: PASS")
    }
}
