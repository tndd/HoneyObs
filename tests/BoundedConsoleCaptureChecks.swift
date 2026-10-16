import Foundation

@main struct BoundedConsoleCaptureChecks {
    static func main() throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let file=output.appendingPathComponent("capture.log")
        let console=try BoundedConsole(url:file,limit:8192,capturePattern:EgressPolicy.publicURLPattern)
        try console.writer.write(contentsOf:Data([0xff,0xfe]))
        for chunk in ["https://wrong.trycloudflare.com.evil.invalid ","https://","retained-value.","trycloudflare.","com"]{
            try console.writer.write(contentsOf:Data(chunk.utf8));Thread.sleep(forTimeInterval:0.03)
        }
        precondition(console.capturedValue == nil,"区切り前や別ドメインをURLとして確定した")
        try console.writer.write(contentsOf:Data(" \n".utf8));Thread.sleep(forTimeInterval:0.04)
        precondition(console.capturedValue == "https://retained-value.trycloudflare.com","分割されたURLを取得できない")
        try console.writer.write(contentsOf:Data(repeating:65,count:100000))
        try console.writer.write(contentsOf:Data("\nhttps://later-value.trycloudflare.com \n".utf8))
        try console.writer.write(contentsOf:Data(repeating:66,count:100000))
        var closed=false;console.close{closed=true}
        let deadline=Date().addingTimeInterval(3)
        while !closed && Date()<deadline{RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
        precondition(closed && console.capturedValue == "https://retained-value.trycloudflare.com","rotationやcloseで最初のURLを失った")
        let bytes=try Data(contentsOf:file)
        precondition(bytes.count<=8192 && !String(decoding:bytes,as:UTF8.self).contains("retained-value"),"rotationの成立または上限を確認できない")
        print("分割URL・区切り検証・不正UTF8・rotation後の初回URL保持・上限・close: PASS")
    }
}
