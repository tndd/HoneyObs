import Foundation
import Virtualization
import Network
import Darwin
import Security

protocol EgressGuestSocket: AnyObject {
    var fileDescriptor: Int32 { get }
    func close()
}
extension VZVirtioSocketConnection: EgressGuestSocket {}

// 1本のvsockと固定宛先TCPの所有。close完了はworkerとNWの終了後だけ通知する。
final class EgressStream {
    enum Mode { case origin, edge, provision, authKeys }
    private let guest: EgressGuestSocket
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let mode: Mode
    private let protectedProvision: Bool
    private let authKeysDeadline: Double
    private let permit: ForwardingPermit
    private let finished: () -> Void
    private let lock = NSLock()
    private let socketLock = NSLock()
    private var network: NWConnection?
    private var closed = false, workerEnded = false, networkEnded = true, notified = false, guestClosed = false
    private var responseBytes = 0
    private var responseHeader = Data(), responseHeaderAccepted = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "honeyobs.egress.stream")

    init(guest: EgressGuestSocket, host: String, port: UInt16, mode: Mode, permit: ForwardingPermit, protectedProvision: Bool = false, finished: @escaping () -> Void) {
        self.guest = guest; self.host = NWEndpoint.Host(host); self.port = NWEndpoint.Port(rawValue: port)!
        self.mode = mode; self.permit = permit; self.finished = finished
        self.protectedProvision = protectedProvision; self.authKeysDeadline = safetyTime() + 10
    }
    private var live: Bool { lock.lock(); defer { lock.unlock() }; return !closed && permit.valid }
    func start() {
        let fd = guest.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 0, tv_usec: 200000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(100)); t.setEventHandler { [weak self] in
            guard let self, !self.permit.valid || (self.mode == .authKeys && safetyTime() >= self.authKeysDeadline) else { return }; self.cancel()
        }; timer = t; t.resume()
        DispatchQueue.global(qos: .userInitiated).async { self.run() }
    }
    private func exact(_ size: Int, until: Double? = nil) -> Data? {
        var result = Data(), buffer = [UInt8](repeating: 0, count: size)
        while result.count < size && live {
            if let until, safetyTime() >= until { return nil }
            let n = Darwin.read(guest.fileDescriptor, &buffer, size - result.count)
            if n > 0 {
                guard live else { return nil }
                result.append(contentsOf: buffer.prefix(n))
            }
            else if n == 0 || (errno != EAGAIN && errno != EINTR) { return nil }
        }
        return result.count == size && live ? result : nil
    }
    private func record(until: Double? = nil) -> Data? {
        guard let header = exact(5, until: until) else { return nil }
        let length = Int(header[3]) << 8 | Int(header[4])
        guard header[1] == 3, header[2] >= 1, header[2] <= 3, length > 0, length <= 16640,
              let body = exact(length, until: until) else { return nil }
        return header + body
    }
    private func send(_ bytes: Data, to connection: NWConnection) -> Bool {
        let signal = DispatchSemaphore(value: 0)
        let outcome = EgressSendResult()
        guard issueIfLive({
            connection.send(content: bytes, completion: .contentProcessed { error in outcome.ok = error == nil; signal.signal() })
        }) else { return false }
        let deadline = safetyTime() + 4
        while signal.wait(timeout: .now() + 0.1) != .success { if !live || safetyTime() >= deadline { return false } }
        return live && outcome.ok
    }
    private func issueIfLive(_ action: () -> Void) -> Bool {
        // lock→permitの順序はliveと同じ。cancel/revokeが成立した後の新規発行を防ぐ。
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        return permit.ifValid(action)
    }
    #if EGRESS_STREAM_TESTING
    func testingSend(_ bytes: Data, to connection: NWConnection) -> Bool { send(bytes, to: connection) }
    func testingExact(_ size: Int) -> Data? { exact(size) }
    func testingIssue(_ action: () -> Void) -> Bool { issueIfLive(action) }
    #endif
    private func run() {
        defer {
            cancel(); socketLock.lock(); if !guestClosed { guestClosed = true; guest.close() }; socketLock.unlock()
            lock.lock(); workerEnded = true; lock.unlock(); completeIfDone()
        }
        var first = Data()
        if mode == .edge || mode == .authKeys {
            guard let hello = record(until: safetyTime() + 4), EgressPolicy.allowsEdgeHello(hello, authKeys: mode == .authKeys) else { return }
            first = hello
        }
        if mode == .provision {
            var header = Data()
            let deadline = safetyTime() + 3
            while !header.suffix(4).elementsEqual([13,10,13,10]) {
                guard header.count < 4096, let byte = exact(1, until: deadline) else { return }; header += byte
            }
            let expected = protectedProvision ? EgressPolicy.protectedProvisionBody : Data()
            guard EgressPolicy.allowsProvision(header + expected, protected: protectedProvision) else { return }
            if !expected.isEmpty {
                guard let body = exact(expected.count, until: deadline), body == expected else { return }
            }
            first = EgressPolicy.provisioningRequest(protected: protectedProvision)
        }
        guard live else { return }
        let parameters: NWParameters
        if mode == .provision {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, EgressPolicy.provisioningServerName)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let ref = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(ref, SecPolicyCreateSSL(true, EgressPolicy.provisioningServerName as CFString))
                complete(SecTrustEvaluateWithError(ref, nil))
            }, queue)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else { parameters = .tcp }
        let nw = NWConnection(host: host, port: port, using: parameters)
        let ready = DispatchSemaphore(value: 0)
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: ready.signal()
            case .failed: ready.signal(); self.cancel()
            case .cancelled:
                self.lock.lock(); self.networkEnded = true; self.lock.unlock(); ready.signal(); self.completeIfDone()
            default: break
            }
        }
        guard issueIfLive({
            network = nw; networkEnded = false
            nw.start(queue: queue)
        }) else { return }
        let deadline = safetyTime() + 4
        while ready.wait(timeout: .now() + 0.1) != .success { if !live || safetyTime() >= deadline { return } }
        guard live, first.isEmpty || send(first, to: nw) else { return }
        receive(nw)
        if mode == .provision {
            let deadline = safetyTime() + 10
            while live && safetyTime() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            return
        }
        var compatibilityCCS = false
        while live {
            if mode == .edge || mode == .authKeys {
                guard let bytes = record() else { return }
                // TLS1.3の暗号化recordだけ継続。2個目の平文ClientHelloやTLS1.2再交渉は拒否。
                guard EgressPolicy.allowsFollowingRecord(bytes, compatibilityCCSUsed: compatibilityCCS) else { return }
                if bytes[0] == 20 { compatibilityCCS = true }
                guard send(bytes, to: nw) else { return }
            } else {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(guest.fileDescriptor, &buffer, buffer.count)
                if n > 0 { guard live, send(Data(buffer.prefix(n)), to: nw) else { return } }
                else if n == 0 || (errno != EAGAIN && errno != EINTR) { return }
            }
        }
    }
    private func receive(_ nw: NWConnection) {
        guard live else { cancel(); return }
        nw.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self, self.live else { return }
            if var data, !data.isEmpty {
                if self.mode == .authKeys {
                    self.responseBytes += data.count
                    guard self.responseBytes <= 1_114_112 else { self.cancel(); return }
                }
                if self.mode == .provision {
                    self.responseBytes += data.count
                    if self.responseBytes > 65536 { self.cancel(); return }
                    if !self.responseHeaderAccepted {
                        self.responseHeader += data
                        if let end = self.responseHeader.range(of: Data([13,10,13,10])) {
                            guard EgressPolicy.allowsProvisionResponseHeader(self.responseHeader.prefix(end.upperBound)) else { self.cancel(); return }
                            self.responseHeaderAccepted = true; data = self.responseHeader; self.responseHeader = Data()
                        } else {
                            if self.responseHeader.count > 8192 { self.cancel() }
                            else if !done && error == nil { self.receive(nw) }
                            return
                        }
                    }
                }
                self.socketLock.lock()
                let ok = !self.guestClosed && data.withUnsafeBytes { bytes -> Bool in
                    var offset = 0
                    while offset < bytes.count && self.live {
                        let n = Darwin.write(self.guest.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if n <= 0 { return false }; offset += n
                    }
                    return offset == bytes.count
                }
                self.socketLock.unlock()
                if !ok { self.cancel(); return }
            }
            if done || error != nil { self.cancel() } else { self.receive(nw) }
        }
    }
    func cancel() {
        lock.lock(); if closed { lock.unlock(); return }; closed = true
        let nw = network; lock.unlock()
        timer?.cancel(); timer = nil; nw?.cancel()
        socketLock.lock(); if !guestClosed { Darwin.shutdown(guest.fileDescriptor, SHUT_RDWR) }; socketLock.unlock()
    }
    private func completeIfDone() {
        lock.lock()
        let done = workerEnded && networkEnded && !notified
        if done { notified = true }; lock.unlock()
        if done { DispatchQueue.main.async(execute: finished) }
    }
}

private final class EgressSendResult: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var ok: Bool { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}
