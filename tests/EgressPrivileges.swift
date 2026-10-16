import Foundation
import Virtualization

@main struct EgressPrivileges {
    static func main() throws {
        let args = CommandLine.arguments
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 2; config.memorySize = 256 * 1024 * 1024
        let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: args[1]))
        boot.initialRamdiskURL = URL(fileURLWithPath: args[2])
        boot.commandLine = "console=hvc0 rdinit=/init panic=0 quiet"
        config.bootLoader = boot
        config.networkDevices = []; config.storageDevices = []; config.directorySharingDevices = []
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        FileManager.default.createFile(atPath: args[3], contents: nil)
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: FileHandle(forReadingAtPath:"/dev/null"), fileHandleForWriting: output)
        config.serialPorts = [serial]; try config.validate()
        let vm = VZVirtualMachine(configuration: config)
        var error: Error?, started = false
        vm.start { result in
            if case .failure(let e) = result { error = e }
            started = true
        }
        let deadline = Date().addingTimeInterval(30)
        var passed = false
        while Date() < deadline && error == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let log = (try? String(contentsOfFile: args[3], encoding: .utf8)) ?? ""
            if log.contains("HONEYOBS_PRIVILEGES_PASS") { passed = true; break }
            if log.contains("HONEYOBS_PRIVILEGES_FAIL") { break }
        }
        var stopped = !started
        if vm.canStop { vm.stop { result in if result == nil { stopped = true } } }
        let stopDeadline = Date().addingTimeInterval(5)
        while !stopped && Date() < stopDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        try output.close()
        guard passed && stopped && error == nil else {
            fputs("FAIL privileges VM: passed=\(passed), stopped=\(stopped), error=\(String(describing:error)); see \(args[3])\n",stderr); exit(1)
        }
        print("PASS: Linux thread-wide privilege/filter setup and exec inheritance; VM stopped")
    }
}
