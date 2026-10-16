import Foundation
@main struct ObservationChecks {
    static func page(_ ids: [Int], total: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["boot":"fixed", "total": total,
            "events":ids.map { ["id":$0,"time":"2026-10-15T00:00:00Z","method":"GET","path":"/\($0)","ip":"","status":404,"test":false] }])
    }
    static func main() throws {
        let store = ObservationStore()
        for first in stride(from: 1, through: 5000, by: 128) {
            try store.ingest(page(Array(first...min(first+127,5000)), total: 5000))
        }
        precondition(store.lastID == 5000 && store.uncollected == 0 && store.pending == 0)
        precondition(store.events.count == 4096 && store.evicted == 904)
        do { try store.ingest(page([5000], total: 5000)); fatalError("重複ページを受理した") } catch {}
        let gap = ObservationStore()
        try gap.ingest(page(Array(33...160), total: 160))
        precondition(gap.uncollected == 32 && gap.evicted == 0)
        let encoded = try JSONSerialization.jsonObject(with: gap.encoded()) as! [String: Any]
        precondition(encoded["uncollected"] as? Int == 32)
        let invalid = try JSONSerialization.data(withJSONObject:["boot":"fixed","total":1,"events":[
            ["id":1,"time":"now","method":"GET","path":String(repeating:"x",count:513),"ip":"","status":404,"test":false]]])
        do { try ObservationStore().ingest(invalid); fatalError("過大なゲスト記録を受理した") } catch {}
        print("分割取得・保持上限・欠落数・重複拒否: PASS")
    }
}
