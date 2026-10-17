import Foundation
import Network
import Virtualization
import Darwin

// スリープ中も進む単調時計。壁時計の変更で許可を延命しない。
func safetyTime() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }

// 上流の確認時刻に期限を結び付け、一度の失効を不可逆にする。
final class ForwardingPermit {
    private let lock = NSLock()
    private let clock: () -> Double
    private var until: Double
    private var revoked = false
    init(confirmedAt: Double, clock: @escaping () -> Double = safetyTime) {
        self.clock = clock; until = confirmedAt + 3
    }
    var valid: Bool {
        lock.lock(); defer { lock.unlock() }
        if clock() >= until { revoked = true }; return !revoked
    }
    // 短い非同期I/Oの発行だけを行う。actionからこの許可へ再入しない。
    func ifValid(_ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if clock() >= until { revoked = true }
        guard !revoked else { return false }
        action(); return true
    }
    var deadline: Double { lock.lock(); defer { lock.unlock() }; return until }
    func renew(confirmedAt: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if now >= until || confirmedAt + 3 <= now { revoked = true }
        guard !revoked else { return false }
        until = min(now + 3, confirmedAt + 3); return true
    }
    func revoke() { lock.lock(); revoked = true; lock.unlock() }
}

// 公開側からVMの固定ポートへの転送だけを行う。任意宛先の接続機能は持たない。
final class Relay {
    private let client: NWConnection
    private let guest: VZVirtioSocketConnection
    private let queue = DispatchQueue(label: "honeyobs.relay")
    private var stopped = false
    private var received = 0
    private let permit: ForwardingPermit?
    private var permitTimer: DispatchSourceTimer?
    private let guestLock = NSLock()
    private var guestClosed = false
    private var readerFinished = false
    private var clientCancelled = false
    private var completionSent = false
    private var rejectionReason: String?
    private let scheduleRead: (@escaping () -> Void) -> Void
    private func closeGuest() {
        guestLock.lock(); defer { guestLock.unlock() }
        if !guestClosed { guestClosed = true; guest.close() }
    }
    private func shutGuest() {
        guestLock.lock(); defer { guestLock.unlock() }
        if !guestClosed { Darwin.shutdown(guest.fileDescriptor, SHUT_RDWR) }
    }
    private var permitted: Bool { permit?.valid ?? true }

    private let finished: () -> Void
    private let rejected: (String) -> Void

    init(client: NWConnection, guest: VZVirtioSocketConnection, permit: ForwardingPermit? = nil, rejected: @escaping (String) -> Void = { _ in },
         scheduleRead: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global().async(execute: DispatchWorkItem(block: $0)) }, finished: @escaping () -> Void) {
        self.client = client; self.guest = guest; self.permit = permit; self.finished = finished; self.rejected = rejected; self.scheduleRead = scheduleRead
    }

    func start() {
        if permit != nil {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, !self.permitted else { return }
                self.client.cancel(); self.shutGuest()
                self.queue.async { self.finish(reason: "permit_expired") }
            }
            permitTimer = timer; timer.resume()
        }
        let fd = guest.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .cancelled = state {
                self.clientCancelled = true; self.finish(reason: self.permitted ? nil : "permit_expired"); self.completeIfClosed()
            }
        }
        client.start(queue: queue)
        queue.async { self.receive() }
        queue.asyncAfter(deadline: .now() + 6) { self.finish(reason: "relay_timeout") }
        scheduleRead {
            var response = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while response.count <= 65536 {
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { break }
                response.append(contentsOf: buf.prefix(n))
            }
            let data = response
            self.queue.async {
                self.readerFinished = true
                if self.stopped { self.closeGuest(); self.completeIfClosed(); return }
                if !self.permitted { self.finish(reason: "permit_expired"); return }
                if data.count > 65536 || data.isEmpty { self.finish(); return }
                self.client.send(content: data, completion: .contentProcessed { _ in
                    self.finish()
                })
            }
        }
    }

    private func receive() {
        guard !stopped, permitted else { finish(reason: "permit_expired"); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
            guard !self.stopped, self.permitted else { self.finish(reason: "permit_expired"); return }
            if let data, !data.isEmpty {
                self.received += data.count
                guard self.received <= 32768 else { self.finish(reason: "relay_input_limit"); return }
                let ok = data.withUnsafeBytes { p -> Bool in
                    var offset = 0
                    while offset < p.count {
                        guard self.permitted else { return false }
                        let n = Darwin.write(self.guest.fileDescriptor, p.baseAddress!.advanced(by: offset), p.count - offset)
                        if n <= 0 { return false }; offset += n
                    }; return true
                }
                if !ok { self.finish(); return }
            }
            if done || error != nil { self.finish() } else { self.receive() }
        }
    }

    private func finish(reason: String? = nil) {
        guard !stopped else { return }; stopped = true
        rejectionReason = reason
        client.cancel()
        permitTimer?.cancel(); permitTimer = nil
        shutGuest()
        // 読取worker終了後、書込と同じ直列キューでFDを閉じる。
        if readerFinished { closeGuest() }
        completeIfClosed()
    }

    private func completeIfClosed() {
        guard stopped, readerFinished, guestClosed, clientCancelled, !completionSent else { return }
        completionSent = true
        DispatchQueue.main.async { if let reason = self.rejectionReason { self.rejected(reason) }; self.finished() }
    }

    func cancel() { client.cancel(); shutGuest(); queue.async { self.finish() } }
}

// shutdownとcloseの排他によりFD再利用先への操作を防ぐ。closeはI/O完了後だけ行う。
final class GuestRead {
    private let lock = NSLock()
    private var connection: VZVirtioSocketConnection?
    private var cancelled = false
    func attach(_ value: VZVirtioSocketConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { value.close(); return false }
        connection = value; return true
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }; cancelled = true
        if let connection { _ = shutdown(connection.fileDescriptor,SHUT_RDWR) }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }; connection?.close(); connection = nil
    }
}

// VZのAPIはメインキューで呼び、ブロッキングI/Oは別キューへ逃がす。
@discardableResult func guestRequest(_ machine: VZVirtualMachine, port: UInt32 = 7001, path: String = "/", completion: @escaping (Result<Data, Error>) -> Void) -> GuestRead {
    let operation = GuestRead()
    guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
        completion(.failure(NSError(domain: "HoneyObs", code: 1))); return operation
    }
    device.connect(toPort: port) { result in
        switch result {
        case .failure(let error): completion(.failure(error))
        case .success(let connection):
            guard operation.attach(connection) else {
                completion(.failure(NSError(domain:"HoneyObs",code:4,userInfo:[NSLocalizedDescriptionKey:"観測要求を中止しました"]))); return
            }
            DispatchQueue.global().async {
                let fd = connection.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var noSig: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
                let request = Data("GET \(path) HTTP/1.0\r\nHost: control\r\nConnection: close\r\n\r\n".utf8)
                let written = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                var response = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                if written == request.count {
                    while response.count <= 262144 {
                        let n = Darwin.read(fd, &buf, buf.count)
                        if n <= 0 { break }; response.append(contentsOf: buf.prefix(n))
                    }
                }
                operation.close()
                let output: Result<Data, Error>
                if response.count <= 262144, let range = response.range(of: Data("\r\n\r\n".utf8)) {
                    output = .success(response.subdata(in: range.upperBound..<response.count))
                } else { output = .failure(NSError(domain: "HoneyObs", code: 2, userInfo: [NSLocalizedDescriptionKey: "VM応答が不正またはタイムアウト"])) }
                DispatchQueue.main.async { completion(output) }
            }
        }
    }
    return operation
}
