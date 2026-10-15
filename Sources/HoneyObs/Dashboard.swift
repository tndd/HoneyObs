import Cocoa
import WebKit

// 描画にはmacOS同梱WebKitを使う。画面・地図はバンドル内のみ、接続はEngineだけが担当する。
final class Dashboard: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private let engine: Engine
    private let geo: GeoIP
    private let documentURL: URL
    private var ready = false
    private var lastPayload = Data()
    var onReady: (() -> Void)?

    init(engine: Engine) {
        self.engine = engine
        geo = GeoIP(resources: engine.resources)
        documentURL = engine.resources.appendingPathComponent("Dashboard/index.html")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "honeyobs")
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = NSColor(calibratedRed: 0.047, green: 0.094, blue: 0.137, alpha: 1)
        webView.loadFileURL(documentURL, allowingReadAccessTo: documentURL.deletingLastPathComponent())
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == documentURL.standardizedFileURL,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready": ready = true; refresh(); onReady?()
        case "start-local": engine.start(publish: false)
        case "start-public": engine.start(publish: true)
        case "stop": engine.stop(reason: "停止ボタン")
        case "copy-url":
            if engine.isActive, !engine.publicURL.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(engine.publicURL, forType: .string)
            }
        default: break
        }
    }

    func refresh() {
        guard ready else { return }
        let payload: [String: Any] = ["session": engine.sessionID, "phase": engine.phase,
            "active": engine.isActive, "canStart": engine.canStart, "url": engine.publicURL,
            "detail": engine.detail, "total": engine.eventCount,
            "events": engine.events.reversed().map { $0.presentation(geo: geo) },
            "geoAvailable": geo.available, "geoEdition": GeoIP.edition]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), data != lastPayload else { return }
        lastPayload = data
        // リクエスト文字列をコードとして連結せず、構造化された引数で渡す。
        webView.callAsyncJavaScript("window.honeyobs.update(state)", arguments: ["state": payload], in: nil, in: .page) { [weak self] result in
            if case .failure = result { self?.lastPayload = Data() }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url?.standardizedFileURL == documentURL.standardizedFileURL {
            decisionHandler(.allow); return
        }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           ["https://db-ip.com", "https://www.naturalearthdata.com"].contains(url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func capture(to url: URL, completion: (() -> Void)? = nil) {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { image, _ in
            if let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            completion?()
        }
    }

    // --ui-dashboard-smoke指定時だけ使う検証経路。公開・停止は通常画面と同じボタンを通す。
    func testAction(_ action: String) {
        let scripts = ["public": "document.querySelector('#toggle').click()",
                       "local": "document.querySelector('#local').click()",
                       "stop": "document.querySelector('#toggle').click()",
                       "first": "document.querySelector('.event')?.click()",
                       "last": "document.querySelector('#events li:last-child .event')?.click()"]
        if let script = scripts[action] { webView.evaluateJavaScript(script) }
    }

    func testState() {
        guard ready else { return }
        let script = """
        (() => ({ phase:document.querySelector('#phase').textContent,
          count:document.querySelector('#count').textContent,
          country:document.querySelector('#country').textContent,
          request:document.querySelector('#request').textContent,
          ip:document.querySelector('#ip').textContent,
          location:document.querySelector('#location').textContent,
          rows:document.querySelectorAll('.event').length,
          selected:document.querySelector('.event[aria-pressed=true]')?.dataset.id || '',
          routes:document.querySelectorAll('.route').length,
          packets:document.querySelectorAll('.packet').length,
          canStart:!document.querySelector('#local').disabled,
          url:document.querySelector('#url').textContent,
          width:innerWidth,height:innerHeight,
          overflow:document.documentElement.scrollWidth>innerWidth }))()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let value else { return }
            self.engine.save(value, name: "ui-state.json")
        }
    }
}
