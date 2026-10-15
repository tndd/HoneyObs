import Foundation
import Darwin

// 固定長のソート済み範囲を二分探索する。IPを外部へ送信しない。
final class GeoIP {
    private let ipv4: Data
    private let ipv6: Data
    let available: Bool
    static let edition = "DB-IP Lite 2026-10"

    init(resources: URL) {
        ipv4 = (try? Data(contentsOf: resources.appendingPathComponent("geo-v4.bin"), options: .mappedIfSafe)) ?? Data()
        ipv6 = (try? Data(contentsOf: resources.appendingPathComponent("geo-v6.bin"), options: .mappedIfSafe)) ?? Data()
        available = !ipv4.isEmpty && !ipv6.isEmpty && ipv4.count % 10 == 0 && ipv6.count % 34 == 0
    }

    func country(for address: String) -> String? {
        guard available, address.utf8.count <= 45 else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return lookupV4(bytes)
        }
        guard address.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return lookupV4(Array(bytes.suffix(4)))
        }
        guard bytes[0] & 0xe0 == 0x20 else { return nil }
        // 文書用・ベンチマーク用の予約範囲は位置を付けない。
        if bytes.prefix(4).elementsEqual([0x20, 0x01, 0x0d, 0xb8]) ||
            (bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0) ||
            bytes.prefix(6).elementsEqual([0x20, 0x01, 0x00, 0x02, 0, 0]) { return nil }
        return lookup(bytes, in: ipv6)
    }

    private func lookupV4(_ ip: [UInt8]) -> String? {
        let a = ip[0], b = ip[1], c = ip[2]
        guard a != 0, a != 10, a != 127, a < 224,
              !(a == 100 && b >= 64 && b <= 127), !(a == 169 && b == 254),
              !(a == 172 && b >= 16 && b <= 31), !(a == 192 && b == 168),
              !(a == 192 && b == 0 && (c == 0 || c == 2)),
              !(a == 198 && (b == 18 || b == 19)), !(a == 198 && b == 51 && c == 100),
              !(a == 203 && b == 0 && c == 113) else { return nil }
        return lookup(ip, in: ipv4)
    }

    private func lookup(_ ip: [UInt8], in data: Data) -> String? {
        let width = ip.count, stride = width * 2 + 2
        var low = 0, high = data.count / stride
        func compare(_ offset: Int) -> Int {
            for i in 0..<width where ip[i] != data[offset + i] { return ip[i] < data[offset + i] ? -1 : 1 }
            return 0
        }
        while low < high {
            let mid = (low + high) / 2
            if compare(mid * stride) >= 0 { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let offset = (low - 1) * stride
        guard compare(offset + width) <= 0 else { return nil }
        let code = String(bytes: data[(offset + width * 2)..<(offset + stride)], encoding: .ascii)
        return code == "ZZ" ? nil : code
    }
}
