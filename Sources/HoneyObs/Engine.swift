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
    private var console: BoundedConsole?
    private var consoleClosing = false
    private var guestReads: [UUID:GuestRead] = [:]
    private var finalDrain: ObservationDrain?
    private var finalObservation: [String:Any] = ["status":"unverified","unconfirmedTail":true]
    private var archiveSession: SessionArchive?
    private var listener: NWListener?
    private var sessions: [UUID: Relay] = [:]
    private var pending: [UUID: NWConnection] = [:]
    private var cancellingClients: [ObjectIdentifier:NWConnection] = [:]
    #if EGRESS_TESTING
    var egressTestHandler: ((UInt32, VZVirtioSocketConnection, @escaping () -> Void) -> Void)?
    private var egressFixture: EgressTestingFixture?
    var egressFixtureStatus: [String:Any] { egressFixture?.status ?? [:] }
    func enableEgressTestingFixture() throws {
        guard testing, !active else { throw NSError(domain:"HoneyObs.EgressFixture",code:1) }
        let fixture = try EgressTestingFixture(originPort:{[weak self] in self?.localPort ?? 0})
        egressFixture = fixture
        egressTestHandler = { [weak fixture] port, connection, finished in
            guard let fixture else { connection.close(); finished(); return }
            fixture.handle(port,connection:connection,finished:finished)
        }
    }
    #endif
    private var egress: EgressVM?
    private var egressStopRequested = false
    private var stopVMsStarted = false
    private var finalDrainStarted = false
    private var permit: ForwardingPermit?
    private var permitTimer: Timer?
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
    private var snapshot: [String: Any] = [:]
    private var sleepObserver: NSObjectProtocol?
    private var stopTimer: Timer?
    private var stopStarted = 0.0
    private var stopAttempt = UUID()
    private var stopRequested = false
    private var stopping = false
    private var stopFailed = false
    private var runError: String?
    private var stopCallbacks: [(Bool) -> Void] = []
    private var lastGuestReply = 0.0
    private let stopLimit: TimeInterval
    private let healthLimit: TimeInterval
    private let stopMachine: (VZVirtualMachine, @escaping (Result<Void, Error>) -> Void) -> Void
    private let readGuest: ((VZVirtualMachine, @escaping (Result<Data, Error>) -> Void) -> Void)?
    private let persistFinal: (Data,URL) throws -> Void
    private let testing: Bool
    private let probeTargets: String
    var requiresSessionRecovery: Bool { stopFailed || (egress?.requiresSessionRecovery ?? false) }
    private var observations = ObservationStore()
    private var lastArchive = Data()
    private var hostRejections: [String: ObservationStore.Rejection] = [:]
    private(set) var events: [ObservedEvent] = []
    private(set) var sessionID = UUID().uuidString
    var shutdownComplete: Bool {
        !active && !stopping && !stopFailed && machine == nil &&
        egress == nil && console == nil && guestReads.isEmpty && finalDrain == nil && listener == nil && sessions.isEmpty && pending.isEmpty && cancellingClients.isEmpty
    }
    var canStart: Bool { shutdownComplete }
    var isActive: Bool { active }
    var isLocalExercise: Bool { localExercise }
    var testingSnapshot: [String:Any] {
        guard testing else { return [:] }
        return ["safetyNow":safetyTime(),"guestConfirmedAt":guestConfirmed,"uiConfirmedAt":uiConfirmed,
                "permitDeadline":permit?.deadline ?? 0,"permitValid":permit?.valid ?? false,
                "finalDrainPending":finalDrain != nil]
    }

    init(directory: URL, resources: URL, stopLimit: TimeInterval = 8, healthLimit: TimeInterval = 5, testing: Bool = false, probeTargets: String = "", requireManagedArchive: Bool = false,
         stopMachine: @escaping (VZVirtualMachine, @escaping (Result<Void, Error>) -> Void) -> Void = { vm, done in vm.stop { error in done(error.map { .failure($0) } ?? .success(())) } },
         readGuest: ((VZVirtualMachine, @escaping (Result<Data, Error>) -> Void) -> Void)? = nil,
         persistFinal: @escaping (Data,URL) throws -> Void = { data,url in try data.write(to:url,options:.atomic) }) throws {
        self.directory = directory; self.resources = resources; self.testing = testing; self.probeTargets = probeTargets
        self.stopLimit = stopLimit; self.healthLimit = healthLimit; self.stopMachine = stopMachine
        self.readGuest = readGuest
        self.persistFinal = persistFinal
        super.init()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if requireManagedArchive {
            archiveSession = try SessionArchive(directory:directory)
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(reason: "スリープ通知")
        }
        try archiveSession?.setClosed(true)
        update()
    }

    @discardableResult func save(_ object: Any, name: String) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try archiveSession?.checkWrite(bytes:data.count,name:name)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            detail = "保存失敗: \(error.localizedDescription)"
            if active, runError == nil {
                runError = detail
                DispatchQueue.main.async { [weak self] in self?.stop(reason:"記録を保存できないため停止します") }
            }
            return false
        }
    }

    @discardableResult private func requestGuest(_ vm:VZVirtualMachine,path:String,completion:@escaping (Result<Data,Error>)->Void) -> UUID {
        let id = UUID()
        guestReads[id] = guestRequest(vm,path:path) { [weak self] result in
            // connect失敗が同期応答でも、辞書への代入より後に回収する。
            DispatchQueue.main.async {
                guard let self else { return }
                self.guestReads.removeValue(forKey:id); completion(result); self.advanceStop()
            }
        }
        return id
    }
    private func closeConsole() {
        guard let console, !consoleClosing else { return }; consoleClosing = true
        console.close { [weak self, weak console] in
            guard let self, self.console === console else { return }
            self.console = nil; self.consoleClosing = false; self.advanceStop()
        }
    }
    // Relayへ渡さなかった接続も、Network.frameworkの取消完了まで所有する。
    private func cancelClient(_ client:NWConnection) {
        if case .cancelled = client.state { return }
        let id = ObjectIdentifier(client)
        guard cancellingClients[id] == nil else { return }
        cancellingClients[id] = client
        client.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state, let self else { return }
            self.cancellingClients.removeValue(forKey:id); self.advanceStop()
        }
        client.start(queue:.main); client.cancel()
    }

    private func update() {
        save(["phase": phase, "detail": detail, "url": publicURL, "pid": getpid(),
              "supervisorPID": 0, "originPort": localPort,
              "egressVMPresent": egress != nil, "egressHealthy": egress?.healthy ?? false,
              "egressHealthAt": egress?.lastHealthAt ?? 0,
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
        do { try archiveSession?.setClosed(false) } catch { phase = "エラー"; detail = error.localizedDescription; update(); return }
        finalObservation = ["status":"collecting","unconfirmedTail":true]
        permit = nil; guestConfirmed = 0; uiConfirmed = 0; egressStopRequested = false; stopVMsStarted = false; finalDrainStarted = false
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
            console = try BoundedConsole(url:log,onFailure:{ [weak self] error in self?.fail("VMログ保存失敗: " + error.localizedDescription) })
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: FileHandle(forReadingAtPath: "/dev/null"), fileHandleForWriting: console!.writer)
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
        if testing, let value = try? String(contentsOf: command, encoding: .utf8) {
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
        let read = readGuest ?? { vm, done in _ = self.requestGuest(vm,path:"/?after=\(self.observations.lastID)",completion:done) }
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
                    try self.archiveSession?.checkWrite(bytes:archive.count,name:"events.json")
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
                let extra = testing ? probeTargets : ""
                let suffix = extra.split(separator: ",").map { "target=" + $0 }.joined(separator: "&")
                self.requestGuest(machine, path: "/isolation?" + suffix) { result in
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
                    if let port = server?.port {
                        self.localPort = port.rawValue
                        if self.testing { self.save(["host": self.originHost], name: "test-origin.json") }
                        self.originReady()
                    }
                case .failed(let error): self.fail(error.localizedDescription)
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] client in
                guard let self else { client.cancel(); return }
                guard self.active, self.generation == current, permission.valid,
                      let device = self.machine?.socketDevices.first as? VZVirtioSocketDevice else { self.cancelClient(client); return }
                guard self.pending.count + self.sessions.count < 8 else {
                    self.recordHostRejection("connection_limit"); self.cancelClient(client); return
                }
                let pendingID = UUID(); self.pending[pendingID] = client
                device.connect(toPort: 7000) { result in
                    self.pending.removeValue(forKey: pendingID)
                    guard self.active, self.generation == current, permission.valid else {
                        self.cancelClient(client)
                        if case .success(let guest) = result { guest.close() }
                        self.advanceStop(); return
                    }
                    switch result {
                    case .failure: self.recordHostRejection("guest_connect"); self.cancelClient(client)
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
    }

    private func startTunnel() {
        guard egress == nil, let permit, permit.valid else { fail("通信VMの転送許可がありません"); return }
        let current = generation
        let communication = EgressVM(resources: resources, directory: directory, originPort: localPort, originHost: originHost, permit: permit) { [weak self] message in
            guard let self else { return }
            if self.active { self.fail(message) } else { self.advanceStop() }
        }
        #if EGRESS_TESTING
        communication.testHandler = egressTestHandler
        #endif
        egress = communication; phase = "通信VM起動中"; update()
        communication.start { [weak self, weak communication] result in
            guard let self, let communication, self.egress === communication else { return }
            guard self.active, self.generation == current else { self.advanceStop(); return }
            switch result {
            case .failure(let error): self.fail(error.localizedDescription)
            case .success:
                self.phase = "公開接続中"; self.detail = "通信VMの準備完了。外部からの到達は未確認です"
                self.readTunnelURL(); self.update()
            }
        }
    }

    private func readTunnelURL() {
        let acquiredURL = egress?.publicURL ?? ""
        guard wantsPublic, publicURL.isEmpty, !acquiredURL.isEmpty else { return }
        publicURL = acquiredURL; phase = "公開URL取得済み"
        detail = "通信VMで一時公開URLを取得しました。外部からの到達は未確認です"; update()
    }

    func stop(reason: String, completion: ((Bool) -> Void)? = nil) {
        if shutdownComplete { completion?(true); return }
        // 回収期限後もOSの保存I/Oは残り得る。旧書込の回収前に停止再試行から再開を許さない。
        if stopFailed, finalDrain != nil { completion?(false); return }
        if let completion { stopCallbacks.append(completion) }
        guard !stopping else { return }
        active = false; generation = UUID(); phase = "停止処理中"; detail = reason
        stopping = true; stopFailed = false; stopRequested = false; egressStopRequested = false; stopVMsStarted = false; finalDrainStarted = false
        permit?.revoke(); permitTimer?.invalidate(); permitTimer = nil
        stopAttempt = UUID(); stopStarted = ProcessInfo.processInfo.systemUptime
        timer?.invalidate(); timer = nil
        listener?.cancel()
        for client in pending.values { cancelClient(client) }
        for relay in sessions.values { relay.cancel() }
        for read in guestReads.values { read.cancel() }
        stopTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.advanceStop() }
        update(); advanceStop()
    }

    private func advanceStop() {
        guard stopping else { return }
        if !stopVMsStarted {
            if listener == nil, sessions.isEmpty, pending.isEmpty, cancellingClients.isEmpty, !finalDrainStarted {
                finalDrainStarted = true; let attempt = stopAttempt
                drainFinalObservations { [weak self] in
                    guard let self, self.stopping, self.stopAttempt == attempt else { return }
                    self.stopVMsStarted = true; self.advanceStop()
                }
            }
        } else if let communication = egress, !egressStopRequested {
            egressStopRequested = true; let attempt = stopAttempt
            communication.stop { [weak self, weak communication] confirmed in
                guard let self, let communication, self.stopping, self.stopAttempt == attempt, self.egress === communication else { return }
                guard confirmed, communication.shutdownComplete else {
                    self.finishStop(error: "通信VMの停止完了を確認できません。再開できません"); return
                }
                self.egress = nil; self.advanceStop()
            }
        }
        if stopVMsStarted, let vm = machine {
            if vm.state == .stopped, !stopRequested {
                machine = nil; closeConsole()
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
                        self.machine = nil; self.closeConsole(); self.advanceStop()
                    }
                }
                // テスト用の同期応答を含め、失敗後に完了へ上書きしない。
                guard stopping else { return }
            }
        }
        if machine == nil { closeConsole() }
        if stopVMsStarted, finalDrain == nil, machine == nil, console == nil, guestReads.isEmpty, egress == nil, listener == nil, sessions.isEmpty, pending.isEmpty, cancellingClients.isEmpty {
            finishStop(error: nil)
        } else if ProcessInfo.processInfo.systemUptime - stopStarted >= stopLimit {
            finishStop(error: "停止期限を超えました。終了未確認のため再開できません")
        }
    }

    // 入口と処理中Relayが閉じた後、両VMを止める前の差込箇所。
    // 統合側はここでfinalize=1と最大0.5秒の最終観測取得を行う。
    private func drainFinalObservations(completion: @escaping () -> Void) {
        guard let vm = machine, vm.state == .running else {
            finalObservation = ["status":"unverified","unconfirmedTail":true,"reason":"VM応答不可"]
            saveFinalObservation(); completion(); return
        }
        let attempt = stopAttempt
        // workerからEngineの状態を触らず、保存先とarchive lockだけを保持する。
        let archive = archiveSession, target = directory.appendingPathComponent("events.json"), persist = persistFinal
        let drain = ObservationDrain(store:observations,budget:min(0.5,stopLimit/4),request:{ [weak self, weak vm] path,reply in
            guard let self, let vm else {
                reply(.failure(NSError(domain:"HoneyObs.ObservationDrain",code:2,userInfo:[NSLocalizedDescriptionKey:"模擬VMは回収済みです"]))); return {}
            }
            let id = self.requestGuest(vm,path:path,completion:reply)
            return { [weak self] in self?.guestReads[id]?.cancel() }
        },persist:{ data in
            try archive?.checkWrite(bytes:data.count,name:"events.json")
            try persist(data,target)
        },completed:{ [weak self] receipt in
            guard let self, self.stopAttempt == attempt else { return }
            self.finalObservation = receipt
            self.events = Array(self.observations.events.suffix(128))
            // 期限通知でVM停止を先に始める。保存中はsettledまで再開・停止完了を認めない。
            if self.stopping { completion() }
            self.saveFinalObservation()
        },settled:{ [weak self] in
            guard let self, self.stopAttempt == attempt else { return }
            self.finalDrain = nil; self.advanceStop()
        })
        finalDrain = drain; drain.start()
    }
    private func saveFinalObservation() {
        var receipt = finalObservation; receipt["session"] = sessionID
        if !save(receipt,name:"final-observation.json") {
            finalObservation["status"] = "partial"; finalObservation["unconfirmedTail"] = true
            finalObservation["reason"] = "最終観測のreceiptを保存できません"
        }
        saveObservationStatus()
    }

    private func finishStop(error: String?) {
        guard stopping else { return }
        stopTimer?.invalidate(); stopTimer = nil; stopping = false
        finalDrain?.cancel()
        stopFailed = error != nil
        if let error { phase = "停止失敗"; detail = error }
        else { phase = runError == nil ? "停止完了" : "エラー"; if let runError { detail = runError } }
        let callbacks = stopCallbacks; stopCallbacks.removeAll()
        let confirmed = shutdownComplete
        if confirmed { do { try archiveSession?.setClosed(true) } catch { detail = "保存終了情報の記録失敗: " + error.localizedDescription } }
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
        machine = nil; closeConsole()
        if active { fail(error.localizedDescription) } else { advanceStop() }
    }
    var eventCount: UInt64 { observations.total }
    var observationStatus: [String: Any] {
        var rejected: [String: Any] = [:]
        for (reason, value) in observations.rejections.merging(hostRejections, uniquingKeysWith: { _, host in host }) {
            rejected[reason] = ["count": value.count, "lastTime": value.lastTime]
        }
        return ["retained": observations.events.count, "uncollected": observations.uncollected,
                "evicted": observations.evicted, "pending": observations.pending, "rejections": rejected,
                "finalization":finalObservation["status"] ?? "unverified", "finalObservation":finalObservation]
    }
    private func saveObservationStatus() { save(observationStatus, name: "observation.json") }
    private func recordHostRejection(_ reason: String) {
        var entry = hostRejections[reason] ?? .init(count: 0, lastTime: "")
        entry.count += 1; entry.lastTime = ISO8601DateFormatter().string(from: Date())
        hostRejections[reason] = entry; saveObservationStatus(); onChange?()
    }
}
