import Foundation
import Network
import Virtualization
import Darwin

// 公開側からVMの固定ポートへの転送だけを行う。任意宛先の接続機能は持たない。
final class Relay {
    private let client: NWConnection
    private let guest: VZVirtioSocketConnection
    private let queue = DispatchQueue(label: "honeyobs.relay")
    private var stopped = false
    private var received = 0
    private let finished: () -> Void

    init(client: NWConnection, guest: VZVirtioSocketConnection, finished: @escaping () -> Void) {
        self.client = client; self.guest = guest; self.finished = finished
    }

    func start() {
        let fd = guest.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        client.start(queue: queue)
        queue.async { self.receive() }
        queue.asyncAfter(deadline: .now() + 6) { self.finish() }
        DispatchQueue.global().async {
            var response = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while response.count <= 65536 {
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { break }
                response.append(contentsOf: buf.prefix(n))
            }
            let data = response
            self.queue.async {
                if self.stopped { self.guest.close(); return }
                if data.count > 65536 || data.isEmpty { self.finish(); self.guest.close(); return }
                self.client.send(content: data, completion: .contentProcessed { _ in
                    self.finish(); self.guest.close()
                })
            }
        }
    }

    private func receive() {
        guard !stopped else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
            guard !self.stopped else { return }
            if let data, !data.isEmpty {
                self.received += data.count
                guard self.received <= 32768 else { self.finish(); return }
                let ok = data.withUnsafeBytes { p -> Bool in
                    var offset = 0
                    while offset < p.count {
                        let n = Darwin.write(self.guest.fileDescriptor, p.baseAddress!.advanced(by: offset), p.count - offset)
                        if n <= 0 { return false }; offset += n
                    }; return true
                }
                if !ok { self.finish(); return }
            }
            if done || error != nil { self.finish() } else { self.receive() }
        }
    }

    private func finish() {
        guard !stopped else { return }; stopped = true
        client.cancel()
        Darwin.shutdown(guest.fileDescriptor, SHUT_RDWR)
        DispatchQueue.main.async { self.finished() }
    }

    func cancel() { queue.async { self.finish() } }
}

// VZのAPIはメインキューで呼び、ブロッキングI/Oは別キューへ逃がす。
func guestRequest(_ machine: VZVirtualMachine, port: UInt32 = 7001, path: String = "/", completion: @escaping (Result<Data, Error>) -> Void) {
    guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
        completion(.failure(NSError(domain: "HoneyObs", code: 1))); return
    }
    device.connect(toPort: port) { result in
        switch result {
        case .failure(let error): completion(.failure(error))
        case .success(let connection):
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
                connection.close()
                let output: Result<Data, Error>
                if response.count <= 262144, let range = response.range(of: Data("\r\n\r\n".utf8)) {
                    output = .success(response.subdata(in: range.upperBound..<response.count))
                } else { output = .failure(NSError(domain: "HoneyObs", code: 2, userInfo: [NSLocalizedDescriptionKey: "VM応答が不正またはタイムアウト"])) }
                DispatchQueue.main.async { completion(output) }
            }
        }
    }
}
