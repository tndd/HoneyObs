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

// GUIと監視役は別々の一時launchdジョブ本体。相手の本体消滅を確認してから自分を回収する。
// 同一ユーザーがこのアプリや0700の記録を書き換えた場合は信頼境界の外とする。
enum SessionOwnership {
    static func birth(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
    static func control(_ arguments: [String]) -> (Int32, String) {
        controlCommand("/bin/launchctl", arguments: arguments)
    }

    // launchctlにも生存期限を設ける。FDは継承対象だけを明示し、新しいPGIDを作らない。
    private static func controlCommand(_ executable: String, arguments: [String], limit: Double = 2,
                                       outputLimit: Int = 65_536) -> (Int32, String) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { return (-1, "制御CLIのpipeを作成できません") }
        let reader = descriptors[0], writer = descriptors[1]
        defer { close(reader) }
        guard descriptors.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else {
            close(writer); return (-1, "制御CLIのFD継承制限に失敗")
        }
        let flags = fcntl(reader, F_GETFL)
        guard flags >= 0, fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(writer); return (-1, "制御CLIを非同期読取りへ設定できません")
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { close(writer); return (-1, "制御CLIのFD設定に失敗") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { close(writer); return (-1, "制御CLIの起動属性に失敗") }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for value in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, value) }
        let settings = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO),
            posix_spawnattr_setsigdefault(&attributes, &defaults), posix_spawnattr_setsigmask(&attributes, &mask),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))]
        guard settings.allSatisfy({ $0 == 0 }) else { close(writer); return (-1, "制御CLIの起動設定に失敗") }
        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var argvPointers = argv + [nil], environmentPointers = envp + [nil], pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, &argvPointers, &environmentPointers)
        close(writer)
        guard spawned == 0 else { return (-1, "制御CLIを起動できません: \(spawned)") }
        var output = Data(), status: Int32 = 0
        let deadline = safetyTime() + limit
        func drain() -> Bool {
            var bytes = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 {
                let count = Darwin.read(reader, &bytes, bytes.count)
                if count <= 0 { return count == 0 || errno == EAGAIN || errno == EINTR }
                guard output.count + count <= outputLimit else { return false }
                output.append(contentsOf: bytes.prefix(count))
            }
            return true
        }
        func textOutput() -> String { String(decoding: output, as: UTF8.self) }
        func abort(_ reason: String) -> (Int32, String) {
            // この関数以外は子をreapしない。未reapならPIDは再利用されない。
            // ECHILDでは所有を推測してkillしない。
            var waited = waitpid(pid, &status, WNOHANG)
            while waited < 0 && errno == EINTR { waited = waitpid(pid, &status, WNOHANG) }
            guard waited == 0 || waited == pid else { return (-1, reason + "・子の終了所有を確認できません") }
            if waited == 0 {
                _ = Darwin.kill(pid, SIGKILL)
                let reapDeadline = safetyTime() + 0.5
                repeat {
                    waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid { break }
                    if waited < 0 && errno != EINTR { break }
                    usleep(5_000)
                } while safetyTime() < reapDeadline
                if waited != pid {
                    // OS自体の終了停滞も成功に変換しない。後のreapはPIDを殺さない。
                    if waited == 0 {
                        DispatchQueue.global(qos: .utility).async {
                            var childStatus: Int32 = 0
                            while waitpid(pid, &childStatus, 0) < 0 && errno == EINTR {}
                        }
                    }
                    return (-1, reason + "・SIGKILL後のwaitは未確認")
                }
            }
            return (-1, reason + "・子をreap済み\n" + textOutput())
        }
        while true {
            guard drain() else { return abort("制御CLIの出力上限") }
            if safetyTime() >= deadline { return abort("制御CLIの期限超過") }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                guard drain() else { return (-1, "制御CLIの出力上限・子をreap済み") }
                let exitStatus = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                return (exitStatus, textOutput())
            }
            if waited < 0, errno != EINTR { return (-1, "制御CLIの終了所有を確認できません") }
            usleep(5_000)
        }
    }
    #if SESSION_CONTROL_TESTING
    static func testingControl(_ executable: String, arguments: [String]) -> (Int32, String) {
        controlCommand(executable, arguments: arguments)
    }
    #endif
    static func object(_ url: URL) -> [String: Any] {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    static func save(_ value: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
    static func valid(_ service: String) -> Bool {
        for kind in ["session", "monitor"] {
            let prefix = "gui/\(getuid())/local.honeyobs.\(kind)."
            if service.hasPrefix(prefix), UUID(uuidString: String(service.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }
    static func jobPID(_ service: String) -> pid_t? {
        let result = control(["print", service]); guard result.0 == 0 else { return nil }
        for line in result.1.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if parts.count == 3, parts[0] == "pid", parts[1] == "=", let pid = pid_t(parts[2]), pid > 1 { return pid }
        }
        return nil
    }
    static func waitForDeath(_ service: String, pid: pid_t?, identity: String?, seconds: Double = 4) -> Bool {
        // PID未取得を死亡確認へ変換しない。job不在と本体identity消滅を別々に確認する。
        guard let pid, let identity, !identity.isEmpty else { return false }
        let end = safetyTime() + seconds
        repeat {
            if birth(pid) != identity, control(["print", service]).0 == 113 { return true }
            usleep(50_000)
        } while safetyTime() < end
        return false
    }
    static func registry(_ arguments: [String], directory: URL) -> URL {
        arguments.contains("--test-mode") ? directory.appendingPathComponent(".session-registry") :
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HoneyObs/OSSession")
    }
    static func removeSocketDirectory(_ directory: URL) {
        guard directory.deletingLastPathComponent().path == "/private/tmp", directory.lastPathComponent.hasPrefix("HoneyObs-"),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst("HoneyObs-".count))) != nil else { return }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { return }
        try? FileManager.default.removeItem(at: directory)
    }
    static func removeRegistry(_ record: URL, monitor: String) {
        if object(record)["ownerService"] as? String == monitor { try? FileManager.default.removeItem(at: record) }
    }
    static func bootoutSelf(_ service: String, status: Int32) -> Never {
        _ = control(["bootout", service]); exit(status)
    }
    static func handoff(_ arguments: [String], directory: URL) -> Int32 { launch(arguments, directory: directory) }
    static func launch(_ arguments: [String], directory: URL) -> Int32 {
        let files = FileManager.default, testing = arguments.contains("--test-mode")
        let sessionID = UUID().uuidString.lowercased(), token = UUID().uuidString
        let ownerService = "gui/\(getuid())/local.honeyobs.monitor." + sessionID
        let clientService = "gui/\(getuid())/local.honeyobs.session." + sessionID
        let temporary = URL(fileURLWithPath: "/private/tmp/HoneyObs-" + UUID().uuidString)
        var ownerPID: pid_t?, ownerBirth: String?, ready = false
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let helper = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/HoneyObsSession")
            guard let launcherBirth = birth(getpid()), files.isExecutableFile(atPath: helper.path) else { throw POSIXError(.ENOENT) }
            let program = [helper.path, "--monitor-job", ownerService, clientService, directory.path, temporary.path, token,
                           String(getpid()), launcherBirth] + arguments
            var plist = job(label: String(ownerService.split(separator: "/").last!), arguments: program, directory: directory, log: "owner.log")
            if testing, let probes = ProcessInfo.processInfo.environment["HONEYOBS_PROBE_TARGETS"] { plist["EnvironmentVariables"] = ["HONEYOBS_PROBE_TARGETS": probes] }
            let plistURL = directory.appendingPathComponent("monitor-job.plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL, options: .atomic)
            try save(["ownerService": ownerService, "clientService": clientService, "socketDirectory": temporary.path], directory.appendingPathComponent("bootstrap.json"))
            try save(["token": token, "expires": safetyTime() + 2], temporary.appendingPathComponent("launcher-lease.json"))
            guard control(["bootstrap", "gui/\(getuid())", plistURL.path]).0 == 0 else { throw POSIXError(.EIO) }
            signal(SIGTERM) { _ in sessionStop = 1 }; signal(SIGINT) { _ in sessionStop = 1 }
            let end = safetyTime() + 15
            while safetyTime() < end, sessionStop == 0 {
                if ownerPID == nil, let pid = jobPID(ownerService), let identity = birth(pid) { ownerPID = pid; ownerBirth = identity }
                let value = object(directory.appendingPathComponent("ui-ready.json"))
                if value["token"] as? String == token, let pid = value["clientPID"] as? Int32, let identity = value["clientBirth"] as? String {
                    if jobPID(clientService) == pid, birth(pid) == identity, ownerPID != nil, birth(ownerPID!) == ownerBirth { ready = true; break }
                    // 起動直後の通常終了も、既に書いた認証済みreadyと回収receiptで確認する。
                    if object(directory.appendingPathComponent("session-result.json"))["status"] as? Int32 == 0,
                       birth(pid) != identity, control(["print", clientService]).0 == 113, control(["print", ownerService]).0 == 113 { return 0 }
                }
                try save(["token": token, "expires": safetyTime() + 2], temporary.appendingPathComponent("launcher-lease.json"))
                if ownerPID != nil, birth(ownerPID!) != ownerBirth { break }
                usleep(50_000)
            }
            guard ready else { throw POSIXError(.ETIMEDOUT) }
            try save(["ready": true], directory.appendingPathComponent("launcher-ready.json"))
            if !testing { return 0 }
            // CLI検証だけのobserver。製品の安全な所有はこのwrapperの寿命に依存しない。
            var stopping = false, stopAt = 0.0
            while birth(ownerPID!) == ownerBirth {
                if sessionStop != 0, !stopping { stopping = true; stopAt = safetyTime(); _ = control(["kill", "SIGTERM", clientService]) }
                if stopping, safetyTime() - stopAt > 10 { throw POSIXError(.ETIMEDOUT) }
                usleep(50_000)
            }
            let receipt = object(directory.appendingPathComponent("session-result.json"))
            return receipt["status"] as? Int32 ?? 1
        } catch {
            let clientRecord = object(directory.appendingPathComponent("owner.json"))
            let clientPID = (clientRecord["clientPID"] as? Int32) ?? jobPID(clientService)
            let clientBirth = (clientRecord["clientBirth"] as? String) ?? clientPID.flatMap(birth)
            _ = control(["bootout", clientService]); _ = control(["bootout", ownerService])
            let clientGone = waitForDeath(clientService, pid: clientPID, identity: clientBirth)
            let ownerGone = waitForDeath(ownerService, pid: ownerPID, identity: ownerBirth)
            if clientGone && ownerGone { removeSocketDirectory(temporary) }
            fputs("セッション起動・回収失敗（回収確認: \(clientGone && ownerGone)）: \(error)\n", stderr)
            return 1
        }
    }
    private static func job(label: String, arguments: [String], directory: URL, log: String) -> [String: Any] {
        let output = arguments.contains("--test-mode") ? directory.appendingPathComponent(log).path : "/dev/null"
        return ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true, "KeepAlive": false, "ExitTimeOut": 1,
         "AbandonProcessGroup": false, "ProcessType": "Interactive", "Umask": 0o077, "WorkingDirectory": directory.path,
         "StandardOutPath": output, "StandardErrorPath": output]
    }
    static func monitor(_ arguments: [String]) -> Never {
        guard arguments.count > 9, arguments[1] == "--monitor-job", getppid() == 1, getpgrp() == getpid(),
              valid(arguments[2]), valid(arguments[3]), let launcher = pid_t(arguments[7]) else { exit(2) }
        let ownerService = arguments[2], clientService = arguments[3], directory = URL(fileURLWithPath: arguments[4])
        let temporary = URL(fileURLWithPath: arguments[5]), token = arguments[6], launcherBirth = arguments[8]
        let original = Array(arguments.dropFirst(9)), record = registry(original, directory: directory).appendingPathComponent("active-session.json")
        var client: pid_t?, clientBirth: String?, reason = "startup-failure", status: Int32 = 1, cleanExit = false, attemptedClientBootstrap = false
        do {
            let files = FileManager.default
            try files.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let lockFD = open(record.deletingLastPathComponent().appendingPathComponent("ownership.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw POSIXError(.EACCES) }
            defer { close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
            let previous = object(record)
            guard previous.isEmpty || (previous["ownerService"] is String && previous["clientService"] is String) else { throw POSIXError(.EINVAL) }
            if let oldOwner = previous["ownerService"] as? String, let oldClient = previous["clientService"] as? String {
                guard valid(oldOwner), valid(oldClient), let oldDirectory = previous["directory"] as? String else { throw POSIXError(.EINVAL) }
                let old = object(URL(fileURLWithPath: oldDirectory).appendingPathComponent("owner.json"))
                let oldOwnerPID = old["ownerPID"] as? Int32, oldClientPID = old["clientPID"] as? Int32
                let oldOwnerBirth = old["ownerBirth"] as? String, oldClientBirth = old["clientBirth"] as? String
                _ = control(["bootout", oldClient]); _ = control(["bootout", oldOwner])
                guard waitForDeath(oldClient, pid: oldClientPID, identity: oldClientBirth),
                      waitForDeath(oldOwner, pid: oldOwnerPID, identity: oldOwnerBirth) else { throw POSIXError(.EBUSY) }
                if let path = previous["socketDirectory"] as? String { removeSocketDirectory(URL(fileURLWithPath: path)) }
                try files.removeItem(at: record)
            }
            let path = temporary.appendingPathComponent("lease.sock").path
            let listener = try SessionSocket.open(); defer { close(listener) }
            var address = try SessionSocket.address(path)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EIO) }
            SessionSocket.nonblocking(listener)
            guard let identity = birth(getpid()) else { throw POSIXError(.ESRCH) }
            try save(["ownerService": ownerService, "clientService": clientService, "directory": directory.path,
                      "socketDirectory": temporary.path], record)
            var clientArguments = [original[0], "--session-client", clientService, ownerService, path, token, String(getpid()), identity] + Array(original.dropFirst())
            if !clientArguments.contains("--run-directory") { clientArguments += ["--run-directory", directory.path] }
            var plist = job(label: String(clientService.split(separator: "/").last!), arguments: clientArguments, directory: directory, log: "client.log")
            if original.contains("--test-mode"), let probes = ProcessInfo.processInfo.environment["HONEYOBS_PROBE_TARGETS"] { plist["EnvironmentVariables"] = ["HONEYOBS_PROBE_TARGETS": probes] }
            let plistURL = directory.appendingPathComponent("session-job.plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL, options: .atomic)
            try save(object(record), directory.appendingPathComponent("os-session.json"))
            attemptedClientBootstrap = true
            guard control(["bootstrap", "gui/\(getuid())", plistURL.path]).0 == 0 else { throw POSIXError(.EIO) }
            signal(SIGTERM) { _ in sessionStop = 1 }; signal(SIGINT) { _ in sessionStop = 1 }
            var fd: Int32 = -1
            let startup = safetyTime() + 10
            while fd < 0, safetyTime() < startup, sessionStop == 0 {
                guard birth(launcher) == launcherBirth else { throw POSIXError(.ESRCH) }
                if client == nil, let pid = jobPID(clientService), let birth = birth(pid) { client = pid; clientBirth = birth }
                fd = accept(listener, nil, nil)
                if fd < 0 { usleep(20_000) }
            }
            guard fd >= 0 else { throw POSIXError(.ETIMEDOUT) }
            defer { close(fd) }; _ = fcntl(fd, F_SETFD, FD_CLOEXEC); SessionSocket.nonblocking(fd)
            guard let peer = SessionSocket.peer(fd), jobPID(clientService) == peer, let peerBirth = birth(peer) else { throw POSIXError(.EPERM) }
            client = peer; clientBirth = peerBirth
            var pending = Data(), sequence: UInt64 = 0, deadline = safetyTime() + 3, handshaken = false, uiReady = false
            monitorLoop: while true {
                if sessionStop != 0 { reason = "monitor-termination"; break }
                if !uiReady {
                    let lease = object(temporary.appendingPathComponent("launcher-lease.json"))
                    guard birth(launcher) == launcherBirth, lease["token"] as? String == token,
                          let expires = lease["expires"] as? Double, expires > safetyTime(), expires <= safetyTime() + 2.1 else { reason = "launcher-startup-expired"; break }
                }
                guard safetyTime() < deadline, SessionSocket.drain(fd, into: &pending) else { reason = "client-lease-ended"; break }
                if !handshaken, pending.count >= token.utf8.count {
                    guard pending.prefix(token.utf8.count) == Data(token.utf8) else { reason = "invalid-token"; break }
                    pending.removeFirst(token.utf8.count); handshaken = true
                }
                var invalid = false
                while handshaken, pending.count >= 16 {
                    let frame = Data(pending.prefix(16)); pending.removeFirst(16)
                    let next = frame.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                    let expiry = frame.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
                    if next == 0 && expiry == 1 {
                        guard uiReady else { invalid = true; break }
                        cleanExit = true; reason = "client-normal-exit"; break monitorLoop
                    }
                    if next == 0 && expiry == 0 {
                        guard !uiReady else { invalid = true; break }; uiReady = true
                        let receipt: [String: Any] = ["token": token, "clientPID": peer, "clientBirth": peerBirth]
                        try save(receipt, temporary.appendingPathComponent("ready.json"))
                        try save(receipt, directory.appendingPathComponent("ui-ready.json")); continue
                    }
                    let now = safetyTime(), expires = Double(expiry) / 1_000_000_000
                    guard next > sequence, expires > now, expires <= now + 3.01 else {
                        if original.contains("--test-mode") {
                            try? save(["next":next,"previous":sequence,"expires":expires,"safetyNow":now,"uiReady":uiReady], directory.appendingPathComponent("invalid-lease.json"))
                        }
                        invalid = true; break
                    }
                    sequence = next; deadline = expires
                    if frame.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) != 16 { invalid = true; break }
                }
                if invalid { reason = "invalid-lease"; break }
                usleep(20_000)
            }
        } catch { fputs("OS監視失敗: \(error)\n", stderr) }
        // 相互bootoutが重なると双方がdeath待ち中にOS回収される。再接続口は先に閉じる。
        // unlink自体をプロセス・VMの回収証明には使わない。
        removeSocketDirectory(temporary)
        if client == nil, let pid = jobPID(clientService), let identity = birth(pid) { client = pid; clientBirth = identity }
        _ = control(["bootout", clientService])
        let gone = !attemptedClientBootstrap || waitForDeath(clientService, pid: client, identity: clientBirth)
        if gone {
            status = cleanExit && object(directory.appendingPathComponent("state.json"))["shutdownComplete"] as? Bool == true ? 0 : 1
            removeRegistry(record, monitor: ownerService); removeSocketDirectory(temporary)
        }
        try? save(["reason": reason, "status": status, "osOwnerGone": gone], directory.appendingPathComponent("session-result.json"))
        bootoutSelf(ownerService, status: status)
    }
}

final class SessionClient {
    var requiresRecovery: () -> Bool = { false }
    var onRevoke: () -> Void = {}
    private let service: String, monitorService: String, fd: Int32, monitorPID: pid_t, monitorBirth: String
    private let temporary: URL, record: URL, directory: URL
    private var timer: Timer?, sequence: UInt64 = 0, acknowledged: UInt64 = 0
    private var issued: [UInt64: UInt64] = [:], pending = Data(), deadline = safetyTime() + 3
    private var revoked = false, ready = false, finished = false
    init(arguments: [String], directory: URL) throws {
        guard let index = arguments.firstIndex(of: "--session-client"), index + 6 < arguments.count,
              getppid() == 1, getpgrp() == getpid(), let launcher = pid_t(arguments[index + 5]) else { throw POSIXError(.EPERM) }
        service = arguments[index + 1]; monitorService = arguments[index + 2]
        guard SessionOwnership.valid(service), SessionOwnership.valid(monitorService) else { throw POSIXError(.EPERM) }
        let path = arguments[index + 3], token = arguments[index + 4]
        monitorPID = launcher; monitorBirth = arguments[index + 6]; self.directory = directory
        temporary = URL(fileURLWithPath: path).deletingLastPathComponent()
        record = SessionOwnership.registry(arguments, directory: directory).appendingPathComponent("active-session.json")
        let socket = try SessionSocket.open(); var address = try SessionSocket.address(path)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0, SessionSocket.peer(socket) == launcher, SessionOwnership.birth(launcher) == monitorBirth,
              SessionOwnership.jobPID(monitorService) == launcher, SessionOwnership.jobPID(service) == getpid() else { close(socket); throw POSIXError(.EPERM) }
        fd = socket
        let nonce = Data(token.utf8)
        guard nonce.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == nonce.count else { close(fd); throw POSIXError(.EPIPE) }
        SessionSocket.nonblocking(fd)
        try SessionOwnership.save(["label": String(service.split(separator: "/").last!), "ownerService": monitorService, "clientService": service,
            "ownerPID": launcher, "ownerBirth": monitorBirth, "clientPID": getpid(), "clientBirth": SessionOwnership.birth(getpid()) ?? "",
            "ownerPGID": getpgid(launcher), "clientPGID": getpgrp(), "jobBodyIsVZOwner": true, "socketDirectory": temporary.path], directory.appendingPathComponent("owner.json"))
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }; tick()
    }
    deinit { timer?.invalidate(); close(fd) }
    func markUIReady() {
        guard !ready, !revoked else { return }; ready = true
        let frame = Data(repeating: 0, count: 16)
        if frame.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) != 16 { revoke() }
    }
    func finish() {
        guard ready, !revoked, !finished else { return }; finished = true
        timer?.invalidate(); timer = nil
        var control: UInt64 = 0, cleanExit: UInt64 = 1
        var frame = withUnsafeBytes(of: &control) { Data($0) }; frame.append(withUnsafeBytes(of: &cleanExit) { Data($0) })
        _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    private func revoke() {
        guard !revoked else { return }; revoked = true; timer?.invalidate(); timer = nil
        SessionOwnership.removeSocketDirectory(temporary)
        onRevoke()
        _ = SessionOwnership.control(["bootout", monitorService])
        let gone = SessionOwnership.waitForDeath(monitorService, pid: monitorPID, identity: monitorBirth)
        if gone { SessionOwnership.removeRegistry(record, monitor: monitorService); SessionOwnership.removeSocketDirectory(temporary) }
        try? SessionOwnership.save(["reason": "monitor-lease-ended", "status": 1, "monitorGone": gone], directory.appendingPathComponent("session-result.json"))
        SessionOwnership.bootoutSelf(service, status: 1)
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
        guard issued.count < 32 else { revoke(); return }; sequence += 1
        var next = sequence, expiry = UInt64((safetyTime() + 3) * 1_000_000_000); issued[next] = expiry
        var frame = withUnsafeBytes(of: &next) { Data($0) }; frame.append(withUnsafeBytes(of: &expiry) { Data($0) })
        if frame.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) != 16 { revoke() }
    }
}
