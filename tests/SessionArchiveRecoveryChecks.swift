import Foundation
import Darwin

@main struct SessionArchiveRecoveryChecks {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe" {
            var policy = SessionArchive.Policy(); policy.maxSessions = 1
            do { _ = try SessionArchive.makeDirectory(root:URL(fileURLWithPath:CommandLine.arguments[2]),policy:policy); exit(1) }
            catch { print("監視役の結果保存中は保持上限からの新規起動を拒否: PASS"); return }
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("HoneyObs-recovery-" + UUID().uuidString)
        defer { try? fm.removeItem(at:root) }
        var policy = SessionArchive.Policy(); policy.maxSessions = 1
        let now = Date(), past = now.addingTimeInterval(-7200)
        let directory = try SessionArchive.makeDirectory(root:root,policy:policy,now:past)
        let lock = open(directory.appendingPathComponent(".recovery.lock").path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        precondition(lock >= 0 && flock(lock,LOCK_EX|LOCK_NB) == 0)
        defer { close(lock) }
        func refused(at date: Date) -> Bool {
            do { _ = try SessionArchive.makeDirectory(root:root,policy:policy,now:date); return false } catch { return true }
        }
        precondition(refused(at:now), "長時間セッションのmonitor結果保存前に削除した")
        let receipt = Data("{\"status\":1}".utf8)
        try receipt.write(to:directory.appendingPathComponent("session-result.json"),options:.atomic)
        let saved = try Data(contentsOf:directory.appendingPathComponent("session-result.json"))
        precondition(saved == receipt)
        precondition(flock(lock,LOCK_UN) == 0)
        // 作成から2時間経っていても、最初に中断を観測した今から600秒を保護する。
        precondition(refused(at:now), "中断の初回観測直後に記録を削除した")
        let markerURL = directory.appendingPathComponent("session-owner.json")
        let observed = try JSONDecoder().decode(SessionArchive.Marker.self,from:Data(contentsOf:markerURL))
        precondition(observed.created == past && observed.interruptedAt == now)
        precondition(refused(at:now.addingTimeInterval(599)), "中断猶予を短縮した")
        let repeated = try JSONDecoder().decode(SessionArchive.Marker.self,from:Data(contentsOf:markerURL))
        precondition(repeated.interruptedAt == now, "再試行で中断猶予を無限に延ばした")
        _ = try SessionArchive.makeDirectory(root:root,policy:policy,now:now.addingTimeInterval(601))
        precondition(!fm.fileExists(atPath:directory.path))
        // 起動と初回観測が競合しても、実際に開いたsessionは中断済み時刻を消す。
        let reopeningRoot = root.appendingPathComponent("reopening")
        let reopening = try SessionArchive.makeDirectory(root:reopeningRoot,policy:policy,now:past)
        do { _ = try SessionArchive.makeDirectory(root:reopeningRoot,policy:policy,now:now) } catch {}
        var active: SessionArchive? = try SessionArchive(directory:reopening)
        let opened = try JSONDecoder().decode(SessionArchive.Marker.self,from:Data(contentsOf:reopening.appendingPathComponent("session-owner.json")))
        precondition(opened.interruptedAt == nil)
        withExtendedLifetime(active) {}; active = nil
        var protected = false
        do { _ = try SessionArchive.makeDirectory(root:reopeningRoot,policy:policy,now:now.addingTimeInterval(1200)) } catch { protected = true }
        precondition(protected, "再開前の中断時刻を引き継いだ")
        print("監視役lock・中断初回観測の猶予・満了後回収: PASS")
    }
}
