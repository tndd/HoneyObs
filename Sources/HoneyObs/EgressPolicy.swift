import Foundation

enum EgressPolicy {
    static let provisioningAddress = "104.16.230.132"
    static let provisioningServerName = "api.trycloudflare.com"
    static let edgeAddress = "198.41.192.7"
    static let edgePort: UInt16 = 7844
    static let edgeServerName = "h2.cftunnel.com"
    static let provisioningURL = URL(string: "https://api.trycloudflare.com/tunnel")!
    static let maximumHello = 16384

    // 許可した要求そのものは外へ転送せず、ホストが固定の空POSTを再構成する。
    static func allowsProvision(_ data: Data) -> Bool {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8), text.hasSuffix("\r\n\r\n") else { return false }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "POST /tunnel HTTP/1.1" else { return false }
        var lengths = 0, hosts = 0
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { return false }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "host": hosts += 1; if value != "127.0.0.1:7002" { return false }
            case "content-length": lengths += 1; if value != "0" { return false }
            case "user-agent", "content-type", "accept-encoding", "connection": break
            default: return false
            }
        }
        return hosts == 1 && lengths <= 1
    }

    static func allowsProvisionResponseHeader(_ data: Data) -> Bool {
        guard data.count <= 8192, let text = String(data: data, encoding: .ascii), text.hasSuffix("\r\n\r\n") else { return false }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 200 ") || first.hasPrefix("HTTP/1.0 200 ") else { return false }
        var length = false, chunked = false
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { return false }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "location" || key == "upgrade" { return false }
            if key == "content-length" {
                guard !length, let size = Int(value), size >= 0, size <= 57344 else { return false }; length = true
            }
            if key == "transfer-encoding" { guard !chunked, value.lowercased() == "chunked" else { return false }; chunked = true }
        }
        return !(length && chunked)
    }

    static func allowsFollowingRecord(_ record: Data, compatibilityCCSUsed: Bool) -> Bool {
        let b = Array(record)
        guard b.count >= 6, b[1] == 3, b[2] == 3,
              Int(b[3]) << 8 | Int(b[4]) == b.count - 5 else { return false }
        if b[0] == 20 { return !compatibilityCCSUsed && b == [20,3,3,0,1,1] }
        return b[0] == 23 && b.count <= 16645
    }

    // 完全な単一recordのClientHelloを解析。fragment/ECH/早期データを許可しない。
    // 暗号化後のCloudflareプロトコルやテナントの正当性はこの検査の保証外。
    static func allowsEdgeHello(_ record: Data) -> Bool {
        let b = Array(record)
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        guard b.count >= 9, b.count <= maximumHello, b[0] == 22, b[1] == 3, b[2] >= 1, b[2] <= 3,
              u16(3) == b.count - 5, b[5] == 1 else { return false }
        let helloSize = Int(b[6]) << 16 | Int(b[7]) << 8 | Int(b[8])
        guard helloSize == b.count - 9, b.count >= 44 else { return false }
        var i = 43
        let session = Int(b[i]); i += 1
        guard session <= 32, i + session + 2 <= b.count else { return false }; i += session
        let ciphers = u16(i); i += 2
        guard ciphers > 0, ciphers % 2 == 0, i + ciphers + 1 <= b.count else { return false }; i += ciphers
        let compression = Int(b[i]); i += 1
        guard compression == 1, i + 3 <= b.count, b[i] == 0 else { return false }; i += compression
        let extensions = u16(i); i += 2
        guard i + extensions == b.count else { return false }
        var names: [String] = [], seen = Set<Int>()
        while i < b.count {
            guard i + 4 <= b.count else { return false }
            let kind = u16(i), size = u16(i + 2); i += 4
            let end = i + size
            guard end <= b.count, seen.insert(kind).inserted, kind != 0xfe0d, kind != 42 else { return false }
            if kind == 0 {
                guard i + 2 <= end, u16(i) == size - 2 else { return false }; i += 2
                while i < end {
                    guard i + 3 <= end, b[i] == 0 else { return false }
                    let length = u16(i + 1); i += 3
                    guard length > 0, i + length <= end, let name = String(bytes: b[i..<i + length], encoding: .ascii) else { return false }
                    names.append(name); i += length
                }
            } else if kind == 16 {
                guard i + 2 <= end, u16(i) == size - 2 else { return false }; i += 2
                var protocols: [String] = []
                while i < end {
                    let length = Int(b[i]); i += 1
                    guard length > 0, i + length <= end, let proto = String(bytes: b[i..<i + length], encoding: .ascii) else { return false }
                    protocols.append(proto); i += length
                }
                guard protocols == ["h2"] else { return false }
            }
            i = end
        }
        return names == [edgeServerName]
    }
}
