//
//  GameWebViewController.swift
//  PokeBonk
//
//  The whole app: one full-bleed WKWebView on appassets://appassets.local/index.html.
//
//  Checklist enforced by makeConfiguration():
//    - WKURLSchemeHandler for appassets://             -> bundle site/
//    - bridge.js as WKUserScript at .atDocumentStart  (before main-*.js)
//    - WKWebsiteDataStore.default() (persistent localStorage / IndexedDB)
//    - javaScriptEnabled / allowsContentJavaScript
//    - mediaTypesRequiringUserActionForPlayback = []  (music/sfx/cries autoplay)
//    - allowsInlineMediaPlayback = true
//    - no scrolling, no bounce, no long-press menu, no text selection, no callout
//    - status bar hidden, home indicator auto-hidden, landscape only
//

import ObjectiveC
import UIKit
import WebKit

final class GameWebViewController: UIViewController {

    // MARK: - State

    private(set) var webView: WKWebView!
    private var schemeHandler: AssetSchemeHandler?

    /// True after the first navigation finished; reload() is cheap after that.
    private var didFinishFirstLoad = false
    private var didInstallObservers = false

    // MARK: - Lifecycle

    override func loadView() {
        let root = UIView(frame: UIScreen.main.bounds)
        root.backgroundColor = .black
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view = root

        do {
            let configuration = try makeConfiguration()
            let webView = WKWebView(frame: root.bounds, configuration: configuration)
            webView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                webView.topAnchor.constraint(equalTo: root.topAnchor),
                webView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
            self.webView = webView
            style(webView)
        } catch {
            // site/ missing from the bundle: say so instead of showing black.
            showFatal(error.localizedDescription)
            return
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        applyBlackUnderPageBackground(to: webView)

        let scroll = webView.scrollView
        scroll.isScrollEnabled = false
        scroll.bounces = false
        scroll.bouncesZoom = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.pinchGestureRecognizer?.isEnabled = false

        removeInteractionMenus(in: webView)

        // Keep the 1x1 keyboard field inside the window: UIKit drops first
        // responder for views outside the visible bounds.
        root.addSubview(keyboardField)
        root.bringSubviewToFront(keyboardField)

        installObservers()
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration

    private func makeConfiguration() throws -> WKWebViewConfiguration {
        // Resources are flattened into the bundle root (`site` folder reference in
        // project.yml), so the site is Bundle.main/site. The second candidate covers
        // build systems that keep the Resources/ parent directory.
        let candidates = [
            Bundle.main.url(forResource: AppScheme.siteDirectoryName, withExtension: nil),
            Bundle.main.resourceURL?.appendingPathComponent(AppScheme.siteDirectoryName)
        ].compactMap { $0 }
        guard let siteRoot = candidates.first(where: { (try? $0.checkResourceIsReachable()) == true })
        else {
            throw NSError(domain: "PokeBonk", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "site/ is missing from the app bundle.\n" +
                    "The release site.zip was not unpacked into Resources/site."
            ])
        }

        let config = WKWebViewConfiguration()

        // --- Storage: .default() is the ONLY persistent store. The non-persistent
        // variant drops localStorage / IndexedDB on process death (lost saves).
        config.websiteDataStore = .default()

        // --- Custom scheme -> bundle
        let handler = AssetSchemeHandler(siteRoot: siteRoot)
        self.schemeHandler = handler
        config.setURLSchemeHandler(handler, forURLScheme: AppScheme.scheme)

        // --- User scripts. Order matters: bridge.js first (it patches fetch and must
        // see the pristine window), then our glue, then the CSS override. All three
        // run at document start, i.e. before any game module executes.
        let controller = config.userContentController
        // Diagnostics first: it must be installed before any page script so that
        // module-load failures and early exceptions are captured.
        controller.addUserScript(Diagnostics.script())
        // bridge.js second; it exports its router in window.__pbInternals.
        if let bridge = WebScripts.bridgeScript() {
            controller.addUserScript(bridge)
        }
        // ApiRouter last => outermost fetch. It dispatches using the exported
        // router and plain string paths, so it does not depend on WebKit's
        // origin/host values for a custom URL scheme.
        controller.addUserScript(ApiRouter.script())
        controller.addUserScript(WebScripts.bootstrapScript())
        controller.addUserScript(WebScripts.styleScript())
        // Perf tier: seed profile defaults BEFORE the game reads them, so a cold
        // install does not boot on quality:'high'.
        controller.addUserScript(PerfTuning.bootstrapScript())
        // In-game switch panel (needs document.body, hence .atDocumentEnd).
        controller.addUserScript(PerfPanel.script())
        controller.add(WeakScriptMessageHandler(), name: "pbLog")
        controller.add(DiagMessageHandler(), name: Diagnostics.handlerName)
        controller.add(KeyboardScriptMessageHandler(owner: self), name: "pbKeyboard")

        // --- JavaScript: deprecated on iOS 15 but still honoured by the 15.0
        // runtime; the live switch is WKWebpagePreferences (see navigation delegate).
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // --- Media
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = false
        config.allowsPictureInPictureMediaPlayback = false
        if #available(iOS 15.4, *) {
            config.preferences.isElementFullscreenEnabled = false
        }

        // --- Misc: no network host is ever contacted.
        config.preferences.isFraudulentWebsiteWarningEnabled = false

        return config
    }

    /// `underPageBackgroundColor` is iOS 15+, but the selector is resolved at
    /// runtime so the same source also compiles on older SDKs (CI matrix).
    private func applyBlackUnderPageBackground(to webView: WKWebView) {
        let selector = NSSelectorFromString("setUnderPageBackgroundColor:")
        if webView.responds(to: selector), let fn = webView.method(for: selector) {
            typealias SetColor = @convention(c) (AnyObject, Selector, UIColor) -> Void
            unsafeBitCast(fn, to: SetColor.self)(webView, selector, UIColor.black)
        }
    }

    private func style(_ webView: WKWebView) {
        // iOS 16.4+: Web Inspector off in release; no private API involved.
        if #available(iOS 16.4, *) {
            webView.isInspectable = false
        }
        if #available(iOS 16.0, *) {
            // `WKWebView.preferences` was removed in the Xcode 16 SDK; the same
            // property lives on the configuration.
            webView.configuration.preferences.isTextInteractionEnabled = false
        }
    }

    /// Recursively disable long-press / double-tap recognizers WebKit installs.
    /// Public API only: UIGestureRecognizer.isEnabled / UITextView.isSelectable.
    private func removeInteractionMenus(in view: UIView) {
        if let textView = view as? UITextView {
            // Still accepts taps, but shows no loupe / interaction menu.
            textView.isSelectable = false
        }
        view.gestureRecognizers?.forEach { recognizer in
            if let long = recognizer as? UILongPressGestureRecognizer {
                long.isEnabled = false            // touch callout / link preview
            } else if let tap = recognizer as? UITapGestureRecognizer,
                      tap.numberOfTapsRequired >= 2 {
                tap.isEnabled = false             // double-tap zoom / word select
            }
        }
        view.subviews.forEach { removeInteractionMenus(in: $0) }
    }

    // MARK: - Loading

    func reload() {
        guard webView != nil else { return }
        if didFinishFirstLoad {
            webView.reload()
        } else {
            webView.load(URLRequest(url: AppScheme.indexURL,
                                    cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 30))
        }
    }

    // MARK: - Native keyboard relay (the only text input: the account name)

    /// Raw JS that focuses the page element the shell mirrors keystrokes into.
    private var keyboardFocusScriptForID = ""
    private var keyboardCurrentID = ""

    private lazy var keyboardField: UITextField = {
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        field.alpha = 0.02          // must stay "visible" enough to become first responder
        field.isUserInteractionEnabled = false
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .go
        field.textContentType = .username
        field.delegate = self
        field.addTarget(self, action: #selector(keyboardChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(keyboardReturn), for: .editingDidEndOnExit)
        return field
    }()

    private func focusScript(for id: String) -> String {
        "var el=document.getElementById(\(WebScripts.jsStringLiteral(id)));" +
        "if(!el){return;}el.focus();"
    }

    /// pbKeyboard message handler -> the page wants the system keyboard.
    func keyboardFocus(id: String, value: String?) {
        // Repeated focusin on the same element must not reset the text.
        if keyboardCurrentID == id, keyboardField.isFirstResponder { return }
        keyboardCurrentID = id
        keyboardFocusScriptForID = focusScript(for: id)
        keyboardField.text = value ?? ""
        keyboardField.isUserInteractionEnabled = true
        _ = keyboardField.becomeFirstResponder()
    }

    func keyboardBlur() {
        // The page element already blurred (that is why we got here); drop state.
        keyboardCurrentID = ""
        keyboardFocusScriptForID = ""
        keyboardField.text = ""
        keyboardField.isUserInteractionEnabled = false
        keyboardField.resignFirstResponder()
    }

    @objc private func keyboardChanged() {
        guard !keyboardCurrentID.isEmpty else { return }
        let value = WebScripts.jsStringLiteral(keyboardField.text ?? "")
        let script = keyboardFocusScriptForID +
            "el.value=\(value);" +
            "el.dispatchEvent(new Event('input',{bubbles:true}));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    @objc private func keyboardReturn() {
        guard !keyboardCurrentID.isEmpty else { return }
        let script = keyboardFocusScriptForID +
            "el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));"
        webView.evaluateJavaScript(script, completionHandler: nil)
        keyboardBlur()
    }

    // MARK: - Persistence hooks (SceneDelegate)

    /// Give the page a last chance to flush, then let the data store write out.
    func persistWebState() {
        guard webView != nil else { return }
        webView.evaluateJavaScript(
            "try{window.dispatchEvent(new Event('pagehide'));}catch(e){}",
            completionHandler: nil)
        // Spins up the data store's cookie/SQLite writers before suspension.
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { _ in }
    }

    func restoreWebState() {
        // iOS keeps (or suspends) the WebProcess; only reload if it was jetsammed.
        guard webView != nil, didFinishFirstLoad else { return }
        if webView.url == nil {
            didFinishFirstLoad = false
            reload()
        }
    }

    func setPageVisible(_ visible: Bool) {
        guard webView != nil else { return }
        webView.evaluateJavaScript(
            "try{window.__pbNativeVisible=\(visible ? "true" : "false")}catch(e){}",
            completionHandler: nil)
    }

    // MARK: - Observers

    private func installObservers() {
        guard !didInstallObservers else { return }
        didInstallObservers = true
        // Process termination is a WKNavigationDelegate callback
        // (webViewWebContentProcessDidTerminate); the old
        // .WKWebViewWebProcessDidCrash notification constant no longer exists in
        // the Xcode 16 SDK, so nothing is registered here.

        // Low Power Mode: drop to the 省电 tier while the system flag is on and
        // restore the user's own choice when it clears.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(lowPowerModeChanged(_:)),
                                               name: .NSProcessInfoPowerStateDidChange,
                                               object: nil)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            autoLowPower = true
        }
    }

    /// True while Low Power Mode forced the 省电 tier.
    private var autoLowPower = false

    @objc private func lowPowerModeChanged(_ note: Notification) {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard enabled != autoLowPower else { return }
        autoLowPower = enabled
        PerfTuning.lowPowerModeChanged(enabled: enabled) { [weak self] in self?.webView }
    }

    private func webProcessTerminated() {
        // GPU/JS memory pressure can kill the WebProcess. localStorage already lives
        // in the persistent data store; the game restores from its own autosave.
        NSLog("[PokeBonk] WebProcess terminated, reloading")
        didFinishFirstLoad = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Chrome

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    // MARK: - Helpers

    private func showFatal(_ message: String) {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        label.text = "PokeBonk\n\n" + message
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8)
        ])
    }
}

// MARK: - WKNavigationDelegate

extension GameWebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        // Only appassets://appassets.local may load. Everything else is dropped:
        // the app is offline by design (an <a> to Discord is simply ignored).
        guard url.scheme?.lowercased() == AppScheme.scheme,
              url.host?.lowercased() == AppScheme.host.lowercased() else {
            decisionHandler(.cancel, preferences)
            return
        }
        preferences.allowsContentJavaScript = true
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Make the JS switch explicit for every committed document.
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishFirstLoad = true
        removeInteractionMenus(in: webView)
    }

    /// Xcode 16 SDK: this is the supported replacement for the removed
    /// .WKWebViewWebProcessDidCrash notification.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webProcessTerminated()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[PokeBonk] navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        NSLog("[PokeBonk] provisional navigation failed: \(error)")
    }
}

// MARK: - WKUIDelegate

extension GameWebViewController: WKUIDelegate {

    /// window.open() / target=_blank: never spawn additional web views.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    @available(iOS 13.0, *)
    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - JS -> native log bridge

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        NSLog("[PokeBonk/js] \(message.body)")
    }
}

// MARK: - Keyboard relay

/// Injected at document start (see WebScripts.bootstrapScript). When the page
/// focuses a text input it asks the shell to raise the system keyboard; the shell
/// echoes keystrokes into the element's `value` and fires `input`, which is what the
/// account form listens to.
private final class KeyboardScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: GameWebViewController?
    init(owner: GameWebViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "focus":
            guard let id = body["id"] as? String, !id.isEmpty else { return }
            owner?.keyboardFocus(id: id, value: body["value"] as? String)
        case "blur":
            owner?.keyboardBlur()
        default:
            break
        }
    }
}

extension GameWebViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        keyboardReturn()
        return false
    }
}

// MARK: - Diagnostics sink

/// Receives `{seq, kind, text}` messages from Diagnostics.swift and appends them
/// to Documents/pokebonk.log. Nothing is drawn on screen.
final class DiagMessageHandler: NSObject, WKScriptMessageHandler {

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let kind = (body["kind"] as? String) ?? "?"
        let text = (body["text"] as? String) ?? ""
        LogStore.shared.append(kind: kind, text: text)
    }
}
