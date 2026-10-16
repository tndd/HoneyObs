import Cocoa
import Darwin

private var watchdogStop: sig_atomic_t = 0

func watchdog(_ args: [String]) {
    guard args.count > 5, let parent = Int32(args[2]) else { exit(2) }
    signal(SIGTERM) { _ in watchdogStop = 1 }
    signal(SIGINT) { _ in watchdogStop = 1 }
    signal(SIGPIPE, SIG_IGN)
    let process = Process(); process.executableURL = URL(fileURLWithPath: args[4])
    process.arguments = Array(args.dropFirst(5))
    let output = Pipe()
    process.standardOutput = output; process.standardError = output
    let fd = output.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var logBytes = 0
    func drain() {
        var buf = [UInt8](repeating: 0, count: 8192)
        // ログで監視ループが占有されないよう、1回の回収量も制限する。
        for _ in 0..<8 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return }
            if logBytes + n > 262144 {
                _ = ftruncate(STDOUT_FILENO, 0); _ = lseek(STDOUT_FILENO, 0, SEEK_SET); logBytes = 0
            }
            let data = Data(buf.prefix(n)); try? FileHandle.standardOutput.write(contentsOf: data); logBytes += n
        }
    }
    do { try process.run() } catch { fputs("公開用プロセスの起動失敗\n", stderr); exit(1) }
    let data = try! JSONSerialization.data(withJSONObject: ["watchdogPID":getpid(),"tunnelPID":process.processIdentifier,"parentPID":parent])
    try? data.write(to: URL(fileURLWithPath: args[3]).appendingPathComponent("watchdog.json"), options: .atomic)
    while process.isRunning && watchdogStop == 0 && getppid() == parent { drain(); usleep(100_000) }
    if process.isRunning { process.terminate() }
    for _ in 0..<20 { drain(); if !process.isRunning { break }; usleep(100_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    drain()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine: Engine
    let headless: Bool
    private var window: NSWindow?
    private var dashboard: Dashboard?
    private var exercise: LocalPentest?
    private var sources: [DispatchSourceSignal] = []
    private var statusTimer: Timer?
    private let uiSmoke: Bool
    private let uiPublicSmoke: Bool
    private let dashboardSmoke = CommandLine.arguments.contains("--ui-dashboard-smoke") || CommandLine.arguments.contains("--ui-exercise-smoke")
    private var smokeStage = 0
    private var terminationPending = false

    init(engine: Engine, headless: Bool, uiSmoke: Bool, uiPublicSmoke: Bool) {
        self.engine = engine; self.headless = headless; self.uiSmoke = uiSmoke; self.uiPublicSmoke = uiPublicSmoke
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onChange = { [weak self] in self?.refresh() }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume(); sources.append(source)
        }
        if headless { engine.start(publish: CommandLine.arguments.contains("--public")) }
        else { createWindow() }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func createWindow() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.applicationIconImage = NSImage(contentsOf: engine.resources.appendingPathComponent("AppIcon.icns"))
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let submenu = NSMenu(); submenu.addItem(withTitle: "HoneyObsを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = submenu
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; NSApp.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "HoneyObs — 世界のアクセス"
        window.contentMinSize = NSSize(width: 860, height: 650)
        window.backgroundColor = NSColor(calibratedRed: 0.047, green: 0.094, blue: 0.137, alpha: 1)
        let dashboard = Dashboard(engine: engine)
        let exercise = LocalPentest(engine: engine, dashboard: dashboard)
        self.exercise = exercise
        dashboard.onExerciseStart = { [weak exercise] in exercise?.start() }
        dashboard.onExerciseStop = { [weak exercise] in exercise?.cancel() }
        dashboard.onReady = { [weak self] in
            guard let self else { return }
            if self.uiSmoke { self.dashboard?.testAction("local") }
            if self.uiPublicSmoke { self.dashboard?.testAction("public") }
            if CommandLine.arguments.contains("--ui-exercise-smoke") { self.dashboard?.testAction("exercise") }
        }
        window.contentView = dashboard.webView
        self.dashboard = dashboard; self.window = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    private func refresh() {
        dashboard?.refresh()
        if dashboardSmoke {
            dashboard?.testState()
            let command = engine.directory.appendingPathComponent("ui-command")
            if let value = try? String(contentsOf: command, encoding: .utf8) {
                try? FileManager.default.removeItem(at: command)
                switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "capture": dashboard?.capture(to: engine.directory.appendingPathComponent("ui-capture.png"))
                case "resize": window?.setContentSize(NSSize(width: 860, height: 650))
                case "quit": NSApp.terminate(nil)
                case let action: dashboard?.testAction(action)
                }
            }
        }
        if uiSmoke, engine.phase == "ローカル準備完了", smokeStage == 0 {
            smokeStage = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.dashboard?.capture(to: self.engine.directory.appendingPathComponent("ui-local.png")) {
                    self.dashboard?.testAction("stop")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.dashboard?.capture(to: self.engine.directory.appendingPathComponent("ui-stopped.png")) { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if uiPublicSmoke, engine.phase == "公開中", smokeStage == 0 {
            smokeStage = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.dashboard?.capture(to: self.engine.directory.appendingPathComponent("ui-public.png")) { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if engine.shutdownComplete { return .terminateNow }
        guard !terminationPending else { return .terminateCancel }
        terminationPending = true
        engine.stop(reason: "アプリ終了") { [weak self] success in
            // terminateLaterのネストしたモーダルループでVMの主キュー応答を止めない。
            // 元の終了要求を取り消し、通常ループで回収した後に改めて終了する。
            DispatchQueue.main.async {
                self?.terminationPending = false
                if success { sender.terminate(nil) }
                else {
                    self?.window?.makeKeyAndOrderFront(nil)
                    sender.activate(ignoringOtherApps: true)
                }
            }
        }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct HoneyObs {
    static func main() {
        umask(0o077)
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if args.contains("--watchdog") { watchdog(args); return }
        let headless = args.contains("--headless")
        let directory: URL
        if let i = args.firstIndex(of: "--run-directory"), i+1 < args.count { directory = URL(fileURLWithPath: args[i+1]) }
        else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HoneyObs/検証/" + UUID().uuidString)
        }
        do {
            let engine = try Engine(directory: directory, resources: Bundle.main.resourceURL!)
            let delegate = AppDelegate(engine: engine, headless: headless, uiSmoke: args.contains("--ui-smoke"), uiPublicSmoke: args.contains("--ui-public-smoke"))
            let application = NSApplication.shared
            application.setActivationPolicy(headless ? .prohibited : .regular)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch { fputs("起動失敗: \(error)\n",stderr); exit(1) }
    }
}
