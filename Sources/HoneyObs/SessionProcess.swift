import Foundation
import Darwin

/// Foundation.Process starts a new process group. Session children must remain
/// in launchd's group so that OS cleanup includes a killed or stopped child.
final class SessionProcess {
    var executableURL: URL?
    var arguments: [String] = []
    var environment: [String: String]?
    var standardInput: Any? = FileHandle.nullDevice
    var standardOutput: Any? = FileHandle.nullDevice
    var standardError: Any? = FileHandle.nullDevice
    var terminationHandler: ((SessionProcess) -> Void)?
    private(set) var processIdentifier: pid_t = 0
    private(set) var terminationStatus: Int32 = 0
    private(set) var terminationReason: Process.TerminationReason = .exit
    private var running = false
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var source: DispatchSourceProcess?
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func run() throws {
        guard let executableURL else { throw POSIXError(.EINVAL) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        // No SETPGROUP or SETSID: inherit the launchd owner's process group.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        for (value, target, reading) in [(standardInput, STDIN_FILENO, true), (standardOutput, STDOUT_FILENO, false), (standardError, STDERR_FILENO, false)] {
            let handle: FileHandle
            if let pipe = value as? Pipe { handle = reading ? pipe.fileHandleForReading : pipe.fileHandleForWriting }
            else { handle = value as? FileHandle ?? FileHandle.nullDevice }
            posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, target)
        }
        let values = [executableURL.path] + arguments
        let variables = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        let argv = values.map { strdup($0) }, envp = variables.map { strdup($0) }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var argvPointers = argv + [nil], environmentPointers = envp + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executableURL.path, &actions, &attributes, &argvPointers, &environmentPointers)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        processIdentifier = pid; running = true; finished.enter()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        self.source = source
        source.setEventHandler { [self] in
            // Signal and reap share a lock. A PID cannot be reused between the
            // ownership check and kill because only this object reaps the child.
            lock.lock()
            var status: Int32 = 0
            let waited = waitpid(pid, &status, 0)
            if waited == pid {
                terminationReason = status & 0x7f == 0 ? .exit : .uncaughtSignal
                terminationStatus = terminationReason == .exit ? (status >> 8) & 0xff : status & 0x7f
            } else { terminationReason = .uncaughtSignal; terminationStatus = SIGKILL }
            running = false; lock.unlock()
            source.cancel(); self.source = nil
            finished.leave(); terminationHandler?(self)
        }
        source.resume()
    }

    func send(_ signal: Int32) { lock.lock(); defer { lock.unlock() }; if running { _ = Darwin.kill(processIdentifier, signal) } }
    func terminate() { send(SIGTERM) }
    func waitUntilExit() { finished.wait() }
}
