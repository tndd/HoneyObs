import Cocoa
import Darwin

private var watchdogStop: sig_atomic_t = 0

// 通常表示とビュー単体の画像取得で、同じ不透明な背景を描く。
final class WindowSurface: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

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
    private let status = NSTextField(labelWithString: "停止中")
    private let url = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: "受信: 0件")
    private var sources: [DispatchSourceSignal] = []
    private var statusTimer: Timer?
    private let uiSmoke: Bool
    private let uiPublicSmoke: Bool
    private var smokeStage = 0
    private var localButton: NSButton!
    private var publicButton: NSButton!
    private var stopButton: NSButton!

    init(engine: Engine, headless: Bool, uiSmoke: Bool, uiPublicSmoke: Bool) { self.engine = engine; self.headless = headless; self.uiSmoke = uiSmoke; self.uiPublicSmoke = uiPublicSmoke }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onChange = { [weak self] in self?.refresh() }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.engine.stop(reason: "終了シグナル"); DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) } }
            source.resume(); sources.append(source)
        }
        if headless {
            engine.start(publish: CommandLine.arguments.contains("--public"))
        } else {
            createWindow()
            if uiSmoke { localButton.performClick(nil) }
            if uiPublicSmoke { publicButton.performClick(nil) }
        }
        // 操作不能を防ぐため、状態保存の成否とは独立してUIを更新する。
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func createWindow() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let submenu = NSMenu(); submenu.addItem(withTitle: "HoneyObsを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = submenu; NSApp.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 390), styleMask: [.titled,.closable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "HoneyObs — 内蔵VM・一時公開の技術検証"
        window.contentView = WindowSurface(frame: NSRect(x: 0, y: 0, width: 660, height: 390))
        let heading = NSTextField(labelWithString: "HoneyObs")
        heading.font = .systemFont(ofSize: 28, weight: .semibold)
        status.font = .systemFont(ofSize: 20, weight: .medium)
        url.isSelectable = true; url.lineBreakMode = .byTruncatingMiddle
        info.maximumNumberOfLines = 4
        let caption = NSTextField(wrappingLabelWithString: "内蔵Linux VMで模擬応答を返します。VMにネットワーク機器・共有フォルダはありません。一時公開にはCloudflareを利用します。地図は今回の試作に含みません。")
        caption.textColor = .secondaryLabelColor
        localButton = NSButton(title: "ローカル検証", target: self, action: #selector(localStart))
        publicButton = NSButton(title: "一時公開を開始", target: self, action: #selector(publicStart))
        stopButton = NSButton(title: "停止", target: self, action: #selector(stop))
        let buttons = NSStackView(views: [localButton,publicButton,stopButton]); buttons.spacing = 12
        let stack = NSStackView(views: [heading,caption,status,url,count,info,buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26)])
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    @objc private func localStart() { engine.start(publish: false) }
    @objc private func publicStart() { engine.start(publish: true) }
    @objc private func stop() { engine.stop(reason: "停止ボタン") }

    private func refresh() {
        status.stringValue = engine.phase; url.stringValue = engine.publicURL.isEmpty ? "公開URLなし" : engine.publicURL
        info.stringValue = engine.detail; count.stringValue = "受信: \(engine.eventCount)件（確認用アクセスを含む）"
        let canStart = engine.phase == "停止中" || engine.phase == "エラー"
        localButton?.isEnabled = canStart; publicButton?.isEnabled = canStart; stopButton?.isEnabled = !canStart
        if uiSmoke, engine.phase == "ローカル準備完了", smokeStage == 0 {
            smokeStage = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.capture("ui-local.png"); self.stopButton.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.capture("ui-stopped.png"); NSApp.terminate(nil) }
            }
        }
        if uiPublicSmoke, engine.phase == "公開中", smokeStage == 0 {
            smokeStage = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.capture("ui-public.png"); NSApp.terminate(nil)
            }
        }
    }

    private func capture(_ name: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: engine.directory.appendingPathComponent(name))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        engine.stop(reason: "アプリ終了")
        // プロセス終了でVMも破棄される。トンネルの回収は親の死を検出する監視プロセスに任せる。
        return .terminateNow
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
