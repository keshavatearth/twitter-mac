import AppKit
import WebKit

/// Headless snapshot mode: proves the filter pipeline against a local HTML fixture
/// without a login or Screen Recording permission.
///
///   TwitterMac shot <input.html> <output.png>
///
/// Loads a local file in an offscreen WKWebView with the same user scripts the live
/// app injects, lets the MutationObserver run, takes a snapshot via
/// WKWebView.takeSnapshot (which renders the view's layer directly — no screen
/// capture), writes a PNG, and exits.
enum Snapshot {
    static func run(input: String, output: String) -> Int32 {
        let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            FileHandle.standardError.write(Data("shot: input not found: \(inputURL.path)\n".utf8))
            return 2
        }

        let runner = SnapshotRunner()
        switch runner.capture(input: inputURL, output: outputURL) {
        case .ok:
            print("wrote \(outputURL.path) (\(runner.scanned) scanned, \(runner.hidden) hidden)")
            return 0
        case .error(let msg):
            FileHandle.standardError.write(Data("shot: \(msg)\n".utf8))
            return 1
        }
    }
}

private final class SnapshotRunner: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var finished = false
    private var errorMessage: String?
    private var webView: WKWebView!
    private var outputURL: URL!
    private var startTime: Date!

    var scanned = 0
    var hidden = 0

    enum Result { case ok, error(String) }

    func capture(input: URL, output: URL) -> Result {
        outputURL = output
        startTime = Date()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "tmac")

        // Same scripts the live app injects, with all filters on.
        let settings = FilterSettings()
        let scripts = UserScripts.makeUserScripts(settingsJSON: settings.jsPayloadJSON)
        scripts.forEach { configuration.userContentController.addUserScript($0) }

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 900),
            configuration: configuration
        )
        webView.navigationDelegate = self

        // Offscreen window so the webview gets a backing layer for snapshotting.
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 900),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView

        webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())

        // Hard timeout so a hung load can't wedge the CLI.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, !self.finished else { return }
            self.errorMessage = self.errorMessage ?? "timeout"
            self.stopApp()
        }

        app.run()

        if let errorMessage { return .error(errorMessage) }
        return .ok
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let the MutationObserver process existing posts + the late-appended ones.
        let elapsed = Date().timeIntervalSince(startTime)
        let wait = max(0.1, 3.0 - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.takeSnapshot()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        errorMessage = error.localizedDescription
        stopApp()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        errorMessage = error.localizedDescription
        stopApp()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "stats" {
            scanned = body["scanned"] as? Int ?? scanned
            hidden = body["hidden"] as? Int ?? hidden
        }
    }

    // MARK: - Snapshot

    private func takeSnapshot() {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: 1000, height: 900)
        config.snapshotWidth = 1000

        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self else { return }
            self.finished = true
            if let error {
                self.errorMessage = error.localizedDescription
                self.stopApp()
                return
            }
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                self.errorMessage = "PNG encoding failed"
                self.stopApp()
                return
            }
            do {
                try png.write(to: self.outputURL, options: .atomic)
            } catch {
                self.errorMessage = "write failed: \(error.localizedDescription)"
            }
            self.stopApp()
        }
    }

    // MARK: - Stop

    private func stopApp() {
        NSApp.stop(nil)
        // Post a dummy event so -[NSApplication run] actually returns.
        if let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 0, data1: 0, data2: 0
        ) {
            NSApp.postEvent(event, atStart: false)
        }
    }
}
