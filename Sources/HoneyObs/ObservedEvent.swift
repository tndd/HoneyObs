import Foundation

struct ObservedEvent: Decodable {
    let id: UInt64
    let time: String
    let method: String
    let path: String
    let ip: String
    let status: Int
    let test: Bool

    func presentation(geo: GeoIP) -> [String: Any] {
        let code = geo.country(for: ip)
        return ["id": String(id), "time": String(time.prefix(64)), "method": String(method.prefix(32)),
                "path": String(path.prefix(512)), "ip": String(ip.prefix(45)), "status": status, "test": test,
                "countryCode": code ?? "", "country": code.flatMap { Locale(identifier: "ja_JP").localizedString(forRegionCode: $0) } ?? "位置不明"]
    }
}

struct EventSnapshot: Decodable {
    let events: [ObservedEvent]?
}
