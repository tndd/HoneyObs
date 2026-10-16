import Foundation
import Darwin

func safetyTime() -> Double {
    var value = timespec(); clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
}

@main enum HoneyObsSessionMonitor {
    static func main() {
        umask(0o077); signal(SIGPIPE, SIG_IGN)
        SessionOwnership.monitor(CommandLine.arguments)
    }
}
