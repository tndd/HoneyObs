import Foundation

// 状態は主キュー専用。保存I/Oは別キューに置き、期限通知とI/O回収完了を分ける。
final class ObservationDrain {
    typealias Request = (String, @escaping (Result<Data,Error>) -> Void) -> (() -> Void)
    private let store: ObservationStore, budget: TimeInterval, request: Request
    private let persist: (Data) throws -> Void
    private let completed: ([String:Any]) -> Void
    private let settled: () -> Void
    private let persistenceQueue = DispatchQueue(label:"HoneyObs.final-observation-persistence",qos:.utility)
    private var timer: Timer?, cancelRead: (() -> Void)?
    private var finished = false, replied = false, fenced = true
    private var writing = false, didSettle = false
    private var started = 0.0, pages = 0
    init(store: ObservationStore, budget: TimeInterval, request: @escaping Request,
         persist: @escaping (Data) throws -> Void, completed: @escaping ([String:Any]) -> Void,
         settled: @escaping () -> Void = {}) {
        self.store = store; self.budget = max(0,min(0.5,budget)); self.request = request
        self.persist = persist; self.completed = completed; self.settled = settled
    }
    func start() {
        started = ProcessInfo.processInfo.systemUptime
        let deadlineTimer = Timer(timeInterval:max(0.001,budget),repeats:false) { [weak self] _ in self?.finish("取得期限") }
        timer = deadlineTimer; RunLoop.main.add(deadlineTimer,forMode:.common)
        next()
    }
    func cancel() { finish("停止処理中断") }
    private func next() {
        guard !finished else { return }
        guard pages < 40, ProcessInfo.processInfo.systemUptime-started < budget else { finish("取得期限"); return }
        pages += 1
        let cancel = request("/?after=\(store.lastID)&finalize=1") { [weak self] result in
            guard let self, !self.finished else { return }
            guard ProcessInfo.processInfo.systemUptime-self.started < self.budget else { self.finish("取得期限"); return }
            self.cancelRead = nil
            do {
                let data = try result.get()
                guard let json = try JSONSerialization.jsonObject(with:data) as? [String:Any], json["uid"] as? Int == 65534 else {
                    throw NSError(domain:"HoneyObs",code:1,userInfo:[NSLocalizedDescriptionKey:"最終観測の形式が不正です"])
                }
                try self.store.ingest(data); self.replied = true
                self.fenced = self.fenced && json["finalized"] as? Bool == true
                let archive = try self.store.encoded()
                guard ProcessInfo.processInfo.systemUptime-self.started < self.budget else { self.finish("取得期限"); return }
                self.write(archive)
            } catch { self.finish("取得・保存失敗: " + error.localizedDescription) }
        }
        if finished { cancel() } else { cancelRead = cancel }
    }
    private func write(_ data:Data) {
        writing = true
        let persist = self.persist, deadline = started + budget
        persistenceQueue.async { [weak self] in
            let result: Result<Void,Error> = Result {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NSError(domain:"HoneyObs.ObservationDrain",code:1,userInfo:[NSLocalizedDescriptionKey:"保存開始期限"])
                }
                try persist(data)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writing = false
                defer { self.settleIfPossible() }
                guard !self.finished else { return }
                guard ProcessInfo.processInfo.systemUptime < deadline else { self.finish("取得期限"); return }
                do {
                    try result.get()
                    if self.store.pending == 0 { self.finish(self.fenced ? "最終フェンスと全ページを確認" : "ゲストの最終フェンス未成立") }
                    else { DispatchQueue.main.async { self.next() } }
                } catch { self.finish("取得・保存失敗: " + error.localizedDescription) }
            }
        }
    }
    private func finish(_ reason:String) {
        guard !finished else { return }; finished = true
        timer?.invalidate(); timer = nil; cancelRead?(); cancelRead = nil
        // Timerと保存完了の順序に依存せず、sealの直前にも期限を確認する。
        let reason = reason == "最終フェンスと全ページを確認" && ProcessInfo.processInfo.systemUptime-started >= budget ? "取得期限" : reason
        let sealed = replied && fenced && store.pending == 0 && reason == "最終フェンスと全ページを確認"
        let complete = sealed && store.uncollected == 0 && store.evicted == 0
        completed(["status":complete ? "confirmed" : replied ? "partial" : "unverified", "sealed":sealed,
                   "unconfirmedTail":!sealed,"reason":reason,"pages":pages,
                   "lastID":store.lastID,"knownUncollected":store.uncollected,"evicted":store.evicted,
                   "pending":store.pending,"elapsedMilliseconds":Int((ProcessInfo.processInfo.systemUptime-started)*1000)])
        settleIfPossible()
    }
    private func settleIfPossible() {
        guard finished, !writing, !didSettle else { return }
        didSettle = true; settled()
    }
}
