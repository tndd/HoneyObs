import Foundation
import Darwin

// 検証用操作は明示した私有ディレクトリ内だけで有効にする。
// 通常起動では環境変数から通信検査の対象や画面操作を受け取らない。
struct LaunchOptions {
    let testing: Bool
    let directory: URL
    let headless: Bool
    let uiSmoke: Bool
    let uiPublicSmoke: Bool
    let dashboardSmoke: Bool
    let exerciseSmoke: Bool
    let probeTargets: String

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
         defaultDirectory: URL? = nil) throws {
        testing = arguments.contains("--test-mode")
        let restricted = ["--headless", "--public", "--local-origin", "--ui-smoke", "--ui-public-smoke", "--ui-dashboard-smoke", "--ui-exercise-smoke"]
        guard testing || !restricted.contains(where: arguments.contains) else {
            throw Self.invalid("検証用フラグには --test-mode と私有の --run-directory が必要です")
        }
        let indices = arguments.indices.filter { arguments[$0] == "--run-directory" }
        let internalSession = arguments.contains("--session-owner") || arguments.contains("--session-client")
        if testing || !indices.isEmpty {
            guard testing || internalSession else { throw Self.invalid("通常起動では保存先の検証用変更を受け付けません") }
            guard indices.count == 1, let index = indices.first, index + 1 < arguments.count,
                  arguments[index + 1].hasPrefix("/") else {
                throw Self.invalid("--run-directory は絶対パスで一度だけ指定してください")
            }
            directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
            try Self.preparePrivateDirectory(directory)
        } else {
            directory = defaultDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HoneyObs/検証/" + UUID().uuidString, isDirectory: true)
        }
        headless = testing && arguments.contains("--headless")
        uiSmoke = testing && arguments.contains("--ui-smoke")
        uiPublicSmoke = testing && arguments.contains("--ui-public-smoke")
        exerciseSmoke = testing && arguments.contains("--ui-exercise-smoke")
        dashboardSmoke = testing && (arguments.contains("--ui-dashboard-smoke") || exerciseSmoke)
        probeTargets = testing ? environment["HONEYOBS_PROBE_TARGETS"] ?? "" : ""
    }

    private static func preparePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw invalid("検証用保存先を確認できません") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw invalid("検証用保存先には所有者だけが使用できる0700の実ディレクトリが必要です")
        }
    }

    private static func invalid(_ message: String) -> Error {
        NSError(domain: "HoneyObs.LaunchOptions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
