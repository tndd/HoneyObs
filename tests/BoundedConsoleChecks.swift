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
        let markerPath = path.appendingPathExtension("marker")
        defer { try? FileManager.default.removeItem(at:markerPath) }
        var markers = 0, markerClosed = false
        let markerConsole = try BoundedConsole(url:markerPath,capturePattern:"https://[a-z]+",marker:"READY_MARKER",onMarker:{ markers += 1 })
        try markerConsole.writer.write(contentsOf:Data("REA".utf8))
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        try markerConsole.writer.write(contentsOf:Data("DY_MARKER READY_MARKER https://example".utf8))
        let markerDeadline = Date().addingTimeInterval(2)
        while markers == 0 && Date() < markerDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        precondition(markers == 1 && markerConsole.capturedValue == "https://example")
        markerConsole.close { markerClosed = true }
        while !markerClosed && Date() < markerDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        precondition(markerClosed)
        print("VMコンソールの固定量保存・最終drain・全FD解放: PASS")
    }
}
