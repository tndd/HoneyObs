import Foundation
import Darwin

@main struct SessionArchiveChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("honeyobs-archive-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var policy = SessionArchive.Policy(); policy.maxSessions = 2; policy.maxBytes = 20000; policy.reservationBytes = 1000; policy.maxAge = 60
        let now = Date(), past = now.addingTimeInterval(-120)
        let first = try SessionArchive.makeDirectory(root:root,policy:policy,now:past)
        var held: SessionArchive? = try SessionArchive(directory:first)
        try held!.setClosed(true)
        // ロック中の古い記録と、管理対象外のディレクトリを保護する。
        let unmanaged = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at:unmanaged,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let second = try SessionArchive.makeDirectory(root:root,policy:policy,now:now)
        let other = try SessionArchive(directory:second)
        var refused = false
        do { _ = try SessionArchive.makeDirectory(root:root,policy:policy,now:now) } catch { refused = true }
        precondition(refused && FileManager.default.fileExists(atPath:first.path),"利用中の記録を削除した")
        held = nil
        _ = try SessionArchive.makeDirectory(root:root,policy:policy,now:now)
        precondition(!FileManager.default.fileExists(atPath:first.path) && FileManager.default.fileExists(atPath:unmanaged.path),"期限・管理対象の判定が不正")
        withExtendedLifetime(other) {}
        // symlinkを管理対象の実ディレクトリと誤認しない。
        let link = root.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:unmanaged)
        policy.maxSessions = 10
        _ = try SessionArchive.makeDirectory(root:root,policy:policy,now:now)
        precondition(FileManager.default.fileExists(atPath:unmanaged.path))
        print("保存期限・排他・容量・管理対象外の保護: PASS")
    }
}
