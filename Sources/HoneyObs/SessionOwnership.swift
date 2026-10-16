import Foundation
import Darwin

private var sessionStop: sig_atomic_t = 0

private enum SessionSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func open() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        return fd
    }
    static func nonblocking(_ fd: Int32) { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    static func peer(_ fd: Int32) -> pid_t? {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
        return pid
    }
    static func drain(_ fd: Int32, into pending: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { return false }
        if count > 0 { pending.append(contentsOf: buffer.prefix(count)) }
        return pending.count <= 4096
    }
}

/// The VZ-owning GUI is the actual launchd job body. A separate CLI monitor
/// requests bootout on a terminal lease failure; ExitTimeOut hard-kills the VZ
/// owner itself, so recovery does not depend on cooperative child-group cleanup.
enum SessionOwnership {
    static func birth(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
    static func control(_ arguments: [String]) -> (Int32, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }
    private static func object(_ url: URL) -> [String: Any] {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    private static func valid(_ service: String) -> Bool {
        let prefix = "gui/\(getuid())/local.honeyobs.session."
        return service.hasPrefix(prefix) && UUID(uuidString: String(service.dropFirst(prefix.count))) != nil
    }
    private static func waitForDeath(_ service: String, pid: pid_t?, identity: String?, seconds: Double = 3) -> Bool {
        let end = safetyTime() + seconds
        repeat {
            let dead = pid == nil || identity == nil || birth(pid!) != identity
            if dead, control(["print", service]).0 != 0 { return true }
            usleep(50_000)
        } while safetyTime() < end
        return false
    }

    /// The original Launch Services app exits after the real UI and monitor
    /// have authenticated. The standalone helper has no NSApplication identity.
    static func handoff(_ arguments: [String]) -> Int32 {
        let helper = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/HoneyObsSession")
        let process = Process(); process.executableURL = helper; process.arguments = arguments
        let readiness = Pipe(); process.standardOutput = readiness; process.standardError = FileHandle.standardError
        do {
            try process.run()
            let fd = readiness.fileHandleForReading.fileDescriptor
            SessionSocket.nonblocking(fd)
            var data = Data(); let end = safetyTime() + 12
            while process.isRunning, safetyTime() < end {
                if !SessionSocket.drain(fd, into: &data) { break }
                if data.count >= 6 { return data == Data("READY\n".utf8) ? 0 : 1 }
                usleep(20_000)
            }
            if process.isRunning { process.terminate() }
            return 1
        } catch { fputs("セッション監視役を開始できません: \(error)\n", stderr); return 1 }
    }

    static func launch(_ arguments: [String], directory: URL, announceReady: Bool = false) -> Int32 {
        let files = FileManager.default
        var service = "", client: pid_t?, clientBirth: String?
        var registered = false, terminalReason = "startup-failure", socketDirectory: URL?
        var registryRecord: URL?
        defer {
            if registered { _ = control(["bootout", service]) }
            if let socketDirectory { try? files.removeItem(at: socketDirectory) }
        }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let testing = arguments.contains("--test-mode")
            let registry = testing ? directory.deletingLastPathComponent().appendingPathComponent(".session-registry") :
                files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HoneyObs/OSSession")
            try files.createDirectory(at: registry, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let lockFD = open(registry.appendingPathComponent("ownership.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw POSIXError(.EACCES) }
            defer { close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
            let record = registry.appendingPathComponent("active-session.json"); registryRecord = record
            let previous = object(record)
            if let oldService = previous["service"] as? String {
                guard valid(oldService), let oldDirectory = previous["directory"] as? String else { throw POSIXError(.EINVAL) }
                let old = object(URL(fileURLWithPath: oldDirectory).appendingPathComponent("owner.json"))
                let oldPID = ((previous["clientPID"] ?? old["clientPID"]) as? NSNumber)?.int32Value
                let oldBirth = (previous["clientBirth"] ?? old["clientBirth"]) as? String
                if control(["print", oldService]).0 == 0 { _ = control(["bootout", oldService]) }
                guard waitForDeath(oldService, pid: oldPID, identity: oldBirth) else {
                    throw NSError(domain: "前のOSセッションを回収できません。再開しません", code: 1)
                }
                try files.removeItem(at: record)
            }
            let label = "local.honeyobs.session." + UUID().uuidString.lowercased()
            service = "gui/\(getuid())/" + label
            guard let launcherBirth = birth(getpid()) else { throw POSIXError(.ESRCH) }
            let temporary = URL(fileURLWithPath: "/private/tmp/HoneyObs-" + UUID().uuidString)
            try files.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); socketDirectory = temporary
            let path = temporary.appendingPathComponent("lease.sock").path, token = UUID().uuidString
            let listener = try SessionSocket.open(); defer { close(listener) }
            var address = try SessionSocket.address(path)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EIO) }
            SessionSocket.nonblocking(listener)
            var jobArguments = [arguments[0], "--session-client", label, path, token, String(getpid()), launcherBirth] + Array(arguments.dropFirst())
            if !jobArguments.contains("--run-directory") { jobArguments += ["--run-directory", directory.path] }
            var plist: [String: Any] = ["Label": label, "ProgramArguments": jobArguments,
                "RunAtLoad": true, "KeepAlive": false, "AbandonProcessGroup": false, "ExitTimeOut": 1,
                "ProcessType": "Interactive", "Umask": 0o077, "WorkingDirectory": directory.path,
                "StandardOutPath": directory.appendingPathComponent("client.log").path,
                "StandardErrorPath": directory.appendingPathComponent("client.log").path]
            if testing, let probes = ProcessInfo.processInfo.environment["HONEYOBS_PROBE_TARGETS"] { plist["EnvironmentVariables"] = ["HONEYOBS_PROBE_TARGETS": probes] }
            let plistURL = directory.appendingPathComponent("session-job.plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL, options: .atomic)
            let ownership: [String: Any] = ["service": service, "directory": directory.path, "launcherPID": getpid()]
            let encoded = try JSONSerialization.data(withJSONObject: ownership)
            try encoded.write(to: record, options: .atomic); try encoded.write(to: directory.appendingPathComponent("os-session.json"), options: .atomic)
            guard control(["bootstrap", "gui/\(getuid())", plistURL.path]).0 == 0 else { throw POSIXError(.EIO) }
            registered = true
            signal(SIGTERM) { _ in sessionStop = 1 }; signal(SIGINT) { _ in sessionStop = 1 }; signal(SIGPIPE, SIG_IGN)
            var fd: Int32 = -1, pending = Data(), nextCheck = 0.0
            let startupEnd = safetyTime() + 10
            while fd < 0, safetyTime() < startupEnd, sessionStop == 0 {
                fd = accept(listener, nil, nil)
                if fd < 0 { usleep(20_000); continue }
                guard let peer = SessionSocket.peer(fd), let identity = birth(peer) else { close(fd); throw POSIXError(.EPERM) }
                let job = control(["print", service])
                guard job.0 == 0, job.1.range(of: "(?m)^\\s*pid = \(peer)$", options: .regularExpression) != nil,
                      birth(peer) == identity else { close(fd); throw POSIXError(.EPERM) }
                client = peer; clientBirth = identity
                var authenticatedOwnership = ownership
                authenticatedOwnership["clientPID"] = peer; authenticatedOwnership["clientBirth"] = identity
                try JSONSerialization.data(withJSONObject: authenticatedOwnership).write(to: record, options: .atomic)
            }
            guard fd >= 0 else { throw POSIXError(.ETIMEDOUT) }
            defer { close(fd) }; SessionSocket.nonblocking(fd)
            var sequence: UInt64 = 0, deadline = safetyTime() + 3, handshaken = false, stoppingAt = 0.0
            while true {
                if sessionStop != 0, stoppingAt == 0 { stoppingAt = safetyTime(); _ = control(["kill", "SIGTERM", service]) }
                if stoppingAt > 0, safetyTime() - stoppingAt >= 8 { terminalReason = "stop-timeout"; break }
                guard safetyTime() < deadline else { terminalReason = "lease-expired"; break }
                guard SessionSocket.drain(fd, into: &pending) else { terminalReason = "client-eof"; break }
                if !handshaken, pending.count >= token.utf8.count {
                    guard pending.prefix(token.utf8.count) == Data(token.utf8) else { terminalReason = "invalid-token"; break }
                    pending.removeFirst(token.utf8.count); handshaken = true
                    if announceReady { try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8)) }
                }
                var invalid = false
                while handshaken, pending.count >= 16 {
                    let frame = Data(pending.prefix(16)); pending.removeFirst(16)
                    let next = frame.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                    let expiry = frame.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
                    let now = safetyTime(), expires = Double(expiry) / 1_000_000_000
                    guard next > sequence, expires > now, expires <= now + 3.01 else { invalid = true; break }
                    sequence = next; deadline = expires
                    if frame.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) != 16 { invalid = true; break }
                }
                if invalid { terminalReason = "invalid-lease"; break }
                if safetyTime() >= nextCheck {
                    nextCheck = safetyTime() + 1
                    if birth(client!) != clientBirth { terminalReason = "client-death"; break }
                }
                usleep(20_000)
            }
            _ = control(["bootout", service])
            guard waitForDeath(service, pid: client, identity: clientBirth) else { throw POSIXError(.ETIMEDOUT) }
            registered = false
            let state = object(directory.appendingPathComponent("state.json"))
            let status: Int32 = (state["shutdownComplete"] as? Bool == true) ? 0 : 1
            try JSONSerialization.data(withJSONObject: ["reason": terminalReason, "status": status, "osOwnerGone": true])
                .write(to: directory.appendingPathComponent("session-result.json"), options: .atomic)
            try files.removeItem(at: record)
            return status
        } catch {
            if registered {
                _ = control(["bootout", service])
                if waitForDeath(service, pid: client, identity: clientBirth) { registered = false; if let registryRecord { try? files.removeItem(at: registryRecord) } }
            }
            fputs("OSセッション失敗: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

final class SessionClient {
    var requiresRecovery: () -> Bool = { false }
    private let service: String, fd: Int32
    private var timer: Timer?
    private var sequence: UInt64 = 0, acknowledged: UInt64 = 0
    private var issued: [UInt64: UInt64] = [:]
    private var pending = Data(), deadline = safetyTime() + 3
    private var revoked = false
    init(arguments: [String], directory: URL) throws {
        guard let owned = arguments.firstIndex(of: "--session-client"), owned + 5 < arguments.count,
              getppid() == 1, getpgrp() == getpid(), let launcher = pid_t(arguments[owned + 4]) else { throw POSIXError(.EPERM) }
        let label = arguments[owned + 1], path = arguments[owned + 2], token = arguments[owned + 3], identity = arguments[owned + 5]
        service = "gui/\(getuid())/" + label
        let socket = try SessionSocket.open()
        var address = try SessionSocket.address(path)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0, SessionSocket.peer(socket) == launcher, SessionOwnership.birth(launcher) == identity else { close(socket); throw POSIXError(.EPERM) }
        fd = socket
        let nonce = Data(token.utf8)
        guard nonce.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == nonce.count else { close(fd); throw POSIXError(.EPIPE) }
        SessionSocket.nonblocking(fd)
        if let data = try? JSONSerialization.data(withJSONObject: ["label": label, "ownerPID": launcher, "ownerPGID": getpgid(launcher),
            "clientPID": getpid(), "clientPGID": getpgrp(), "clientBirth": SessionOwnership.birth(getpid()) ?? "", "jobBodyIsVZOwner": true]) {
            try? data.write(to: directory.appendingPathComponent("owner.json"), options: .atomic)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    deinit { timer?.invalidate(); close(fd) }
    private func revoke() {
        guard !revoked else { return }; revoked = true; timer?.invalidate(); timer = nil
        _ = SessionOwnership.control(["bootout", service])
    }
    private func tick() {
        guard !revoked else { return }
        guard !requiresRecovery(), safetyTime() < deadline, SessionSocket.drain(fd, into: &pending) else { revoke(); return }
        while pending.count >= 16 {
            let frame = Data(pending.prefix(16)); pending.removeFirst(16)
            let next = frame.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let expiry = frame.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
            let now = safetyTime(), expires = Double(expiry) / 1_000_000_000
            guard next > acknowledged, issued[next] == expiry, expires > now, expires <= now + 3.01 else { revoke(); return }
            acknowledged = next; deadline = expires; issued = issued.filter { $0.key > next }
        }
        guard issued.count < 32 else { revoke(); return }
        sequence += 1
        var next = sequence, expiry = UInt64((safetyTime() + 3) * 1_000_000_000)
        issued[next] = expiry
        var frame = withUnsafeBytes(of: &next) { Data($0) }; frame.append(withUnsafeBytes(of: &expiry) { Data($0) })
        if frame.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) != 16 { revoke() }
    }
}
