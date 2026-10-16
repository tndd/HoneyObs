import Cocoa
import Virtualization
import Network
import Darwin

final class Engine: NSObject, VZVirtualMachineDelegate {
    let directory: URL
    let resources: URL
    var onChange: (() -> Void)?
    private(set) var phase = "停止完了"
    private(set) var publicURL = ""
    private(set) var detail = ""
    private var machine: VZVirtualMachine?
    private var console: FileHandle?
    private var listener: NWListener?
    private var sessions: [UUID: Relay] = [:]
    private var pending: [UUID: NWConnection] = [:]
    private var supervisor: Process?
    private var permit: ForwardingPermit?
    private var permitTimer: Timer?
    private var leaseWriter: FileHandle?
    private var leaseReader: FileHandle?
    private var ackBytes = Data()
    private var leaseSequence: UInt64 = 0
    private var ackSequence: UInt64 = 0
    private var guardianDeadline = 0.0
    private var guardianStarted = 0.0
    private var guestConfirmed = 0.0
    private var uiConfirmed = 0.0
    var requiresUIHeartbeat = false
    func confirmUI(session: String) {
        guard session == sessionID else { return }; uiConfirmed = safetyTime()
    }
    private var timer: Timer?
    private var wantsPublic = false
    private var localExercise = false
    private var active = false
    private var polling = false
    private var generation = UUID()
    private var originHost = ""
    private var started = Date()
    private var localPort: UInt16 = 0
    private var tunnelStarted = false
    private var diagnosticsStarted = false
    private var publicCheckStarted = Date()
    private var snapshot: [String: Any] = [:]
    private var sleepObserver: NSObjectProtocol?
    private var stopTimer: Timer?
    private var stopStarted = 0.0
    private var stopAttempt = UUID()
    private var stopRequested = false
    private var stopping = false
    private var stopFailed = false
    private var supervisorUnconfirmed = false
    private var runError: String?
    private var stopCallbacks: [(Bool) -> Void] = []
    private var lastGuestReply = 0.0
    private var publicSession: URLSession?
    private let stopLimit: TimeInterval
    private let healthLimit: TimeInterval
    private let stopMachine: (VZVirtualMachine, @escaping (Result<Void, Error>) -> Void) -> Void
    private let readGuest: ((VZVirtualMachine, @escaping (Result<Data, Error>) -> Void) -> Void)?
    private var observations = ObservationStore()
    private var lastArchive = Data()
    private var hostRejections: [String: ObservationStore.Rejection] = [:]
    private(set) var events: [ObservedEvent] = []
    private(set) var sessionID = UUID().uuidString
    var shutdownComplete: Bool {
        !active && !stopping && !stopFailed && !supervisorUnconfirmed && machine == nil &&
        supervisor == nil && listener == nil && sessions.isEmpty && pending.isEmpty
    }
    var canStart: Bool { shutdownComplete }
    var isActive: Bool { active }
    var isLocalExercise: Bool { localExercise }

    init(directory: URL, resources: URL, stopLimit: TimeInterval = 8, healthLimit: TimeInterval = 5,
         stopMachine: @escaping (VZVirtualMachine, @escaping (Result<Void, Error>) -> Void) -> Void = { vm, done in vm.stop { error in done(error.map { .failure($0) } ?? .success(())) } },
         readGuest: ((VZVirtualMachine, @escaping (Result<Data, Error>) -> Void) -> Void)? = nil) throws {
        self.directory = directory; self.resources = resources
        self.stopLimit = stopLimit; self.healthLimit = healthLimit; self.stopMachine = stopMachine
        self.readGuest = readGuest
        super.init()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(reason: "スリープ通知")
        }
    }

    func save(_ object: Any, name: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch { detail = "保存失敗: \(error.localizedDescription)" }
    }

    private func update() {
        save(["phase": phase, "detail": detail, "url": publicURL, "pid": getpid(),
              "supervisorPID": supervisor?.processIdentifier ?? 0, "originPort": localPort,
              "active": active, "vmPresent": machine != nil, "canStart": canStart,
              "shutdownComplete": shutdownComplete, "stopping": stopping, "networkDevices": 0, "sharedDirectories": 0,
              "storageDevices": 0, "time": ISO8601DateFormatter().string(from: Date())], name: "state.json")
        onChange?()
    }

    var exerciseEndpoint: (port: UInt16, host: String)? {
        active && localExercise && localPort != 0 ? (localPort, originHost) : nil
    }

    func start(publish: Bool, localExercise: Bool = false) {
        guard canStart else { return }
        self.localExercise = localExercise
        permit = nil; guestConfirmed = 0; uiConfirmed = 0; leaseSequence = 0; ackSequence = 0; guardianDeadline = 0; ackBytes = Data()
        active = true; wantsPublic = publish; publicURL = ""; detail = ""; phase = "VM起動中"
        runError = nil; lastGuestReply = ProcessInfo.processInfo.systemUptime
        generation = UUID(); let current = generation
        sessionID = generation.uuidString; events = []; observations = ObservationStore(); lastArchive = Data(); hostRejections = [:]
        originHost = UUID().uuidString.lowercased() + ".invalid"
        started = Date(); tunnelStarted = false; diagnosticsStarted = false; snapshot = [:]
        localPort = 0; polling = false; update()
        do {
            let config = VZVirtualMachineConfiguration()
            config.cpuCount = 1; config.memorySize = 512 * 1024 * 1024
            let boot = VZLinuxBootLoader(kernelURL: resources.appendingPathComponent("vmlinuz"))
            boot.initialRamdiskURL = resources.appendingPathComponent("initramfs.gz")
            boot.commandLine = "console=hvc0 rdinit=/init panic=0 quiet honeyobs.host=\(originHost)"
            config.bootLoader = boot
            config.networkDevices = []; config.storageDevices = []; config.directorySharingDevices = []
            config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            let log = directory.appendingPathComponent("console.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            console = try FileHandle(forWritingTo: log)
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: FileHandle(forReadingAtPath: "/dev/null"), fileHandleForWriting: console!)
            config.serialPorts = [serial]
            config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            try config.validate()
            let vm = VZVirtualMachine(configuration: config); machine = vm; vm.delegate = self
            vm.start { [weak self] result in
                guard let self, self.machine === vm else { return }
                // 起動中のOFFでもVMの所有を保持し、起動完了後に停止する。
                if !self.active { self.advanceStop(); return }
                guard self.generation == current else { return }
                switch result {
                case .failure(let error): self.fail(error.localizedDescription)
                case .success:
                    self.phase = "VM準備中"; self.update()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                    self.tick()
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func tick() {
        guard active, let machine else { return }
        let command = directory.appendingPathComponent("command")
        if let value = try? String(contentsOf: command, encoding: .utf8) {
            try? FileManager.default.removeItem(at: command)
            if value.trimmingCharacters(in: .whitespacesAndNewlines) == "simulate-sleep" {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil); return
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines) == "stop" { stop(reason: "通常停止"); return }
        }
        if !tunnelStarted && Date().timeIntervalSince(started) > 30 { fail("VM起動の期限を超えました"); return }
        if tunnelStarted, publicURL.isEmpty, wantsPublic, Date().timeIntervalSince(started) > 90 { fail("一時公開URLの取得に失敗しました"); return }
        if tunnelStarted, ProcessInfo.processInfo.systemUptime - lastGuestReply > healthLimit {
            fail("VMの応答期限を超えたため公開を停止します"); return
        }
        readTunnelURL()
        guard !polling else { return }; polling = true
        let current = generation
        let read = readGuest ?? { vm, done in guestRequest(vm, path: "/?after=\(self.observations.lastID)", completion: done) }
        read(machine) { [weak self] result in
            guard let self, self.active, self.generation == current else { return }
            self.polling = false
            guard case .success(let data) = result,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["uid"] as? Int == 65534 else { return }
            self.lastGuestReply = ProcessInfo.processInfo.systemUptime
            self.guestConfirmed = safetyTime()
            do {
                try self.observations.ingest(data)
                let archive = try self.observations.encoded()
                if archive != self.lastArchive {
                    try archive.write(to: self.directory.appendingPathComponent("events.json"), options: .atomic)
                    self.lastArchive = archive
                }
            } catch { self.fail("観測の取得・保存失敗: " + error.localizedDescription); return }
            self.snapshot = json
            self.events = Array(self.observations.events.suffix(128))
            self.saveObservationStatus()
            if self.observations.pending > 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.generation == current else { return }
                    self.tick()
                }
            }
            if !self.tunnelStarted {
                self.tunnelStarted = true
                if self.wantsPublic || self.localExercise { self.startOrigin() } else { self.phase = "ローカル準備完了"; self.update() }
            }
            if !self.diagnosticsStarted {
                self.diagnosticsStarted = true
                let extra = ProcessInfo.processInfo.environment["HONEYOBS_PROBE_TARGETS"] ?? ""
                let suffix = extra.split(separator: ",").map { "target=" + $0 }.joined(separator: "&")
                guestRequest(machine, path: "/isolation?" + suffix) { result in
                    guard self.active, self.generation == current else { return }
                    if case .success(let data) = result, let value = try? JSONSerialization.jsonObject(with: data) { self.save(value, name: "isolation.json") }
                }
            }
            self.onChange?()
        }
    }

    private func startOrigin() {
        let confirmed = requiresUIHeartbeat ? min(guestConfirmed, uiConfirmed) : guestConfirmed
        let permission = ForwardingPermit(confirmedAt: confirmed)
        guard permission.valid else { fail("画面またはVMの応答が古いため転送を開始しません"); return }
        permit = permission
        permitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.maintainPermit() }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            listener = server; let current = generation
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self else { return }
                if case .cancelled = state, self.listener === server {
                    self.listener = nil; self.advanceStop(); return
                }
                guard self.active, self.generation == current else { return }
                switch state {
                case .ready:
                    if let port = server?.port { self.localPort = port.rawValue; self.originReady() }
                case .failed(let error): self.fail(error.localizedDescription)
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] client in
                guard let self, self.active, self.generation == current, permission.valid,
                      let device = self.machine?.socketDevices.first as? VZVirtioSocketDevice else { client.cancel(); return }
                guard self.pending.count + self.sessions.count < 8 else {
                    self.recordHostRejection("connection_limit"); client.cancel(); return
                }
                let pendingID = UUID(); self.pending[pendingID] = client
                device.connect(toPort: 7000) { result in
                    self.pending.removeValue(forKey: pendingID)
                    guard self.active, self.generation == current, permission.valid else {
                        client.cancel()
                        if case .success(let guest) = result { guest.close() }
                        self.advanceStop(); return
                    }
                    switch result {
                    case .failure: self.recordHostRejection("guest_connect"); client.cancel()
                    case .success(let guest):
                        let id = UUID()
                        let relay = Relay(client: client, guest: guest, permit: permission, rejected: { [weak self] reason in
                            guard let self, self.generation == current else { return }
                            self.recordHostRejection(reason)
                        }) { [weak self] in
                            self?.sessions.removeValue(forKey: id); self?.advanceStop()
                        }
                        self.sessions[id] = relay; relay.start()
                    }
                }
            }
            server.start(queue: .main)
        } catch { fail(error.localizedDescription) }
    }

    private func originReady() {
        if localExercise { phase = "ローカル準備完了"; update() }
        else { startTunnel() }
    }

    private func maintainPermit() {
        guard active, let permit else { return }
        let confirmed = requiresUIHeartbeat ? min(guestConfirmed, uiConfirmed) : guestConfirmed
        guard permit.renew(confirmedAt: confirmed) else { fail("転送許可の期限切れにより停止します"); return }
        guard let writer = leaseWriter, let reader = leaseReader else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
        if count == 0 { fail("監視役との確認通信が切断されました"); return }
        if count > 0 { ackBytes.append(contentsOf: buffer.prefix(count)) }
        while ackBytes.count >= 16 {
            let frame = Data(ackBytes.prefix(16)); ackBytes.removeFirst(16)
            let sequence = frame.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let expiry = frame.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
            guard sequence > ackSequence, sequence <= leaseSequence else { fail("監視役の確認番号が不正です"); return }
            ackSequence = sequence; guardianDeadline = Double(expiry) / 1_000_000_000
        }
        if safetyTime() - guardianStarted > 1, guardianDeadline <= safetyTime() {
            fail("監視役の応答期限を超えたため転送を停止します"); return
        }
        leaseSequence += 1
        var sequence = leaseSequence, expiry = UInt64(permit.deadline * 1_000_000_000)
        var frame = withUnsafeBytes(of: &sequence) { Data($0) }
        frame.append(withUnsafeBytes(of: &expiry) { Data($0) })
        let written = frame.withUnsafeBytes { Darwin.write(writer.fileDescriptor, $0.baseAddress, $0.count) }
        if written != frame.count { fail("監視役への転送許可を送れません") }
    }

    private func startTunnel() {
        guard supervisor == nil else { return }
        let log = directory.appendingPathComponent("tunnel.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let config = directory.appendingPathComponent("tunnel.yml")
        // 利用者の既存cloudflared設定を読み込まない。
        try? Data("{}\n".utf8).write(to: config)
        let process = Process(); process.executableURL = Bundle.main.executableURL
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.arguments = ["--watchdog", String(getpid()), directory.path, resources.appendingPathComponent("cloudflared").path,
                             "tunnel", "--config", config.path, "--no-autoupdate", "--url", "http://127.0.0.1:\(localPort)",
                             "--http-host-header", originHost, "--protocol", "http2", "--metrics", "127.0.0.1:0"]
        let handle = try? FileHandle(forWritingTo: log)
        let leases = Pipe(), acknowledgements = Pipe()
        process.standardInput = leases; process.standardOutput = acknowledgements; process.standardError = handle
        leaseWriter = leases.fileHandleForWriting; leaseReader = acknowledgements.fileHandleForReading
        for fd in [leaseWriter!.fileDescriptor, leaseReader!.fileDescriptor] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        guardianStarted = safetyTime()
        process.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async {
                guard let self, self.supervisor === exited else { return }
                self.supervisor = nil
                try? self.leaseWriter?.close(); self.leaseWriter = nil
                try? self.leaseReader?.close(); self.leaseReader = nil
                // 監視役の正常終了は子のwaitUntilExit後だけ。異常終了では回収を推測しない。
                if exited.terminationReason != .exit || exited.terminationStatus != 0 {
                    self.supervisorUnconfirmed = true
                }
                if self.active { self.fail("公開用プロセスが終了しました") }
                else { self.advanceStop(); self.update() }
            }
        }
        do {
            try process.run(); supervisor = process
            try? leases.fileHandleForReading.close(); try? acknowledgements.fileHandleForWriting.close()
            maintainPermit(); if active { phase = "公開接続中"; update() }
        }
        catch { fail(error.localizedDescription) }
        try? handle?.close()
    }

    private func readTunnelURL() {
        guard wantsPublic, publicURL.isEmpty,
              let log = try? String(contentsOf: directory.appendingPathComponent("tunnel.log"), encoding: .utf8),
              let range = log.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) else { return }
        publicURL = String(log[range]); phase = "公開URL確認中"; update()
        publicCheckStarted = Date()
        checkPublicURL()
    }

    private func checkPublicURL() {
        let current = generation
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        publicSession = session
        session.dataTask(with: URL(string: publicURL + "/honeyobs-test-ready")!) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == current else { return }
                self.publicSession = nil
                if let response = response as? HTTPURLResponse, response.statusCode == 404,
                   data == Data("Not found\n".utf8) {
                    self.phase = "公開中"; self.detail = "公開URL経由でVMの応答を確認"
                } else {
                    if Date().timeIntervalSince(self.publicCheckStarted) < 180 {
                        self.detail = "公開経路の準備を待っています"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if self.active, self.generation == current { self.checkPublicURL() }
                        }
                    } else {
                        self.fail("公開URL経由でVMの応答を確認できませんでした: " + (error?.localizedDescription ?? "応答不一致"))
                    }
                }
                self.update()
            }
            session.finishTasksAndInvalidate()
        }.resume()
    }

    func stop(reason: String, completion: ((Bool) -> Void)? = nil) {
        if shutdownComplete { completion?(true); return }
        if let completion { stopCallbacks.append(completion) }
        guard !stopping else { return }
        active = false; generation = UUID(); phase = "停止処理中"; detail = reason
        stopping = true; stopFailed = false; stopRequested = false
        permit?.revoke(); permitTimer?.invalidate(); permitTimer = nil
        try? leaseWriter?.close(); leaseWriter = nil
        stopAttempt = UUID(); stopStarted = ProcessInfo.processInfo.systemUptime
        timer?.invalidate(); timer = nil
        publicSession?.invalidateAndCancel(); publicSession = nil
        listener?.cancel()
        for client in pending.values { client.cancel() }
        for relay in sessions.values { relay.cancel() }
        supervisor?.terminate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.advanceStop() }
        update(); advanceStop()
    }

    private func advanceStop() {
        guard stopping else { return }
        if let vm = machine {
            if vm.state == .stopped, !stopRequested {
                machine = nil; console = nil
            } else if vm.canStop, !stopRequested {
                stopRequested = true
                let attempt = stopAttempt
                stopMachine(vm) { [weak self] result in
                    guard let self, self.stopAttempt == attempt, self.stopping else { return }
                    switch result {
                    case .failure(let error): self.finishStop(error: "VM停止に失敗: " + error.localizedDescription)
                    case .success:
                        guard vm.state == .stopped else {
                            self.finishStop(error: "VMの停止完了を確認できません"); return
                        }
                        self.machine = nil; self.console = nil; self.advanceStop()
                    }
                }
                // テスト用の同期応答を含め、失敗後に完了へ上書きしない。
                guard stopping else { return }
            }
        }
        if machine == nil, listener == nil, sessions.isEmpty, pending.isEmpty, supervisor == nil {
            finishStop(error: supervisorUnconfirmed ? "監視役が異常終了したためトンネルの回収は未確認です。再開できません" : nil)
        } else if ProcessInfo.processInfo.systemUptime - stopStarted >= stopLimit {
            finishStop(error: "停止期限を超えました。終了未確認のため再開できません")
        }
    }

    private func finishStop(error: String?) {
        guard stopping else { return }
        stopTimer?.invalidate(); stopTimer = nil; stopping = false
        stopFailed = error != nil
        if let error { phase = "停止失敗"; detail = error }
        else { phase = runError == nil ? "停止完了" : "エラー"; if let runError { detail = runError } }
        let callbacks = stopCallbacks; stopCallbacks.removeAll()
        let confirmed = shutdownComplete
        update()
        for callback in callbacks { callback(confirmed) }
    }

    private func fail(_ message: String) { runError = message; stop(reason: message); if shutdownComplete { phase = "エラー"; detail = message; update() } }
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard machine === virtualMachine else { return }
        if active { fail("VMが停止しました") } else { advanceStop() }
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guard machine === virtualMachine else { return }
        // このdelegate通知はVMが停止したことを示す。単なるstop失敗とは区別する。
        machine = nil; console = nil
        if active { fail(error.localizedDescription) } else { advanceStop() }
    }
    var eventCount: UInt64 { observations.total }
    var observationStatus: [String: Any] {
        var rejected: [String: Any] = [:]
        for (reason, value) in observations.rejections.merging(hostRejections, uniquingKeysWith: { _, host in host }) {
            rejected[reason] = ["count": value.count, "lastTime": value.lastTime]
        }
        return ["retained": observations.events.count, "uncollected": observations.uncollected,
                "evicted": observations.evicted, "pending": observations.pending, "rejections": rejected]
    }
    private func saveObservationStatus() { save(observationStatus, name: "observation.json") }
    private func recordHostRejection(_ reason: String) {
        var entry = hostRejections[reason] ?? .init(count: 0, lastTime: "")
        entry.count += 1; entry.lastTime = ISO8601DateFormatter().string(from: Date())
        hostRejections[reason] = entry; saveObservationStatus(); onChange?()
    }
}
