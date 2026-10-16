import Cocoa
import Darwin

func safetyTime() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }

private final class MenuDelegate: NSObject, NSApplicationDelegate {
    let client: SessionClient, directory: URL, freeze: Bool
    var window: NSWindow?, opener: Timer?
    init(client: SessionClient, directory: URL, freeze: Bool) {
        self.client = client; self.directory = directory; self.freeze = freeze
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HoneyObs メニュー期限検査"; window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window; NSApp.activate(ignoringOtherApps: true); client.markUIReady()
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in self?.exercise() }
        opener = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func exercise() {
        try? SessionOwnership.save(["started":true], directory.appendingPathComponent("tracking-started.json"))
        if freeze { Thread.sleep(forTimeInterval: 4.5); NSApp.terminate(nil); return }
        let menu = NSMenu(title: "期限検査")
        menu.addItem(withTitle: "このメニューを4.2秒保持", action: nil, keyEquivalent: "")
        var modes: [String:Int] = [:]
        let witness = Timer(timeInterval: 0.05, repeats: true) { _ in
            modes[RunLoop.current.currentMode?.rawValue ?? "nil", default: 0] += 1
            try? SessionOwnership.save(modes, self.directory.appendingPathComponent("tracking-modes.json"))
        }
        let closer = Timer(timeInterval: 4.2, repeats: false) { _ in menu.cancelTracking() }
        RunLoop.main.add(witness, forMode: .common); RunLoop.main.add(closer, forMode: .common)
        let selected = menu.popUp(positioning: nil, at: NSPoint(x: 20, y: 60), in: window?.contentView)
        witness.invalidate(); closer.invalidate()
        try? SessionOwnership.save(["returned":true,"selectionMade":selected,"modes":modes], directory.appendingPathComponent("tracking-finished.json"))
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        try? SessionOwnership.save(["acknowledged":client.finish()], directory.appendingPathComponent("finish-result.json"))
    }
}

@main struct MenuSessionFixture {
    static func main() throws {
        umask(0o077); signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--run-directory"), index + 1 < args.count else { exit(2) }
        let directory = URL(fileURLWithPath: args[index + 1])
        if !args.contains("--session-client") { exit(SessionOwnership.launch(args, directory: directory)) }
        let client = try SessionClient(arguments: args, directory: directory)
        try SessionOwnership.save(["shutdownComplete":true,"vmPresent":false], directory.appendingPathComponent("state.json"))
        let delegate = MenuDelegate(client: client, directory: directory, freeze: args.contains("--fixture-main-freeze"))
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
