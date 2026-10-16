import Foundation
import Virtualization
import Network
import Darwin

@main struct EgressChecks {
    static func check(_ condition: Bool, _ message: String) { if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) } }
    static func u16(_ n: Int) -> [UInt8] { [UInt8((n >> 8) & 255), UInt8(n & 255)] }
    static func hello(name: String = EgressPolicy.edgeServerName, extra: [UInt8] = []) -> Data {
        let bytes = Array(name.utf8), nameEntry = [UInt8(0)] + u16(bytes.count) + bytes
        let sni = u16(nameEntry.count) + nameEntry
        let ext = [UInt8(0),0] + u16(sni.count) + sni + extra
        let body = [UInt8(3),3] + Array(repeating: UInt8(7), count: 32) + [0,0,2,0x13,1,1,0] + u16(ext.count) + ext
        let handshake = [UInt8(1),0] + u16(body.count) + body
        return Data([22,3,1] + u16(handshake.count) + handshake)
    }
    static func policy() {
        let good = hello(); check(EgressPolicy.allowsEdgeHello(good), "valid SNI")
        check(!EgressPolicy.allowsEdgeHello(hello(name: "example.com")), "foreign SNI")
        check(!EgressPolicy.allowsEdgeHello(hello(name: "h2.cftunnel.com.attacker.invalid")), "suffix SNI")
        check(!EgressPolicy.allowsEdgeHello(hello(extra: [0xfe,0x0d,0,0])), "ECH")
        check(!EgressPolicy.allowsEdgeHello(hello(extra: [0,42,0,0])), "early data")
        check(!EgressPolicy.allowsEdgeHello(hello(extra: [0,16,0,11,0,9,8] + Array("http/1.1".utf8))), "foreign ALPN")
        check(EgressPolicy.allowsEdgeHello(hello(extra: [0,16,0,5,0,3,2,104,50])), "h2 ALPN")
        check(!EgressPolicy.allowsEdgeHello(good + good), "second hello")
        check(!EgressPolicy.allowsFollowingRecord(good,compatibilityCCSUsed:false),"second plaintext handshake")
        check(EgressPolicy.allowsFollowingRecord(Data([20,3,3,0,1,1]),compatibilityCCSUsed:false),"one CCS")
        check(!EgressPolicy.allowsFollowingRecord(Data([20,3,3,0,1,1]),compatibilityCCSUsed:true),"repeated CCS")
        check(EgressPolicy.allowsFollowingRecord(Data([23,3,3,0,1,0]),compatibilityCCSUsed:true),"encrypted TLS1.3 envelope")
        for i in 0..<good.count { check(!EgressPolicy.allowsEdgeHello(good.prefix(i)), "truncated hello \(i)") }
        for i in 0..<4000 {
            var bytes = Array(good); let index = (i * 31) % bytes.count; bytes[index] ^= UInt8((i % 255) + 1)
            _ = EgressPolicy.allowsEdgeHello(Data(bytes))
        }
        let request = "POST /tunnel HTTP/1.1\r\nHost: 127.0.0.1:7002\r\nContent-Length: 0\r\n\r\n"
        check(EgressPolicy.allowsProvision(Data(request.utf8)), "empty fixed API POST")
        for evil in [request.replacingOccurrences(of: "/tunnel", with: "/other"),request.replacingOccurrences(of: "POST", with: "CONNECT"),request.replacingOccurrences(of: "127.0.0.1:7002",with: "example.com"),request.replacingOccurrences(of: "Content-Length: 0", with:"Transfer-Encoding: chunked"),request.replacingOccurrences(of: "Content-Length: 0",with:"Content-Length: 0\r\nContent-Length: 0"),request + "body"] {check(!EgressPolicy.allowsProvision(Data(evil.utf8)), "API method/path/header/body rejection")}
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n".utf8)
        check(EgressPolicy.allowsProvisionResponseHeader(response),"API response")
        check(!EgressPolicy.allowsProvisionResponseHeader(Data("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/\r\n\r\n".utf8)),"API redirect")
        check(!EgressPolicy.allowsProvisionResponseHeader(Data("HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n".utf8)),"API response cap")
        let worker = "Name:\tcloudflared\nUid:\t65533\t65533\t65533\t65533\nGid:\t65533\t65533\t65533\t65533\nCapEff:\t0000000000000000\nCapPrm:\t0000000000000000\nCapAmb:\t0000000000000000\nNoNewPrivs:\t1\nSeccomp:\t2\nState:\tS (sleeping)"
        check(EgressVM.validWorker(worker,uid:65533,seccomp:"2"),"worker process boundary")
        check(!EgressVM.validWorker(worker.replacingOccurrences(of:"Seccomp:\t2",with:"Seccomp:\t0"),uid:65533,seccomp:"2"),"missing seccomp")
        check(!EgressVM.validWorker(worker.replacingOccurrences(of:"S (sleeping)",with:"Z (zombie)"),uid:65533,seccomp:"2"),"dead worker")
        print("PASS: egress policy, malformed TLS, fixed API, process boundary")
    }
    static func wait(until condition: () -> Bool, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    static func vm(root: URL) throws {
        let directory = root.appendingPathComponent("test-results/egress-vm-\(getpid())")
        let permit = ForwardingPermit(confirmedAt:safetyTime())
        var renewal: Timer? = Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){_ in _ = permit.renew(confirmedAt:safetyTime())}
        defer { renewal?.invalidate() }
        let fake = try NWListener(using:.tcp, on:.any)
        var fakePort: UInt16 = 0, captured = 0, foreignSNIReachedFake = false
        var fakeClients: [NWConnection] = []
        fake.stateUpdateHandler = { state in if case .ready = state { fakePort = fake.port!.rawValue } }
        fake.newConnectionHandler = { connection in
            fakeClients.append(connection); connection.start(queue:.main)
            connection.receive(minimumIncompleteLength:5,maximumLength:16384){data,_,_,_ in
                if let data, data.count >= 5 { captured += 1; if !EgressPolicy.allowsEdgeHello(data) {foreignSNIReachedFake=true} }
                connection.send(content:Data([21,3,3,0,2,2,40]),completion:.contentProcessed{_ in connection.cancel()})
            }
        }
        fake.start(queue:.main); wait(until:{fakePort != 0},seconds:3); check(fakePort != 0,"fake edge listener")
        var failure = "", ready = false, apiRequests = 0, apiAllowed = false, edgeChannels = 0, badSNIDeniedBeforeAPI = false, pending: [UUID:EgressStream] = [:]
        let subject = EgressVM(resources:root.appendingPathComponent("build/HoneyObs.app/Contents/Resources"),directory:directory,originPort:12345,originHost:"egress-test.invalid",permit:permit,onFailure:{failure=$0})
        subject.testHandler = {port,connection,finished in
            if port == 9002 {
                edgeChannels += 1
                let id = UUID(); let stream = EgressStream(guest:connection,host:"127.0.0.1",port:fakePort,mode:.edge,permit:permit){pending.removeValue(forKey:id);finished()}
                pending[id]=stream;stream.start();return
            }
            if port == 9000 { connection.close();finished();return }
            apiRequests += 1; badSNIDeniedBeforeAPI = captured == 0 && edgeChannels == 2
            DispatchQueue.global().async {
                let fd = connection.fileDescriptor; _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) & ~O_NONBLOCK)
                var timeout = timeval(tv_sec:2,tv_usec:0);setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                var bytes = Data(), byte: UInt8 = 0
                while bytes.count < 4096 && !bytes.suffix(4).elementsEqual([13,10,13,10]) { if Darwin.read(fd,&byte,1) != 1 {break};bytes.append(byte) }
                let allowed = EgressPolicy.allowsProvision(bytes)
                let body = Data("{\"success\":true,\"errors\":[],\"result\":{\"id\":\"00000000-0000-0000-0000-000000000001\",\"hostname\":\"local-test.trycloudflare.com\",\"account_tag\":\"local-test\",\"secret\":\"bG9jYWw=\"}}".utf8)
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)+body
                response.withUnsafeBytes{_ = Darwin.write(fd,$0.baseAddress,$0.count)}
                connection.close();DispatchQueue.main.async{apiAllowed=allowed;finished()}
            }
        }
        let startTime = safetyTime()
        subject.start { result in if case .success = result {ready=true} else if case .failure(let e)=result{failure=e.localizedDescription} }
        wait(until:{(ready && captured > 0) || !failure.isEmpty},seconds:35)
        let bootSeconds = safetyTime()-startTime
        let snapshot = subject.status
        let log = (try? String(contentsOf:directory.appendingPathComponent("tunnel.log"),encoding:.utf8)) ?? ""
        var stopped: Bool?;subject.stop { stopped=$0 }
        for stream in pending.values{stream.cancel()}
        wait(until:{stopped != nil},seconds:12)
        fake.cancel();fakeClients.forEach{$0.cancel()};renewal?.invalidate();renewal=nil
        check(stopped == true && subject.shutdownComplete,"VM and connectors shutdown: \(failure)")
        check(ready,"root health validates cloudflared: \(failure); \(log.suffix(1800))")
        check(apiRequests == 1 && apiAllowed,"real cloudflared fixed provisioning")
        check(captured > 0 && badSNIDeniedBeforeAPI && !foreignSNIReachedFake,"two foreign SNI attempts make zero fake-edge connections; one actual cloudflared SNI passes (channels \(edgeChannels), dials \(captured)): \(log.suffix(1200))")
        guard let line = log.components(separatedBy:"\n").first(where:{$0.contains("HONEYOBS_EGRESS_ISOLATION ")}),let range=line.range(of:"HONEYOBS_EGRESS_ISOLATION "),let data=String(line[range.upperBound...]).data(using:.utf8),let isolation=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{check(false,"VM isolation report missing: \(log.prefix(2000))");return}
        check(isolation["interfaces"] as? [String] == ["lo"],"no VM NIC")
        let probes = isolation["probes"] as? [String:String] ?? [:]
        check(!probes.isEmpty && !probes.values.contains("CONNECTED"),"LAN/internet/IPv6 not reached")
        for key in ["raw-ipv4","socket-domain-40","socket-domain-10","socket-domain-17"]{check(probes[key]?.contains("operation not permitted") == true,"seccomp denied \(key): \(probes[key] ?? "missing")")}
        let report: [String:Any] = ["configuredMemoryMiB":256,"bootToFakeEdgeSeconds":bootSeconds,"apiRequests":apiRequests,"fakeEdgeConnections":captured,"health":snapshot,"isolation":isolation,"shutdownComplete":subject.shutdownComplete,"externalPublication":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
        let earlyPermit = ForwardingPermit(confirmedAt:safetyTime())
        let early = EgressVM(resources:root.appendingPathComponent("build/HoneyObs.app/Contents/Resources"),directory:directory.appendingPathComponent("early-stop"),originPort:12345,originHost:"egress-early.invalid",permit:earlyPermit,onFailure:{_ in})
        var startReplies = 0, earlyStopped: Bool?
        early.testHandler = {_,connection,finished in connection.close();finished()}
        early.start{_ in startReplies += 1};early.stop{earlyStopped=$0}
        wait(until:{earlyStopped != nil},seconds:12)
        check(earlyStopped == true && early.shutdownComplete && startReplies == 1,"stop while VZ starts retains ownership and cancels start once")
        print("PASS: NIC-free egress VM, real Linux cloudflared→localhost fake edge, denied escape probes, stop; boot \(String(format:"%.2f",bootSeconds))s; \(directory.path)")
    }
    static func main() throws {
        policy()
        if CommandLine.arguments.contains("--vm") {try vm(root:URL(fileURLWithPath:CommandLine.arguments[1]))}
    }
}
