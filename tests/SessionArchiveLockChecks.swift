import Foundation
import Darwin

@main struct SessionArchiveLockChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoneyObs-retention-lock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let held = open(root.appendingPathComponent(".retention.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        precondition(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0)
        defer { close(held) }
        // blocking flockへ退行した場合も、この検証プロセスだけを2秒で失敗させる。
        signal(SIGALRM) { _ in _exit(1) }; alarm(2)
        defer { alarm(0) }
        let started = ProcessInfo.processInfo.systemUptime
        var rejected = false
        do { _ = try SessionArchive.makeDirectory(root: root) } catch { rejected = true }
        precondition(rejected, "保存先の排他保持中に新しいsessionを作成しました")
        precondition(ProcessInfo.processInfo.systemUptime - started < 0.5, "保存先の排他取得が即座に失敗しませんでした")
        precondition(flock(held, LOCK_UN) == 0)
        let created = try SessionArchive.makeDirectory(root: root)
        precondition(FileManager.default.fileExists(atPath: created.appendingPathComponent("session-owner.json").path))
        print("保存先の排他競合を即時拒否・解放後の新規起動: PASS")
    }
}
