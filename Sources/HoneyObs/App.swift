import Cocoa
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReady: (() -> Void)?
    var onWillTerminate: (() -> Void)?
    let engine: Engine
    let headless: Bool
    private var window: NSWindow?
    private var dashboard: Dashboard?
    private var exercise: LocalPentest?
    private var sources: [DispatchSourceSignal] = []
    private var statusTimer: Timer?
    private let uiSmoke: Bool
    private let uiPublicSmoke: Bool
    private let options: LaunchOptions
    private var dashboardSmoke: Bool { options.dashboardSmoke }
    private var smokeStage = 0
    private var terminationPending = false
    private var lastTestAction = ""

    init(engine: Engine, options: LaunchOptions) {
        self.options = options
        self.engine = engine; self.headless = options.headless; self.uiSmoke = options.uiSmoke; self.uiPublicSmoke = options.uiPublicSmoke
        engine.requiresUIHeartbeat = !options.headless
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onChange = { [weak self] in self?.refresh() }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume(); sources.append(source)
        }
        if headless { engine.start(publish: CommandLine.arguments.contains("--public"), localExercise: options.testing && CommandLine.arguments.contains("--local-origin")); onReady?() }
        else { createWindow() }
        let status = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        statusTimer = status; RunLoop.main.add(status, forMode: .common)
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
            self.onReady?()
            if self.uiSmoke { self.dashboard?.testAction("local") }
            if self.uiPublicSmoke { self.dashboard?.testAction("public") }
            if options.exerciseSmoke { self.dashboard?.testAction("exercise") }
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
        }
        if options.testing {
            if let endpoint = engine.exerciseEndpoint {
                engine.save(["host":endpoint.host],name:"test-origin.json")
            }
            var state = engine.testingSnapshot
            let native: [String:Any] = ["pid":getpid(),"windowMiniaturized":window?.isMiniaturized ?? false,
                         "appHidden":NSApp.isHidden,"windowVisible":window?.isVisible ?? false,
                         "appActive":NSApp.isActive,"activationPolicy":NSApp.activationPolicy().rawValue,
                         "windowKey":window?.isKeyWindow ?? false,"windowNumber":window?.windowNumber ?? 0,
                         "windowStyle":window?.styleMask.rawValue ?? 0,
                         "minimizeEnabled":window?.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false,
                         "lastAction":lastTestAction]
            state.merge(native) { _,new in new }
            if let number = window?.windowNumber,
               let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(number)) as? [[String:Any]],
               let bounds = windows.first?[kCGWindowBounds as String] as? [String:Any] {
                state["windowServerBounds"] = bounds
            }
            state["stageManagerEnabled"] = UserDefaults(suiteName:"com.apple.WindowManager")?.bool(forKey:"GloballyEnabled") ?? false
            engine.save(state,name:"background-state.json")
            let command = engine.directory.appendingPathComponent("ui-command")
            if let value = try? String(contentsOf: command, encoding: .utf8) {
                try? FileManager.default.removeItem(at: command)
                lastTestAction = value.trimmingCharacters(in:.whitespacesAndNewlines)
                switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "local-origin": engine.start(publish:false,localExercise:true)
                case "minimize": window?.performMiniaturize(nil)
                case "restore": window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                case "hide": NSApp.hide(nil)
                case "show": NSApp.unhide(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                case "track-menu":
                    if dashboardSmoke {
                        // status TimerとGCD main blockの両方を抜け、通常のAppKit追跡と同じ再入条件にする。
                        DispatchQueue.main.async { [weak self] in
                            RunLoop.main.perform(inModes:[.default]) { [weak self] in self?.trackMenuForTesting() }
                        }
                    }
                case "stop":
                    if dashboardSmoke { dashboard?.testAction("stop") }
                    else { engine.stop(reason:"検証からの停止") }
                case "capture": dashboard?.capture(to: engine.directory.appendingPathComponent("ui-capture.png"))
                case "resize": window?.setContentSize(NSSize(width: 860, height: 650))
                case "quit": NSApp.terminate(nil)
                case "freeze-main": if dashboardSmoke { Thread.sleep(forTimeInterval:5) }
                case "freeze-ui": if dashboardSmoke { dashboard?.testFreezeUI() }
                case let action: if dashboardSmoke { dashboard?.testAction(action) }
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
        if uiPublicSmoke, ["公開中","公開URL取得済み"].contains(engine.phase), smokeStage == 0 {
            smokeStage = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.dashboard?.capture(to: self.engine.directory.appendingPathComponent("ui-public.png")) { NSApp.terminate(nil) }
            }
        }
    }

    private func trackMenuForTesting() {
        guard options.testing, dashboardSmoke, let view = window?.contentView else { return }
        let menu = NSMenu(title:"HoneyObs QA")
        menu.autoenablesItems = false
        menu.addItem(withTitle:"検証中（4.2秒後に閉じます）",action:nil,keyEquivalent:"")
        let started = safetyTime()
        var samples:[[String:Any]] = [], cancelledByTimer = false
        let sample = Timer(timeInterval:0.2,repeats:true) { [weak self] _ in
            guard let self else { return }
            var value = self.engine.testingSnapshot
            value["mode"] = RunLoop.main.currentMode?.rawValue ?? ""
            value["elapsed"] = safetyTime()-started
            value["active"] = self.engine.isActive
            samples.append(value)
            self.engine.save(["finished":false,"pid":getpid(),"samples":samples],name:"menu-tracking.json")
        }
        let end = Timer(timeInterval:4.2,repeats:false) { _ in cancelledByTimer = true; menu.cancelTracking() }
        RunLoop.main.add(sample,forMode:.common); RunLoop.main.add(end,forMode:.common)
        let shown = menu.popUp(positioning:nil,at:NSPoint(x:80,y:view.bounds.height-70),in:view)
        sample.invalidate(); end.invalidate()
        engine.save(["finished":true,"pid":getpid(),"duration":safetyTime()-started,
                     "popupReturnValue":shown,"cancelledByTimer":cancelledByTimer,"samples":samples],name:"menu-tracking.json")
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
    func applicationWillTerminate(_ notification: Notification) {
        if engine.shutdownComplete { onWillTerminate?() }
    }
}

@main struct HoneyObs {
    static func main() {
        umask(0o077)
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        do {
            let options = try LaunchOptions(arguments: args)
            if args.contains("--test-egress-fixture") {
                guard options.testing else { throw NSError(domain:"HoneyObs.EgressFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"通信VMの模擬接続には検証モードが必要です"]) }
                #if !EGRESS_TESTING
                throw NSError(domain:"HoneyObs.EgressFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"通信VMの模擬接続は検証専用ビルドだけで使用できます"])
                #endif
            }
            if !args.contains("--session-client") {
                exit(options.testing ? SessionOwnership.launch(args, directory: options.directory) : SessionOwnership.handoff(args, directory: options.directory))
            }
            let ownership = try SessionClient(arguments: args, directory: options.directory)
            let engine = try Engine(directory: options.directory, resources: Bundle.main.resourceURL!, testing: options.testing, probeTargets: options.probeTargets, allowedMail: options.allowedMail, qaAccessKey: options.qaAccessKey, requireManagedArchive:!options.testing)
            #if EGRESS_TESTING
            if args.contains("--test-egress-fixture") { try engine.enableEgressTestingFixture() }
            #endif
            ownership.requiresRecovery = { engine.requiresSessionRecovery }
            ownership.onRevoke = { engine.stop(reason: "OS監視の確認期限切れ") }
            let delegate = AppDelegate(engine: engine, options: options)
            delegate.onReady = { [weak ownership] in ownership?.markUIReady() }
            delegate.onWillTerminate = { [weak ownership] in ownership?.finish() }
            let application = NSApplication.shared
            application.setActivationPolicy(options.headless ? .prohibited : .regular)
            application.delegate = delegate
            withExtendedLifetime((delegate, ownership)) {
                application.run()
                if engine.shutdownComplete { ownership.finish() }
            }
        } catch { fputs("起動失敗: \(error)\n",stderr); exit(1) }
    }
}
