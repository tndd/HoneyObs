import Cocoa

@main struct EgressEngineChecks {
    static func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n",stderr);exit(1) } }
    static func wait(_ predicate: () -> Bool, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.02))}
    }
    static func main() throws {
        _ = NSApplication.shared; signal(SIGPIPE,SIG_IGN)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),directory=root.appendingPathComponent("test-results/egress-engine-\(getpid())")
        let engine=try Engine(directory:directory,resources:root.appendingPathComponent("build/Applications.noindex/HoneyObs.app/Contents/Resources"),testing:true)
        try engine.enableEgressTestingFixture();engine.start(publish:true)
        wait({(!engine.publicURL.isEmpty && (engine.egressFixtureStatus["fakeEdgeDials"] as? Int ?? 0)>0) || !engine.isActive},seconds:40)
        let status=(try? JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("state.json"))) as? [String:Any]) ?? [:]
        var stopped:Bool?;engine.stop(reason:"外部公開なしの二台VM統合確認"){stopped=$0};wait({stopped != nil},seconds:12)
        check(stopped == true && engine.shutdownComplete,"both VMs and fixed connectors reclaimed: \(engine.detail)")
        check(status["vmPresent"] as? Bool == true && status["egressVMPresent"] as? Bool == true && status["egressHealthy"] as? Bool == true,"both VMs present and egress healthy before stop")
        check(status["supervisorPID"] as? Int == 0,"no host tunnel/watchdog child")
        check(engine.publicURL == "https://local-fixture.trycloudflare.com" && status["phase"] as? String == "公開URL取得済み","URL reaches existing UI state without external reachability claim")
        let fixture=engine.egressFixtureStatus
        check(fixture["apiCalls"] as? Int == 1 && (fixture["fakeEdgeDials"] as? Int ?? 0)>0 && fixture["invalidHello"] as? Bool == false,"only localhost fake API/validated edge")
        let attributes=try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("tunnel.log").path)
        check((attributes[.size] as? Int ?? Int.max)<=262144,"bounded egress console")
        try JSONSerialization.data(withJSONObject:["actualDecoyVM":true,"actualEgressVM":true,"fixture":fixture,"shutdownComplete":engine.shutdownComplete,"externalPublication":false],options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
        print("PASS: Engine→two actual VMs→fixed localhost fake edge, public URL/UI state, no host tunnel, bounded log, full stop; \(directory.path)")
    }
}
