import Foundation
import Darwin

func safetyTime() -> Double {
    var value = timespec(); clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
}

@main enum HoneyObsSessionMonitor {
    static func main() {
        umask(0o077); signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try LaunchOptions(arguments: arguments)
            exit(SessionOwnership.launch(arguments, directory: options.directory, announceReady: true))
        } catch { fputs("監視役の起動失敗: \(error)\n", stderr); exit(1) }
    }
}
