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
    let allowedMail: String?
    let qaAccessKey: QAAccessKey?

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
         defaultDirectory: URL? = nil) throws {
        testing = arguments.contains("--test-mode")
        let restricted = ["--headless", "--public", "--local-origin", "--ui-smoke", "--ui-public-smoke", "--ui-dashboard-smoke", "--ui-exercise-smoke", "--allowed-mail", "--qa-key-file"]
        guard testing || !restricted.contains(where: arguments.contains) else {
            throw Self.invalid("検証用フラグには --test-mode と私有の --run-directory が必要です")
        }
        let mailIndices = arguments.indices.filter { arguments[$0] == "--allowed-mail" }
        if let index = mailIndices.first {
            guard mailIndices.count == 1, index + 1 < arguments.count, EgressPolicy.validRecipient(arguments[index + 1]) else {
                throw Self.invalid("本人限定の認証先には単一のメールアドレスが必要です")
            }
            allowedMail = arguments[index + 1]
        } else { allowedMail = nil }
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
            if let defaultDirectory { directory = defaultDirectory }
            else {
                let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                    .appendingPathComponent("HoneyObs/Sessions",isDirectory:true)
                directory = try SessionArchive.makeDirectory(root:root)
            }
        }
        let keyIndices = arguments.indices.filter { arguments[$0] == "--qa-key-file" }
        if let index = keyIndices.first {
            guard testing, arguments.contains("--public"), !arguments.contains("--local-origin"), allowedMail == nil,
                  keyIndices.count == 1, index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
                throw Self.invalid("検証鍵は明示した公開QAで一度だけ指定し、メール方式とは併用できません")
            }
            qaAccessKey = try QAAccessKey(file: URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL, directory: directory)
        } else { qaAccessKey = nil }
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
