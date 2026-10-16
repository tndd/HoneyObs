import Foundation
import Virtualization
import Network
import Darwin

// 実vsockの読取開始だけを遅延させ、取消確認とFD閉鎖より先に完了しないことを検証する。
@main struct RelayClosureChecks {
    static func wait(_ message: String, seconds: Double = 5, until: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !until(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(until(), message)
    }
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 1; config.memorySize = 512 * 1024 * 1024
        let boot = VZLinuxBootLoader(kernelURL: resources.appendingPathComponent("vmlinuz"))
        boot.initialRamdiskURL = resources.appendingPathComponent("initramfs.gz")
        boot.commandLine = "rdinit=/init panic=0 quiet honeyobs.host=relay-test.invalid"
        config.bootLoader = boot; config.networkDevices = []; config.storageDevices = []; config.directorySharingDevices = []
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]; config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try config.validate()
        let vm = VZVirtualMachine(configuration: config)
        var running = false
        vm.start { result in if case .success = result { running = true } }
        wait("VM起動", seconds: 30) { running }
        var ready = false
        let readyDeadline = Date().addingTimeInterval(30)
        while !ready, Date() < readyDeadline {
            var replied = false
            _ = guestRequest(vm) { result in
                if case .success = result { ready = true }; replied = true
            }
            wait("VM準備応答", seconds: 5) { replied }
        }
        precondition(ready, "VM準備期限")
        let device = vm.socketDevices[0] as! VZVirtioSocketDevice
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        var port: NWEndpoint.Port?, subject: Relay?, accepted: NWConnection?, guestFD: Int32 = -1
        var delayedRead: (() -> Void)?, finished = 0
        listener.stateUpdateHandler = { state in if case .ready = state { port = listener.port } }
        listener.newConnectionHandler = { client in
            accepted = client
            device.connect(toPort: 7000) { result in
                let guest = try! result.get(); guestFD = guest.fileDescriptor
                subject = Relay(client: client, guest: guest, scheduleRead: { delayedRead = $0 }) {
                    precondition(fcntl(guestFD, F_GETFD) == -1 && errno == EBADF, "vsock FD閉鎖より先に完了した")
                    guard case .cancelled = client.state else { preconditionFailure("NW取消より先に完了した") }
                    finished += 1
                }
                subject!.start()
            }
        }
        listener.start(queue: .main); wait("localhost listen") { port != nil }
        let caller = NWConnection(host: "127.0.0.1", port: port!, using: .tcp)
        caller.start(queue: .main)
        caller.send(content: Data("GET /held HTTP/1.1\r\nHost: relay-test.invalid\r\n".utf8), completion: .contentProcessed { _ in })
        wait("読取workerの保留") { delayedRead != nil }
        subject!.cancel()
        wait("NWConnection取消") { if case .cancelled = accepted!.state { return true }; return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(finished == 0 && fcntl(guestFD, F_GETFD) != -1, "保留中workerの所有を失った")
        let read = delayedRead!; delayedRead = nil
        DispatchQueue.global().async(execute: DispatchWorkItem(block: read))
        wait("worker・FD・NW取消の完了") { finished == 1 }
        // 終了後の重複取消でも、新たに開いたFDを閉じないことを確認する。
        let reused = open("/dev/null", O_RDONLY | O_CLOEXEC)
        precondition(reused >= 0); subject!.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(finished == 1 && fcntl(reused, F_GETFD) != -1, "重複取消がFDを再操作した")
        close(reused); caller.cancel(); subject = nil; accepted = nil
        // 通常応答でもFD閉鎖・NW取消を確認してから完了し、応答を途中で切らない。
        listener.newConnectionHandler = { client in
            accepted = client
            device.connect(toPort: 7000) { result in
                let guest = try! result.get(); let fd = guest.fileDescriptor
                subject = Relay(client: client, guest: guest) {
                    precondition(fcntl(fd, F_GETFD) == -1 && errno == EBADF)
                    guard case .cancelled = client.state else { preconditionFailure("通常完了時のNW取消未確認") }
                    finished += 1
                }
                subject!.start()
            }
        }
        let normal = NWConnection(host: "127.0.0.1", port: port!, using: .tcp)
        var response = Data(), responseEnded = false
        func receive() {
            normal.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, ended, error in
                if let data { response.append(data) }
                precondition(response.count <= 4096)
                if ended || error != nil { responseEnded = true } else { DispatchQueue.main.async { receive() } }
            }
        }
        normal.start(queue: .main); receive()
        normal.send(content: Data("GET /closure-check HTTP/1.1\r\nHost: relay-test.invalid\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        wait("通常応答と所有回収") { finished == 2 && responseEnded }
        let text = String(decoding: response, as: UTF8.self)
        precondition(text.hasPrefix("HTTP/1.1 404") && text.hasSuffix("Not found\n"), "通常応答の欠落: \(text)")
        normal.cancel(); listener.cancel(); subject = nil; accepted = nil
        var stopped = false; vm.stop { error in precondition(error == nil); stopped = true }
        wait("VM停止", seconds: 10) { stopped }
        print("実VM・遅延読取・NW取消・FD閉鎖・重複取消・通常応答: PASS")
    }
}
