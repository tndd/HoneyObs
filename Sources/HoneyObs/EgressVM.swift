import Foundation
import Virtualization
import Darwin

// 通信VMもNIC・ディスク・共有ディレクトリを持たない。ゲストからの接続は
// 9000=固定origin、9001=固定POSTを一度だけ、9002=固定edge。
// 本人限定の検証時だけ9003=固定認証ホストの公開鍵TLSを追加する。
final class EgressVM: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    let resources: URL, directory: URL
    private let originPort: UInt16, originHost: String, permit: ForwardingPermit
    private let allowedMail: String?
    private let qaAccessKey: Data?
    private var qaInput: Pipe?
    private var qaKeySent = false, qaDeadline = 0.0
    private let onFailure: (String) -> Void
    private var machine: VZVirtualMachine?
    private var console: BoundedConsole?
    private var consoleClosing = false
    private var listeners: [UInt32: VZVirtioSocketListener] = [:]
    private var streams: [UUID: EgressStream] = [:]
    private var healthTimer: Timer?, stopTimer: Timer?
    private var healthPending = false, active = false, stopping = false, stopRequested = false, stopFailed = false
    private var provisioned = false, failed = false
    private var edgeAttempts: [Double] = []
    private var started = 0.0, stopStarted = 0.0
    private var startCallback: ((Result<Void, Error>) -> Void)?
    private var stopCallbacks: [(Bool) -> Void] = []
    private(set) var lastHealthAt = 0.0
    private(set) var status: [String: Any] = [:]
    var healthy: Bool { active && safetyTime() - lastHealthAt < 2 }
    var shutdownComplete: Bool { !active && machine == nil && console == nil && qaInput == nil && streams.isEmpty && listeners.isEmpty && !healthPending && !stopping && !stopFailed && testPendingCount == 0 }
    var canStart: Bool { shutdownComplete }
    var requiresSessionRecovery: Bool { stopFailed }
    private var acquiredURL = ""
    var publicURL: String {
        if acquiredURL.isEmpty, let value = console?.capturedValue { acquiredURL = value }
        return acquiredURL
    }
    private var testPendingCount: Int {
        #if EGRESS_TESTING
        return testPending.count
        #else
        return 0
        #endif
    }
    #if EGRESS_TESTING
    var testHandler: ((UInt32, VZVirtioSocketConnection, @escaping () -> Void) -> Void)?
    private var testPending: [UUID: VZVirtioSocketConnection] = [:]
    #endif

    init(resources: URL, directory: URL, originPort: UInt16, originHost: String, permit: ForwardingPermit, allowedMail: String? = nil, qaAccessKey: Data? = nil, onFailure: @escaping (String) -> Void) {
        self.resources = resources; self.directory = directory; self.originPort = originPort; self.originHost = originHost
        self.permit = permit; self.onFailure = onFailure
        self.allowedMail = allowedMail
        self.qaAccessKey = qaAccessKey
    }
    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        guard canStart, originPort != 0, permit.valid else { completion(.failure(error("通信VMを開始できません"))); return }
        guard allowedMail.map(EgressPolicy.validRecipient) ?? true else { completion(.failure(error("本人限定の認証先が不正です"))); return }
        guard qaAccessKey == nil || (qaAccessKey?.count == 32 && allowedMail == nil) else { completion(.failure(error("検証鍵の指定が不正です"))); return }
        active = true; acquiredURL = ""; failed = false; stopFailed = false; provisioned = false; edgeAttempts = []; lastHealthAt = 0; started = safetyTime(); startCallback = completion
        do {
            qaKeySent = false; qaDeadline = qaAccessKey == nil ? 0 : safetyTime() + 600
            if qaAccessKey != nil {
                qaInput = Pipe()
                let fd = qaInput!.fileHandleForWriting.fileDescriptor
                guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw error("検証鍵の入力を準備できません") }
            }
            let config = VZVirtualMachineConfiguration(); config.cpuCount = 1; config.memorySize = 256 * 1024 * 1024
            let boot = VZLinuxBootLoader(kernelURL: resources.appendingPathComponent("vmlinuz"))
            boot.initialRamdiskURL = resources.appendingPathComponent("egress-initramfs.gz")
            boot.commandLine = "console=hvc0 rdinit=/init panic=0 quiet honeyobs.host=\(originHost)"
            if let allowedMail { boot.commandLine += " honeyobs.allowedmail=" + Data(allowedMail.utf8).base64EncodedString() }
            if qaAccessKey != nil { boot.commandLine += " honeyobs.qaauth=1" }
            config.bootLoader = boot; config.networkDevices = []; config.storageDevices = []; config.directorySharingDevices = []
            config.socketDevices = [VZVirtioSocketDeviceConfiguration()]; config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let log = directory.appendingPathComponent("tunnel.log")
            console = try BoundedConsole(url: log, capturePattern:EgressPolicy.publicURLPattern,
                marker: qaAccessKey == nil ? nil : "HONEYOBS_QA_KEY_READY",
                onMarker: { [weak self] in self?.deliverQAKey() }) { [weak self] error in self?.fail("通信VMのログ保存失敗: " + error.localizedDescription) }
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: qaInput?.fileHandleForReading ?? FileHandle(forReadingAtPath: "/dev/null"), fileHandleForWriting: console!.writer)
            config.serialPorts = [serial]; try config.validate()
            let vm = VZVirtualMachine(configuration: config); machine = vm; vm.delegate = self
            guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { throw error("通信VMのvsockがありません") }
            let ports: [UInt32] = allowedMail == nil ? [9000, 9001, 9002] : [9000, 9001, 9002, 9003]
            for port in ports {
                let listener = VZVirtioSocketListener(); listener.delegate = self; listeners[port] = listener; device.setSocketListener(listener, forPort: port)
            }
            vm.start { [weak self] result in
                guard let self, self.machine === vm else { return }
                if self.stopping { self.advanceStop(); return }
                switch result {
                case .failure(let error): self.fail(error.localizedDescription)
                case .success:
                    let health = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkHealth() }
                    self.healthTimer = health; RunLoop.main.add(health, forMode: .common)
                    self.checkHealth()
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard active, !stopping, permit.valid, streams.count + testPendingCount < 12,
              let device = machine?.socketDevices.first as? VZVirtioSocketDevice, device === socketDevice,
              let port = listeners.first(where: { $0.value === listener })?.key else { return false }
        if port == 9001 { guard !provisioned else { return false }; provisioned = true }
        if port == 9002 || port == 9003 {
            let now = safetyTime(); edgeAttempts.removeAll { now - $0 >= 1 }
            guard edgeAttempts.count < 4 else { return false }; edgeAttempts.append(now)
        }
        #if EGRESS_TESTING
        if let handler = testHandler {
            let id = UUID(); testPending[id] = connection
            handler(port, connection) { [weak self] in
                DispatchQueue.main.async { self?.testPending.removeValue(forKey: id); self?.advanceStop() }
            }
            return true
        }
        #endif
        let id = UUID()
        let host = port == 9000 ? "127.0.0.1" : port == 9002 ? EgressPolicy.edgeAddress : EgressPolicy.provisioningAddress
        let targetPort: UInt16 = port == 9000 ? originPort : port == 9002 ? EgressPolicy.edgePort : 443
        let mode: EgressStream.Mode = port == 9000 ? .origin : port == 9001 ? .provision : port == 9002 ? .edge : .authKeys
        let stream = EgressStream(guest: connection, host: host, port: targetPort, mode: mode, permit: permit, protectedProvision: allowedMail != nil) { [weak self] in
            self?.streams.removeValue(forKey: id); self?.advanceStop()
        }
        streams[id] = stream; stream.start(); return true
    }
    private func deliverQAKey() {
        guard active, !stopping, !qaKeySent, permit.valid, let key = qaAccessKey, let input = qaInput else { return }
        let line = key.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + "\n"
        let data = Data(line.utf8)
        let written = data.withUnsafeBytes { Darwin.write(input.fileHandleForWriting.fileDescriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { fail("検証鍵の入力に失敗しました"); return }
        qaKeySent = true
    }
    private func checkHealth() {
        guard active, let vm = machine else { return }
        guard permit.valid else { fail("通信VMの転送許可が失効しました"); return }
        if qaAccessKey != nil {
            guard safetyTime() < qaDeadline else { fail("検証鍵の10分の期限に達しました"); return }
            if !qaKeySent {
                if safetyTime() - started > 5 { fail("検証鍵の受け渡し期限を超えました") }
                return
            }
        }
        if lastHealthAt > 0 && safetyTime() - lastHealthAt >= 2 { fail("通信VMの応答期限を超えました"); return }
        if lastHealthAt == 0 && safetyTime() - started > 30 { fail("通信VMの起動期限を超えました"); return }
        guard !healthPending else { return }; healthPending = true
        let nonce = UUID().uuidString
        guestRequest(vm, port: 7003, path: "/?nonce=" + nonce) { [weak self] result in
            guard let self else { return }; self.healthPending = false
            if self.stopping { self.advanceStop(); return }
            guard self.active, case .success(let data) = result,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["nonce"] as? String == nonce,
                  object["ready"] as? Bool == true,
                  let cloudflared = object["cloudflaredStatus"] as? String, let bridge = object["bridgeStatus"] as? String,
                  Self.validWorker(cloudflared, uid: 65533, seccomp: "2"), Self.validWorker(bridge, uid: 65534, seccomp: nil) else { return }
            self.status = object; self.lastHealthAt = safetyTime()
            if let callback = self.startCallback { self.startCallback = nil; callback(.success(())) }
        }
    }
    static func validWorker(_ status: String, uid: Int, seccomp: String?) -> Bool {
        var fields: [String: String] = [:]
        for line in status.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let ids = Array(repeating: String(uid), count: 4)
        return fields["Uid"]?.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init) == ids &&
            fields["Gid"]?.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init) == ids &&
            fields["CapEff"] == "0000000000000000" && fields["CapPrm"] == "0000000000000000" &&
            fields["CapAmb"] == "0000000000000000" && fields["NoNewPrivs"] == "1" &&
            !(fields["State"]?.hasPrefix("Z") ?? true) && (seccomp == nil || (fields["Seccomp"] == seccomp && fields["Name"] == "cloudflared"))
    }
    private func error(_ message: String) -> Error { NSError(domain: "HoneyObs.Egress", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func fail(_ message: String) {
        guard !failed else { return }; failed = true
        let callback = startCallback; startCallback = nil; callback?(.failure(error(message)))
        stop { _ in }; onFailure(message)
    }
    func stop(completion: @escaping (Bool) -> Void) {
        if shutdownComplete { completion(true); return }
        stopCallbacks.append(completion)
        guard !stopping else { return }; stopping = true; active = false; stopRequested = false; stopStarted = safetyTime()
        healthTimer?.invalidate(); healthTimer = nil
        try? qaInput?.fileHandleForWriting.close()
        let callback = startCallback; startCallback = nil; callback?(.failure(error("通信VMの開始を取り消しました")))
        if let device = machine?.socketDevices.first as? VZVirtioSocketDevice { for port in listeners.keys { device.removeSocketListener(forPort: port) } }
        listeners.removeAll()
        for stream in streams.values { stream.cancel() }
        #if EGRESS_TESTING
        for connection in testPending.values { Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR) }
        #endif
        let stoppingTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.advanceStop() }
        stopTimer = stoppingTimer; RunLoop.main.add(stoppingTimer, forMode: .common)
        advanceStop()
    }
    private func advanceStop() {
        guard stopping else { return }
        if let vm = machine {
            if vm.state == .stopped { machine = nil; closeConsole() }
            else if vm.canStop && !stopRequested {
                stopRequested = true
                vm.stop { [weak self] error in
                    guard let self, self.machine === vm else { return }
                    if let error { self.stopFailed = true; self.finishStop(false); self.onFailure("通信VMの停止失敗: " + error.localizedDescription) }
                    else { self.machine = nil; self.closeConsole(); self.advanceStop() }
                }
            }
        }
        if machine == nil {
            try? qaInput?.fileHandleForWriting.close(); try? qaInput?.fileHandleForReading.close(); qaInput = nil
            closeConsole()
        }
        if machine == nil && console == nil && streams.isEmpty && !healthPending && testPendingCount == 0 { finishStop(!stopFailed) }
        else if safetyTime() - stopStarted > 8 { stopFailed = true; finishStop(false) }
    }
    private func closeConsole() {
        guard let collector = console, !consoleClosing else { return }; consoleClosing = true
        collector.close { [weak self, weak collector] in
            guard let self, let collector, self.console === collector else { return }
            if self.acquiredURL.isEmpty { self.acquiredURL = collector.capturedValue ?? "" }
            self.console = nil; self.consoleClosing = false; self.advanceStop()
        }
    }
    private func finishStop(_ success: Bool) {
        guard stopping else { return }; stopping = false; stopTimer?.invalidate(); stopTimer = nil
        let callbacks = stopCallbacks; stopCallbacks = []; for callback in callbacks { callback(success) }
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { if active { fail("通信VM異常停止: " + error.localizedDescription) } else { advanceStop() } }
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { if active { fail("通信VMが停止しました") } else { advanceStop() } }
}
