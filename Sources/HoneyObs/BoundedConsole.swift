import Foundation
import Darwin

// VMのシリアル出力を直接ファイルへ渡さず、固定量のリングとして保存する。
final class BoundedConsole {
    let writer: FileHandle
    private let reader: FileHandle, output: FileHandle
    private let queue = DispatchQueue(label:"HoneyObs.console",qos:.utility)
    private var timer: DispatchSourceTimer?
    private var bytes = 0, closing = false, failed = false
    private let limit: Int
    private let onFailure: ((Error) -> Void)?
    init(url: URL, limit: Int = 262144, onFailure: ((Error) -> Void)? = nil) throws {
        self.limit = max(limit,8192); self.onFailure = onFailure
        let fd = Darwin.open(url.path,O_CREAT|O_TRUNC|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        output = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        let pipe = Pipe(); writer = pipe.fileHandleForWriting; reader = pipe.fileHandleForReading
        _ = fcntl(reader.fileDescriptor,F_SETFL,fcntl(reader.fileDescriptor,F_GETFL)|O_NONBLOCK)
        let timer = DispatchSource.makeTimerSource(queue:queue); self.timer = timer
        timer.schedule(deadline:.now(),repeating:.milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }; timer.resume()
    }
    private func drain() {
        var buffer = [UInt8](repeating:0,count:8192)
        do {
            for _ in 0..<8 {
                let n = Darwin.read(reader.fileDescriptor,&buffer,buffer.count)
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { return }; throw POSIXError(.EIO)
                }
                if n == 0 { return }
                if failed { continue }
                if bytes+n > limit { try output.truncate(atOffset:0); try output.seek(toOffset:0); bytes = 0 }
                try output.write(contentsOf:Data(buffer.prefix(n))); bytes += n
            }
        } catch {
            if !failed { failed = true; DispatchQueue.main.async { [onFailure] in onFailure?(error) } }
        }
    }
    // VM停止後に呼ぶ。最終drainと全FDの解放後に主キューで応答する。
    func close(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            guard !closing else { DispatchQueue.main.async(execute:completion); return }
            closing = true
            try? writer.close(); drain(); timer?.cancel(); timer = nil
            try? reader.close(); try? output.close()
            DispatchQueue.main.async(execute:completion)
        }
    }
    deinit { timer?.cancel(); try? writer.close(); try? reader.close(); try? output.close() }
}
