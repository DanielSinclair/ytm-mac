import AppKit
import WebKit

let homeURL = URL(string: "https://music.youtube.com")!
// Safari UA: Google rejects sign-in from unknown embedded browsers.
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

/// Remembers the last mouse-down so a nav-bar drag (reported from JS) can move the window.
final class PlayerWebView: WKWebView {
    var lastMouseDown: NSEvent?
    override func mouseDown(with event: NSEvent) { lastMouseDown = event; super.mouseDown(with: event) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler {
    var window: NSWindow!
    var webView: PlayerWebView!
    var nowPlaying: NowPlaying!
    let cookies = CookieImport()
    var sheetOpen = false
    var silentReloginTried = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent: cookies, HTTP cache, service worker
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.inactiveSchedulingPolicy = .none // keep playing when hidden/occluded
        if let url = Bundle.main.url(forResource: "inject", withExtension: "js"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        webView = PlayerWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        nowPlaying = NowPlaying(webView: webView)
        config.userContentController.add(nowPlaying, name: "ytm")
        config.userContentController.add(self, name: "ytmWindow")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "YouTube Music"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Main")
        window.makeKeyAndOrderFront(nil)

        buildMenu()

        webView.load(URLRequest(url: homeURL))
        Task { @MainActor in
            let store = config.websiteDataStore.httpCookieStore
            if await !cookies.hasSession(in: store), !UserDefaults.standard.bool(forKey: "OnboardingDone") {
                await showOnboarding()
            }
        }
    }

    func showOnboarding(_ reason: Onboarding.Reason = .firstRun) async {
        guard !sheetOpen else { return }
        sheetOpen = true
        defer { sheetOpen = false }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let imported = await Onboarding.present(on: window, cookies: cookies, store: store, reason: reason)
        UserDefaults.standard.set(true, forKey: "OnboardingDone")
        if imported { webView.load(URLRequest(url: homeURL)) }
    }

    /// The page reports YTM's own login state. When a session we imported dies
    /// (Google rotated or revoked it), first re-import the browser's latest
    /// cookies silently; if the page is still signed out after that, ask.
    func authChanged(signedIn: Bool) {
        let d = UserDefaults.standard
        if signedIn {
            silentReloginTried = false
            d.set(false, forKey: "SignedOutByUser")
            return
        }
        guard !d.bool(forKey: "SignedOutByUser"), !sheetOpen else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        guard let source = cookies.lastSource, !silentReloginTried else {
            // Still holding session cookies the page rejects = a dead session, not a
            // user who chose to browse signed out.
            Task { if await cookies.hasSession(in: store) { await showOnboarding(.signedOut) } }
            return
        }
        silentReloginTried = true
        Task {
            if (try? await cookies.importSession(from: source, into: store, interactive: false)) != nil {
                webView.load(URLRequest(url: homeURL))
            } else {
                await showOnboarding(.signedOut)
            }
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.body as? String {
        case "drag": if let e = webView.lastMouseDown { window.performDrag(with: e) }
        case "zoom": window.performZoom(nil)
        case "auth:signedIn": authChanged(signedIn: true)
        case "auth:signedOut": authChanged(signedIn: false)
        default: break
        }
    }

    func windowDidEnterFullScreen(_ n: Notification) { webView.evaluateJavaScript("document.documentElement.classList.add('ytm-fullscreen')") }
    func windowDidExitFullScreen(_ n: Notification) { webView.evaluateJavaScript("document.documentElement.classList.remove('ytm-fullscreen')") }

    // Background playback: closing hides; Dock click re-shows.
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }

    // Keep YouTube/Google in-app; send everything else to the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let host = url.host?.lowercased(),
              action.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }
        // A deliberate sign-out must not trigger the automatic re-login.
        if url.absoluteString.range(of: "logout", options: .caseInsensitive) != nil {
            UserDefaults.standard.set(true, forKey: "SignedOutByUser")
        }
        let inApp = ["youtube.com", "google.com", "gstatic.com", "googleusercontent.com", "youtu.be"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
        if inApp || url.scheme == "about" { decisionHandler(.allow) }
        else { NSWorkspace.shared.open(url); decisionHandler(.cancel) }
    }

    // target=_blank links.
    func webView(_ webView: WKWebView, createWebViewWith c: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()
        func item(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
            NSMenuItem(title: title, action: sel, keyEquivalent: key)
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.submenu = m
            main.addItem(i); return i
        }

        _ = submenu("YouTube Music", [
            item("About YouTube Music", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Import Login from Browser…", #selector(importLogin)),
            item("Settings…", #selector(openSettings), ","),
            .separator(),
            item("Hide YouTube Music", #selector(NSApplication.hide(_:)), "h"),
            item("Quit YouTube Music", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "Z"), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = submenu("View", [
            item("Reload", #selector(reload), "r"),
            item("Back", #selector(goBack), "["), item("Forward", #selector(goForward), "]"),
        ])
        let arrow = { (c: Int) in String(Character(UnicodeScalar(c)!)) }
        _ = submenu("Controls", [
            item("Play/Pause", #selector(togglePlay)), // Space is handled by the page itself
            item("Next", #selector(next), arrow(NSRightArrowFunctionKey)),
            item("Previous", #selector(previous), arrow(NSLeftArrowFunctionKey)),
            .separator(),
            item("Volume Up", #selector(volumeUp), arrow(NSUpArrowFunctionKey)),
            item("Volume Down", #selector(volumeDown), arrow(NSDownArrowFunctionKey)),
        ])
        let win = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Show Player", #selector(showPlayer), "0"),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = win.submenu
    }

    func js(_ s: String) { webView.evaluateJavaScript("window.__ytm && window.__ytm.\(s); 0") }
    @objc func togglePlay() { js("toggle()") }
    @objc func next() { js("next()") }
    @objc func previous() { js("previous()") }
    @objc func volumeUp() { js("volume(10)") }
    @objc func volumeDown() { js("volume(-10)") }
    @objc func reload() { webView.reload() }
    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func showPlayer() { window.makeKeyAndOrderFront(nil) }
    @objc func openSettings() { showPlayer(); js("settings()") }
    @objc func importLogin() { Task { await showOnboarding() } }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
