import Foundation

@main struct ObservationDrainChecks {
    static func wait(_ condition:() -> Bool, limit:TimeInterval = 1) {
        let deadline = Date().addingTimeInterval(limit)
        while !condition(), Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.002)) }
        precondition(condition(),"観測回収の待機期限")
    }
    static func main() throws {
        let data = try JSONSerialization.data(withJSONObject:["boot":"fixed","uid":65534,"total":0,"events":[],"finalized":true])
        var report: [String:Any] = [:]
        let complete = ObservationDrain(store:ObservationStore(),budget:0.5,request:{ _,done in done(.success(data)); return {} },persist:{ _ in },completed:{ report=$0 })
        complete.start(); wait { report["status"] as? String == "confirmed" }
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
        report = [:]; failed.start(); wait { report["status"] as? String == "partial" }
        precondition(report["sealed"] as? Bool == false)

        // 保存を止めたままでも主キューの期限通知（EngineではVM停止開始）が進む。
        // 書込はOSから撤回できないため、完了は別に待ち、遅着で確定へ戻さない。
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        var slowReport:[String:Any] = [:], settled = false, completions = 0
        let slow = ObservationDrain(store:ObservationStore(),budget:0.5,request:{ _,done in done(.success(data)); return {} },persist:{ _ in
            precondition(!Thread.isMainThread,"保存I/Oが主キューを塞いでいる")
            entered.signal(); precondition(release.wait(timeout:.now()+1) == .success)
        },completed:{ slowReport=$0; completions += 1 },settled:{ settled=true })
        slow.start(); precondition(entered.wait(timeout:.now()+1) == .success)
        wait({ !slowReport.isEmpty },limit:0.9)
        precondition(slowReport["status"] as? String == "partial" && slowReport["sealed"] as? Bool == false)
        precondition(slowReport["reason"] as? String == "取得期限" && !settled)
        release.signal(); wait { settled }
        precondition(completions == 1 && slowReport["status"] as? String == "partial","保存の遅着で確定へ戻った")

        var cancelledReport:[String:Any] = [:], cancelledSettled = false
        let cancelEntered = DispatchSemaphore(value:0), cancelRelease = DispatchSemaphore(value:0)
        let duringWrite = ObservationDrain(store:ObservationStore(),budget:0.5,request:{ _,done in done(.success(data)); return {} },persist:{ _ in
            cancelEntered.signal(); precondition(cancelRelease.wait(timeout:.now()+1) == .success)
        },completed:{ cancelledReport=$0 },settled:{ cancelledSettled=true })
        duringWrite.start(); precondition(cancelEntered.wait(timeout:.now()+1) == .success)
        duringWrite.cancel(); precondition(cancelledReport["sealed"] as? Bool == false && !cancelledSettled)
        cancelRelease.signal(); wait { cancelledSettled }
        precondition(cancelledReport["reason"] as? String == "停止処理中断")
        print("最終フェンス・期限・キャンセル・遅着応答・保存失敗・保存I/O中の停止と回収分離: PASS")
    }
}
