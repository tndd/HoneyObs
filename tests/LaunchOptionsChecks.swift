import Foundation

@main struct LaunchOptionsChecks {
    static func rejected(_ arguments: [String]) {
        do { _ = try LaunchOptions(arguments: arguments); fatalError("検証用引数を拒否しませんでした: \(arguments)") }
        catch {}
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HONEYOBS_PROBE_TARGETS": "127.0.0.1:1234"]
        let normal = try LaunchOptions(arguments: ["HoneyObs"], environment: environment, defaultDirectory: root)
        precondition(!normal.testing && !normal.headless && !normal.dashboardSmoke && normal.probeTargets.isEmpty)
        rejected(["HoneyObs", "--headless"])
        rejected(["HoneyObs", "--allowed-mail", "owner@example.com"])
        rejected(["HoneyObs", "--ui-exercise-smoke", "--run-directory", root.path])
        rejected(["HoneyObs", "--run-directory", root.path])
        rejected(["HoneyObs", "--test-mode"])
        rejected(["HoneyObs", "--test-mode", "--run-directory", "relative"])
        rejected(["HoneyObs", "--test-mode", "--run-directory", root.path, "--run-directory", root.path])
        let run = root.appendingPathComponent("run")
        let options = try LaunchOptions(arguments: ["HoneyObs", "--test-mode", "--ui-exercise-smoke", "--run-directory", run.path], environment: environment)
        precondition(options.testing && options.dashboardSmoke && options.exerciseSmoke && !options.headless)
        precondition(options.probeTargets == "127.0.0.1:1234")
        precondition(options.allowedMail == nil && normal.allowedMail == nil)
        let privateBase = ["HoneyObs", "--test-mode", "--run-directory", run.path]
        let privateOptions = try LaunchOptions(arguments: privateBase + ["--allowed-mail", "owner+qa@example.com"])
        precondition(privateOptions.allowedMail == "owner+qa@example.com")
        rejected(privateBase + ["--allowed-mail"])
        rejected(privateBase + ["--allowed-mail", "owner@example.com", "--allowed-mail", "owner@example.com"])
        for invalid in ["", "*", "*@example.com", "one@example.com,two@example.com", "owner@example.com\n", "a@localhost", "a@-example.com"] {
            rejected(privateBase + ["--allowed-mail", invalid])
        }
        let client = try LaunchOptions(arguments: ["HoneyObs", "--session-client", "--run-directory", run.path], environment: environment)
        precondition(!client.testing && !client.dashboardSmoke && client.probeTargets.isEmpty)
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        rejected(["HoneyObs", "--test-mode", "--run-directory", shared.path])
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: run)
        rejected(["HoneyObs", "--test-mode", "--run-directory", link.path])
        print("通常起動の環境変数無視・明示QA・絶対パス・私有保存先・内部セッションの境界: PASS")
    }
}
