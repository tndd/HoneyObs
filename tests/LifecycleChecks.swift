import Cocoa
import Virtualization

// 実VMを使い、停止API・保存I/O境界だけを注入する。製品にテストコマンドは追加しない。
@main struct LifecycleChecks {
    static func wait(_ description: String, seconds: Double = 12, until: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !until(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(until(), description)
    }

    static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = root.appendingPathComponent("test-results/lifecycle-" + UUID().uuidString)
        let resources = root.appendingPathComponent("build/HoneyObs.app/Contents/Resources")
        var checks: [String] = []
        func engine(_ name: String, stopLimit: Double = 8, healthLimit: Double = 5,
                    stop: @escaping (VZVirtualMachine, @escaping (Result<Void, Error>) -> Void) -> Void = { vm, done in vm.stop { error in done(error.map { .failure($0) } ?? .success(())) } },
                    read: @escaping (VZVirtualMachine, @escaping (Result<Data, Error>) -> Void) -> Void = { vm, done in guestRequest(vm, completion: done) }) throws -> Engine {
            try Engine(directory: output.appendingPathComponent(name), resources: resources,
                       stopLimit: stopLimit, healthLimit: healthLimit, stopMachine: stop, readGuest: read)
        }
        func ready(_ value: Engine) {
            value.start(publish: false)
            wait("VMが準備完了にならない", seconds: 35) { value.phase == "ローカル準備完了" }
        }
        func stopped(_ value: Engine) {
            wait("終了確認が完了しない") { value.shutdownComplete }
            precondition(value.canStart && !value.isActive)
        }
        func record(_ name: String) { checks.append(name); print(name + ": PASS") }
        func command(_ executable:String,_ arguments:[String]) -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try! process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        }
        func helperIdentity(_ pid:String) -> String {
            let text = command("/bin/ps",["-p",pid,"-o","stat=,lstart=,command="])
            return text.hasPrefix("Z") ? "" : text
        }
        func helpers() -> [[String:String]] {
            let domain = command("/bin/launchctl",["print","pid/\(getpid())"])
            let pattern = try! NSRegularExpression(pattern:#"(?m)^\s+(\d+)\s+\S+\s+(com\.apple\.Virtualization\.VirtualMachine\.[A-F0-9-]+)\s*$"#)
            return pattern.matches(in:domain,range:NSRange(domain.startIndex...,in:domain)).compactMap { match in
                let pid = String(domain[Range(match.range(at:1),in:domain)!]), identity = helperIdentity(pid)
                guard identity.contains("/Virtualization.framework/") else { return nil }
                return ["pid":pid,"identity":identity,"service":String(domain[Range(match.range(at:2),in:domain)!])]
            }
        }

        do {
            let value = try engine("start-stop")
            for _ in 0..<3 {
                value.start(publish: false)
                var replies: [Bool] = []
                value.stop(reason: "起動途中") { replies.append($0) }
                value.stop(reason: "停止連打") { replies.append($0) }
                precondition(!value.canStart && value.phase == "停止処理中")
                stopped(value)
                precondition(replies == [true, true] && value.phase == "停止完了")
            }
            record("起動途中のOFF・連打・再起動")
        }
        do {
            var failOnce = true
            let value = try engine("stop-failure", stop: { vm, done in
                if failOnce {
                    failOnce = false
                    done(.failure(NSError(domain: "検証用停止失敗", code: 1)))
                } else { vm.stop { error in done(error.map { .failure($0) } ?? .success(())) } }
            })
            ready(value)
            var result: Bool?
            value.stop(reason: "停止失敗の注入") { result = $0 }
            wait("停止失敗を返さない") { result != nil }
            precondition(result == false && value.phase == "停止失敗" && !value.canStart, "停止API失敗を停止完了として扱った")
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: value.directory.appendingPathComponent("state.json"))) as! [String: Any]
            precondition(state["vmPresent"] as? Bool == true && state["shutdownComplete"] as? Bool == false)
            value.start(publish: false)
            precondition(!value.isActive)
            value.stop(reason: "終了確認の再試行")
            stopped(value)
            record("停止API失敗時の所有保持・再開禁止・回収再試行")
        }
        do {
            var delayed: ((Result<Void, Error>) -> Void)?
            var hangOnce = true
            let value = try engine("stop-timeout", stopLimit: 0.3, stop: { vm, done in
                if hangOnce { hangOnce = false; delayed = done }
                else { vm.stop { error in done(error.map { .failure($0) } ?? .success(())) } }
            })
            ready(value)
            var result: Bool?
            value.stop(reason: "停止API無応答") { result = $0 }
            wait("停止期限が働かない") { result != nil }
            precondition(result == false && value.phase == "停止失敗" && !value.canStart)
            value.stop(reason: "回収再試行")
            stopped(value)
            ready(value)
            delayed?(.success(()))
            precondition(value.isActive && value.phase == "ローカル準備完了")
            value.stop(reason: "検証終了")
            stopped(value)
            record("停止無応答・期限・古い完了通知の無効化")
        }
        do {
            let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
            weak var stoppedVM:VZVirtualMachine?
            var stopCalled = false
            let value = try Engine(directory:output.appendingPathComponent("slow-final-persist"),resources:resources,
                stopMachine:{ vm,done in
                    stopCalled = true; stoppedVM = vm
                    vm.stop { error in done(error.map { .failure($0) } ?? .success(())) }
                },persistFinal:{ data,url in
                    precondition(!Thread.isMainThread)
                    entered.signal(); precondition(release.wait(timeout:.now()+6) == .success)
                    try data.write(to:url,options:.atomic)
                })
            ready(value)
            let ownedHelpers = helpers(); precondition(!ownedHelpers.isEmpty,"実VZ helperを取得できない")
            let started = ProcessInfo.processInfo.systemUptime
            value.stop(reason:"最終保存のI/O停止")
            wait("保存を待ってVM停止が始まらない",seconds:3) { stopCalled }
            precondition(entered.wait(timeout:.now()) == .success,"最終保存に到達していない")
            wait("最終保存中に実VMを回収できない",seconds:3) { stoppedVM == nil }
            wait("保存I/O待ち中にVZ helperが残存",seconds:3) { ownedHelpers.allSatisfy { helperIdentity($0["pid"]!) != $0["identity"]! } }
            precondition(!value.shutdownComplete && !value.canStart,"保存I/Oが残るまま停止完了とした")
            let vmStopBeforeWriterReleased = ProcessInfo.processInfo.systemUptime-started
            release.signal(); stopped(value)
            let receipt = try JSONSerialization.jsonObject(with:Data(contentsOf:value.directory.appendingPathComponent("final-observation.json"))) as! [String:Any]
            precondition(receipt["status"] as? String == "partial" && receipt["sealed"] as? Bool == false)
            precondition(receipt["reason"] as? String == "取得期限")
            try JSONSerialization.data(withJSONObject:["vmStoppedWhileWriteBlocked":true,"helpersGoneBeforeWriteRelease":true,"helpersBefore":ownedHelpers,"seconds":vmStopBeforeWriterReleased,"receipt":receipt],options:.prettyPrinted)
                .write(to:value.directory.appendingPathComponent("slow-persist-proof.json"))
            record("保存I/O中の期限・実VM先行回収・再開禁止・遅着非確定")
        }
        do {
            let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
            let value = try Engine(directory:output.appendingPathComponent("persist-after-stop-timeout"),resources:resources,
                stopLimit:0.3,testing:true,persistFinal:{ data,url in
                    entered.signal(); precondition(release.wait(timeout:.now()+5) == .success)
                    try data.write(to:url,options:.atomic)
                })
            ready(value); value.stop(reason:"保存I/Oが停止期限も超過")
            wait("停止期限超過を返さない",seconds:3) { value.phase == "停止失敗" }
            precondition(entered.wait(timeout:.now()) == .success)
            var retry:Bool?
            value.stop(reason:"保存回収前の再試行") { retry=$0 }
            precondition(retry == false && !value.shutdownComplete && !value.canStart)
            value.start(publish:false); precondition(!value.isActive)
            release.signal()
            wait("古い保存I/Oを回収できない") { value.testingSnapshot["finalDrainPending"] as? Bool == false }
            value.stop(reason:"保存回収後の再試行"); stopped(value)
            record("保存I/Oが停止期限を超えても参照保持・再試行と再開の拒否")
        }
        do {
            var suppressReplies = false
            let value = try engine("health-timeout", healthLimit: 1.5, read: { vm, done in
                if !suppressReplies { guestRequest(vm, completion: done) }
            })
            ready(value)
            suppressReplies = true
            let started = Date()
            wait("VM応答喪失でも稼働が続く", seconds: 5) { !value.isActive }
            stopped(value)
            precondition(value.phase == "エラー" && value.detail.contains("応答期限"))
            precondition(Date().timeIntervalSince(started) < 5)
            record("VM応答なし・要求コールバックなしからの自動停止")
        }
        try JSONSerialization.data(withJSONObject: ["checks": checks, "actualVM": true, "publicTunnel": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
        print("検証記録: " + output.path)
    }
}
