import Cocoa
import Virtualization
import Network
import Darwin

final class Engine: NSObject, VZVirtualMachineDelegate {
    let directory: URL
    let resources: URL
    var onChange: (() -> Void)?
    private(set) var phase = "停止中"
    private(set) var publicURL = ""
    private(set) var detail = ""
    private var machine: VZVirtualMachine?
    private var console: FileHandle?
    private var listener: NWListener?
    private var sessions: [UUID: Relay] = [:]
    private var pending = 0
    private var supervisor: Process?
    private var timer: Timer?
    private var wantsPublic = false
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
    private(set) var events: [ObservedEvent] = []
    private(set) var sessionID = UUID().uuidString
    var canStart: Bool { !active && machine == nil && supervisor == nil }
    var isActive: Bool { active }

    init(directory: URL, resources: URL) throws {
        self.directory = directory; self.resources = resources
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
              "active": active, "vmPresent": machine != nil, "networkDevices": 0, "sharedDirectories": 0,
              "storageDevices": 0, "time": ISO8601DateFormatter().string(from: Date())], name: "state.json")
        onChange?()
    }

    func start(publish: Bool) {
        guard canStart else { return }
        active = true; wantsPublic = publish; publicURL = ""; detail = ""; phase = "VM起動中"
        generation = UUID(); let current = generation
        sessionID = generation.uuidString; events = []
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
                guard let self, self.generation == current, self.active else { return }
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
        readTunnelURL()
        guard !polling else { return }; polling = true
        let current = generation
        guestRequest(machine) { [weak self] result in
            guard let self, self.active, self.generation == current else { return }
            self.polling = false
            guard case .success(let data) = result,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["uid"] as? Int == 65534 else { return }
            if (self.snapshot["total"] as? Int) != (json["total"] as? Int) || (self.snapshot["boot"] as? String) != (json["boot"] as? String) {
                self.save(json, name: "events.json")
            }
            self.snapshot = json
            self.events = Array(((try? JSONDecoder().decode(EventSnapshot.self, from: data).events) ?? []).suffix(128))
            if !self.tunnelStarted {
                self.tunnelStarted = true
                if self.wantsPublic { self.startOrigin() } else { self.phase = "ローカル準備完了"; self.update() }
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
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            listener = server; let current = generation
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self, self.active, self.generation == current else { return }
                switch state {
                case .ready:
                    if let port = server?.port { self.localPort = port.rawValue; self.startTunnel() }
                case .failed(let error): self.fail(error.localizedDescription)
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] client in
                guard let self, self.active, self.generation == current,
                      self.pending + self.sessions.count < 8,
                      let device = self.machine?.socketDevices.first as? VZVirtioSocketDevice else { client.cancel(); return }
                self.pending += 1
                device.connect(toPort: 7000) { result in
                    self.pending -= 1
                    guard self.active, self.generation == current else { client.cancel(); return }
                    switch result {
                    case .failure: client.cancel()
                    case .success(let guest):
                        let id = UUID()
                        let relay = Relay(client: client, guest: guest) { [weak self] in self?.sessions.removeValue(forKey: id) }
                        self.sessions[id] = relay; relay.start()
                    }
                }
            }
            server.start(queue: .main)
        } catch { fail(error.localizedDescription) }
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
        process.standardOutput = handle; process.standardError = handle
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.supervisor = nil
                if self.active { self.fail("公開用プロセスが終了しました") } else { self.update() }
            }
        }
        do { try process.run(); supervisor = process; phase = "公開接続中"; update() }
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
        session.dataTask(with: URL(string: publicURL + "/honeyobs-test-ready")!) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == current else { return }
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

    func stop(reason: String) {
        guard active || machine != nil else { return }
        active = false; generation = UUID(); phase = "停止中"; detail = reason
        timer?.invalidate(); timer = nil
        listener?.cancel(); listener = nil
        for relay in sessions.values { relay.cancel() }; sessions.removeAll()
        supervisor?.terminate()
        if let vm = machine {
            if vm.canStop { vm.stop { [weak self] _ in self?.machine = nil; self?.console = nil; self?.update() } }
            else { machine = nil; console = nil }
        }
        update()
    }

    private func fail(_ message: String) { stop(reason: message); phase = "エラー"; update() }
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { if active { fail("VMが停止しました") } }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { if active { fail(error.localizedDescription) } }
    var eventCount: Int { snapshot["total"] as? Int ?? 0 }
}
