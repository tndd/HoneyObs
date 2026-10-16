import Foundation

@main struct ObservationDrainChecks {
    static func main() throws {
        let data = try JSONSerialization.data(withJSONObject:["boot":"fixed","uid":65534,"total":0,"events":[],"finalized":true])
        var report: [String:Any] = [:]
        let complete = ObservationDrain(store:ObservationStore(),budget:0.5,request:{ _,done in done(.success(data)); return {} },persist:{ _ in },completed:{ report=$0 })
        complete.start(); precondition(report["status"] as? String == "confirmed")
        var late: ((Result<Data,Error>) -> Void)?, cancelled = false, writes = 0
        let timeout = ObservationDrain(store:ObservationStore(),budget:0.03,request:{ _,done in late=done; return { cancelled=true } },persist:{ _ in writes += 1 },completed:{ report=$0 })
        timeout.start()
        RunLoop.main.run(until:Date().addingTimeInterval(0.08))
        precondition(cancelled && report["status"] as? String == "unverified" && report["unconfirmedTail"] as? Bool == true)
        late?(.success(data)); precondition(writes == 0,"期限後の観測を保存した")
        // 主キューが詰まってTimerが未発火でも、先に届いた遅着応答で成功にしない。
        let blocked = ObservationDrain(store:ObservationStore(),budget:0.02,request:{ _,done in late=done; return {} },persist:{ _ in writes += 1 },completed:{ report=$0 })
        blocked.start(); Thread.sleep(forTimeInterval:0.04); late?(.success(data))
        precondition(writes == 0 && report["status"] as? String == "unverified")
        let failed = ObservationDrain(store:ObservationStore(),budget:0.5,request:{ _,done in done(.success(data)); return {} },persist:{ _ in throw NSError(domain:"disk",code:1) },completed:{ report=$0 })
        failed.start(); precondition(report["status"] as? String == "partial" && report["sealed"] as? Bool == false)
        print("最終フェンス・期限・キャンセル・遅着応答・保存失敗: PASS")
    }
}
