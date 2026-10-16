import Cocoa
import CryptoKit

@main enum InstalledIdentityChecks {
    static func pixels(_ image:NSImage) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:512,bitsPerPixel:32)!
        let context = NSGraphicsContext(bitmapImageRep:rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in:NSRect(x:0,y:0,width:128,height:128),from:.zero,operation:.copy,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes:rep.bitmapData!,count:512*128)
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("inspect|quit|assert と .app絶対パスを指定") }
        let path = URL(fileURLWithPath:args[2]).standardizedFileURL
        let bundle = Bundle(url:path)!, identifier = bundle.bundleIdentifier!
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).filter { $0.activationPolicy == .regular }
        let matching = applications.filter { $0.bundleURL?.standardizedFileURL == path }
        if args[1] == "quit" {
            for app in matching { precondition(app.executableURL?.path == path.appendingPathComponent("Contents/MacOS/HoneyObs").path); precondition(app.terminate()) }
            let deadline = Date().addingTimeInterval(15)
            while matching.contains(where:{ !$0.isTerminated }), Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
            precondition(matching.allSatisfy({ $0.isTerminated }),"通常終了しなかった")
        }
        if args[1] == "assert" {
            precondition(applications.count == 1 && matching.count == 1,"regularアプリの所有が重複または別path")
            precondition(NSWorkspace.shared.urlForApplication(withBundleIdentifier:identifier)?.standardizedFileURL == path,"通常の起動先が導入済みappではない")
            let expected = NSImage(contentsOf:path.appendingPathComponent("Contents/Resources/AppIcon.icns"))!
            precondition(matching[0].icon != nil && pixels(matching[0].icon!) == pixels(expected),"実行中アプリの採用アイコンが一致しない")
        }
        let report:[String:Any] = ["mode":args[1],"resolver":NSWorkspace.shared.urlForApplication(withBundleIdentifier:identifier)?.path ?? "",
            "applications":applications.map { ["pid":$0.processIdentifier,"path":$0.bundleURL?.path ?? "","terminated":$0.isTerminated] as [String:Any] }]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)
    }
}
