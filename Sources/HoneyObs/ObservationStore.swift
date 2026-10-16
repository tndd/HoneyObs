import Foundation

// 画面の128件と取得・保存用の4096件を分離する。超過は件数として残す。
final class ObservationStore {
    struct Rejection: Codable { var count: UInt64; var lastTime: String }
    struct Page: Decodable {
        let boot: String
        let total: UInt64
        let events: [ObservedEvent]
        let rejections: [String: Rejection]?
    }
    struct Archive: Encodable {
        let boot: String
        let total: UInt64
        let events: [ObservedEvent]
        let lastID: UInt64
        let uncollected: UInt64
        let evicted: UInt64
        let rejections: [String: Rejection]
    }
    private(set) var boot = ""
    private(set) var total: UInt64 = 0
    private(set) var lastID: UInt64 = 0
    private(set) var uncollected: UInt64 = 0
    private(set) var evicted: UInt64 = 0
    private(set) var events: [ObservedEvent] = []
    private(set) var rejections: [String: Rejection] = [:]
    var pending: UInt64 { total - lastID }

    func ingest(_ data: Data) throws {
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard (boot.isEmpty || boot == page.boot), page.total >= total,
              !page.boot.isEmpty, page.boot.utf8.count <= 64,
              page.events.count <= 128, !page.events.isEmpty || page.total == lastID,
              (page.rejections?.count ?? 0) <= 32 else { throw invalid() }
        for (key,value) in page.rejections ?? [:] {
            guard key.utf8.count <= 64, value.lastTime.utf8.count <= 64 else { throw invalid() }
        }
        var cursor = lastID, missing: UInt64 = 0
        for event in page.events {
            guard event.id > cursor, event.id <= page.total,
                  event.time.utf8.count <= 64, event.method.utf8.count <= 32,
                  event.ip.utf8.count <= 45, event.path.utf8.count <= 512,
                  event.path.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
                  (100...599).contains(event.status),
                  (event.pathSHA256?.utf8.count ?? 0) <= 64 else { throw invalid() }
            missing += event.id - cursor - 1; cursor = event.id
        }
        boot = page.boot; total = page.total; lastID = cursor; uncollected += missing
        events.append(contentsOf: page.events)
        if events.count > 4096 { let count = events.count - 4096; evicted += UInt64(count); events.removeFirst(count) }
        rejections = page.rejections ?? [:]
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(boot: boot, total: total, events: events, lastID: lastID,
                                          uncollected: uncollected, evicted: evicted, rejections: rejections))
        guard data.count <= 6 * 1024 * 1024 else { throw invalid() }; return data
    }
    private func invalid() -> Error { NSError(domain: "HoneyObs", code: 3, userInfo: [NSLocalizedDescriptionKey: "観測ページの順序または形式が不正です"]) }
}
