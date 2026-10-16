import Foundation

@main struct BoundedConsoleChecks {
    static func main() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:path) }
        let console = try BoundedConsole(url:path,limit:32768)
        let block = Data(repeating:65,count:8192)
        var done = false
        DispatchQueue.global().async {
            for _ in 0..<128 { try! console.writer.write(contentsOf:block) }
            console.close { done = true }
        }
        let deadline = Date().addingTimeInterval(8)
        while !done && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        precondition(done,"ログFDの回収が完了しなかった")
        let data = try Data(contentsOf:path)
        precondition(!data.isEmpty && data.count <= 32768,"出力上限を超えた")
        print("VMコンソールの固定量保存・最終drain・全FD解放: PASS")
    }
}
