import Foundation
import Darwin

func safetyTime() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }

// 所有・相互リースだけを製品コードで検査する。GUI/VM/トンネルは生成しない。
@main struct SessionJobFixture {
    static func main() throws {
        umask(0o077); signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--run-directory"), index + 1 < args.count else { exit(2) }
        let directory = URL(fileURLWithPath: args[index + 1])
        if !args.contains("--session-client") { exit(SessionOwnership.launch(args, directory: directory)) }
        let client = try SessionClient(arguments: args, directory: directory)
        client.requiresRecovery = { FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture-revoke").path) }
        try SessionOwnership.save(["shutdownComplete": true, "vmPresent": false, "pid": getpid()], directory.appendingPathComponent("state.json"))
        client.markUIReady()
        withExtendedLifetime(client) {
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture-quit").path) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try? SessionOwnership.save(["ready":true], directory.appendingPathComponent("finish-started.json"))
            let acknowledged = client.finish()
            try? SessionOwnership.save(["acknowledged":acknowledged], directory.appendingPathComponent("finish-result.json"))
        }
    }
}
