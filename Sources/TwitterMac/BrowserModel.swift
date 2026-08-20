import AppKit
import Combine
import WebKit

/// Owns the single WKWebView, its user scripts, and the native side of the page bridge.
///
/// A singleton on purpose: the SwiftUI `Commands` menus need to reach the same web view
/// the window is displaying, and the view is created once and handed to SwiftUI as-is so
/// a re-render can never tear down the session.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    static let shared = BrowserModel()

    enum Destination: String, CaseIterable {
        case home = "/home"
        case notifications = "/notifications"
        case messages = "/messages"
        case bookmarks = "/i/bookmarks"
        case explore = "/explore"
        case compose = "/compose/post"

        var title: String {
            switch self {
            case .home: return "Home"
            case .notifications: return "Notifications"
            case .messages: return "Messages"
            case .bookmarks: return "Bookmarks"
            case .explore: return "Explore"
            case .compose: return "New Post"
            }
        }
    }

    let settings = FilterSettings()
    let stats = FilterStats()
    private(set) var config = AppConfig.load()
    private(set) lazy var grader = GeminiGrader(config: config)

    let webView: WKWebView

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var pageTitle = "TwitterMac"
    @Published var currentURL: URL?
    @Published var isLoading = false
    @Published var zoom: CGFloat = 1.0
    @Published var scriptsSummary = ""

    private var cancellables = Set<AnyCancellable>()

    private enum DefaultsKey {
        static let zoom = "view.pageZoom"
        static let lastURL = "nav.lastURL"
    }

    /// Hosts kept inside the app. Everything else is a candidate for the default browser
    /// when the user actually clicks it. Note t.co is absent: an outbound link in a tweet
    /// should open in the real browser. It still resolves in-app for redirect chains,
    /// because only `.linkActivated` navigations are intercepted.
    private static let inAppDomains = [
        "x.com", "twitter.com", "twimg.com",
        // Third-party login and bot-check providers used by X's sign-in flow. If these
        // opened in Safari the OAuth callback would land in the wrong app and login
        // would silently fail.
        "google.com", "gstatic.com", "googleusercontent.com", "recaptcha.net",
        "apple.com", "icloud.com",
        "arkoselabs.com", "funcaptcha.com"
    ]

    private override init() {
        let configuration = WKWebViewConfiguration()
        // Default (not .nonPersistent) store: cookies and local storage survive relaunch,
        // which is the whole reason login sticks.
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        if !config.userAgent.isEmpty { webView.customUserAgent = config.userAgent }

        configuration.userContentController.add(self, name: "tmac")

        zoom = CGFloat(UserDefaults.standard.double(forKey: DefaultsKey.zoom) == 0
                       ? 1.0 : UserDefaults.standard.double(forKey: DefaultsKey.zoom))
        webView.pageZoom = zoom

        settings.onChange = { [weak self] in self?.pushSettings() }
        grader.onVerdict = { [weak self] id, blocked in self?.deliverVerdict(id: id, blocked: blocked) }
        grader.onStatus = { [weak self] status in
            self?.stats.llmStatus = status
            if status != nil { NSLog("TwitterMac: LLM status — \(status!)") }
        }

        installUserScripts()
        observeWebView()
    }

    // MARK: - Startup

    func loadInitialPage() {
        webView.load(URLRequest(url: initialURL()))
    }

    private func initialURL() -> URL {
        let fallback = URL(string: "https://x.com/home")!
        guard let saved = UserDefaults.standard.string(forKey: DefaultsKey.lastURL),
              let url = URL(string: saved),
              let host = url.host,
              Self.matches(host: host, domain: "x.com") || Self.matches(host: host, domain: "twitter.com")
        else { return fallback }
        // Never resume into a modal/auth route — those are stateful and resume badly.
        let path = url.path
        if path.hasPrefix("/compose") || path.hasPrefix("/i/flow") || path.hasPrefix("/logout") {
            return fallback
        }
        return url
    }

    private func observeWebView() {
        webView.publisher(for: \.canGoBack).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).assign(to: &$isLoading)
        webView.publisher(for: \.title)
            .map { ($0?.isEmpty == false ? $0! : "TwitterMac") }
            .assign(to: &$pageTitle)
        webView.publisher(for: \.url)
            .sink { [weak self] url in
                self?.currentURL = url
                if let url, let host = url.host, Self.matches(host: host, domain: "x.com") {
                    UserDefaults.standard.set(url.absoluteString, forKey: DefaultsKey.lastURL)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - User scripts

    private func installUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let scripts = UserScripts.makeUserScripts(settingsJSON: settings.jsPayloadJSON)
        scripts.forEach(controller.addUserScript)
        let missing = UserScripts.order.filter { UserScripts.url(for: $0) == nil }
        scriptsSummary = missing.isEmpty
            ? "\(UserScripts.order.count) scripts from \(UserScripts.effectiveDirectory()?.path ?? "?")"
            : "MISSING: \(missing.joined(separator: ", "))"
    }

    /// Toggle changed: refresh the scripts for future loads and patch the live page.
    private func pushSettings() {
        installUserScripts()
        let json = settings.jsPayloadJSON
        webView.evaluateJavaScript("window.__tmac && window.__tmac.applySettings(\(json));")
    }

    /// Filters > Reload Filter Scripts: re-read the JS from disk and reload the page.
    func reloadUserScripts() {
        config = AppConfig.load()
        grader.config = config
        stats.reset()
        stats.llmStatus = nil
        installUserScripts()
        webView.reload()
    }

    // MARK: - Navigation

    func go(_ destination: Destination) {
        guard let url = URL(string: "https://x.com" + destination.rawValue) else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func openCurrentPageInBrowser() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Zoom

    func zoomIn() { setZoom(zoom + 0.1) }
    func zoomOut() { setZoom(zoom - 0.1) }
    func resetZoom() { setZoom(1.0) }

    private func setZoom(_ value: CGFloat) {
        zoom = min(3.0, max(0.5, (value * 100).rounded() / 100))
        webView.pageZoom = zoom
        UserDefaults.standard.set(Double(zoom), forKey: DefaultsKey.zoom)
    }

    // MARK: - Filters

    func revealAllHidden() {
        webView.evaluateJavaScript("window.__tmac && window.__tmac.revealAll();")
    }

    // MARK: - Sign in

    /// Imports x.com cookies from the user's Chrome profile, injects them into the
    /// webview's cookie store, and reloads. The user never types credentials into the
    /// webview — their own Chrome session is the source of truth.
    func signInFromChrome() {
        let importer = ChromeCookieImporter()
        do {
            let result = try importer.importCookies()
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let group = DispatchGroup()
            for cookie in result.cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                self.webView.load(URLRequest(url: URL(string: "https://x.com/home")!))
                self.showAlert(
                    title: "Signed in from Chrome",
                    message: "Imported \(result.cookieCount) cookies from Chrome profile \"\(result.profileName)\". Reloading x.com\u{2026}"
                )
            }
        } catch {
            showAlert(title: "Sign in from Chrome failed", message: error.localizedDescription)
        }
    }

    /// Manual fallback: loads x.com/login in the webview.
    func signInManually() {
        webView.load(URLRequest(url: URL(string: "https://x.com/login")!))
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func deliverVerdict(id: String, blocked: Bool) {
        stats.llmGraded = grader.gradedThisSession
        let payload: [String: Any] = ["id": id, "blocked": blocked, "detail": "graded blocked"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.__tmac && window.__tmac.onVerdict(\(json));")
    }

    // MARK: - Helpers

    static func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private func isInAppHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return Self.inAppDomains.contains { Self.matches(host: host, domain: $0) }
    }

    private func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if let scheme = url.scheme?.lowercased(), scheme != "https", scheme != "http", scheme != "about" {
            // mailto:, itms-apps:, etc. — hand to the system.
            openExternally(url)
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if settings.openLinksExternally,
           isMainFrame,
           navigationAction.navigationType == .linkActivated,
           !isInAppHost(url.host) {
            openExternally(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Attachments and unviewable types become real downloads instead of dead ends.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.pageZoom = zoom
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("TwitterMac: navigation failed — \((error as NSError).localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        NSLog("TwitterMac: load failed — \(ns.localizedDescription)")
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKUIDelegate

extension BrowserModel: WKUIDelegate {
    /// target="_blank" and window.open. Login popups must stay in-app; anything else
    /// obeys the "open links in browser" preference.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if settings.openLinksExternally, !isInAppHost(url.host) {
            openExternally(url)
        } else {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}

// MARK: - WKDownloadDelegate

extension BrowserModel: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var target = downloads.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        var index = 1
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        while FileManager.default.fileExists(atPath: target.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            target = downloads.appendingPathComponent(name)
            index += 1
        }
        completionHandler(target)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("TwitterMac: download failed — \((error as NSError).localizedDescription)")
    }
}

// MARK: - Page bridge

extension BrowserModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "stats":
            stats.scanned = body["scanned"] as? Int ?? stats.scanned
            stats.hidden = body["hidden"] as? Int ?? stats.hidden
            if let reasons = body["byReason"] as? [String: Int] { stats.byReason = reasons }

        case "grade":
            guard settings.llmEnabled,
                  let id = body["id"] as? String,
                  let text = body["text"] as? String,
                  !text.isEmpty
            else { return }
            grader.enqueue(id: id, text: text)

        case "ready":
            if settings.debugLogging { NSLog("TwitterMac: filters ready on \(body["href"] as? String ?? "?")") }

        case "log":
            NSLog("TwitterMac[page]: \(body["message"] as? String ?? "")")

        default:
            break
        }
    }
}
