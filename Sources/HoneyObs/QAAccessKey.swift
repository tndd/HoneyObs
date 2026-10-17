import Foundation
import CryptoKit
import Darwin

// 検証用seedを引数・環境・ログへ載せず読み、起動ごとのHost値に鍵を結び付ける。
struct QAAccessKey {
    private let seed: Data
    init(file: URL, directory: URL) throws {
        guard file.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw Self.invalid()
        }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Self.invalid() }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1, info.st_size == 32 else { throw Self.invalid() }
        var bytes = [UInt8](repeating: 0, count: 33)
        guard Darwin.read(fd, &bytes, bytes.count) == 32 else { throw Self.invalid() }
        seed = Data(bytes.prefix(32))
    }
    func derived(for originHost: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(("HoneyObs QA v1\0" + originHost).utf8), using: SymmetricKey(data: seed)))
    }
    private static func invalid() -> Error {
        NSError(domain: "HoneyObs.QAAccessKey", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "検証鍵にはrun-directory直下の所有者専用0600・単一リンク・32バイトの実ファイルが必要です"])
    }
}
