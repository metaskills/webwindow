import Cocoa
import WebKit

let defaultURL = "https://www.twitch.tv"
let lastURLKey = "LastURL"

// Overlay bar shown on hover at the top edge. Dragging it moves the window.
final class HoverBar: NSVisualEffectView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .titlebar
        blendingMode = .withinWindow
        state = .active
        label.font = .titleBarFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 80),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -80),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
}

// Container that watches the mouse and toggles the hover bar.
final class RootView: NSView {
    let bar: HoverBar
    static let barHeight: CGFloat = 28
    static let triggerHeight: CGFloat = 6
    var barShown = false

    init(webView: WKWebView) {
        bar = HoverBar(frame: .zero)
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        addSubview(bar)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: RootView.barHeight),
        ])
        bar.alphaValue = 0
        bar.isHidden = true
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); setButtons(hidden: true) }

    override func mouseMoved(with event: NSEvent) {
        let fromTop = bounds.height - convert(event.locationInWindow, from: nil).y
        if !barShown && fromTop <= RootView.triggerHeight { show(true) }
        else if barShown && fromTop > RootView.barHeight { show(false) }
    }
    override func mouseExited(with event: NSEvent) { if barShown { show(false) } }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func show(_ on: Bool) {
        if on && isFullScreen { return }
        barShown = on
        if on { bar.isHidden = false }
        setButtons(hidden: !on)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            bar.animator().alphaValue = on ? 1 : 0
        }, completionHandler: { [weak self] in
            if let self, !self.barShown { self.bar.isHidden = true }
        })
    }

    func setButtons(hidden: Bool) {
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(b)?.isHidden = hidden
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var root: RootView!
    var titleObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        guard let url = askForURL() else { NSApp.terminate(nil); return }
        openWindow(with: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func locationAlert(_ initial: String, cancelTitle: String) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = "Open Location"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: cancelTitle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return (alert, field)
    }

    func url(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = defaultURL }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return URL(string: defaultURL) }
        UserDefaults.standard.set(text, forKey: lastURLKey)
        return url
    }

    func askForURL() -> URL? {
        let (alert, field) = locationAlert(
            UserDefaults.standard.string(forKey: lastURLKey) ?? defaultURL, cancelTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return url(from: field.stringValue)
    }

    // Cmd+L: ask for a new location as a sheet over the current page.
    @objc func openLocation(_ sender: Any?) {
        guard let window, let webView else { return }
        let (alert, field) = locationAlert(webView.url?.absoluteString ?? defaultURL, cancelTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let url = self?.url(from: field.stringValue) else { return }
            webView.load(URLRequest(url: url))
        }
        field.selectText(nil)
    }

    func openWindow(with url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent cookies, cache, local storage
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.acceptsMouseMovedEvents = true
        root = RootView(webView: webView)
        window.contentView = root
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.title = url.host ?? "WebWindow"
        root.bar.label.stringValue = window.title
        titleObservation = webView.observe(\.title) { [weak self] wv, _ in
            if let t = wv.title, !t.isEmpty { self?.window.title = t; self?.root.bar.label.stringValue = t }
        }
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: url))
    }

    // Links that want a new window open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    @objc func reload(_ sender: Any?) { webView?.reload() }
    @objc func goBack(_ sender: Any?) { webView?.goBack() }
    @objc func goForward(_ sender: Any?) { webView?.goForward() }

    // Hidden-ish menu so standard shortcuts (copy/paste, quit, reload, back) work.
    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(); let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }; item.submenu = m; main.addItem(item)
        }
        func mi(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        sub("App", [mi("Hide", #selector(NSApplication.hide(_:)), "h"),
                    mi("Quit", #selector(NSApplication.terminate(_:)), "q")])
        sub("File", [mi("Open Location...", #selector(openLocation(_:)), "l")])
        sub("Edit", [mi("Undo", Selector(("undo:")), "z"),
                     mi("Redo", Selector(("redo:")), "z", [.command, .shift]),
                     mi("Cut", #selector(NSText.cut(_:)), "x"),
                     mi("Copy", #selector(NSText.copy(_:)), "c"),
                     mi("Paste", #selector(NSText.paste(_:)), "v"),
                     mi("Select All", #selector(NSText.selectAll(_:)), "a")])
        sub("View", [mi("Reload", #selector(reload(_:)), "r"),
                     mi("Back", #selector(goBack(_:)), "["),
                     mi("Forward", #selector(goForward(_:)), "]"),
                     mi("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        sub("Window", [mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                       mi("Close", #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
