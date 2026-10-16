import Foundation
import Darwin

func safetyTime() -> Double {
    var value = timespec(); clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
}

@main enum SessionControlFixture {
    static func main() throws {
        // 実GUIはDispatchSourceSignal用にSIGTERMをignoreしている。子へは継承させない。
        signal(SIGTERM, SIG_IGN)
        let args = CommandLine.arguments
        let canary = open(args[4] + ".canary", O_CREAT | O_RDWR, 0o600)
        defer { close(canary) }
        let start = safetyTime()
        let result = SessionOwnership.testingControl(args[1], arguments: [args[2], args[3], String(canary)])
        try SessionOwnership.save(["status": result.0, "outputBytes": result.1.utf8.count,
            "prefix": String(result.1.prefix(100)), "elapsed": safetyTime() - start,
            "pid": getpid(), "pgid": getpgrp()], URL(fileURLWithPath: args[4]))
    }
}
