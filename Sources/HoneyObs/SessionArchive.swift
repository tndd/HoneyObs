import Foundation
import Darwin

// この版が作成した保存先だけを管理する。生存プロセスが保持するflockは削除しない。
final class SessionArchive {
    struct Policy {
        var maxSessions = 30
        var maxBytes: Int64 = 256 * 1024 * 1024
        var reservationBytes: Int64 = 8 * 1024 * 1024
        var maxAge: TimeInterval = 7 * 24 * 3600
        var interruptionGrace: TimeInterval = 600
    }
    struct Marker: Codable {
        var schema = 1
        var created: Date
        var closed = false
        var interruptedAt: Date?
    }
    private var fd: Int32 = -1
    let directory: URL
    private var marker: Marker
    private static let markerName = "session-owner.json"
    private static func failure(_ text: String) -> Error {
        NSError(domain:"HoneyObs.SessionArchive",code:1,userInfo:[NSLocalizedDescriptionKey:text])
    }
    static func makeDirectory(root: URL, policy: Policy = Policy(), now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard try isPrivateDirectory(root) else { throw failure("保存先の所有者または権限が不正です") }
        let lock = Darwin.open(root.appendingPathComponent(".retention.lock").path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard lock >= 0 else { throw failure("保存先の排他を開始できません") }
        defer { Darwin.close(lock) }
        guard flock(lock,LOCK_EX|LOCK_NB) == 0 else { throw failure("別の起動処理が保存先を利用中です") }
        var items: [(URL,Marker,Int64,Bool)] = []
        var probes: [Int32] = []
        defer { for probe in probes { Darwin.close(probe) } }
        for url in try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) {
            guard (try? isPrivateDirectory(url)) == true,
                  let data = try? Data(contentsOf:url.appendingPathComponent(markerName)),
                  var marker = try? JSONDecoder().decode(Marker.self,from:data), marker.schema == 1 else { continue }
            // UIの保存workerと、終了結果を保存するmonitorの両方が退出するまで削除しない。
            let recovery = Darwin.open(url.appendingPathComponent(".recovery.lock").path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
            var deletable = false
            if recovery >= 0 {
                probes.append(recovery)
                if flock(recovery,LOCK_EX|LOCK_NB) == 0 {
                    let probe = Darwin.open(url.appendingPathComponent(".session.lock").path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
                    if probe >= 0 {
                        probes.append(probe)
                        if flock(probe,LOCK_EX|LOCK_NB) == 0 {
                            if !marker.closed, marker.interruptedAt == nil {
                                marker.interruptedAt = now; try write(marker,to:url)
                            }
                            deletable = marker.closed || marker.interruptedAt.map { now.timeIntervalSince($0) >= policy.interruptionGrace } == true
                        }
                    }
                }
            }
            items.append((url,marker,try size(url),deletable))
        }
        items.sort { $0.1.created < $1.1.created }
        var count = items.count, bytes = items.reduce(Int64(0)) { $0 + $1.2 }
        for (url,marker,length,deletable) in items where deletable {
            if count >= policy.maxSessions || bytes + policy.reservationBytes > policy.maxBytes || now.timeIntervalSince(marker.created) >= policy.maxAge {
                try fm.removeItem(at:url); count -= 1; bytes -= length
            }
        }
        guard count < policy.maxSessions, bytes + policy.reservationBytes <= policy.maxBytes else { throw failure("保存上限に達しています。利用中の記録を保護するため開始できません") }
        let directory = root.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do { try write(Marker(created:now),to:directory) }
        catch { try? fm.removeItem(at:directory); throw error }
        return directory
    }
    init(directory: URL) throws {
        self.directory = directory
        guard try Self.isPrivateDirectory(directory),
              let value = try? JSONDecoder().decode(Marker.self,from:Data(contentsOf:directory.appendingPathComponent(Self.markerName))),
              value.schema == 1 else { throw Self.failure("管理対象の保存先ではありません") }
        marker = value
        fd = Darwin.open(directory.appendingPathComponent(".session.lock").path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0, flock(fd,LOCK_EX|LOCK_NB) == 0 else {
            if fd >= 0 { Darwin.close(fd); fd = -1 }; throw Self.failure("記録は別のアプリで利用中です")
        }
        // 初回pruneと起動が近接していても、実際に開いたセッションを中断済みのままにしない。
        do {
            marker = try JSONDecoder().decode(Marker.self,from:Data(contentsOf:directory.appendingPathComponent(Self.markerName)))
            guard marker.schema == 1 else { throw Self.failure("管理対象の保存先ではありません") }
            if marker.interruptedAt != nil { marker.interruptedAt = nil; try Self.write(marker,to:directory) }
        } catch { Darwin.close(fd); fd = -1; throw error }
    }
    func setClosed(_ closed: Bool) throws { marker.closed = closed; marker.interruptedAt = nil; try Self.write(marker,to:directory) }
    func checkWrite(bytes: Int, name: String) throws {
        guard !name.contains("/"), bytes >= 0 else { throw Self.failure("保存名が不正です") }
        var old = stat(); let target = directory.appendingPathComponent(name)
        let previous = lstat(target.path,&old) == 0 && old.st_mode & S_IFMT == S_IFREG ? old.st_size : 0
        // atomic書き込みの一時的な二重領域も8MiB内に収める。
        // 別キューの二つの256KiBコンソールと小さな所有receiptのため1MiBを残す。
        guard try Self.size(directory) + Int64(bytes) <= 7 * 1024 * 1024 else {
            throw Self.failure("セッションの保存予算を超えました（既存\(previous)bytes）")
        }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    private static func write(_ marker: Marker,to directory:URL) throws {
        try JSONEncoder().encode(marker).write(to:directory.appendingPathComponent(markerName),options:.atomic)
    }
    private static func isPrivateDirectory(_ url:URL) throws -> Bool {
        var st = stat()
        guard lstat(url.path,&st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid() && st.st_mode & 0o077 == 0
    }
    private static func size(_ root:URL) throws -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for path in try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) {
            var st = stat(); guard lstat(path.path,&st) == 0 else { throw failure("保存容量を確認できません") }
            if st.st_mode & S_IFMT == S_IFDIR { total += try size(path) }
            else if st.st_mode & S_IFMT == S_IFREG { total += st.st_size }
        }
        return total
    }
}
