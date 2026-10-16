import Foundation
import Network
import Darwin

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class GuestSocket: EgressGuestSocket {
    let descriptor: Int32
    let peer: Int32
    private let lock = NSLock()
    private var closed = false
    var onDescriptor: (() -> Void)?
    var fileDescriptor: Int32 { onDescriptor?(); return descriptor }
    init() throws {
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        descriptor = fds[0]; peer = fds[1]
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; Darwin.close(descriptor) }
    }
    deinit { close(); Darwin.close(peer) }
    func write(_ data: Data) {
        let count = data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        precondition(count == data.count)
    }
}

private final class LocalPeer {
    let listener: NWListener
    var client: NWConnection!
    private var accepted: NWConnection?
    private(set) var bytes = Data()
    private var port: NWEndpoint.Port?
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.port = self.listener.port }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accepted = connection; connection.start(queue: .main); self.receive(connection)
        }
        listener.start(queue: .main)
        EgressRevocationChecks.wait("localhost待受") { self.port != nil }
        client = NWConnection(host: "127.0.0.1", port: port!, using: .tcp)
        client.start(queue: .main)
        EgressRevocationChecks.wait("localhost接続") { if case .ready = self.client.state { return true }; return false }
    }
    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, ended, error in
            guard let self else { return }
            if let data { self.bytes.append(data) }
            precondition(self.bytes.count <= 4096)
            if !ended && error == nil { self.receive(connection) }
        }
    }
    func stop() {
        client.cancel(); accepted?.cancel(); listener.cancel()
        EgressRevocationChecks.wait("localhost取消") {
            guard case .cancelled = self.client.state else { return false }
            if let accepted = self.accepted { guard case .cancelled = accepted.state else { return false } }
            return true
        }
    }
}

@main struct EgressRevocationChecks {
    static func wait(_ label: String, until: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !until(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(until(), label + "の期限超過")
    }
    static func check(_ value: Bool, _ reason: String) throws {
        if !value { throw NSError(domain: "EgressRevocation", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
    private static func subject(_ guest: GuestSocket, _ permit: ForwardingPermit, mode: EgressStream.Mode = .origin) -> EgressStream {
        EgressStream(guest: guest, host: "127.0.0.1", port: 1, mode: mode, permit: permit, finished: {})
    }
    static func expiredSend() throws {
        for mode: EgressStream.Mode in [.origin, .edge, .provision] { try expiredSend(mode: mode) }
    }
    private static func expiredSend(mode: EgressStream.Mode) throws {
        let peer = try LocalPeer(); defer { peer.stop() }
        let guest = try GuestSocket(), clock = Box(0.0)
        let permit = ForwardingPermit(confirmedAt: 0, clock: { clock.value }), stream = subject(guest, permit, mode: mode)
        defer { stream.cancel() }
        let waiting = DispatchSemaphore(value: 0), result = Box<Bool?>(nil)
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 64)
            precondition(permit.valid)
            waiting.signal()
            let count = Darwin.read(guest.fileDescriptor, &buffer, buffer.count)
            precondition(count > 0)
            result.value = stream.testingSend(Data(buffer.prefix(count)), to: peer.client)
        }
        precondition(waiting.wait(timeout: .now() + 2) == .success)
        clock.value = 3; guest.write(Data("expired-after-read".utf8))
        wait("期限後のsend判定") { result.value != nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try check(result.value == false && peer.bytes.isEmpty, "期限後にNW.sendが新規発行された: \(String(decoding: peer.bytes, as: UTF8.self))")
    }
    static func lateRead() throws {
        let guest = try GuestSocket(), clock = Box(0.0)
        let permit = ForwardingPermit(confirmedAt: 0, clock: { clock.value }), stream = subject(guest, permit)
        defer { stream.cancel() }
        let waiting = DispatchSemaphore(value: 0), ended = Box(false), value = Box<Data?>(nil)
        // exactの先頭有効性検査後、実readへ入る位置を捕捉する。自動timerは起動しない。
        guest.onDescriptor = { waiting.signal() }
        DispatchQueue.global().async { value.value = stream.testingExact(1); ended.value = true }
        precondition(waiting.wait(timeout: .now() + 2) == .success)
        clock.value = 3; guest.write(Data([7]))
        wait("期限後に完了したread") { ended.value }
        try check(value.value == nil, "期限をまたいだ最終readの内容を受理した")
    }
    static func serialIssue(revoke: Bool) throws {
        let peer = try LocalPeer(); defer { peer.stop() }
        let guest = try GuestSocket(), permit = ForwardingPermit(confirmedAt: 0, clock: { 0 })
        let stream = subject(guest, permit); defer { stream.cancel() }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cancelling = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0), issued = Box(false)
        DispatchQueue.global().async {
            issued.value = stream.testingIssue {
                // 発行の直前だけ保留し、cancel/revokeと同じcritical sectionかを観測する。
                entered.signal(); precondition(release.wait(timeout: .now() + 2) == .success)
                peer.client.send(content: Data("before-revocation".utf8), completion: .contentProcessed { _ in })
            }
        }
        precondition(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            cancelling.signal()
            if revoke { permit.revoke() } else { stream.cancel() }
            cancelled.signal()
        }
        precondition(cancelling.wait(timeout: .now() + 2) == .success)
        let cancelledDuringIssue = cancelled.wait(timeout: .now() + 0.05) == .success
        release.signal()
        if !cancelledDuringIssue { precondition(cancelled.wait(timeout: .now() + 2) == .success) }
        wait("取消前の発行") { issued.value && !peer.bytes.isEmpty }
        let after = stream.testingSend(Data("after-revocation".utf8), to: peer.client)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try check(!cancelledDuringIssue, "send発行のcritical section内で取消が先行した")
        try check(!after && peer.bytes == Data("before-revocation".utf8), "取消後の新規sendを受理した")
    }
    static func main() {
        let selected = CommandLine.arguments.dropFirst().first
        let cases: [(String, () throws -> Void)] = [
            ("expired-send", expiredSend), ("late-read", lateRead),
            ("cancel-race", { try serialIssue(revoke: false) }), ("revoke-race", { try serialIssue(revoke: true) })
        ]
        do {
            try check(selected == nil || cases.contains(where: { $0.0 == selected }), "不明な検査名")
            for (name, action) in cases where selected == nil || selected == name {
                try action(); print(name + ": PASS")
            }
        } catch { fputs("FAIL: " + error.localizedDescription + "\n", stderr); exit(1) }
    }
}
